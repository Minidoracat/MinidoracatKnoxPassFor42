-- 門柱上的讀頭模型：裝了讀頭的門，在錨點那片的外端門柱上多放一個 IsoObject（tileset MinidoracatKnoxPass_reader，
-- 索引＝讀頭顏色×8＋變體；兩層樓大門掛在 A 端門柱的柱面，tileset MinidoracatKnoxPass_readerpillar，Core.lua KP.readerCode）。
-- tile 沒有任何屬性：不擋人車、AutoDrive 當成沒東西、不能搬、不能拆；
-- 3D 模型由 common/media/spriteModels.txt 掛上（有 spriteModel 的物件只畫模型，IsoObject.java:3540-3545）。
-- 帳本是唯一依據，世界上的物件只是顯示，全部只在伺服器（含 SP）改：
--   放上：KP.registerReader → R.attach（帳本記 post＝宿主格與變體）；抬升閘門與其他 MOD 的門不放
--   拿掉：L.remove → R.detach（拆讀頭、門不見了、閘門移除都走 L.remove）
--   自我修復：宿主格（與還沒記 post 的舊記錄的錨點格）所在的 chunk 載入時，下一個 tick 對齊：帳本有、格上沒有就補；
--   格上有、帳本沒有（或變體、顏色不對、重複）就移除。更新前已裝的讀頭因此在門所在的格子載入時補上
--   改色：帳本 rec.color 改完呼叫 R.refresh，對齊把舊顏色的換成新顏色（rec.color 沒有＝米白，舊記錄）
-- 同一個 LoadChunk 也叫醒大門掃描（Sensor.lua S.wake）：有讀頭大門（含閘門與其他 MOD 的門）的 chunk 載入時下一個 tick 就掃
-- media/lua/server 的檔 MP client 也會載入：大錘游標的過濾（client UI）在檔頭，其餘只在 server／SP 掛
require "MinidoracatKnoxPass/Core"
require "BuildingObjects/ISDestroyCursor"
local KP = MinidoracatKnoxPass

-- 大錘游標不列出讀頭模型（清單逐物件問 canDestroy，ISDestroyCursor.lua:293-362、410-421）。
-- 不能搬、不能拆解（ISMoveableSpriteProps.lua:100-130 要 IsMoveAble／Material 屬性）靠 tile 沒有屬性
local canDestroy = ISDestroyCursor.canDestroy
function ISDestroyCursor:canDestroy(object)
    if KP.readerCode(object) then return false end
    return canDestroy(self, object)
end

if isClient() then return end
require "MinidoracatKnoxPass/Gates"
require "MinidoracatKnoxPass/Ledger"
local G = KP.Gates
local L = KP.Ledger

local R = {}
KP.ReaderPost = R

local DOOR_ADAPTERS = { ["vanilla.IsoDoor"] = true, ["vanilla.IsoThumpable"] = true }

-- 讀頭掛在哪根門柱。宿主格＝西北角就是那根門柱的格子，模型原點在宿主格西北角（spriteModels translate -0.5 0 -0.5），
-- 往遠離門洞的方向伸出，兩面都有（不擋門片：門片繞鉸鏈轉，碰不到門柱外側；不穿牆：只貼在牆線兩面）：
-- - 單門（IsoDoor／IsoThumpable，含柵欄門）放鉸鏈那根：原版門的開門 sprite 門片都落在格子西北角那條邊
--   （Tiles2x fixtures_doors_01_2/3、fixtures_doors_fences_01_2/3），N 門鉸鏈在西端、W 門在北端，往格內（南／東）擺
-- - 雙開門（IsoDoor.java:120-129）：N 向第 1 片在西端、第 4 片在東端，開門時第 2、3 片搬到 y+1（往南擺）；
--   W 向第 1 片在南端（y 最大）、第 4 片在北端，開門搬到 x+1（往東擺）。兩扇門葉的鉸鏈都在外端，第 1／4 片不搬格
-- - 車庫門：第 1 片在 N 向最小 x、W 向最大 y（getGarageDoorPrev 往 x-1／y+1，IsoDoor.java:3241-3280），外端＝西／南端，捲起不擺
-- - 兩層樓大門：門柱 0.34-0.60 格厚，上面的讀頭會埋進去，改用柱面讀頭掛在 A 端門柱（宿主＝A 端那格）
-- 回傳宿主 x, y, 變體（0 N 西端、1 N 東端、2 W 北端、3 W 南端；大門 8＋外觀×4＋方向序）；閘門（機箱頂已有讀頭）與其他 MOD 的門回 nil
function R.spot(adapter, anchor)
    if not DOOR_ADAPTERS[adapter.id] or KP.isBarrier(anchor) then return nil end
    local sq = anchor:getSquare()
    local x, y = sq:getX(), sq:getY()
    local mg = KP.modelGate(anchor)
    if mg and mg.def.kind == "Gate" then
        local ex, ey = KP.gateEnds(mg, x, y)
        for i, ts in ipairs(KP.GATE_LOOKS) do
            if ts == mg.tileset then return ex, ey, 8 + (i - 1) * 4 + mg.fi end
        end
        return nil
    end
    local dd = IsoDoor.getDoubleDoorIndex(anchor)
    if anchor:getNorth() then
        if dd == 4 then return x + 1, y, 1 end
        return x, y, 0
    end
    if dd == 1 or IsoDoor.getGarageDoorIndex(anchor) ~= -1 then return x, y + 1, 3 end
    return x, y, 2
end

-- 格座標 → 數字鍵（不組字串）。地圖座標 < 65536、z 在 -64..63
local function cell(x, y, z)
    return (z + 64) * 4294967296 + y * 65536 + x
end

-- 格座標 → 所在 chunk（8×8 格）的數字鍵
local function chunkKey(x, y)
    return math.floor(y / 8) * 65536 + math.floor(x / 8)
end

local hosts = nil     -- 格 → { [變體] = 帳本 key }（宿主格）
local legacy = nil    -- 格 → { [帳本 key] = true }（還沒記 post 的舊記錄的錨點格）
local chunks = nil    -- chunk 鍵 → { wake = 有大門錨點, cells = { [格] = { x, y, z } } }：這個 chunk 載入時要做的事。
                      -- 只增不減：記錄刪掉後留下的項目只會多對齊一次、多掃描一次，伺服器重開時重建
local queue = {}      -- 等下一個 tick 對齊的格 { x, y, z }

local function chunkAt(x, y)
    local k = chunkKey(x, y)
    local c = chunks[k]
    if not c then
        c = { cells = {} }
        chunks[k] = c
    end
    return c
end

local function index(key, rec)
    chunkAt(rec.x, rec.y).wake = true
    local p = rec.post
    if p then
        local c = cell(p.x, p.y, rec.z)
        hosts[c] = hosts[c] or {}
        hosts[c][p.i] = key
        chunkAt(p.x, p.y).cells[c] = { p.x, p.y, rec.z }
    elseif DOOR_ADAPTERS[rec.adapter] and rec.kind ~= "Barrier" then
        local c = cell(rec.x, rec.y, rec.z)
        legacy[c] = legacy[c] or {}
        legacy[c][key] = true
        chunkAt(rec.x, rec.y).cells[c] = { rec.x, rec.y, rec.z }
    end
end

-- 帳本載入後第一次用到時建索引，並把每筆記錄排一次對齊：帳本載入前就載入的 chunk（開機順序）不會再觸發 LoadChunk
local function ready()
    if hosts then return true end
    local gates = L.gates()
    if not gates then return false end
    hosts, legacy, chunks = {}, {}, {}
    for key, rec in pairs(gates) do
        index(key, rec)
        local p = rec.post
        queue[#queue + 1] = p and { p.x, p.y, rec.z } or { rec.x, rec.y, rec.z }
    end
    return true
end

-- IsoObject(cell, square, spriteName)（IsoObject.java:331-336）→ AddTileObject（IsoGridSquare.java:5851-5880）→
-- MP 送給附近客戶端（transmitCompleteItemToClients，IsoObject.java:4604-4611；SP 是 no-op）
local function add(sq, code)
    local o = IsoObject.new(getCell(), sq, KP.readerTileName(code))
    sq:AddTileObject(o)
    o:transmitCompleteItemToClients()
end

-- 帳本這筆讀頭在變體 v 該用哪個讀頭代碼（顏色×64＋變體，Core.lua KP.readerCode）
local function tileFor(key, v)
    local rec = L.get(key)
    return ((rec and rec.color) or 0) * 64 + v
end

local function heal(x, y, z)
    local sq = getCell():getGridSquare(x, y, z)
    if not sq then return end
    local c = cell(x, y, z)
    local old = legacy[c]
    if old then
        legacy[c] = nil
        for key in pairs(old) do
            local rec = L.get(key)
            local adapter, anchor = nil, nil
            if rec and not rec.post then adapter, anchor = G.findAt(rec) end
            if adapter then R.attach(key, rec, adapter, anchor) end
        end
    end
    local want = {}   -- 變體 → 該用的 tile 索引
    for v, key in pairs(hosts[c] or {}) do want[v] = tileFor(key, v) end
    local seen, extra = {}, {}
    local objects = sq:getObjects()
    for i = 0, objects:size() - 1 do   -- 留最早放的那個，之後的重複、顏色不對與帳本沒有的移除
        local o = objects:get(i)
        local n = KP.readerCode(o)
        local v = n and n % 64
        if n and want[v] == n and not seen[v] then
            seen[v] = true
        elseif n then
            extra[#extra + 1] = o
        end
    end
    for _, o in ipairs(extra) do
        -- 普通 IsoObject 不是多格 entity；safelyRemove 照閘門給 false，不去找整組（IsoGridSquare.java:5942-5968）
        sq:transmitRemoveItemFromSquare(o, false)
        KP.log("reader post removed (not in ledger) at " .. x .. "," .. y .. "," .. z)
    end
    for v, n in pairs(want) do
        if not seen[v] then add(sq, n) end
    end
end

-- 帳本剛寫入讀頭（rec 已在帳本裡）：登記 chunk（載入時叫醒掃描，閘門與其他 MOD 的門也要）；門再記下門柱位置並放上模型
function R.attach(key, rec, adapter, anchor)
    if not ready() then return end
    local x, y, v = R.spot(adapter, anchor)
    if x then
        local old = legacy[cell(rec.x, rec.y, rec.z)]
        if old then old[key] = nil end
        rec.post = { x = x, y = y, i = v }
    end
    index(key, rec)
    if x then heal(x, y, rec.z) end
end

-- 帳本要刪這筆記錄（L.remove，刪之前呼叫）：拿掉模型。宿主格沒載入時留著，載入時由對齊移除
function R.detach(key, rec)
    if not ready() then return end
    local p = rec.post
    if not p then return end
    local m = hosts[cell(p.x, p.y, rec.z)]
    if m and m[p.i] == key then m[p.i] = nil end
    heal(p.x, p.y, rec.z)
end

-- 帳本改了讀頭顏色（rec.color）：宿主格已載入就馬上換模型，沒載入時等載入對齊
function R.refresh(key, rec)
    if not ready() then return end
    local p = rec.post
    if p then heal(p.x, p.y, rec.z) end
end

-- 任一格就算得出 chunk 位置（同一 chunk 的格 floor(x/8)、floor(y/8) 相同）。(0, 0, 0) 那格可能不存在，就掃其他格
local function anySquare(chunk)
    local sq = chunk:getGridSquare(0, 0, 0)
    if sq then return sq end
    for z = chunk:getMinLevel(), chunk:getMaxLevel() do
        for x = 0, 7 do
            for y = 0, 7 do
                sq = chunk:getGridSquare(x, y, z)
                if sq then return sq end
            end
        end
    end
end

-- LoadChunk：伺服器與 SP 每載入一個 chunk 觸發一次，在這個 chunk 的物件都 addToWorld 之後（IsoChunk.java:3695-3969；
-- 伺服器一次載入 64×64 格、逐 chunk 呼叫，ServerMap.java:950-956）。有讀頭大門的錨點就叫醒掃描（Sensor.lua S.wake），
-- 有要對齊的格就排到下一個 tick（雙開門的門片可能跨到還沒載入的相鄰 chunk）。不用每格觸發一次的 LoadGridsquare：
-- 地圖載入是所有 MOD 共用的負擔，每格都進一次 Lua 太貴
Events.LoadChunk.Add(function(chunk)
    if not ready() then return end
    local sq = anySquare(chunk)
    if not sq then return end
    local c = chunks[chunkKey(sq:getX(), sq:getY())]
    if not c then return end
    if c.wake then KP.Sensor.wake() end
    for _, q in pairs(c.cells) do queue[#queue + 1] = q end
end)

-- 格上已有的讀頭模型（帳本被清掉、存檔不同步時的孤兒）：chunk 載入時逐物件回呼（Lua/MapObjects.java:134-216，
-- 觸發點 IsoChunk.java:3829，伺服器與 SP 都跑）。7 色 × 變體 0-3
local names = {}
for c = 0, #KP.COLORS - 1 do
    for v = 0, 3 do names[#names + 1] = KP.readerTileName(c * 64 + v) end
    for v = 8, 8 + #KP.GATE_LOOKS * 4 - 1 do names[#names + 1] = KP.readerTileName(c * 64 + v) end
end
MapObjects.OnLoadWithSprite(names, function(obj)
    local sq = obj:getSquare()
    if sq then queue[#queue + 1] = { sq:getX(), sq:getY(), sq:getZ() } end
end, 5)

-- 門被拆、被打壞、被搬走（任何移除路徑都先觸發這個事件，IsoGridSquare.java:5745-5748、RemoveItemFromSquarePacket.java:151）：
-- handler 裡門還在，先記 key，下一個 tick 確認錨點真的不在（G.findAt 回 false）才刪帳本。讀頭標記只在錨點上，
-- 雙開門開關時刪掉重建的是第 2、3 片（IsoDoor.java:2855-2922），錨點第 1／4 片與宿主格的模型都不動。閘門由 Barrier.lua 自己收
local doomed = {}
Events.OnObjectAboutToBeRemoved.Add(function(obj)
    if not (obj.hasModData and obj:hasModData() and obj:getModData()[KP.MARKER_OWNER] ~= nil) or KP.isBarrier(obj) then
        return
    end
    local _, anchor = G.resolve(obj)
    if anchor then doomed[#doomed + 1] = G.key(anchor) end
end)

Events.OnTick.Add(function()
    if #doomed > 0 then
        local list = doomed
        doomed = {}
        for _, key in ipairs(list) do
            local rec = L.get(key)
            if rec and G.findAt(rec) == false then
                KP.log("gate removed, reader record removed key=" .. key .. " owner=" .. tostring(rec.owner))
                L.remove(key)
                KP.Sensor.forget(key)
            end
        end
    end
    -- 先 ready()：帳本載入後的第一個 tick 就建索引並排開機對齊，不等有格子載入
    if not ready() or #queue == 0 then return end
    local list = queue
    queue = {}
    for _, q in ipairs(list) do heal(q[1], q[2], q[3]) end
end)
