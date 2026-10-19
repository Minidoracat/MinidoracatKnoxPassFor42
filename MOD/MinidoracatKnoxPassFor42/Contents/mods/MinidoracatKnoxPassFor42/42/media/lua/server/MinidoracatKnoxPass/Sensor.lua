-- 伺服器偵測：有人駕駛、車上裝著已登記且有電的感應盒（或駕駛戴著已登記、有作用的地圖手錶模組），車或它拖著的拖車
-- 靠近（含行進預測）已登記的大門就開門；戴著已登記模組的人走向門線也開（scanWalker）。
-- 車和拖車整台通過門口後就不再撐住門，範圍內沒有撐門的車滿延遲秒數，把 Knox Pass 開的門關上並鎖回去。
-- 感應距離與關門延遲每扇門可以不同（擁有者設定、夾在沙盒上下限內：KP.gateRange／KP.gateDelay）。
-- 「不會被破壞」的門也在這裡墊高耐久（下方「不會被破壞」段）。
-- 專用伺服器也會觸發 OnTick（GameServer.java:840,1020 → IngameState.java:1520,1563）；
-- OnPlayerUpdate 在伺服器不觸發（IsoPlayer.java:2234-2286），所以走 OnTick＋玩家清單。
if isClient() then return end
require "MinidoracatKnoxPass/Core"
require "MinidoracatKnoxPass/Gates"
require "MinidoracatKnoxPass/Ledger"
require "MinidoracatKnoxPass/Watch"
require "Moveables/ISMoveableSpriteProps"
local KP = MinidoracatKnoxPass
local G = KP.Gates
local L = KP.Ledger

local S = {}
KP.Sensor = S

S.SCAN_MS = 250        -- 掃描間隔
S.RETRY_MS = 2000      -- 關不上（擋住、沒載入、沒人可當開關者）時多久再試
S.FAIL_MS = 3000       -- 開不了（沒電、被釘板、被擋）時多久再試
S.MISSING_MS = 30000   -- 格子載入但門不在，持續多久才當作門被拆掉、刪除記錄
S.PASSES_MS = 5000     -- 已授權大門清單沒變動時，多久補推一次給本人
S.WALK_MS = 5000       -- 右鍵開門至少開這麼久才開始算延遲（人還要走到門口；延遲設 0 時人也走得過去）
S.RELOCK_MS = 5000     -- 多久替關著的上鎖門補一次鎖（S.relock）、核對一次室內判定（S.syncRegions）與耐久（S.shieldAll）

-- gateKey → { presence, retryAt, failAt, missingSince, by, holdUntil, cars }；
-- cars＝這扇門範圍內每台登記車的通過紀錄（車輛 runtime id → { from, passed }），只在記憶體
local runtime = {}
local tracks = {}      -- 車輛 runtime id → { x, y, t, vx, vy }（算行進速度，平滑過）
local walkers = {}     -- 戴模組走路的人：使用者名稱 → { x, y, t, vx, vy }（同上）
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

-- 門關好之後：鎖回 Knox Pass 門鎖或原本的鑰匙鎖，清掉開著的狀態。門開著時擁有者拿掉了門鎖（Server.lua H.lock 記
-- rec.unlockOnClose），這時才拿：車庫門鏈開著時仍上鎖（Gates.lua setGarageOpen），開著改鎖的話，客戶端回送的「開著」
-- 晚到時會把剛關上的門打開
local function settleClosed(key, rec, adapter, anchor)
    if G.supportsLock(adapter) then
        local pieces = G.pieces(adapter, anchor)
        if rec.unlockOnClose then G.unlockKnox(adapter, anchor, pieces) end
        if rec.lock or rec.keyed then G.lock(adapter, anchor, pieces, rec.lock, rec.keyed) end
    end
    rec.keyed, rec.doorway, rec.unlockOnClose = nil, nil, nil
    L.setOpen(key, rec, false)
end

-- 開門。who 是觸發的玩家；tag/part/vehicle 是要扣電的感應盒（沒有感應盒時 tag/part 為 nil）。
-- holdMs＝右鍵開門先撐著多久（人還要走到門口）；感應（車、手錶）每輪都會撐門，不留。回傳 true 或 false, 原因
function S.open(key, rec, who, tag, part, vehicle, now, holdMs)
    local r = rt(key)
    local adapter, anchor = G.findAt(rec)
    if adapter == nil then return false, "NotLoaded" end
    if adapter == false then
        noteMissing(key, rec, now)
        return false, "NoGate"
    end
    r.missingSince = nil
    r.presence, r.by = now, who
    if holdMs then r.holdUntil = now + holdMs end
    -- 記下載著這顆感應盒經過的車（管理視窗的登記清單顯示用；感應盒換車後在這裡跟著改）。
    -- 門已經開著時也記，步行開門沒有車就不動
    local info = tag and vehicle and rec.tags[tag:getID()]
    if info then info.script = vehicle:getScriptName() end
    -- 開著：Knox Pass 開的就延長；別人用手開著的不接手，也不替它關
    if G.isOpen(adapter, anchor) then return true end
    -- Knox Pass 開的門被人用手關上了（rec.open 卻關著）：直接重開，原本的鎖別沿用 rec.keyed；開不成才照關好的規則鎖回。
    -- 不先鎖再開：車庫門改鎖的同步會讓客戶端把「關著」回送伺服器，蓋掉同一個 tick 的重開（Gates.lua setGarageOpen）
    local reopen = rec.open
    local function fail(why)
        if reopen then settleClosed(key, rec, adapter, anchor) end
        return false, why
    end
    if now < r.failAt then return fail("Busy") end
    local pieces = G.pieces(adapter, anchor)
    if KP.sandbox("RequirePower") == true and not G.powered(pieces) then
        r.failAt = now + S.FAIL_MS
        return fail("NoPower")
    end
    rec.doorway = doorwayOf(pieces)   -- 門還關著：記下各片的門口格
    local keyed = reopen and rec.keyed or nil
    if G.supportsLock(adapter) then keyed = G.unlock(adapter, anchor, pieces) or keyed end
    if not G.setOpen(adapter, anchor, true, who) then
        r.failAt = now + S.FAIL_MS
        if reopen then
            rec.keyed = keyed
            return fail("Blocked")
        end
        if G.supportsLock(adapter) then G.lock(adapter, anchor, pieces, rec.lock, keyed) end
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

-- 推送給本人：他的感應盒（開車時）與戴著的模組登記了哪些大門（客戶端 KnoxPassAPI.willOpenFor、小地圖用，
-- 讓 AutoDrive 事先知道哪扇門會開）。換了感應盒或模組、帳本版本變了就馬上推，平常每 PASSES_MS 補推一次
-- （重連、封包遺失會自己好）。只查索引（gatesForTag／gatesForModule），不掃全部大門；別人的登記不外流
local pushed = {}   -- 使用者名稱 → { tag, mod, ver, at }
local function keyList(keys)
    local list = {}
    for key in pairs(keys or {}) do list[#list + 1] = key end
    return list
end

local function pushPasses(p, tagId, tagKeys, serial, modKeys, now)
    local name = p:getUsername() or "?"
    local last = pushed[name]
    local ver = L.version()
    if last and last.tag == tagId and last.mod == serial and last.ver == ver and now - last.at < S.PASSES_MS then return end
    if not last then
        last = {}
        pushed[name] = last
    end
    last.tag, last.mod, last.ver, last.at = tagId, serial, ver, now
    -- 模組的門多帶座標與種類（小地圖畫標記）；一扇約 90 位元組（TableNetworkUtils.java:30-99）
    local gates = {}
    for key in pairs(modKeys or {}) do
        local rec = L.get(key)
        if rec then gates[#gates + 1] = { key = key, x = rec.cx, y = rec.cy, z = rec.z, kind = rec.kind } end
    end
    if KP.reply then KP.reply(p, "passes", { tag = tagId, keys = keyList(tagKeys), mod = serial, gates = gates }) end
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

-- 位置差算速度：伺服器收到的位置是一批一批到的，單次位置差忽快忽慢、方向也抖：取一半新值做平滑。
-- 超過 2 秒沒看到（剛上車、剛下車）從 0 起算
local function smooth(tbl, id, x, y, now)
    local tr = tbl[id]
    if not tr then
        tr = { vx = 0, vy = 0 }
        tbl[id] = tr
    elseif now > tr.t and now - tr.t < 2000 then
        local dt = (now - tr.t) / 1000
        tr.vx = (tr.vx + (x - tr.x) / dt) * 0.5
        tr.vy = (tr.vy + (y - tr.y) / dt) * 0.5
    else
        tr.vx, tr.vy = 0, 0
    end
    tr.x, tr.y, tr.t = x, y, now
    return tr.vx, tr.vy
end

-- 這一輪這台車的位置、速度與參數（scanDriver 填、scanKeys 讀；重複用同一張表）
local car = {}

-- 一組登記的門（感應盒或駕駛的模組）：車與它拖的拖車的範圍、預判線段，AutoDrive 車頭朝向，holds 照舊。skip＝已經用感應盒掃過的門
-- （同一扇門只掃一次：感應盒開門扣它的電）。serial＝用模組開的，開了記下「上次通過」
local function scanKeys(p, v, keys, skip, tag, part, serial)
    for key in pairs(keys) do
        local rec = car.gates[key]
        if rec and not (skip and skip[key]) and math.abs(rec.z - car.z) < 1 then
            local range = KP.gateRange(rec)
            local r2 = range * range
            if KP.segDistSq(rec.cx, rec.cy, car.x, car.y, car.ax, car.ay) <= r2
                or (car.tx and KP.segDistSq(rec.cx, rec.cy, car.tx, car.ty, car.tx + car.vx * car.lead, car.ty + car.vy * car.lead) <= r2)
                or (car.fx and headingAt(rec, car.x, car.y, car.fx, car.fy, car.ahead)) then
                if holds(key, rec, v, car.vx, car.vy, car.lead) and S.open(key, rec, p, tag, part, v, car.now) and serial then
                    L.touchModule(rec, serial, p)
                end
            elseif runtime[key] and runtime[key].cars then
                runtime[key].cars[v:getId()] = nil
            end
        end
    end
end

-- 駕駛：車上的感應盒，加上駕駛戴著、有作用的模組（任何一台車都算；乘客戴著不算，和感應盒「一台車一顆」一致）
local function scanDriver(p, gates, now, lead, ahead)
    local v = p:getVehicle()
    if not v or v:getDriver() ~= p then return end
    local tag, part = KP.vehicleTag(v)
    local serial = KP.watchSerial(p)
    if not tag and not serial then return end
    local tagKeys = tag and L.gatesForTag(tag:getID())
    local modKeys = serial and L.gatesForModule(serial)
    pushPasses(p, tag and tag:getID(), tagKeys, serial, modKeys, now)
    if tagKeys and KP.charge(tag) <= 0 then tagKeys = nil end
    if not tagKeys and not modKeys then return end
    local x, y = v:getX(), v:getY()
    local vx, vy = smooth(tracks, v:getId(), x, y, now)
    car.gates, car.now, car.lead, car.ahead = gates, now, lead, ahead
    car.x, car.y, car.z, car.vx, car.vy = x, y, v:getZ(), vx, vy
    -- 停著就是圓形範圍；行進中把「現在位置→lead 秒後位置」這段線段拿去量距離（往遠離大門的方向不延伸）。
    -- 感應距離每扇門自己的（KP.gateRange）
    car.ax, car.ay = x + vx * lead, y + vy * lead
    -- 拖著的拖車也量（同樣的範圍與預判）：倒車時拖車在前，長掛車（W900 貨櫃掛車，車頭中心到拖車尾 12.4 格）只看車頭時
    -- 拖車尾先頂到關著的門，停住後速度 0、車頭還在範圍外，門就永遠不開（E2E semirev-mp）。拖車跟著車走，用車的速度推
    -- （holds 同理）。原版掛車選單可能把掛車設成拖的一方（ISVehicleMenu.lua:434-444），有人坐進被拖的車、拖的那台沒人駕駛時，
    -- 伺服器把連結反過來（CarController.java:360-366），所以駕駛那台就是拖著拖車的那台
    local tr = v:getVehicleTowing()
    car.tx, car.ty = tr and tr:getX(), tr and tr:getY()
    car.fx, car.fy = nil, nil
    if ahead > 0 and autoDriving(v) then car.fx, car.fy = facing(v) end
    if tagKeys then scanKeys(p, v, tagKeys, nil, tag, part, nil) end
    if modKeys then scanKeys(p, v, modKeys, tagKeys, nil, nil, serial) end
end

-- ── 手錶模組：戴著走向門線就開 ──────────────────────────────────────────
local WALK_COS, WALK_MIN_SPEED = 0.5, 0.5   -- 走路方向與「到門線最近點」夾角 60° 內；每秒至少 0.5 格
local HINT_MS = 30000                       -- 開不了的提示，同一扇門多久一次
local hinted = {}                           -- 使用者名稱 → { key, at }

-- 門線兩端：錨點和它對中心的對稱點（N 門沿 x、W 門沿 y），九格寬的門兩端也量得到；中心是各片格子中心的平均
-- （Gates.lua G.center）。其他 MOD 的門沒有朝向（key 不以 N／W 結尾），只有中心一點
local function span(rec)
    local edge = string.sub(rec.key, -1)
    if edge == "N" then
        local h = math.abs(rec.cx - (rec.x + 0.5)) + 0.5
        return rec.cx - h, rec.y, rec.cx + h, rec.y
    elseif edge == "W" then
        local h = math.abs(rec.cy - (rec.y + 0.5)) + 0.5
        return rec.x, rec.cy - h, rec.x, rec.cy + h
    end
    return rec.cx, rec.cy, rec.cx, rec.cy
end

-- 開了就記下這次是誰、何時（管理視窗的「上次通過」）；開不了只說玩家排除得了的原因（沒電、擋住），同一扇門 30 秒一次。
-- Busy 是剛失敗過的冷卻，已經提示過
local function walkOpen(p, key, rec, serial, now)
    local ok, why = S.open(key, rec, p, nil, nil, nil, now)
    if ok then return L.touchModule(rec, serial, p) end
    if why ~= "NoPower" and why ~= "Blocked" then return end
    local name = p:getUsername() or "?"
    local h = hinted[name]
    if h and h.key == key and now - h.at < HINT_MS then return end
    hinted[name] = { key = key, at = now }
    if KP.reply then KP.reply(p, "result", { cmd = "walk", ok = false, why = why, key = key }) end
end

-- 步行：只看這顆模組登記過的門（通常只有幾扇）。站著（在門邊做事）或沿著門走（速度和「到門線」的方向垂直）不開；
-- 人一直走近，每輪都會撐門，走過去就照延遲關，門口有人時照舊不關
local function scanWalker(p, gates, now, range)
    if p:getVehicle() then return end
    local serial = KP.watchSerial(p)            -- 沒戴、沒電、槽位失效＝nil
    if not serial then return end
    local keys = L.gatesForModule(serial)
    pushPasses(p, nil, nil, serial, keys, now)  -- 小地圖用
    if not keys then return end
    local x, y, z = p:getX(), p:getY(), p:getZ()
    local vx, vy = smooth(walkers, p:getUsername() or "?", x, y, now)
    local speed = math.sqrt(vx * vx + vy * vy)
    if speed < WALK_MIN_SPEED then return end
    for key in pairs(keys) do
        local rec = gates[key]
        if rec and rec.walk ~= false and math.abs(rec.z - z) < 1 then
            local d2, ex, ey = KP.segDistSq(x, y, span(rec))
            if d2 <= range * range and ex * vx + ey * vy >= WALK_COS * speed * math.sqrt(d2) then
                walkOpen(p, key, rec, serial, now)
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

-- 室內判定跟上門現在的狀態（Gates.lua G.syncRegions）：原版右鍵、會開門的殭屍開關門都不通知引擎，Knox Pass 自己開關時
-- 已經通知過（setGarageOpen），這裡補其他路徑。只看已載入的登記大門，位元對得上就什麼都不做
function S.syncRegions(gates)
    for _, rec in pairs(gates) do
        local adapter, anchor = G.findAt(rec)
        if adapter then G.syncRegions(G.pieces(adapter, anchor)) end
    end
end

-- ── 不會被破壞（沙盒 Indestructible、管理員替個別大門開的 rec.indestructible：KP.gateIndestructible）─────────
-- 原版沒有讓門不受傷的開關：IsoDoor.Damage 直接扣 health（IsoDoor.java:1897-1905），殭屍拍門（:1197-1209）與武器（:1305-1308）
-- 扣到 0 就拆掉整組（:1218-1240、:1359-1375）；IsoThumpable 同樣（IsoThumpable.java:1027-1088、:1161-1162、:1563-1566）。
-- Lua 攔不到，所以把整扇門每一片（閘門與模型門連兩端：兩端被打壞整座移除，Barrier.lua）的 health 墊到 SHIELD_HP：
-- 殭屍一下扣 1-5 點（超人另加圍著拍的數量×2，IsoDoor.java:1197-1204），武器一下幾百點，打不完。殭屍照樣會拍、拍門聲照樣
-- 引來別的殭屍，只是拍不壞。health 在存檔與同步都是 int（IsoDoor.java:936-937、958-959、1693），getThumpCondition
-- 夾在 maxHealth 以內（:1261-1263），拍門聲照滿格的門播。墊之前的 health 記在那一片的 modData（HP_KEY），不再打不壞時照它還原。
-- 大錘照原版伺服器設定（SledgehammerOnlyInSafehouse，ISDestroyStuffAction.lua:120-127），火燒直接移除門
-- （IsoGridSquare.java:6353-6356），都不看 health，擋不住。
-- 雙開門第 2、3 片每次開關都刪掉重建、health 回到預設（IsoDoor.java:2892-2922），移除前觸發 OnObjectAboutToBeRemoved
-- （IsoGridSquare.java:5745）：看到墊過的片被移除，下一個 tick 就重墊雙開門。其餘（剛開啟、剛載入、別的 MOD 改了 health、
-- 客戶端送回舊的 health）由每 5 秒的巡檢補上。
-- 錨點被移除（火燒、大錘、搬走）時帳本下一個 tick 就刪（ReaderPost.lua），但雙開門不會整扇一起走：火燒移那片連同側那片
-- （伺服器 RemoveItemFromSquarePacket.java:158-159、SP RemoveTileObject，都經 IsoObjectUtils.java:83-96），打壞外側那片連旁邊
-- 那片、中間片只拆自己（IsoDoor.java:3187-3205）。移除事件裡記下整扇，下一個 tick 移除做完了才還原還在世界上的片，不然沒有
-- 讀頭也一直打不壞。不在事件裡同步：移除封包先送出（GameServer.java:2995-2996），客戶端先移掉的話，同步照索引套到同格遞補
-- 上來的物件（GameClient.java:1630-1631）
-- HP_KEY 在 modData，改過的客戶端改得到（ObjectModDataPacket.java:50-72），但它們本來就能直接送任意 health
-- （IsoDoor.java:1757、1775；IsoThumpable.java:1852），防護等級＝原版
S.SHIELD_HP = 1000000000   -- 10 億：比任何門的耐久大好幾個數量級，又在 int 範圍內
local HALF = S.SHIELD_HP / 2
local HP_KEY = "KnoxPassHp"

local function hasHealth(o) return instanceof(o, "IsoDoor") or instanceof(o, "IsoThumpable") end

-- IsoDoor 在伺服器上 setHealth 只改欄位（IsoDoor.java:2401-2403），照 Gates.lua syncDoor 手動同步。客戶端開關門、改鎖時
-- 會把自己那份 health 送回伺服器、伺服器照收（:1693、1757、1775）：客戶端留著舊值的話，墊高的門被玩家一開關就沒墊；
-- 還原過的門一開關又打不壞（拍門時伺服器每一下都同步，:1900-1903，附近客戶端拿到的是 10 億）。
-- IsoThumpable 在伺服器上自己同步（IsoThumpable.java:281-288）
local function setHealth(o, hp)
    o:setHealth(hp)
    if instanceof(o, "IsoDoor") then o:syncIsoObject(false, 0, nil, nil) end
end

local function shieldOne(o, on)
    if not hasHealth(o) then return end
    local hp = o:getHealth()
    if on then
        if hp < HALF then   -- 還沒墊（剛開啟、剛重建、被客戶端蓋回去）；墊過的被打掉不到一半不必動，也就不必每輪同步
            local md = o:getModData()
            if md[HP_KEY] == nil then md[HP_KEY] = hp end
            setHealth(o, S.SHIELD_HP)
        end
        return
    end
    -- 有記錄就照它還原，沒墊高也一樣：開著時重建的 IsoThumpable 帶著記錄、health 回預設（IsoDoor.java:2899-2913），
    -- 跟墊回去之後才關掉的結果相同
    local md = o:hasModData() and o:getModData()
    local to = md and tonumber(md[HP_KEY]) or hp >= HALF and o:getMaxHealth() or hp
    if to ~= hp then setHealth(o, to) end
    if md then md[HP_KEY] = nil end
end

-- 整扇門的物件：閘門與有兩端的模型門連兩端（兩端被打壞整座移除，Barrier.lua），其他門 G.pieces
local function partsOf(adapter, anchor)
    return KP.Barrier and KP.Barrier.parts(anchor) or G.pieces(adapter, anchor)
end

-- on＝nil 照這扇門現在的設定（KP.gateIndestructible）；拆讀頭時傳 false 還原
function S.shield(rec, adapter, anchor, on)
    if on == nil then on = KP.gateIndestructible(rec) end
    for _, o in ipairs(partsOf(adapter, anchor)) do shieldOne(o, on) end
end

-- 已載入的登記大門照設定墊高或還原；kind＝只看這一種門（雙開門重建後）
function S.shieldAll(gates, kind)
    for _, rec in pairs(gates) do
        if kind == nil or rec.kind == kind then
            local adapter, anchor = G.findAt(rec)
            if adapter then S.shield(rec, adapter, anchor) end
        end
    end
end

-- 管理視窗的耐久（Server.lua buildState）：整扇門剩下耐久最少的那一片（最先被打壞；閘門與模型門任一片壞就整座移除），
-- 回 現在, 那一片的滿格。墊高的照墊之前的值（沙盒剛關、巡檢還沒還原的那幾秒也對）；滿格照 KP.Barrier.fullHealth，
-- 其他照 getMaxHealth，至少是現在的值。沒有 health 的門回 nil
function S.durability(adapter, anchor)
    local parts = partsOf(adapter, anchor)
    local hp, full = nil, nil
    for _, o in ipairs(parts) do
        if hasHealth(o) then
            local h = o:getHealth()
            if h >= HALF then h = o:hasModData() and tonumber(o:getModData()[HP_KEY]) or o:getMaxHealth() end
            if hp == nil or h < hp then
                hp, full = h, math.max(KP.Barrier and KP.Barrier.fullHealth(o, #parts, h) or o:getMaxHealth(), h)
            end
        end
    end
    return hp, full
end

local rebuilt, orphans = false, {}
Events.OnObjectAboutToBeRemoved.Add(function(obj)
    if not hasHealth(obj) then return end
    if obj:getHealth() >= HALF then rebuilt = true end
    -- 錨點（閘門整座一起移除，Barrier.lua）：記下整扇，S.tick 還原留下的片
    if obj:hasModData() and obj:getModData()[KP.MARKER_OWNER] ~= nil and not KP.isBarrier(obj) then
        local adapter, anchor = G.resolve(obj)
        if anchor == obj then orphans[#orphans + 1] = { key = G.key(obj), parts = partsOf(adapter, obj) } end
    end
end)

-- 墊過的 IsoThumpable 被搬起來（原版搬家具把 health 記進物品、放下時照它設，ISMoveableSpriteProps.lua:1306-1309、:1339-1341）：
-- 記成墊之前的耐久，搬走的門才不會沒裝讀頭也一直打不壞
local saveThumpable = ISMoveableSpriteProps.saveThumpableParameters
function ISMoveableSpriteProps:saveThumpableParameters(t, obj)
    saveThumpable(self, t, obj)
    if obj:getHealth() >= HALF then
        t.health = tonumber(obj:getModData()[HP_KEY]) or obj:getMaxHealth()
        if type(t.modData) == "table" then t.modData[HP_KEY] = nil end
    end
end

function S.tick()
    if rebuilt then
        rebuilt = false
        local gates = L.gates()
        if gates then S.shieldAll(gates, "Double") end
    end
    if #orphans > 0 then
        local list = orphans
        orphans = {}
        for _, o in ipairs(list) do
            local rec = L.get(o.key)
            if not (rec and G.findAt(rec)) then   -- 錨點還在（沒真的移走）就照設定，交給巡檢
                for _, p in ipairs(o.parts) do
                    if p:getObjectIndex() ~= -1 then shieldOne(p, false) end
                end
            end
        end
    end
    local now = getTimestampMs()
    if now - lastScan < S.SCAN_MS then return end
    lastScan = now
    local gates = L.gates()
    if not gates then return end
    local lead = tonumber(KP.sandbox("LeadSeconds")) or 0
    local ahead = tonumber(KP.sandbox("AutoDriveAhead")) or 0
    local walk = KP.watchSensing() and tonumber(KP.sandbox("WatchRange")) or 0   -- 0＝不跑步行感應
    KP.eachPlayer(function(p)
        scanDriver(p, gates, now, lead, ahead)
        if walk > 0 then scanWalker(p, gates, now, walk) end
    end)
    for key in pairs(L.openKeys()) do
        local rec = gates[key]
        if rec then tryClose(key, rec, now, KP.gateDelay(rec) * 1000) end
    end
    if now - lastRelock >= S.RELOCK_MS then
        lastRelock = now
        S.relock(gates)
        S.syncRegions(gates)
        S.shieldAll(gates)
        if isServer() then KP.eachPlayer(L.seenPlayer) end   -- 共同管理者的候選：伺服器認得的玩家（Ledger.lua）
    end
end

Events.OnTick.Add(S.tick)

-- 伺服器剛載入有讀頭大門的 chunk（ReaderPost.lua 的 LoadChunk）：下一個 tick 就掃描，不等 250 ms 節流。
-- 自駕車看得到的區塊是伺服器載入後才送過去的，越早掃描，它就越可能一開始就看到開著的門。
-- 只歸零節流、不直接開門：雙開門的門片可能跨到還沒載入的相鄰 chunk，這時開門重建會出錯
function S.wake()
    lastScan = 0
end
