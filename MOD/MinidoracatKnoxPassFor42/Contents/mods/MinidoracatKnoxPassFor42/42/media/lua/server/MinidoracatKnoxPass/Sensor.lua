-- 伺服器偵測：有人駕駛、車上裝著已登記且有電的感應盒，靠近（含行進預測）已登記的大門就開門；
-- 車和拖車整台通過門口後就不再撐住門，範圍內沒有撐門的車滿延遲秒數，把 Knox Pass 開的門關上並鎖回去。
-- 感應距離與關門延遲每扇門可以不同（擁有者設定、夾在沙盒上下限內：KP.gateRange／KP.gateDelay）。
-- 專用伺服器也會觸發 OnTick（GameServer.java:840,1020 → IngameState.java:1520,1563）；
-- OnPlayerUpdate 在伺服器不觸發（IsoPlayer.java:2234-2286），所以走 OnTick＋玩家清單。
if isClient() then return end
require "MinidoracatKnoxPass/Core"
require "MinidoracatKnoxPass/Gates"
require "MinidoracatKnoxPass/Ledger"
local KP = MinidoracatKnoxPass
local G = KP.Gates
local L = KP.Ledger

local S = {}
KP.Sensor = S

S.SCAN_MS = 250        -- 掃描間隔
S.RETRY_MS = 2000      -- 關不上（擋住、沒載入、沒人可當開關者）時多久再試
S.FAIL_MS = 3000       -- 開不了（沒電、被釘板、被擋）時多久再試
S.MISSING_MS = 30000   -- 格子載入但門不在，持續多久才當作門被拆掉、刪除記錄
S.PASSES_MS = 5000     -- 已授權大門清單沒變動時，多久補推一次給駕駛
S.WALK_MS = 5000       -- 步行開門至少開這麼久才開始算延遲（延遲設 0 時人也走得過去）
S.RELOCK_MS = 5000     -- 多久替關著的上鎖門補一次鎖（S.relock）

-- gateKey → { presence, retryAt, failAt, missingSince, by, holdUntil, cars }；
-- cars＝這扇門範圍內每台登記車的通過紀錄（車輛 runtime id → { from, passed }），只在記憶體
local runtime = {}
local tracks = {}      -- 車輛 runtime id → { x, y, t, vx, vy }（算行進速度，平滑過）
local lastScan = 0
local lastRelock = 0

local function rt(key)
    local r = runtime[key]
    if not r then
        r = { presence = 0, retryAt = 0, failAt = 0 }
        runtime[key] = r
    end
    return r
end

function S.forget(key)
    runtime[key] = nil
end

-- 有玩家站在門口格或門另一側那格就不關（引擎只檢查車與固體物件，IsoDoor.java:2734-2767）。殭屍不擋：關門不會
-- 推動殭屍，它留在原本那一側；擋的話，跟著車進門的殭屍會讓門一直開著（2026-10-07 使用者決定）。
-- 雙開門打開時第 2、3 片會移到別格重建（IsoDoor.java:2855-2922），門口要用「關著時」各片的格子：
-- 開門前記進帳本（rec.doorway），重啟後照樣有
local function doorwayOf(pieces)
    local out = {}
    for i = 1, #pieces do
        local p = pieces[i]
        local sq = p:getSquare()
        local north = nil
        if p.getNorth ~= nil then north = p:getNorth() end
        out[i] = { x = sq:getX(), y = sq:getY(), z = sq:getZ(), n = north }
    end
    return out
end

local function hasPlayer(x, y, z)
    local sq = getCell():getGridSquare(x, y, z)
    if not sq then return false end
    local list = sq:getMovingObjects()
    for i = 0, list:size() - 1 do
        if instanceof(list:get(i), "IsoPlayer") then return true end
    end
    return false
end

local function doorwayOccupied(rec, pieces)
    local spots = rec.doorway or doorwayOf(pieces)
    for i = 1, #spots do
        local s = spots[i]
        if hasPlayer(s.x, s.y, s.z) then return true end
        if s.n == true and hasPlayer(s.x, s.y - 1, s.z) then return true end
        if s.n == false and hasPlayer(s.x - 1, s.y, s.z) then return true end
    end
    return false
end

-- 開關門要傳真的 IsoPlayer（IsoDoor.java:1501,1593；IsoThumpable.java:1297,1310,1313）。
-- 優先用觸發的人（還在線上），否則離門最近的在線玩家
local function actor(r, rec)
    local best, bestD = nil, nil
    KP.eachPlayer(function(p)
        if p == r.by then
            best, bestD = p, -1
        elseif bestD ~= -1 then
            local d = math.abs(p:getX() - rec.cx) + math.abs(p:getY() - rec.cy)
            if not bestD or d < bestD then best, bestD = p, d end
        end
    end)
    return best
end

-- 門被拆掉：格子載入了卻找不到門，持續一段時間才刪記錄（讀頭跟著門一起沒了）
local function noteMissing(key, rec, now)
    local r = rt(key)
    r.missingSince = r.missingSince or now
    if now - r.missingSince >= S.MISSING_MS then
        KP.log("gate missing, record removed key=" .. key .. " owner=" .. tostring(rec.owner))
        L.remove(key)
        S.forget(key)
    end
end

local function drain(tag, part, vehicle)
    local amount = KP.DRAIN_PER_OPEN * KP.drainScale()
    if not tag or amount <= 0 then return end
    -- setCurrentUsesFloat 量化到 UseDelta 一格（DrainableComboItem.java:83-87、getUseDelta :458）：
    -- 耗電倍率低於一格時至少扣一格，否則整筆被吃掉變成免費
    KP.setCharge(tag, KP.charge(tag) - math.max(amount, tag:getUseDelta()))
    if part and vehicle then
        vehicle:transmitPartUsedDelta(part)
    elseif isServer() then
        sendItemStats(tag)
    end
end

-- 門關好之後：鎖回 Knox Pass 門鎖或原本的鑰匙鎖，清掉開著的狀態
local function settleClosed(key, rec, adapter, anchor)
    if G.supportsLock(adapter) and (rec.lock or rec.keyed) then
        G.lock(adapter, anchor, G.pieces(adapter, anchor), rec.lock, rec.keyed)
    end
    rec.keyed, rec.doorway = nil, nil
    L.setOpen(key, rec, false)
end

-- 開門。who 是觸發的玩家；tag/part/vehicle 是要扣電的感應盒（步行開門時 part/vehicle 為 nil）。
-- 回傳 true 或 false, 原因
function S.open(key, rec, who, tag, part, vehicle, now)
    local r = rt(key)
    local adapter, anchor = G.findAt(rec)
    if adapter == nil then return false, "NotLoaded" end
    if adapter == false then
        noteMissing(key, rec, now)
        return false, "NoGate"
    end
    r.missingSince = nil
    r.presence, r.by = now, who
    if not vehicle then r.holdUntil = now + S.WALK_MS end   -- 步行開門：人還要走到門口，延遲再短也先開著
    -- 記下載著這顆感應盒經過的車（管理視窗的登記清單顯示用；感應盒換車後在這裡跟著改）。
    -- 門已經開著時也記，步行開門沒有車就不動
    local info = tag and vehicle and rec.tags[tag:getID()]
    if info then info.script = vehicle:getScriptName() end
    -- 開著：Knox Pass 開的就延長；別人用手開著的不接手，也不替它關
    if G.isOpen(adapter, anchor) then return true end
    -- Knox Pass 開的門被人用手關上了：先照關好的規則鎖回，再重新開
    if rec.open then settleClosed(key, rec, adapter, anchor) end
    if now < r.failAt then return false, "Busy" end
    local pieces = G.pieces(adapter, anchor)
    if KP.sandbox("RequirePower") == true and not G.powered(pieces) then
        r.failAt = now + S.FAIL_MS
        return false, "NoPower"
    end
    rec.doorway = doorwayOf(pieces)   -- 門還關著：記下各片的門口格
    local keyed = nil
    if G.supportsLock(adapter) then keyed = G.unlock(adapter, anchor, pieces) end
    if not G.setOpen(adapter, anchor, true, who) then
        if G.supportsLock(adapter) then G.lock(adapter, anchor, pieces, rec.lock, keyed) end
        r.failAt = now + S.FAIL_MS
        return false, "Blocked"
    end
    rec.keyed = keyed or nil
    L.setOpen(key, rec, true)
    drain(tag, part, vehicle)
    if tag and rec.tags[tag:getID()] then rec.tags[tag:getID()].last = getGameTime():getWorldAgeHours() end
    return true
end

-- 關門並鎖回。who＝關門的玩家（沒給就找在場的玩家，actor）。回傳 true 或 false, 原因：
-- NotLoaded（格子沒載入）、NoGate（門不見了，已記下）、Blocked（門口有玩家、引擎判定擋住、沒有玩家可當開關者）
local function closeNow(key, rec, now, who)
    local r = rt(key)
    local adapter, anchor = G.findAt(rec)
    if adapter == nil then return false, "NotLoaded" end
    if adapter == false then
        noteMissing(key, rec, now)
        return false, "NoGate"
    end
    r.missingSince = nil
    if not G.isOpen(adapter, anchor) then
        settleClosed(key, rec, adapter, anchor)   -- 有人先用手關上了
        return true
    end
    local pieces = G.pieces(adapter, anchor)
    who = who or actor(r, rec)
    if not who or G.isBlocked(adapter, anchor) or doorwayOccupied(rec, pieces)
        or not G.setOpen(adapter, anchor, false, who) then
        return false, "Blocked"
    end
    settleClosed(key, rec, adapter, anchor)
    return true
end

-- 這一輪掃描剛被撐住（presence＝now）的門不判關門：延遲 0 時，否則同一個 tick 開了又關（r3-mp 1007d 實踩）
local function tryClose(key, rec, now, delayMs)
    local r = rt(key)
    if r.presence == now or now - r.presence < delayMs or now < r.retryAt or now < (r.holdUntil or 0) then return end
    local ok, why = closeNow(key, rec, now)
    if not ok and why ~= "NoGate" then r.retryAt = now + S.RETRY_MS end
end

-- 右鍵「用 Knox Pass 關門」：門被別人打開（會開門的殭屍、有鑰匙的人）時，Knox Pass 門鎖讓玩家用手關不了
-- （couldBeOpen 看 CustomLock，ISWorldObjectContextMenuLogic.java:2296-2301），這是出路。關好照門鎖設定鎖回
function S.close(key, rec, who, now)
    local r = rt(key)
    r.presence, r.holdUntil = 0, nil   -- 不再替剛才的車或步行開門撐著；登記車還在範圍內的話下一輪會再開
    return closeNow(key, rec, now, who)
end

-- 家族 AutoDrive 在伺服器上的自駕租約（MinidoracatAutoDriveFor42 的 shared/MDAD.lua `isAutoUsageActive`：
-- 駕駛、引擎、電瓶都符合且 heartbeat 未過期）。沒裝 AutoDrive 時 MDAD 不存在；對方函式出錯就當一般車
local function autoDriving(v)
    local fn = type(MDAD) == "table" and MDAD.isAutoUsageActive
    if type(fn) ~= "function" then return false end
    local ok, yes = pcall(fn, v)
    return ok and yes == true
end

-- AutoDrive 把關著的門當硬障礙，一看到就依 blocked 接近包絡減速（停止線前壓到 20 km/h）；它看得到多遠受
-- 玩家端載入範圍限制（1080p 約 72 格，IsoChunkMap.java:106-120），而玩家端的區塊是伺服器先載入再送過去的
-- （ServerMap.java:251-271 以 64 格為單位往外取整），所以伺服器一載入門所在的格子就開，門會搶在它看到之前打開。
-- 判定用夾角不用射線：門在車頭朝向左右 12° 內、ahead 格內就算正要開過去；80 格外車頭偏幾度
-- （換車道、彎道前段、位置抖動）射線就會擦過感應範圍。看車頭朝向不看移動方向：自駕車要是沒趕上開門，
-- 會停在門前約 10 公尺（AutoDrive BLOCK_STOP_DIST）等，那裡已在感應距離外，停著也要替它開
local AHEAD_COS = 0.978   -- cos 12°

local function headingAt(rec, x, y, fx, fy, ahead)
    local dx, dy = rec.cx - x, rec.cy - y
    local dSq = dx * dx + dy * dy
    if dSq > ahead * ahead then return false end
    local dot = dx * fx + dy * fy
    return dot > 0 and dot * dot >= dSq * AHEAD_COS * AHEAD_COS
end

-- 車頭朝向的單位向量（世界 x、y）；伺服器上的車輛姿態由駕駛的客戶端回報
local function facing(v)
    local f = BaseVehicle.allocVector3f()
    v:getForwardVector(f)
    local fx, fy = f:x(), f:z()
    BaseVehicle.releaseVector3f(f)
    local n = math.sqrt(fx * fx + fy * fy)
    if n < 1e-6 then return nil end
    return fx / n, fy / n
end

-- 推送給駕駛：他這顆感應盒登記了哪些大門（客戶端 KnoxPassAPI.willOpenFor 用，讓 AutoDrive 事先知道哪扇門會開）。
-- 換了感應盒或帳本版本變了就馬上推，平常每 PASSES_MS 補推一次（重連、封包遺失會自己好）。
-- 只告訴駕駛他自己的感應盒能開的門，別人的登記不外流
local pushed = {}   -- 使用者名稱 → { tag, ver, at }
local function pushPasses(p, id, keys, now)
    local name = p:getUsername() or "?"
    local last = pushed[name]
    local ver = L.version()
    if last and last.tag == id and last.ver == ver and now - last.at < S.PASSES_MS then return end
    if not last then
        last = {}
        pushed[name] = last
    end
    last.tag, last.ver, last.at = id, ver, now
    local list = {}
    for key in pairs(keys or {}) do list[#list + 1] = key end
    if KP.reply then KP.reply(p, "passes", { tag = id, keys = list }) end
end

-- ── 整台通過就不再撐門 ──────────────────────────────────────────────────
-- 門線＝帳本 key 的錨點那條邊（G.key：…N＝錨點格北邊 y = rec.y，…W＝西邊 x = rec.x），整組門片都在同一條線上；
-- 回傳 -1／1。其他 MOD 的門沒有 getNorth（key 沒有 N／W）回 nil，那些門照舊只看範圍與延遲
local function sideOf(rec, x, y)
    local edge = string.sub(rec.key, -1)
    if edge == "N" then return y < rec.y and -1 or 1 end
    if edge == "W" then return x < rec.x and -1 or 1 end
    return nil
end

-- 車身壓到門口格（各片關著時的格子與門線另一側那格，rec.doorway）：引擎用車身多邊形判斷（BaseVehicle.java:5748-5760）
local function onDoorway(rec, c)
    for _, s in ipairs(rec.doorway or {}) do
        if c:isIntersectingSquare(s.x, s.y, s.z)
            or c:isIntersectingSquare(s.x - (s.n and 0 or 1), s.y - (s.n and 1 or 0), s.z) then
            return true
        end
    end
    return false
end

-- 整台通過：車和它拖的車（getVehicleTowing；原版掛拖車在伺服器上建立這個連結，server/Vehicles/VehicleCommands.lua:410）
-- 的中心都離開原本那一側，而且都沒壓到門口格
local function cleared(rec, v, from)
    for _, c in ipairs({ v, v:getVehicleTowing() }) do   -- 沒拖車時只看車
        if sideOf(rec, c:getX(), c:getY()) == from or onDoorway(rec, c) then return false end
    end
    return true
end

-- 這台車還撐著這扇門嗎：第一次在範圍內看到時記下它在門線哪一側，整台通過到另一側之後就不再撐（門照延遲關）；
-- 要掉頭朝門開回來才重新算一趟：車或拖車往前看 lead 秒（至少 1 秒）會回到原本那一側。倒車時拖車在前，只看車心的話
-- 拖車會先頂到關著的門（r3-mp 1007d 實踩），拖車跟著車走，用車的速度推。出了範圍就忘掉（scanDriver）。
-- 門關著時 rec.doorway 是 nil，只看門線，通過的車停在門內不會讓門反覆開關
local function holds(key, rec, v, vx, vy, lead)
    local side = sideOf(rec, v:getX(), v:getY())
    if not side then return true end
    local r = rt(key)
    r.cars = r.cars or {}
    local id = v:getId()
    local e = r.cars[id]
    if not e then
        r.cars[id] = { from = side }
        return true
    end
    if not e.passed then
        e.passed = cleared(rec, v, e.from)
        return not e.passed
    end
    local t = math.max(lead, 1)
    for _, c in ipairs({ v, v:getVehicleTowing() }) do
        if sideOf(rec, c:getX() + vx * t, c:getY() + vy * t) == e.from then
            r.cars[id] = { from = side }
            return true
        end
    end
    return false
end

local function scanDriver(p, gates, now, lead, ahead)
    local v = p:getVehicle()
    if not v or v:getDriver() ~= p then return end
    local tag, part = KP.vehicleTag(v)
    if not tag then return end
    local keys = L.gatesForTag(tag:getID())
    pushPasses(p, tag:getID(), keys, now)
    if not keys or KP.charge(tag) <= 0 then return end
    local x, y, z = v:getX(), v:getY(), v:getZ()
    local id = v:getId()
    local tr = tracks[id]
    if not tr then
        tr = { vx = 0, vy = 0 }
        tracks[id] = tr
    elseif now > tr.t and now - tr.t < 2000 then
        -- 伺服器收到的車輛位置是一批一批到的，單次位置差忽快忽慢、方向也抖：取一半新值做平滑
        local dt = (now - tr.t) / 1000
        tr.vx = (tr.vx + (x - tr.x) / dt) * 0.5
        tr.vy = (tr.vy + (y - tr.y) / dt) * 0.5
    else
        tr.vx, tr.vy = 0, 0
    end
    tr.x, tr.y, tr.t = x, y, now
    local vx, vy = tr.vx, tr.vy
    local fx, fy = nil, nil
    if ahead > 0 and autoDriving(v) then fx, fy = facing(v) end
    -- 停著就是圓形範圍；行進中把「現在位置→lead 秒後位置」這段線段拿去量距離（往遠離大門的方向不延伸）。
    -- 感應距離每扇門自己的（KP.gateRange）
    local ax, ay = x + vx * lead, y + vy * lead
    for key in pairs(keys) do
        local rec = gates[key]
        if rec and math.abs(rec.z - z) < 1 then
            local range = KP.gateRange(rec)
            if KP.segDistSq(rec.cx, rec.cy, x, y, ax, ay) <= range * range
                or (fx and headingAt(rec, x, y, fx, fy, ahead)) then
                if holds(key, rec, v, vx, vy, lead) then S.open(key, rec, p, tag, part, v, now) end
            elseif runtime[key] and runtime[key].cars then
                runtime[key].cars[id] = nil
            end
        end
    end
end

-- 關著的 Knox Pass 上鎖門補回鎖：引擎會在別的路徑清掉 locked（可跨越的柵欄門有人試開、有鑰匙的人或管理員用手開關，
-- IsoDoor.java:1507-1520、1562-1565），會開門的殭屍就又開得了（Gates.lua IsoDoor 段）。舊存檔只有 CustomLock 的門也在這裡補上。
-- G.lock 已是該狀態就不傳送；門開著（有人在用、或 Knox Pass 開著）不動。只看已載入的格，門數是全伺服器登記的大門數
function S.relock(gates)
    for _, rec in pairs(gates) do
        if rec.lock and not rec.open then
            local adapter, anchor = G.findAt(rec)
            if adapter and G.supportsLock(adapter) and not G.isOpen(adapter, anchor) then
                G.lock(adapter, anchor, G.pieces(adapter, anchor), true, nil)
            end
        end
    end
end

function S.tick()
    local now = getTimestampMs()
    if now - lastScan < S.SCAN_MS then return end
    lastScan = now
    local gates = L.gates()
    if not gates then return end
    local lead = tonumber(KP.sandbox("LeadSeconds")) or 0
    local ahead = tonumber(KP.sandbox("AutoDriveAhead")) or 0
    KP.eachPlayer(function(p) scanDriver(p, gates, now, lead, ahead) end)
    for key in pairs(L.openKeys()) do
        local rec = gates[key]
        if rec then tryClose(key, rec, now, KP.gateDelay(rec) * 1000) end
    end
    if now - lastRelock >= S.RELOCK_MS then
        lastRelock = now
        S.relock(gates)
    end
end

Events.OnTick.Add(S.tick)

-- 伺服器剛載入有讀頭大門的 chunk（ReaderPost.lua 的 LoadChunk）：下一個 tick 就掃描，不等 250 ms 節流。
-- 自駕車看得到的區塊是伺服器載入後才送過去的，越早掃描，它就越可能一開始就看到開著的門。
-- 只歸零節流、不直接開門：雙開門的門片可能跨到還沒載入的相鄰 chunk，這時開門重建會出錯
function S.wake()
    lastScan = 0
end
