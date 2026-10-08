-- 抬升閘門：entity 建造（scripts/entities/entity_knoxpass_barrier.txt）的 OnCreate 把三格車道換成 IsoDoor 車庫門鏈，
-- 建好後自動登記內建讀頭（建造者是擁有者）；拆除機箱、機箱被打壞、大錘敲任一格、車道被打壞時整座移除。
-- 形態：機箱格是 entity 建出的 IsoThumpable（sprite 帶 solid，永遠擋車）；車道 1-3 是 GarageDoor 1-3 的 IsoDoor，
-- 第 1 片是錨點，臂的 3D 模型掛在它身上（common/media/spriteModels.txt，原點平移到機箱格）。
-- 四個方向：N／W 向機箱緊鄰第 1 片；S／E 向是 N／W 轉 180°（編號＋80），機箱在第 3 片那端，車道門片建在下一列／下一行。
-- 車庫捲門（KP.RollDoor）走同一段換門程式：原版捲門 sprite 換成 IsoDoor，不內建讀頭。
-- 建造放的是沒有 GarageDoor 屬性的替代 tile（Core.lua）：改寫 ISBuildIsoEntity:setInfo、看到這個屬性就自己建門的
-- 其他 MOD 攔不到，OnCreate 才換成真的門片。
-- media/lua/server 的檔 MP client 也會載入：函式照常定義（entity 腳本以名稱找 OnCreate），事件只在 server／SP 掛。
require "MinidoracatKnoxPass/Core"
require "MinidoracatKnoxPass/Gates"
local KP = MinidoracatKnoxPass
local G = KP.Gates

local B = {}
KP.Barrier = B

-- 建好的車道 1（錨點）等下一個 tick 再登記讀頭：OnCreate 逐格呼叫（ISBuildIsoEntity.lua:736-744），
-- 同一次 create 會把四格放完（:501-593），下一個 tick 整條鏈才齊
local pending = {}

-- 車道 1（含開啟 sprite）→ 機箱的相對位置與機箱編號：鏈的第 1 片在 N 向最小 x、W 向最大 y（IsoDoor.java:3241-3342）。
-- N／W 向機箱再往外一格；S 向機箱在第 3 片東邊、上一列（門片在下一列），E 向在第 3 片北邊、左一行
local M = KP.BARRIER_MIRROR
local CABINET_OF = {
    [0] = { -1, 0, 6 }, [8] = { -1, 0, 6 }, [3] = { 0, 1, 7 }, [11] = { 0, 1, 7 },
    [M] = { 3, -1, M + 6 }, [M + 8] = { 3, -1, M + 6 }, [M + 3] = { -1, -3, M + 7 }, [M + 11] = { -1, -3, M + 7 },
}
local LANE1_OF = {
    [6] = { 1, 0, { [0] = true, [8] = true } }, [7] = { 0, -1, { [3] = true, [11] = true } },
    [M + 6] = { -3, 1, { [M] = true, [M + 8] = true } }, [M + 7] = { 1, 3, { [M + 3] = true, [M + 11] = true } },
}

local function barrierAt(x, y, z, want)
    local sq = getCell():getGridSquare(x, y, z)
    if not sq then return nil end
    local objects = sq:getObjects()
    for i = 0, objects:size() - 1 do
        local o = objects:get(i)
        local idx = KP.barrierIndex(o)
        if idx and want[idx] then return o end
    end
    return nil
end

-- 單臂閘門整座的物件（機箱＋車道各片）與錨點的帳本 key；obj 不是單臂閘門回 nil。殘缺的閘門（少了機箱或車道）回剩下的部分
local function barrierParts(obj)
    local idx = KP.barrierIndex(obj)
    if not idx then return nil end
    local sq = obj:getSquare()
    if not sq then return nil end
    local cabinet, lane
    if LANE1_OF[idx] then   -- 機箱（6、7、86、87）
        cabinet = obj
        local o = LANE1_OF[idx]
        lane = barrierAt(sq:getX() + o[1], sq:getY() + o[2], sq:getZ(), o[3])
    else
        lane = obj
    end
    local out, key = {}, nil
    local adapter, anchor = nil, nil
    if lane then adapter, anchor = G.resolve(lane) end
    if anchor then
        if not cabinet then
            local asq, o = anchor:getSquare(), CABINET_OF[KP.barrierIndex(anchor)]
            if o then cabinet = barrierAt(asq:getX() + o[1], asq:getY() + o[2], asq:getZ(), { [o[3]] = true }) end
        end
        for _, p in ipairs(G.pieces(adapter, anchor)) do out[#out + 1] = p end
        key = G.key(anchor)
    end
    if cabinet then out[#out + 1] = cabinet end
    return out, key
end

-- ── 模型門（Core.lua KP.MODEL_GATES：雙桿閘門、兩層樓捲門、兩層樓大門）─────────────────────────
local SLOT = KP.GATE_SLOT

local function spriteAt(x, y, z, want)
    local sq = getCell():getGridSquare(x, y, z)
    if not sq then return nil end
    local objects = sq:getObjects()
    for i = 0, objects:size() - 1 do
        local o = objects:get(i)
        local spr = o:getSprite()
        if spr and want[spr:getName()] then return o end
    end
    return nil
end

-- 有兩端的模型門整座的物件與錨點的帳本 key；沒有兩端的（兩層樓捲門）回 nil，照一般車庫門由 ReaderPost 收帳本
local function modelParts(obj)
    local mg = KP.modelGate(obj)
    if not (mg and mg.def.ends) then return nil end
    local sq = obj:getSquare()
    if not sq then return nil end
    local z = sq:getZ()
    local function name(slot) return mg.tileset .. "_" .. (mg.index0 + slot) end
    local lane, ax, ay = obj, nil, nil
    if mg.slot == SLOT.END_A or mg.slot == SLOT.END_B then
        ax, ay = KP.gateAnchor(mg, sq:getX(), sq:getY())
        lane = spriteAt(ax, ay, z, { [name(0)] = true, [name(SLOT.OPEN)] = true })
    end
    local out, key = {}, nil
    local adapter, anchor = nil, nil
    if lane then adapter, anchor = G.resolve(lane) end
    if anchor then
        local asq = anchor:getSquare()
        ax, ay = asq:getX(), asq:getY()
        for _, p in ipairs(G.pieces(adapter, anchor)) do out[#out + 1] = p end
        key = G.key(anchor)
    end
    if ax then
        local x1, y1, x2, y2 = KP.gateEnds(mg, ax, ay)
        out[#out + 1] = spriteAt(x1, y1, z, { [name(SLOT.END_A)] = true })
        out[#out + 1] = spriteAt(x2, y2, z, { [name(SLOT.END_B)] = true })
    end
    return out, key
end

-- 整座閘門或有兩端的模型門的物件與帳本 key；都不是回 nil
function B.parts(obj)
    local list, key = barrierParts(obj)
    if list then return list, key end
    return modelParts(obj)
end

-- 移除整座閘門與帳本記錄。已經被移走的物件（getObjectIndex 為 -1）略過：
-- 原版拆除／大錘自己會移走目標（ISDismantleAction.lua:84-94；IsoThumpable.java:1201-1203 也是先查 index）。
-- safelyRemove 要給 false：預設的 true 會把 entity 建的機箱當多格物件找齊整組，車道已換成 IsoDoor 找不齊，
-- 引擎回 -1、什麼都不移（IsoGridSquare.java:5942-5968、IsoObjectUtils.java:20-48；barrier-mp 1005f 實踩：原版拆除也因此留下機箱）
function B.remove(list, key)
    if not list then return end
    for _, o in ipairs(list) do
        local sq = o:getSquare()
        if sq and o:getObjectIndex() ~= -1 then sq:transmitRemoveItemFromSquare(o, false) end
    end
    local L = KP.Ledger
    if key and L and L.get(key) then
        L.remove(key)
        KP.Sensor.forget(key)
        KP.log("barrier removed key=" .. key)
    end
end

-- 建造放下的 IsoThumpable（替代 tile）換成 IsoDoor 車庫門片：sprite 是真的門片，dest 是門片的格子（S／E 向閘門在
-- 相鄰一列／一行）。照原版 windowGlass.OnCreate 換成 IsoWindow 的做法（buildRecipeCode.lua:536-546）。
-- 朝向由呼叫端從 tile 決定，不看 thump:getNorth()：entity 游標的 render 不呼叫 getSprite，self.north 停在建構時的
-- false（ISBuildingObject.lua:448、:482-510；ISBuildIsoEntity.lua:70-109），create 收到的 north 也就一律 false
-- （barrier-mp 2026-10-05 實踩：N 向閘門的門片變成 W 向）。
-- sprite 建構子會照沙盒 lockedHouses 隨機上鎖（IsoDoor.java:820-840）；車庫門的 locked 對玩家是看站位（:1568-1580），
-- 一律不鎖，門鎖只用 Knox Pass 的 CustomLock。耐久用 setHealth：maxHealth 留 500，getThumpCondition 夾在 1 以內
-- （IsoDoor.java:1261-1263），殭屍照 health 打（IsoDoor.java:88-95 預設 500）。
-- 移走替代 tile 一定要 RemoveTileObject(thump, false)：單參數版在 chunk 已載入時走 safelyRemove（IsoGridSquare.java:5713-5716），
-- entity 多格物件要整組找齊（IsoObjectUtils.java:32-41、83-113）——還沒放完時回 -1、什麼都不移（替代 tile 留在伺服器），
-- 放完最後一格時反而整組連機箱一起移掉（r3-mp 1007a 實踩：E 向閘門建好就被整座拆掉）。0.1.x 用真車道 sprite 當建造 tile，
-- 它有 GarageDoor，走車庫門那條只移自己，所以沒出事
local function toGarageDoor(thump, dest, sprite, north, health)
    local door = IsoDoor.new(getCell(), dest, sprite, north)
    door:setLocked(false)
    door:setLockedByKey(false)
    door:setHealth(health)
    dest:AddSpecialObject(door)
    local sq = thump:getSquare()
    sq:RemoveTileObject(thump, false)
    if dest ~= sq then dest:RecalcAllWithNeighbours(true) end   -- 原格由 setInfo 重算（ISBuildIsoEntity.lua:746）
    return door
end

-- 替代 tile 編號 → 真車道編號與它在 N／W 組裡的位置（0-2 N、3-5 W）；不是替代 tile 回 nil
local function laneOf(idx)
    local real = idx - KP.BARRIER_PLACEHOLDER
    if real < 0 or real % M > 5 then return nil end
    return real, real % M
end

-- SpriteConfig OnCreate（伺服器；SP 在本機）：params = { thumpable, craftRecipeData, character, facing }。
-- 車道格換成 IsoDoor；回傳 replaceObject 讓 setInfo 改送新物件（ISBuildIsoEntity.lua:748-756）。機箱格回 nil，照原版送 IsoThumpable
function B.onCreate(params)
    local thump = params and params.thumpable
    local idx = KP.barrierIndex(thump)
    local real, base = nil, nil
    if idx then real, base = laneOf(idx) end
    if not real then return nil end
    local north = base <= 2
    local sq = thump:getSquare()
    local x, y, z = sq:getX(), sq:getY(), sq:getZ()
    -- 轉 180° 的 S／E 向：門線在這一列的南邊／這一行的東邊，門只能在 N／W 邊，門片建在下一列／下一行
    if real >= M then
        if north then y = y + 1 else x = x + 1 end
    end
    local dest = getCell():getGridSquare(x, y, z) or getCell():createNewGridSquare(x, y, z, true)
    local door = toGarageDoor(thump, dest, getSprite(KP.BARRIER_TILESET .. "_" .. real), north, KP.BARRIER_HEALTH)
    if base == 0 or base == 3 then
        pending[#pending + 1] = { anchor = door, who = params.character }
        -- SP 建造不觸發 OnObjectAdded（只有 MP client 收 AddItemToMapPacket 時，AddItemToMapPacket.java:94），
        -- 本機的動畫補播要直接收；專用伺服器沒有載 client 檔，KP.BarrierAnim 是 nil
        if KP.BarrierAnim then KP.BarrierAnim.track(door) end
    end
    return { replaceObject = true, object = door }
end

-- ── 車庫捲門 ────────────────────────────────────────────────────────────
-- 替代 tile（KP.ROLLDOOR_TILESET）編號＝款式×64＋格位（build_barrier_tiles.py ROLLDOOR_SLOTS）：每種寬度一段格位，
-- 前半北向、後半西向，依門片順序（錨點第 1 片在前）。中間片重複：引擎沿鏈找門片號 ≥ 自己的下一片，鏈多長都行
-- （IsoDoor.java:3282-3321）。每個建造項目要自己的替代 tile：原版不允許同一張 sprite 出現在兩個 entity
-- （SpriteConfigManager）。原版門片 k 的 sprite＝第 1 片＋k−1
local R = {}
KP.RollDoor = R

local ROLL_STYLES = {
    { "industry_trucks_01", 35, 32 },   -- 工業白：北向第 1 片、西向第 1 片
    { "walls_garage_01", 19, 16 },      -- 綠色
    { "walls_garage_01", 51, 48 },      -- 白色
}
-- 寬度：第一個北向格位、各片的原版門片號、耐久（兩台車 1500、三台車 2000，2026-10-08 使用者決定照大小加）
local ROLL_WIDTHS = {
    { first = 0, pieces = { 1, 2, 3 }, health = 1000 },
    { first = 8, pieces = { 1, 2, 2, 3 }, health = 1000 },
    { first = 16, pieces = { 1, 2, 2, 2, 2, 3 }, health = 1500 },
    { first = 32, pieces = { 1, 2, 2, 2, 2, 2, 2, 2, 3 }, health = 2000 },
}

-- 替代 tile 編號 → 原版門片 sprite 名稱、是不是北向、耐久；不是捲門的替代 tile 回 nil
function R.sprite(idx)
    local st = ROLL_STYLES[math.floor(idx / 64) + 1]
    if not st then return nil end
    local slot = idx % 64
    for _, w in ipairs(ROLL_WIDTHS) do
        local n = #w.pieces
        local k = slot - w.first
        if k >= 0 and k < n * 2 then
            local north = k < n
            if not north then k = k - n end
            return st[1] .. "_" .. ((north and st[2] or st[3]) + w.pieces[k + 1] - 1), north, w.health
        end
    end
    return nil
end

function R.onCreate(params)
    local thump = params and params.thumpable
    local spr = thump and thump:getSprite()
    local name = spr and spr:getName()
    local idx = name and tonumber(string.match(name, "^" .. KP.ROLLDOOR_TILESET .. "_(%d+)$"))
    local real, north, health = nil, nil, nil
    if idx then real, north, health = R.sprite(idx) end
    if not real then return nil end
    local door = toGarageDoor(thump, thump:getSquare(), getSprite(real), north, health)
    return { replaceObject = true, object = door }
end

-- 模型門的 SpriteConfig OnCreate：替代 tile（格位 16＋k−1）換成車道 k 的門片（第 1 片 GarageDoor 1 是錨點、掛 3D 模型，
-- 中間 GarageDoor 2，最後 GarageDoor 3），耐久照 KP.MODEL_GATES；兩端（格位 3／4）回 nil，照原版送 IsoThumpable。
-- 內建讀頭的（雙桿閘門）下一個 tick 登記，擁有者是建造者（B.settle）
local MG = {}
KP.ModelGate = MG

function MG.onCreate(params)
    local thump = params and params.thumpable
    local mg = KP.modelGate(thump)
    local k = mg and mg.slot - SLOT.PLACEHOLDER + 1
    if not k or k < 1 or k > mg.width then return nil end
    local sq = thump:getSquare()
    local d = KP.GATE_DOOR[mg.face]
    local x, y, z = sq:getX() + d[1], sq:getY() + d[2], sq:getZ()
    local dest = getCell():getGridSquare(x, y, z) or getCell():createNewGridSquare(x, y, z, true)
    local real = mg.index0 + (k == 1 and 0 or k == mg.width and 2 or 1)
    local door = toGarageDoor(thump, dest, getSprite(mg.tileset .. "_" .. real), mg.face == "N" or mg.face == "S",
        mg.def.health[mg.width])
    if k == 1 then
        if mg.def.builtin then pending[#pending + 1] = { anchor = door, who = params.character } end
        if KP.BarrierAnim then KP.BarrierAnim.track(door) end   -- SP 建造不觸發 OnObjectAdded（見 B.onCreate）
    end
    return { replaceObject = true, object = door }
end

function B.settle()
    if #pending == 0 then return end
    local list = pending
    pending = {}
    for _, e in ipairs(list) do
        local adapter, anchor = G.resolve(e.anchor)
        if adapter and not KP.Ledger.get(G.key(anchor)) then
            local name, sid = KP.principal(e.who)
            KP.registerReader(adapter, anchor, name, sid, true)
        end
    end
end

if not isClient() then
    require "MinidoracatKnoxPass/Server"
    require "TimedActions/ISDismantleAction"
    require "TimedActions/ISDestroyStuffAction"

    Events.OnTick.Add(B.settle)

    -- 機箱或門柱被打壞（IsoThumpable.java:1191，觸發在移走之前）
    Events.OnDestroyIsoThumpable.Add(function(thump)
        if KP.isGateEnd(thump) then B.remove(B.parts(thump)) end
    end)

    -- 拆除機箱或門柱（只有兩端是可拆的 IsoThumpable；原版照 buildMaterials 退料：每片都記著整座的材料，ISBuildingObject
    -- updateModData，所以只退被拆的那一端，其餘跟著移除、不退料；單臂閘門只有機箱帶組件，退一個）
    local dismantle = ISDismantleAction.complete
    function ISDismantleAction:complete()
        local list, key = B.parts(self.thumpable)
        local done = dismantle(self)
        if list then B.remove(list, key) end
        return done
    end

    -- 大錘敲任一格：原版只移走那一格，閘門其餘部分跟著移除，不留殘缺的鏈
    local destroy = ISDestroyStuffAction.complete
    function ISDestroyStuffAction:complete()
        local list, key = B.parts(self.item)
        local done = destroy(self)
        if done and list then B.remove(list, key) end
        return done
    end

    -- 任何途徑移走一片車道或一端：整座跟著移除，不退料。殭屍或武器打壞車道走 IsoDoor.destroyGarageDoor，只拆整條車道鏈、
    -- 不碰兩端，也不經任何 Lua 動作（IsoDoor.java:1236,1371,3460-3499；車庫門的 destroy 不掉材料，:1385-1388）。
    -- 移除前伺服器（RemoveItemFromSquarePacket.java:151）與 SP（IsoGridSquare.java:5745）都觸發 OnObjectAboutToBeRemoved
    -- （原版 SGlobalObjectSystem.lua:275 同樣在伺服器掛）；handler 不能移走該物件本身（IsoGridSquare.java:5746-5748），
    -- 所以先記下整座（這時鏈還完整），下一個 tick 再收，B.remove 略過已移走的部分。
    -- 只看 IsoDoor 車道與兩端：建造時 OnCreate 移走的是車道格的 IsoThumpable（上方 onCreate），不能當成拆除。
    -- 沒有兩端的兩層樓捲門 B.parts 回 nil：照一般車庫門，帳本由 ReaderPost 收
    local doomed = {}
    Events.OnObjectAboutToBeRemoved.Add(function(obj)
        if not (instanceof(obj, "IsoDoor") or KP.isGateEnd(obj)) then return end
        local list, key = B.parts(obj)
        if list then doomed[#doomed + 1] = { list, key } end
    end)
    Events.OnTick.Add(function()
        if #doomed == 0 then return end
        local list = doomed
        doomed = {}
        for _, d in ipairs(list) do B.remove(d[1], d[2]) end
    end)
end
