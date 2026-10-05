-- 抬升閘門：entity 建造（scripts/entities/entity_knoxpass_barrier.txt）的 OnCreate 把三格車道換成 IsoDoor 車庫門鏈，
-- 建好後自動登記內建讀頭（建造者是擁有者）；拆除機箱、機箱被打壞、大錘敲任一格、車道被打壞時整座移除。
-- 形態：機箱格是 entity 建出的 IsoThumpable（sprite 帶 solid，永遠擋車）；車道 1-3 是 GarageDoor 1-3 的 IsoDoor，
-- 第 1 片（緊鄰機箱）是錨點，臂的 3D 模型掛在它身上（common/media/spriteModels.txt）。
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

-- 車道 1 與機箱的相對位置：鏈的第 1 片在 N 向最小 x、W 向最大 y（IsoDoor.java:3241-3342），機箱再往外一格
local CABINET_OF = { [0] = { -1, 0, 6 }, [8] = { -1, 0, 6 }, [3] = { 0, 1, 7 }, [11] = { 0, 1, 7 } }
local LANE1_OF = { [6] = { 1, 0, { [0] = true, [8] = true } }, [7] = { 0, -1, { [3] = true, [11] = true } } }

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

-- 整座閘門的物件（機箱＋車道各片）與錨點的帳本 key；obj 不是閘門回 nil。殘缺的閘門（少了機箱或車道）回剩下的部分
function B.parts(obj)
    local idx = KP.barrierIndex(obj)
    if not idx then return nil end
    local sq = obj:getSquare()
    if not sq then return nil end
    local cabinet, lane
    if idx == 6 or idx == 7 then
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

-- SpriteConfig OnCreate（伺服器；SP 在本機）：params = { thumpable, craftRecipeData, character, facing }。
-- 車道格換成 IsoDoor，照原版 windowGlass.OnCreate 換成 IsoWindow 的做法（buildRecipeCode.lua:536-546）；
-- 回傳 replaceObject 讓 setInfo 改送新物件（ISBuildIsoEntity.lua:748-756）。機箱格回 nil，照原版送 IsoThumpable
function B.onCreate(params)
    local thump = params and params.thumpable
    local idx = KP.barrierIndex(thump)
    if not idx or idx == 6 or idx == 7 then return nil end
    local sq = thump:getSquare()
    -- 朝向看 tile（0-2＝N 向車道、3-5＝W 向），不看 thump:getNorth()：entity 游標的 render 不呼叫 getSprite，
    -- self.north 停在建構時的 false（ISBuildingObject.lua:448、:482-510；ISBuildIsoEntity.lua:70-109），
    -- create 收到的 north 也就一律 false（barrier-mp 2026-10-05 實踩：N 向閘門的門片變成 W 向）
    local door = IsoDoor.new(getCell(), sq, thump:getSprite(), idx <= 2)
    -- sprite 建構子會照沙盒 lockedHouses 隨機上鎖（IsoDoor.java:820-840）；車庫門的 locked 對玩家是看站位
    -- （:1568-1580），閘門一律不鎖，門鎖只用 Knox Pass 的 CustomLock
    door:setLocked(false)
    door:setLockedByKey(false)
    sq:AddSpecialObject(door)
    sq:RemoveTileObject(thump)
    if idx == 0 or idx == 3 then
        pending[#pending + 1] = { anchor = door, who = params.character }
        -- SP 建造不觸發 OnObjectAdded（只有 MP client 收 AddItemToMapPacket 時，AddItemToMapPacket.java:94），
        -- 本機的動畫補播要直接收；專用伺服器沒有載 client 檔，KP.BarrierAnim 是 nil
        if KP.BarrierAnim then KP.BarrierAnim.track(door) end
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

    -- 機箱被打壞（IsoThumpable.java:1191，觸發在移走機箱之前）
    Events.OnDestroyIsoThumpable.Add(function(thump)
        if KP.isBarrierCabinet(thump) then B.remove(B.parts(thump)) end
    end)

    -- 拆除機箱（只有機箱是可拆的 IsoThumpable；原版照 buildMaterials 退料，只有機箱帶組件，退一個）
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

    -- 任何途徑移走一片車道或機箱：整座跟著移除，不退料。殭屍或武器打壞車道走 IsoDoor.destroyGarageDoor，只拆整條車道鏈、
    -- 不碰機箱，也不經任何 Lua 動作（IsoDoor.java:1236,1371,3460-3499；車庫門的 destroy 不掉材料，:1385-1388）。
    -- 移除前伺服器（RemoveItemFromSquarePacket.java:151）與 SP（IsoGridSquare.java:5745）都觸發 OnObjectAboutToBeRemoved
    -- （原版 SGlobalObjectSystem.lua:275 同樣在伺服器掛）；handler 不能移走該物件本身（IsoGridSquare.java:5746-5748），
    -- 所以先記下整座（這時鏈還完整），下一個 tick 再收，B.remove 略過已移走的部分。
    -- 只看 IsoDoor 車道與機箱：建造時 OnCreate 移走的是車道格的 IsoThumpable（上方 onCreate），不能當成拆除
    local doomed = {}
    Events.OnObjectAboutToBeRemoved.Add(function(obj)
        if not (instanceof(obj, "IsoDoor") or KP.isBarrierCabinet(obj)) then return end
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
