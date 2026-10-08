--[[
煙霧測試：用假的 PZ 全域載入**真正的** MOD Lua（shared Core/Gates/Parts、server Ledger/Sensor/Server；不載 client），
跑行為情境並斷言結果。

    lua scripts/smoke_harness.lua        （repo 根目錄執行；標準 Lua 5.x 即可）

為什麼需要（兩類 luac -p 抓不到的錯誤，皆為正式服實際事故）：
- 改函式簽章漏改呼叫點：語法完全合法，要等該路徑真的執行才炸
- 邏輯回歸：安全把關（範圍／阻隔／保護規則）被改壞時，「執行到並斷言」是唯一防線

限制（必須誠實面對）：這是標準 Lua，不是遊戲的 Kahlua。
- 標準 Lua 有 next/xpcall，Kahlua 沒有——本 harness **測不出**誤用，
  那由 scripts/verify_mod.py 的靜態掃描負責（發版前兩者都要跑）
- Kahlua 專屬行為（table.sort 遞迴深度、Java instance field 不暴露、rawget 呼叫形式、
  每個 table 都是 LinkedHashMap 的記憶體成本）只能靠反編譯查證與實機測試

假引擎的語意出處（42.21.0 反編譯，D=IsoDoor.java、T=IsoThumpable.java）：
- IsoDoor.ToggleDoor(nil) 什麼都不做（D:1501）；IsoThumpable.ToggleDoor(nil) 翻轉後 NPE、不 sync（T:1297,1310）
- 關著且 lockedByKey 或 modData.CustomLock==true、身上沒有對應 keyId 的鑰匙 → 拒開（D:1552-1560）；
  locked 但沒鑰匙也拒開（D:1577）；成功開關清 locked/lockedByKey（D:1600-1603、T:1307-1308）；
  可跨越的柵欄門強制解 locked/lockedByKey、不碰 CustomLock（D:1517-1520）
- 被擋（isObstructed／isDoubleDoorObstructed）就不翻（D:1597,1632、T:1288,1300）
- 雙開門第 2、3 片每次開關都刪掉重建：IsoDoor 新物件沒 modData、只帶 keyId；IsoThumpable 共用同一份 modData（D:2858-2926）
- setLockedByKey 在 server 不自動 sync（D:2009-2024、T:2429-2444）——用 client 視角 _view 證明 MOD 有手動同步
- IsoThumpable.setKeyId(id, doNetwork=false) 根本不改值（T:2411-2421）
- DrainableComboItem.setCurrentUsesFloat 量化到 UseDelta 一格（DrainableComboItem.java:83-87）
- SP：getOnlinePlayers 回空清單（LuaManager.java:4453-4463）、sendServerCommand 是 no-op（:8952-8970）
- SGlobalObjectSystem：derive／new／initSystem／RegisterSystemClass 照原版 server/Map/SGlobalObjectSystem.lua；
  存檔只留 setModDataKeys 白名單鍵（SGlobalObjectSystem.java:210-220）
- instanceof 走假類別登錄表（以物件為鍵查表，不經過 __index）
- 抬升閘門：entity 建造逐格 IsoThumpable → buildUtil.setInfo 每格都拷一份 need: 材料 → SpriteConfig OnCreate
  （ISBuildIsoEntity.lua:595-764、ISBuildingObject.lua:353-367）；IsoDoor sprite 建構子可能隨機上鎖（D:820-840）；
  車庫門開關換 sprite 為 index+8（D:793-805），整條鏈一起翻、不重建（D:3344-3394）；
  關車庫門時車身同時壓到門線兩側才算擋（D:3396-3457，只有關門時查）；拆除照 buildMaterials 退料後移走目標
  （ISDismantleAction.lua:47-95），大錘只移走被敲的那一個（ISDestroyStuffAction.lua:111-…）；殭屍／武器打壞車庫門走
  destroyGarageDoor，逐片 destroy（D:3460-3499），不掉材料（D:1385-1388）；每次移走物件前觸發 OnObjectAboutToBeRemoved
  （IsoGridSquare.java:5745、RemoveItemFromSquarePacket.java:151）
- IsoObject.setSpriteModelName／setAnimating／isAnimating（IsoObject.java:6274-6298、6399-6405）只記錄呼叫；
  client 檔只載 BarrierAnim（不碰 UI），MODE 不是 server 時才載
- 零件模型：template 讀真正的 vehicle_knoxpass_parts.txt；VehicleScript.Load 只覆寫出現的欄位、沒有的 model id 新增一個
  file 是 nil 的 model（VehicleScript.java:693-722）；setModelVisible 冪等、變了才標記同步（BaseVehicle.java:1707-1754），
  顯示 file 是 nil 的 model 記成客戶端 NPE（BaseVehicle.java:11844-11853）

寫情境的原則：
- 情境要「執行到會炸的路徑」——刪除後的收尾、跨 tick 的第二輪、聚合輸出，都是重災區
- 安全邊界要有**反面**斷言（範圍外／被阻隔／受保護的對象必須存活），不是只測 happy path
- 新防線寫完先「植入違規證明它會抓」再信任它——測不出來的測試等於沒有測試
]]

-- 家族佈局固定，直接填死最省事；scaffold 時由模板替換佔位符
-- KP_MEDIA：植入破壞時指向 MOD Lua 的暫存複本，不必動到 MOD 樹
local MEDIA = os.getenv("KP_MEDIA") or "MOD/MinidoracatKnoxPassFor42/Contents/mods/MinidoracatKnoxPassFor42/42/media/lua"

-- MOD 的 KP.log 走 print：收進 logLines 供斷言，harness 自己的輸出走 out
local out = print
local logLines = {}
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
    logLines[#logLines + 1] = table.concat(parts, " ")
end
local function logHas(pattern, from)
    for i = from or 1, #logLines do
        if string.find(logLines[i], pattern) then return true end
    end
    return false
end

-- ===== 假的 PZ 全域 =====
-- 起始時間要夠大：週期類邏輯常寫成 now - lastAt >= interval 而 lastAt 初值 0，
-- 從 0 起跳會讓第一輪永遠不觸發（遊戲的 getTimestampMs 本來就是大數）
local nowMs = 5000000
local MODE = "server"   -- "server"（專用伺服器）｜"sp"｜"client"（MP client）

function getTimestampMs() return nowMs end
function isServer() return MODE == "server" end
function isClient() return MODE == "client" end
function getDebug() return false end
function writeLog(_, text) logLines[#logLines + 1] = text end
function getText(key) return key end

local handlers = {}
Events = setmetatable({}, {
    __index = function(_, name)
        return {
            Add = function(fn)
                handlers[name] = handlers[name] or {}
                table.insert(handlers[name], fn)
            end,
        }
    end,
})
local function fire(name, ...)
    local list = handlers[name]
    if not list then return end
    for i = 1, #list do list[i](...) end
end

-- java 風格清單（size()/get(i)，0-based）——PZ 回傳的容器幾乎都是這個形狀
local function javaList(items)
    return {
        size = function() return #items end,
        get = function(_, i) return items[i + 1] end,
        _raw = items,
    }
end

-- 假類別登錄表：instanceof 以物件為鍵查表，不碰物件的 __index（Java 物件沒有 Lua 欄位可讀）
local classOf = setmetatable({}, { __mode = "k" })
local SUPER = {
    IsoDoor = "IsoObject", IsoThumpable = "IsoObject", IsoMovingObject = "IsoObject",
    IsoGameCharacter = "IsoMovingObject", IsoPlayer = "IsoGameCharacter", IsoZombie = "IsoGameCharacter",
    BaseVehicle = "IsoMovingObject", DrainableComboItem = "InventoryItem", Key = "InventoryItem",
}
local function new(class, meta, o)
    setmetatable(o, meta)
    classOf[o] = class
    return o
end
function instanceof(o, name)
    if type(o) ~= "table" then return false end
    local c = classOf[o]
    while c do
        if c == name then return true end
        c = SUPER[c]
    end
    return false
end

Capability = { CanOpenLockedDoors = "CanOpenLockedDoors" }

-- ===== 假世界 =====
local W
local function newWorld()
    return {
        squares = {}, unloaded = {}, players = {}, locals = {}, zombies = {}, vehicles = {},
        scripts = {}, template = nil, safehouse = {}, steam = false, hours = 1000, rand = 12345,
        nextItemId = 1233423, nextVid = 1,
        sent = {}, sendServerCalls = 0, itemStats = 0, removeSent = 0, addSent = 0, handsRemoved = 0,
        partDeltas = 0, nilToggles = 0, refused = 0, recreated = 0, obstructChecks = 0, copyCalls = 0,
        customLockTx = 0, garageBlocked = 0, removedObjs = 0, invalidated = 0, dropped = {}, onLoadSprite = {},
        vehicleQueries = 0, postTx = 0, paintUses = 0, modelFlags = 0, npe = {}, echoClosed = 0,
    }
end
-- MapObjects.OnLoadWithSprite（Lua/MapObjects.java:134-176）：記下回呼，loadSprites() 模擬區塊載入時逐物件呼叫
MapObjects = {
    OnLoadWithSprite = function(names, fn)
        if type(names) ~= "table" then names = { names } end
        for _, n in ipairs(names) do W.onLoadSprite[n] = fn end
    end,
}

local Square = {}
Square.__index = Square
local function square(x, y, z)
    z = z or 0
    local k = x .. "," .. y .. "," .. z
    local sq = W.squares[k]
    if not sq then
        sq = new("IsoGridSquare", Square, { _x = x, _y = y, _z = z, _objects = {}, _exterior = true })
        W.squares[k] = sq
    end
    return sq
end
function Square:getX() return self._x end
function Square:getY() return self._y end
function Square:getZ() return self._z end
function Square:getObjects() return javaList(self._objects) end
function Square:getSpecialObjects()   -- 門屬於 special objects（IsoGridSquare.java:9284；雙開門重建時也加進這裡 IsoDoor.java:2915-2918）
    local list = {}
    for _, o in ipairs(self._objects) do
        if instanceof(o, "IsoDoor") or instanceof(o, "IsoThumpable") then list[#list + 1] = o end
    end
    return javaList(list)
end
function Square:haveElectricity() return self._gen == true end
function Square:hasGridPower() return self._grid == true end
local function onSquare(o, sq)
    return math.floor(o:getX()) == sq._x and math.floor(o:getY()) == sq._y and math.floor(o:getZ()) == sq._z
end
function Square:getMovingObjects()
    local list = {}
    for _, p in ipairs(W.players) do if onSquare(p, self) then list[#list + 1] = p end end
    for _, zb in ipairs(W.zombies) do if onSquare(zb, self) then list[#list + 1] = zb end end
    return javaList(list)
end
-- 車身壓到哪些格：預設是車中心那格；_cover 指定多格（例如跨在門線兩側）
local function vehicleCovers(v, x, y, z)
    if v._cover then return v._cover[x .. "," .. y .. "," .. z] == true end
    return math.floor(v._x) == x and math.floor(v._y) == y and math.floor(v._z) == z
end
function Square:getVehicleContainer()   -- 回第一台與這格相交的車（IsoGridSquare.java:9872-9893）
    W.vehicleQueries = W.vehicleQueries + 1
    for _, v in ipairs(W.vehicles) do if vehicleCovers(v, self._x, self._y, self._z) then return v end end
    return nil
end

local cell = {
    getGridSquare = function(_, x, y, z)
        if W.unloaded[x .. "," .. y .. "," .. z] then return nil end
        return square(x, y, z)
    end,
    createNewGridSquare = function(_, x, y, z) return square(x, y, z) end,   -- IsoCell.java（ISBuildIsoEntity.lua 同用法）
}
-- 載入 (x, y) 所在的 chunk：LoadChunk(chunk)（IsoChunk.java:3969）。Lua 拿得到的只有 chunk 內座標的 getGridSquare 與樓層範圍
local function loadChunk(x, y)
    local ox, oy = math.floor(x / 8) * 8, math.floor(y / 8) * 8
    fire("LoadChunk", {
        getGridSquare = function(_, lx, ly, z) return cell:getGridSquare(ox + lx, oy + ly, z) end,
        getMinLevel = function() return 0 end,
        getMaxLevel = function() return 0 end,
    })
end
function getCell() return cell end
function getGameTime() return { getWorldAgeHours = function() return W.hours end } end
function getSteamModeActive() return W.steam end
function ZombRand(a, b)   -- ZombRand(n)＝0..n-1；ZombRand(a, b)＝a..b-1
    if b == nil then a, b = 0, a end
    W.rand = (W.rand * 1103515245 + 12345) % 2147483648
    return a + W.rand % (b - a)
end

SafeHouse = {
    isSafehouseAllowInteract = function(sq, player)
        local allowed = W.safehouse[sq]
        return allowed == nil or allowed[player:getUsername()] == true
    end,
}

-- 網路：只有 server 真的送（LuaManager.java:8952-8970、12366-12426；GameServer.java:3162）
function sendServerCommand(player, module, command, args)
    W.sendServerCalls = W.sendServerCalls + 1
    if isServer() then W.sent[#W.sent + 1] = { via = "mp", player = player, module = module, cmd = command, args = args } end
end
function sendItemStats() if isServer() then W.itemStats = W.itemStats + 1 end end
function sendRemoveItemFromContainer() if isServer() then W.removeSent = W.removeSent + 1 end end
function sendAddItemToContainer() if isServer() then W.addSent = W.addSent + 1 end end

-- ===== 物品與容器 =====
local TAG, READER = "MinidoracatKnoxPass.VehicleTag", "MinidoracatKnoxPass.GateReader"
local COLOR_IDS = { "Black", "Graphite", "Olive", "Navy", "Orange", "Red" }   -- 索引 1-6（米白 0 不帶後綴）
local PAINTS = { "Base.PaintWhite", "Base.PaintBlack", "Base.PaintGrey", "Base.PaintGreen", "Base.PaintBlue", "Base.PaintOrange", "Base.PaintRed" }
local USE_DELTA = { [TAG] = 0.001, ["Base.CarBattery1"] = 0.00001 }
for _, id in ipairs(COLOR_IDS) do USE_DELTA[TAG .. "_" .. id] = 0.001 end
for _, p in ipairs(PAINTS) do USE_DELTA[p] = 0.1 end   -- 原版油漆 UseDelta 0.1（generated/items/drainable.txt:1803-1817）
local TAGS = { ["Base.Paintbrush"] = "base:paintbrush" }
ItemTag = { PAINTBRUSH = "base:paintbrush", SCREWDRIVER = "base:screwdriver" }

local Item = {}
Item.__index = Item
function Item:getID() return self._id end
function Item:getFullType() return self._type end
function Item:getContainer() return self._container end
function Item:getCondition() return self._condition or 100 end
function Item:setCondition(c) self._condition = c end
local Drain = setmetatable({}, { __index = Item })
Drain.__index = Drain
function Drain:getUseDelta() return self._useDelta end
function Drain:getCurrentUsesFloat() return self._uses * self._useDelta end
function Drain:setCurrentUsesFloat(v)   -- 量化到一格（Math.round）
    v = math.max(0, math.min(1, v))
    self._uses = math.floor(v / self._useDelta + 0.5)
end
function Drain:getCurrentUses() return self._uses end
-- 油漆：用一格，用完換成空桶（DrainableComboItem.java:322-383）；伺服器上同步計數
function Drain:UseAndSync()
    W.paintUses = W.paintUses + 1
    self._uses = self._uses - 1
    if self._uses <= 0 and self._container then
        local c = self._container
        c:DoRemoveItem(self)
        c:AddItem("Base.PaintbucketEmpty")
    end
end

local function newItem(fullType, charge)
    local id = W.nextItemId
    W.nextItemId = W.nextItemId + 7919
    local delta = USE_DELTA[fullType]
    if delta then
        local it = new("DrainableComboItem", Drain, { _id = id, _type = fullType, _useDelta = delta, _uses = 0 })
        it:setCurrentUsesFloat(charge or 1)
        return it
    end
    return new("InventoryItem", Item, { _id = id, _type = fullType, _tag = TAGS[fullType] })
end
local function newKey(keyId)
    local k = newItem("Base.Key1")
    k._keyId = keyId
    classOf[k] = "Key"
    return k
end

local Container = {}
Container.__index = Container
local function newContainer() return new("ItemContainer", Container, { _items = {} }) end
function Container:AddItem(x)
    if type(x) == "string" then x = newItem(x) end
    if x._container then x._container:DoRemoveItem(x) end   -- 物品同時只在一個容器
    self._items[#self._items + 1] = x
    x._container = self
    return x
end
function Container:DoRemoveItem(item)
    for i, it in ipairs(self._items) do
        if it == item then
            table.remove(self._items, i)
            item._container = nil
            return
        end
    end
end
function Container:getItems() return javaList(self._items) end   -- 活的清單（ItemContainer.getItems 回內部 ArrayList）
function Container:getItemWithIDRecursiv(id)
    for _, it in ipairs(self._items) do if it._id == id then return it end end
    return nil
end
function Container:haveThisKeyId(id)   -- ItemContainer.java:3242-3255
    for _, it in ipairs(self._items) do if it._keyId == id then return it end end
    return nil
end
local function evalAll(inv, fn)
    local list = {}
    for _, it in ipairs(inv._items) do if fn(it) then list[#list + 1] = it end end
    return list
end
function Container:getAllTypeRecurse(t) return javaList(evalAll(self, function(it) return it._type == t end)) end
function Container:getAllEvalRecurse(fn) return javaList(evalAll(self, fn)) end   -- ItemContainer.java:1936
function Container:getFirstEvalRecurse(fn) return evalAll(self, fn)[1] end          -- :1491
function Container:containsEvalRecurse(fn) return evalAll(self, fn)[1] ~= nil end    -- :1146
function Container:getFirstTypeRecurse(t) return evalAll(self, function(it) return it._type == t end)[1] end
function Container:getFirstTypeEvalRecurse(t, fn) return evalAll(self, function(it) return it._type == t and fn(it) end)[1] end   -- :1569
function Container:getFirstTagRecurse(tag) return evalAll(self, function(it) return it._tag == tag end)[1] end
local function countType(inv, t) return inv:getAllTypeRecurse(t):size() end

-- ===== 角色 =====
local Role = {}
Role.__index = Role
function Role:hasCapability(c) return self._caps[c] == true end

local Player = {}
Player.__index = Player
function Player:getUsername() return self._name end
function Player:getPlayerNum() return self._num end
function Player:getSteamID() return self._sid end
function Player:getRole() return self._role end
function Player:getX() return self._x end
function Player:getY() return self._y end
function Player:getZ() return self._z end
function Player:getVehicle() return self._vehicle end
function Player:getInventory() return self._inv end
function Player:removeFromHands() W.handsRemoved = W.handsRemoved + 1 end
function Player:getCurrentSquare() return square(math.floor(self._x), math.floor(self._y), math.floor(self._z)) end
function Player:getOnlineID() return 1 end

local function newPlayer(name, x, y, opts)
    opts = opts or {}
    local p = new("IsoPlayer", Player, {
        _name = name, _num = opts.num or 0, _sid = opts.sid, _x = x + 0.5, _y = y + 0.5, _z = opts.z or 0,
        _inv = newContainer(), _role = setmetatable({ _caps = opts.caps or {} }, Role),
    })
    W.players[#W.players + 1] = p
    return p
end
local function newZombie(x, y)
    local zb = new("IsoZombie", {
        __index = {
            getX = function(s) return s._x end, getY = function(s) return s._y end, getZ = function() return 0 end,
            getInventory = function(s) return s._inv end,   -- 殭屍沒有鑰匙（ToggleDoorActual 照樣查，IsoDoor.java:1568）
        },
    }, { _x = x + 0.5, _y = y + 0.5, _inv = newContainer() })
    W.zombies[#W.zombies + 1] = zb
    return zb
end
-- 會開門的殭屍（認知 1）歸擁有牠的客戶端模擬，拍門（IsoDoor.Thump，D:1179-1183）與 ToggleDoorActual 都在 client 跑，
-- 看的是 client 那份 locked：locked 時沒鑰匙一律開不了（D:1577-1580），殭屍在室內也一樣。client 開了門再送
-- SyncIsoObject，伺服器照單全收（GameServer.java:2969-2987）：伺服器這邊鎖被清掉、門開了
local function zombieThump(door, zb)
    if door._open or door._view.locked then return end
    door._locked, door._lockedByKey = false, false
    door:ToggleDoor(zb)
end

-- ===== 門 =====
local function syncView(o)   -- client 看到的狀態只在明確 sync 時更新
    local v = o._view
    v.open, v.locked, v.lockedByKey, v.keyId = o._open, o._locked, o._lockedByKey, o._keyId
end
local function hasKey(chr, o) return chr:getInventory():haveThisKeyId(o._keyId) ~= nil end

local Base = {}
function Base:getSquare() return self._square end
function Base:getNorth() return self._north end
function Base:IsOpen() return self._open end
function Base:isLocked() return self._locked end
function Base:isLockedByKey() return self._lockedByKey end
function Base:getKeyId() return self._keyId end
function Base:getModData() return self._modData end
function Base:hasModData()   -- table 存在且非空（IsoObject.java:1037-1039、IsoThumpable.java:170-172）
    for _ in pairs(self._modData) do return true end
    return false
end
function Base:transmitModData()   -- IsoObject.java:4857-4866：整表送給附近 client
    local copy = {}
    for k, v in pairs(self._modData) do copy[k] = v end
    self._view.modData = copy
    if copy.CustomLock == true then W.customLockTx = W.customLockTx + 1 end
end
function Base:isObstructed()
    W.obstructChecks = W.obstructChecks + 1
    return self._obstructed
end
function Base:getObjectIndex()
    local sq = self._square
    if not sq then return -1 end
    for i, o in ipairs(sq._objects) do if o == self then return i - 1 end end
    return -1
end
function Base:sync() if self.syncIsoObject then self:syncIsoObject(false) else syncView(self) end end   -- IsoObject.java:885-887
function Base:setLockedByKey(b)   -- server 上不 sync（D:2009-2024、T:2429-2444）
    local changed = b ~= self._lockedByKey
    self._lockedByKey, self._locked = b, b
    if changed and not isServer() then syncView(self) end
end
function Base:getSprite() return self._spriteObj end
function Base:isAnimating() return self._animating == true end
function Base:setAnimating(b) self._animating = b end
function Base:setSpriteModelName(n) self._smName = n end
function Base:invalidateRenderChunkLevel() W.invalidated = W.invalidated + 1 end

local Door = setmetatable({}, { __index = Base })
Door.__index = Door
local Thump = setmetatable({}, { __index = Base })
Thump.__index = Thump

local function makePiece(cls, x, y, north)
    local o = new(cls, cls == "IsoThumpable" and Thump or Door, {
        _open = false, _locked = false, _lockedByKey = false, _keyId = -1, _modData = {}, _north = north,
        _obstructed = false, _view = { modData = {} },
    })
    local sq = square(x, y, 0)
    o._square = sq
    sq._objects[#sq._objects + 1] = o
    syncView(o)
    return o
end
local function removeObj(o)
    fire("OnObjectAboutToBeRemoved", o)
    local sq = o._square
    for i, x in ipairs(sq._objects) do
        if x == o then
            table.remove(sq._objects, i)
            break
        end
    end
    o._square = nil
end
function Square:AddSpecialObject(o)
    self._objects[#self._objects + 1] = o
    o._square = self
end
-- 單參數＝safelyRemove（chunk 已載入時，IsoGridSquare.java:5713-5716）：sprite 有 GarageDoor 的走車庫門鏈（這裡的用法只有自己）；
-- entity 多格物件（_entity＝同一次建造放下的各格，size＝整組格數）要整組都在才整組移除，少一格就回 -1、什麼都不移
-- （IsoObjectUtils.java:32-41、83-113）。第二參數 false 只移自己
function Square:RemoveTileObject(o, safely)
    if o._square ~= self then return -1 end
    local prefix, i = string.match(o:getSprite():getName(), "^(.-)_(%d+)$")
    if safely ~= false and o._entity and not (prefix and garageProps(prefix, tonumber(i))) then
        if #o._entity < o._entity.size then return -1 end
        for _, p in ipairs(o._entity) do if p._square == nil then return -1 end end
        for _, p in ipairs(o._entity) do removeObj(p) end
        return 0
    end
    removeObj(o)
    return 0
end
-- safelyRemove 預設 true：entity 建出的多格物件要先找齊整組（IsoObjectUtils.safelyRemoveTileObjectFromSquare，
-- IsoGridSquare.java:5942-5968），閘門的車道已換成 IsoDoor、找不齊，引擎回 -1、什麼都不移（barrier-mp 1005f 實踩）
function Square:transmitRemoveItemFromSquare(o, safelyRemove)
    if o._entityMulti and safelyRemove ~= false then return -1 end
    if o._square == self then
        removeObj(o)
        W.removedObjs = W.removedObjs + 1
    end
end
function Square:RecalcAllWithNeighbours() end
function Square:AddTileObject(o)   -- IsoGridSquare.java:5851-5880（門柱讀頭模型用）
    self._objects[#self._objects + 1] = o
    o._square = self
end

-- tile 的 sprite（只要 getName）；getSprite(name) 對任何名稱都回一張（MOD 只拿它當建構子參數）
local Sprite = {}
Sprite.__index = Sprite
function Sprite:getName() return self._name end
local function namedSprite(name) return setmetatable({ _name = name }, Sprite) end
local function barrierSprite(i) return namedSprite("MinidoracatKnoxPass_barrier_" .. i) end
function getSprite(name) return namedSprite(name) end

-- 門柱讀頭模型：IsoObject(cell, square, spriteName)（IsoObject.java:331-336）是普通物件、沒有 modData；
-- transmitCompleteItemToClients 只在伺服器送 AddItemToMap（:4604-4611）
local Prop = setmetatable({}, { __index = Base })
Prop.__index = Prop
function Prop:hasModData() return false end
function Prop:transmitCompleteItemToClients() if isServer() then W.postTx = W.postTx + 1 end end
IsoObject = {
    new = function(_, _sq, name)
        return new("IsoObject", Prop, { _spriteObj = setmetatable({ _name = name }, Sprite), _modData = {} })
    end,
}

-- 雙開門：第 1-4 片在 (x..x+3, y)；開著時第 2、3 片搬到 y-1 那排重建
local function toggleDouble(o)
    local g = o._group
    local open = (g.pieces[1] or g.pieces[4])._open
    for i = 1, 4 do
        local p = g.pieces[i]
        if p then
            p._open = not open
            p:setLockedByKey(false)
            local keyId = instanceof(p, "IsoDoor") and p:checkKeyId() or p:getKeyId()
            if i == 2 or i == 3 then
                removeObj(p)
                local n = makePiece(g.cls, g.x + i - 1, g.y + (open and 0 or -1), p._north)
                n._open, n._keyId, n._group, n._index = not open, keyId, g, i
                if g.cls == "IsoThumpable" then n._modData = p._modData end
                g.pieces[i] = n
                W.recreated = W.recreated + 1
            end
        end
    end
    -- sync 第 1（或 4）片；client 端 toggleDoubleDoor 翻整組並清鎖（D:1795-1815）
    for i = 1, 4 do
        local p = g.pieces[i]
        if p then
            p._view.open, p._view.locked, p._view.lockedByKey = p._open, false, false
        end
    end
end

function Door:setLocked(b) self._locked = b end
function Door:setIsLocked(b) self._locked = b end
function Door:setKeyId(id) self._keyId = id end
function Door:checkKeyId()   -- D:2372-2398
    if self._keyId ~= -1 then return self._keyId end
    if self._buildingKeyId then
        self._keyId = self._buildingKeyId
        if self._locked and not self._lockedByKey then self._lockedByKey = true end
    end
    return self._keyId
end
-- 車庫門：整條鏈一起翻，物件不重建；server 只 sync 被點的那片，client 依片段清單更新整組（D:3344-3393、1795-1815）。
-- 鏈照引擎的 First／Next 走（D:3282-3342）；開關時換成 index±8 的 sprite（D:793-805）
local function garageChain(o)
    local out = {}
    local p = IsoDoor.getGarageDoorFirst(o) or o
    while p do
        out[#out + 1] = p
        p = IsoDoor.getGarageDoorNext(p)
    end
    return out
end
-- client 收到 SyncIsoObject（D:1772-1774）：車庫門另外逐片 setOpen＋setLockedByKey(bLockedByKey)（D:1811-1822），
-- setLockedByKey 會連帶設 locked（D:2013-2016）。所以車庫門只有鑰匙鎖送得到 client，只有 locked 的會被蓋成 false。
-- 鏈上其他片在 client 的鑰匙鎖因此改變時，client 的 setLockedByKey 會 sync，把那片當下的狀態（含開關）送回伺服器
-- （D:2017-2022、1681-1694）；回送下一個 tick 才到（step 套用）
local function echoChain(o, open, byKey)
    if not isServer() then return end
    for _, p in ipairs(garageChain(o)) do
        if p ~= o and p._view.lockedByKey ~= byKey then
            W.echo = W.echo or {}
            W.echo[#W.echo + 1] = { p, byKey, open }
        end
    end
end
function Door:syncIsoObject(bRemote)
    if bRemote then return end
    syncView(self)
    if self._garage then
        echoChain(self, self._open, self._lockedByKey)
        for _, p in ipairs(garageChain(self)) do
            p._view.open, p._view.locked, p._view.lockedByKey = self._open, self._lockedByKey, self._lockedByKey
        end
    end
end
local function garageStraddled(o)   -- D:3396-3457：任一片的格子與門線另一側那格被同一台車壓到
    for _, p in ipairs(garageChain(o)) do
        local sq = p._square
        for _, v in ipairs(W.vehicles) do
            if vehicleCovers(v, sq._x, sq._y, sq._z)
                and vehicleCovers(v, sq._x - (p._north and 0 or 1), sq._y - (p._north and 1 or 0), sq._z) then
                return true
            end
        end
    end
    return false
end
-- 引擎逐片翻開關並清鎖（D:3344-3366），再 sync 被點的那片（D:3384-3386）：client 照上面的語意更新整條鏈並回送
local function toggleGarage(o)
    local chain = garageChain(o)
    for _, p in ipairs(chain) do
        p._open = not p._open
        p:setLockedByKey(false)
        if p._closedName then p._spriteObj = namedSprite(p._open and p._openName or p._closedName) end
    end
    echoChain(o, o._open, false)
    for _, p in ipairs(chain) do
        p._view.open, p._view.locked, p._view.lockedByKey = p._open, false, false
    end
end

function Door:ToggleDoor(chr)
    if chr == nil then
        W.nilToggles = W.nilToggles + 1
        return                                                   -- D:1501
    end
    local isPlayer = instanceof(chr, "IsoPlayer")
    if isServer() and isPlayer and chr:getRole():hasCapability(Capability.CanOpenLockedDoors) then
        self._locked = false
        self:setLockedByKey(false)                               -- D:1507-1510
    end
    if self._hoppable and not self._open then
        self._locked = false
        self:setLockedByKey(false)                               -- D:1517-1520
    end
    self:checkKeyId()
    if self._locked and not self._lockedByKey and self._keyId ~= -1 then self._lockedByKey = true end
    if isPlayer and (self._lockedByKey or self._modData.CustomLock == true) and not self._open then
        if not hasKey(chr, self) then                            -- D:1552-1560
            W.refused = W.refused + 1
            self:sync()
            return
        end
        self._locked = false
        self:setLockedByKey(false)
    end
    local bUnlock = hasKey(chr, self)
    if isPlayer and self._garage then   -- 車庫門改用站的位置決定（D:1569-1575，沒有 InteriorSide 屬性）
        if self._north then bUnlock = chr:getY() < self._square._y else bUnlock = chr:getX() < self._square._x end
    end
    if self._locked and not bUnlock and not self._open then   -- D:1577
        W.refused = W.refused + 1
        return
    end
    if self._garage then
        if self._open and garageStraddled(self) then              -- 只在關門時檢查擋車（D:1583、3396-3408）
            W.garageBlocked = W.garageBlocked + 1
            return
        end
        toggleGarage(self)
    elseif self._group then
        if self._group.obstructed then return end                -- D:1632
        toggleDouble(self)
    elseif self:isObstructed() then
        return                                                   -- D:1597
    else
        self._locked = false
        self:setLockedByKey(false)
        self._open = not self._open
        self:sync()                                              -- D:1600-1622
    end
end

function Thump:isDoor() return self._isDoor ~= false end
function Thump:getBuildMaterials() return self._buildMaterials or {} end
function Thump:setIsLocked(b) self._locked = b end
function Thump:setKeyId(id, doNetwork)   -- T:2411-2421：doNetwork=false 時不改值
    if doNetwork == nil then doNetwork = true end
    if doNetwork and self._keyId ~= id then
        self._keyId = id
        self:syncIsoThumpable()
    end
end
function Thump:syncIsoThumpable() syncView(self) end
function Thump:ToggleDoor(chr)
    if chr == nil then W.nilToggles = W.nilToggles + 1 end
    local isPlayer = chr ~= nil and instanceof(chr, "IsoPlayer")
    local outside = isPlayer and chr:getCurrentSquare()._exterior
    if self._lockedByKey and isPlayer and outside and not hasKey(chr, self) then   -- T:1258-1262
        W.refused = W.refused + 1
        self:sync()
        return
    end
    if self._lockedByKey and isPlayer and hasKey(chr, self) then
        self:setIsLocked(false)
        self:setLockedByKey(false)
    end
    if self._locked and isPlayer and outside and not self._open then             -- T:1274
        W.refused = W.refused + 1
        return
    end
    if self._group then
        if self._group.obstructed then return end
        toggleDouble(self)
        if chr == nil then error("NullPointerException IsoThumpable.java:1297") end
    elseif self:isObstructed() then
        return
    else
        self._open = not self._open
        self:setLockedByKey(false)
        if chr == nil then error("NullPointerException IsoThumpable.java:1310") end   -- 已翻轉、未 sync
        self:sync()
    end
end

-- 引擎門片的耐久：IsoDoor 預設 500（D:808-809）；setHealth 只改 health（maxHealth 不動，D:1261-1263 getThumpCondition 夾住）
function Door:setHealth(h) self._health = h end
function Door:getHealth() return self._health end

-- sprite 的 GarageDoor 屬性（第幾片）與是不是開著的那張（.tiles 的事實，D:793-805 開關差 8）：
-- 閘門照 build_barrier_tiles.py（車道 0-5、80-85 關，＋8 開；機箱、姿勢、替代 tile 160 起都沒有）；
-- 模型門照 build_model_gates.py（每 64 格一個區塊：格位 0-2 關、8-10 開）；
-- 原版捲門每款北向、西向的第 1 片起連續三張（同 Barrier.lua ROLL_STYLES）
local VANILLA_GARAGE = { industry_trucks_01 = { 35, 32 }, walls_garage_01 = { 19, 16, 51, 48 } }
local MODEL_SETS = {}
for _, s in ipairs({ "barrier2", "roll2f_industry", "roll2f_green", "roll2f_white", "gate_a", "gate_b", "gate_c", "gate_d", "gate_e" }) do
    MODEL_SETS["MinidoracatKnoxPass_" .. s] = true
end
function garageProps(prefix, i)
    if prefix == "MinidoracatKnoxPass_barrier" then
        local rel = i % 80
        if i >= 160 or rel == 6 or rel == 7 or rel > 13 then return nil, false end
        local open = rel >= 8
        return (open and rel - 8 or rel) % 3 + 1, open
    end
    if MODEL_SETS[prefix] then
        local slot = i % 64
        if slot <= 2 then return slot + 1, false end
        if slot >= 8 and slot <= 10 then return slot - 7, true end
        return nil, false
    end
    for _, first in ipairs(VANILLA_GARAGE[prefix] or {}) do
        for k = 0, 2 do
            if i == first + k then return k + 1, false end
            if i == first + k + 8 then return k + 1, true end
        end
    end
    return nil, false
end

IsoDoor = {
    getDoubleDoorIndex = function(o)
        if o and o._group and o._square then return o._index end
        return -1
    end,
    getDoubleDoorObject = function(o, i)
        if IsoDoor.getDoubleDoorIndex(o) == -1 then return nil end
        return o._group.pieces[i]
    end,
    isDoubleDoorObstructed = function(o) return o._group.obstructed == true end,
    -- 車庫門 index：關著 1–3、開著的 sprite 4–6 換算回 1–3（D:3212-3238）；Prev 往 x-1／y+1、Next 往 x+1／y-1（D:3241-3321）
    getGarageDoorIndex = function(o)
        if o and o._garage and o._square then return o._garage end
        return -1
    end,
    getGarageDoorPrev = function(o)
        local idx = IsoDoor.getGarageDoorIndex(o)
        if idx == -1 or idx == 1 then return nil end
        local sq = o._square
        local n = getCell():getGridSquare(sq._x - (o._north and 1 or 0), sq._y + (o._north and 0 or 1), sq._z)
        if not n then return nil end
        for _, x in ipairs(n._objects) do
            if instanceof(x, "IsoDoor") and x._north == o._north and IsoDoor.getGarageDoorIndex(x) <= idx then return x end
        end
        return nil
    end,
    getGarageDoorNext = function(o)
        local idx = IsoDoor.getGarageDoorIndex(o)
        if idx == -1 or idx == 3 then return nil end
        local sq = o._square
        local n = getCell():getGridSquare(sq._x + (o._north and 1 or 0), sq._y - (o._north and 0 or 1), sq._z)
        if not n then return nil end
        for _, x in ipairs(n._objects) do
            if instanceof(x, "IsoDoor") and x._north == o._north and IsoDoor.getGarageDoorIndex(x) >= idx then return x end
        end
        return nil
    end,
    getGarageDoorFirst = function(o)   -- D:3323-3338
        local idx = IsoDoor.getGarageDoorIndex(o)
        if idx == -1 then return nil end
        if idx == 1 then return o end
        local prev = IsoDoor.getGarageDoorPrev(o)
        while prev do
            if IsoDoor.getGarageDoorIndex(prev) == 1 then return prev end
            prev = IsoDoor.getGarageDoorPrev(prev)
        end
        return o
    end,
    -- IsoDoor(cell, sq, IsoSprite, north)（D:789-805）：不加進格子（呼叫端 AddSpecialObject）；GarageDoor 的開關 sprite 差 8。
    -- 建構子照沙盒 lockedHouses 可能上鎖（D:820-840），這裡一律鎖上，證明 MOD 有解；health 預設 500（D:808-809）
    new = function(_, _sq, sprite, north)
        local prefix, i = string.match(sprite:getName(), "^(.-)_(%d+)$")
        i = tonumber(i)
        local gd, open = garageProps(prefix, i)
        local closed = open and i - 8 or i
        local d = new("IsoDoor", Door, {
            _open = open, _locked = true, _lockedByKey = true, _keyId = -1, _modData = {}, _north = north,
            _obstructed = false, _view = { modData = {} }, _spriteObj = sprite, _garage = gd, _health = 500,
            _closedName = prefix .. "_" .. closed, _openName = prefix .. "_" .. (closed + 8),
        })
        syncView(d)
        return d
    end,
}

local function makeDoor(cls, x, y, opts)
    opts = opts or {}
    local d = makePiece(cls, x, y, true)
    d._hoppable, d._buildingKeyId = opts.hoppable, opts.buildingKeyId
    if opts.keyId then d._keyId = opts.keyId end
    if opts.lockedByKey then d._lockedByKey, d._locked = true, true end
    if opts.locked then d._locked = true end
    syncView(d)
    return d
end
local function makeDouble(cls, x, y)
    local g = { pieces = {}, cls = cls, x = x, y = y }
    for i = 1, 4 do
        local p = makePiece(cls, x + i - 1, y, true)
        p._group, p._index = g, i
        g.pieces[i] = p
    end
    return g
end
-- 車庫門三片 (x..x+2, y)：第 1 片、中間片、最後一片；地圖上的車庫門關著就是 locked（CellLoader.java:101-104）
local function makeGarage(x, y)
    local gg = { pieces = {} }
    for i = 1, 3 do
        local p = makePiece("IsoDoor", x + i - 1, y, true)
        p._garage, p._gg, p._locked = i, gg, true
        syncView(p)
        gg.pieces[i] = p
    end
    return gg
end

-- ===== 車輛 =====
local Part = {}
Part.__index = Part
function Part:getInventoryItem() return self._item end
function Part:setCondition(c) self._condition = c end
function Part:getId() return self._id end
function Part:getIndex() return self._index or 30 end
-- VehiclePart.setModelVisible → BaseVehicle.setModelVisible（VehiclePart.java:467-470、BaseVehicle.java:1707-1754）：
-- 零件腳本沒有這個 model id 就不動；已顯示再開、沒顯示再關直接返回、不標記同步；真的變了才標記 updateFlags 64（W.modelFlags）。
-- 顯示一個 file 是 nil 的 model＝客戶端畫車時 NPE 踢回主選單：零件沒有 parent 時 ModelInfo.getAnimationPlayer
-- 用 scriptModel.file（BaseVehicle.java:11844-11853）→ getModelScript(null)（ScriptBucketCollection.java:73），記進 W.npe
function Part:setModelVisible(id, visible)
    local m = self._scriptPart and self._scriptPart.models and self._scriptPart.models[id]
    if not m then return end
    self._shown = self._shown or {}
    if (self._shown[id] == true) == visible then return end
    if visible and m.file == nil then W.npe[#W.npe + 1] = id end
    self._shown[id] = visible or nil
    W.modelFlags = W.modelFlags + 1
end

local Vehicle = {}
Vehicle.__index = Vehicle
function Vehicle:getX() return self._x end
function Vehicle:getY() return self._y end
function Vehicle:getZ() return self._z end
function Vehicle:getId() return self._id end
function Vehicle:getDriver() return self._seats[0] end
function Vehicle:getPartById(id) return self._parts[id] end
function Vehicle:getScriptName() return self._script end
function Vehicle:getScript() return self._vscript end
function Vehicle:getBatteryCharge() return self._battery end
function Vehicle:transmitPartUsedDelta() if isServer() then W.partDeltas = W.partDeltas + 1 end end   -- BaseVehicle.java:8235-8244
function Vehicle:isIntersectingSquare(x, y, z) return vehicleCovers(self, x, y, z) end
-- 拖著的車（BaseVehicle.java vehicleTowing；原版掛拖車在伺服器上 addPointConstraint 建立，server/Vehicles/VehicleCommands.lua:410）
function Vehicle:getVehicleTowing() return self._towing end
-- 車頭朝向：getForwardVector(out) 寫入出參數，Vector3f 的 x、z 是世界 x、y（BaseVehicle.java:4286；
-- 家族 MDAD_Driver.lua 同寫法）。假車預設朝北（y 減少），大門都在車的北邊
function Vehicle:getForwardVector(out)
    out._x, out._y, out._z = self._fx, 0, self._fy
    return out
end
local Vector3f = {}
Vector3f.__index = Vector3f
function Vector3f:x() return self._x end
function Vector3f:y() return self._y end
function Vector3f:z() return self._z end
local vecOut = 0
BaseVehicle = {   -- 物件池（BaseVehicle.java:510、522）；計數證明有借有還
    allocVector3f = function()
        vecOut = vecOut + 1
        return setmetatable({ _x = 0, _y = 0, _z = 0 }, Vector3f)
    end,
    releaseVector3f = function() vecOut = vecOut - 1 end,
}

local function makeVehicle(x, y, opts)
    opts = opts or {}
    local v = new("BaseVehicle", Vehicle, {
        _x = x, _y = y, _z = 0, _id = W.nextVid, _seats = {}, _script = opts.script or "Base.CarNormal", _battery = opts.battery or 0.8,
        _fx = 0, _fy = -1,
        _parts = {
            KnoxPassTag = setmetatable({ _id = "KnoxPassTag" }, Part),
            Battery = setmetatable({ _id = "Battery" }, Part),
        },
    })
    W.nextVid = W.nextVid + 1
    if opts.tag then v._parts.KnoxPassTag._item = newItem(opts.tagType or TAG, opts.tag) end
    -- opts.vscript：注入過的車型腳本，零件帶它的 KnoxPassTag 零件腳本（7 個 Dock model）與在腳本裡的索引
    local vs, tagPart = opts.vscript, v._parts.KnoxPassTag
    v._vscript = vs
    for i, p in ipairs(vs and vs._parts or {}) do
        if p.id == "KnoxPassTag" then tagPart._scriptPart, tagPart._index = p, i - 1 end
    end
    tagPart._index = opts.index or tagPart._index
    W.vehicles[#W.vehicles + 1] = v
    return v
end
function getVehicleById(id)
    for _, v in ipairs(W.vehicles) do if v._id == id then return v end end
    return nil
end
local function seat(p, v, idx)
    v._seats[idx or 0] = p
    p._vehicle = v
    p._x, p._y = v._x, v._y
end
local function unseat(p)
    local v = p._vehicle
    for k, x in pairs(v._seats) do if x == p then v._seats[k] = nil end end
    p._vehicle = nil
end
local function moveCar(v, x, y)
    v._x, v._y = x, y
    for _, p in pairs(v._seats) do p._x, p._y = x, y end
end

-- ===== 本機／線上玩家 =====
function getOnlinePlayers()
    if not isServer() then return javaList({}) end   -- SP 回空清單
    return javaList(W.players)
end
function getNumActivePlayers() return #W.locals end
function getSpecificPlayer(i) return W.locals[i + 1] end

-- ===== 載具腳本（零件注入）=====
local VScript = {}
VScript.__index = VScript
local function vec(x, y, z)
    return { x = function() return x end, y = function() return y end, z = function() return z end }
end
-- geo（選用）：加載後的公尺值 { scale, mo = {x,y,z}, ext = {...}, com = {...}, seat = {...} }；seat=nil 表示沒有 inside 位置
local function newScript(name, areas, parts, filler, geo)
    local s = setmetatable({ _name = name, _areas = areas, _parts = {}, _geo = geo }, VScript)
    for _, p in ipairs(parts) do s._parts[#s._parts + 1] = { id = p[1], area = p[2] } end
    for i = 1, filler or 0 do s._parts[#s._parts + 1] = { id = "Filler" .. i, area = "Engine" } end
    return s
end
local GEO_CAR = { scale = 1.82, mo = { 0, 0.4899, 0 }, ext = { 1.62, 1.1801, 4.74 }, com = { 0, 0.55, 0 }, seat = { 0.32, -0.2501, 0.16 } }
function VScript:getModelScale() return self._geo and self._geo.scale or 1 end
function VScript:getModelOffset() local g = self._geo; return g and vec(g.mo[1], g.mo[2], g.mo[3]) end
function VScript:getModel() local g = self._geo; return g and { getFile = function() return g.file end } end
function VScript:getExtents() local g = self._geo; return vec(g.ext[1], g.ext[2], g.ext[3]) end
function VScript:getCenterOfMassOffset() local g = self._geo; return vec(g.com[1], g.com[2], g.com[3]) end
function VScript:getPassengerCount() return self._geo and 1 or 0 end
function VScript:getPassenger(_)
    local seat = self._geo.seat
    return { getPositionById = function(_, id)
        if id ~= "inside" or not seat then return nil end
        return { getOffset = function() return vec(seat[1], seat[2], seat[3]) end }
    end }
end
function VScript:getFullName() return self._name end
function VScript:getPartCount() return #self._parts end
function VScript:getPartById(id)
    for _, p in ipairs(self._parts) do if p.id == id then return p end end
    return nil
end
function VScript:getAreaById(id)
    for _, a in ipairs(self._areas) do if a == id then return a end end
    return nil
end
function VScript:getAreaCount() return #self._areas end
function VScript:getArea(i)
    local id = self._areas[i + 1]
    return { getId = function() return id end }
end
function VScript:copyPartsFrom(tmpl, id)   -- 同 id 整個換成 copy、新 id 就 add（VehicleScript.java:~1270、makeCopy :2381-2388）
    W.copyCalls = W.copyCalls + 1
    local src = tmpl:getPartById(id)
    local copy = { id = src.id, area = src.area, visible = src.visible, models = {} }
    for mid, m in pairs(src.models or {}) do
        copy.models[mid] = { file = m.file, offset = m.offset, rotate = m.rotate, scale = m.scale }
    end
    for i, p in ipairs(self._parts) do
        if p.id == id then
            self._parts[i] = copy
            return
        end
    end
    self._parts[#self._parts + 1] = copy
end
-- 對既有 part／model 只覆寫出現的欄位（VehicleScript.java:909-951、:693-722）；area 不是識別字就像 ScriptParser 一樣炸。
-- model 區塊的 id 不存在就新增一個 file 是 nil 的 model（LoadModel :693-699）
local function scriptFields(text, fn)
    for k, v in string.gmatch(text, "([%w_]+)%s*=%s*([^,\n]+),") do fn(k, v) end
end
local function vec3(v)
    local x, y, z = string.match(v, "^(%S+) (%S+) (%S+)$")
    return { tonumber(x), tonumber(y), tonumber(z) }
end
function VScript:Load(_, body)
    local id = string.match(body, "part%s+([%w_]+)")
    local part = self:getPartById(id)
    local top = string.gsub(body, "model%s+([%w_]+)%s*{(.-)}", function(mid, inner)
        part.models = part.models or {}
        local m = part.models[mid] or {}
        part.models[mid] = m
        scriptFields(inner, function(k, v)
            if k == "file" then m.file = v
            elseif k == "offset" then m.offset = vec3(v)
            elseif k == "rotate" then m.rotate = vec3(v)
            elseif k == "scale" then m.scale = tonumber(v) end
        end)
        return ""
    end)
    scriptFields(top, function(k, v)
        if k == "area" or k == "mechanicArea" then
            if not string.find(v, "^%a[%w_]*$") then error("ScriptParser: bad value " .. v) end
            if k == "area" then part.area = v end
        elseif k == "setAllModelsVisible" then
            part.visible = v == "true"
        end
    end)
end
-- 真正的 template（vehicle_knoxpass_parts.txt）：植入破壞時 KP_MEDIA 的暫存複本要連 ../scripts/vehicles 一起複製
local TEMPLATE_SRC = (function()
    local f = assert(io.open(MEDIA .. "/../scripts/vehicles/vehicle_knoxpass_parts.txt", "r"))
    local src = f:read("*a")
    f:close()
    return (string.gsub(src, "/%*.-%*/", ""))
end)()
local function templateScript()
    local t = setmetatable({ _name = "Base.KnoxPassParts", _areas = { "Engine" }, _parts = { { id = "KnoxPassTag" } } }, VScript)
    t:Load("KnoxPassParts", TEMPLATE_SRC)
    return t
end
-- template 的 lua／complete 欄位（例 "init"）指到的全域函式；找不到回 nil
local function templateHook(key)
    local f = _G
    for seg in string.gmatch(string.match(TEMPLATE_SRC, key .. " = ([%w_.]+),") or "", "[^.]+") do f = f and f[seg] end
    return f ~= _G and f or nil
end
function getScriptManager()
    return {
        getVehicleTemplate = function(_, name)
            if name == "Base.KnoxPassParts" and W.template then return { getScript = function() return W.template end } end
            return nil
        end,
        getAllVehicleScripts = function() return javaList(W.scripts) end,
        -- 模型腳本 → mesh（W.modelScripts[名稱]＝mesh 字串；true＝有腳本但沒寫 mesh）
        getModelScript = function(_, name)
            local m = W.modelScripts and W.modelScripts[name]
            if not m then return nil end
            return { getMeshName = function() if m ~= true then return m end end }
        end,
        -- spriteModels.txt 的每個 tile 都登錄成名稱「tileset_索引」的 SpriteModel 腳本物件（SpriteModels.java:81-96）；
        -- 同名回同一個物件。setAnimationTime 改的就是畫面用的那個（IsoObject.getSpriteModel 照名稱取，IsoObject.java:6280-6286）
        getSpriteModel = function(_, name)
            if not string.match(name, "^MinidoracatKnoxPass_") then return nil end
            W.spriteModels = W.spriteModels or {}
            local sm = W.spriteModels[name]
            if not sm then
                sm = { _time = 0, setAnimationTime = function(s, t) s._time = t; W.smSets = (W.smSets or 0) + 1 end,
                    getAnimationTime = function(s) return s._time end }
                W.spriteModels[name] = sm
            end
            return sm
        end,
    }
end

-- ===== GOS（零物件系統）與存檔 =====
local SAVE = {}       -- 模擬 gos_<name>.bin
local systems = {}
local function persist(v)
    if type(v) ~= "table" then
        assert(type(v) ~= "function", "GOS 存檔不能存函式")
        return v
    end
    assert(classOf[v] == nil, "GOS 存檔不能存 Java 物件")
    local t = {}
    for k, x in pairs(v) do t[k] = persist(x) end
    return t
end
local JSystem = {}
JSystem.__index = JSystem
function JSystem:getModData() return self._md end
function JSystem:setModDataKeys(list)
    self._keys = {}
    for _, k in ipairs(list) do self._keys[k] = true end
end
function JSystem:setObjectModDataKeys() end
function JSystem:setObjectSyncKeys() end
function JSystem:getObjectCount() return 0 end
SGlobalObjects = {
    registerSystem = function(name)   -- 讀入 gos_<name>.bin（SGlobalObjectSystem.java:240）
        local sys = setmetatable({ _name = name, _keys = {}, _md = SAVE[name] and persist(SAVE[name]) or {} }, JSystem)
        systems[#systems + 1] = sys
        return sys
    end,
    getSystemCount = function() return #systems end,
    getSystemByIndex = function(i) return systems[i + 1] end,
}
local function saveWorld()   -- 只存白名單鍵（SGlobalObjectSystem.java:210-220）
    for _, sys in ipairs(systems) do
        local data = {}
        for k in pairs(sys._keys) do data[k] = persist(sys._md[k]) end
        SAVE[sys._name] = data
    end
end

-- 原版 server/Map/SGlobalObjectSystem.lua 與 shared/ISBaseObject.lua 的最小複本（MOD 用到的路徑）
local FAKE_MODULES = {
    ["Map/SGlobalObjectSystem"] = function()
        ISBaseObject = { Type = "ISBaseObject" }
        function ISBaseObject:derive(t)
            local o = {}
            setmetatable(o, self)
            self.__index = self
            o.Type = t
            o.SuperType = self
            return o
        end
        SGlobalObjectSystem = ISBaseObject:derive("SGlobalObjectSystem")
        function SGlobalObjectSystem:new(name)
            local system = SGlobalObjects.registerSystem(name)
            local o = system:getModData()
            setmetatable(o, self)
            self.__index = self
            o.system = system
            o.systemName = name
            o.wantNoise = getDebug()
            o:initSystem()
            o:initLuaObjects()
            return o
        end
        function SGlobalObjectSystem:initSystem() end
        function SGlobalObjectSystem:initLuaObjects()
            for i = 1, self.system:getObjectCount() do self:newLuaObject(nil) end
        end
        function SGlobalObjectSystem.RegisterSystemClass(luaClass)
            for i = 1, SGlobalObjects.getSystemCount() do
                local system = SGlobalObjects.getSystemByIndex(i - 1)
                if system:getModData().Type == luaClass.Type then
                    luaClass.instance = system:getModData()
                    return
                end
            end
            Events.OnSGlobalObjectSystemInit.Add(function() luaClass.instance = luaClass:new() end)
        end
    end,
    ["TimedActions/ISDismantleAction"] = function()
        ISDismantleAction = {}
        function ISDismantleAction:complete()   -- ISDismantleAction.lua:47-95：照 buildMaterials 退料（v=1 → 1 個）、移走目標
            local t = self.thumpable
            for fullType, v in pairs(t:getBuildMaterials()) do W.dropped[fullType] = (W.dropped[fullType] or 0) + v end
            t:getSquare():transmitRemoveItemFromSquare(t)
            return true
        end
    end,
    ["TimedActions/ISDestroyStuffAction"] = function()
        ISDestroyStuffAction = {}
        function ISDestroyStuffAction:complete()   -- ISDestroyStuffAction.lua:111-…：只移走被敲的那一個
            if self.item == nil then return false end
            self.item:getSquare():transmitRemoveItemFromSquare(self.item)
            return true
        end
    end,
    ["BuildingObjects/ISDestroyCursor"] = function()
        ISDestroyCursor = {}
        function ISDestroyCursor:canDestroy() return true end   -- 原版判斷（ISDestroyCursor.lua:293-362）此處一律放行
    end,
}

-- ===== 載入受測程式碼 =====
local loaded = {}
function require(name)
    if loaded[name] then return true end
    loaded[name] = true
    if FAKE_MODULES[name] then
        FAKE_MODULES[name]()
        return true
    end
    for _, dir in ipairs({ "shared", "server" }) do   -- 刻意不載 client
        local chunk = loadfile(MEDIA .. "/" .. dir .. "/" .. name .. ".lua")
        if chunk then
            chunk()
            return true
        end
    end
    error("require 找不到: " .. name)
end

local KP
local MOD_FILES = {
    "MinidoracatKnoxPass/Core", "MinidoracatKnoxPass/Gates", "MinidoracatKnoxPass/Parts",
    "MinidoracatKnoxPass/Ledger", "MinidoracatKnoxPass/Sensor", "MinidoracatKnoxPass/Server",
    "MinidoracatKnoxPass/Barrier", "MinidoracatKnoxPass/ReaderPost", "Items/MinidoracatKnoxPass_Distributions",
}
local CLIENT_FILES = { "MinidoracatKnoxPass/BarrierAnim" }   -- 只載不碰 UI 的 client 檔
-- 開機：Lua 全部重載（各檔 local 狀態歸零）→ OnGameBoot → 世界載入時 OnSGlobalObjectSystemInit
local function bootMod()
    for k in pairs(loaded) do loaded[k] = nil end
    for k in pairs(handlers) do handlers[k] = nil end
    for k in pairs(systems) do systems[k] = nil end
    MinidoracatKnoxPass, KnoxPassAPI, SGlobalObjectSystem, ISBaseObject = nil, nil, nil, nil
    ISDismantleAction, ISDestroyStuffAction, ISDestroyCursor = nil, nil, nil
    for _, name in ipairs(MOD_FILES) do require(name) end
    if MODE ~= "server" then
        for _, name in ipairs(CLIENT_FILES) do assert(loadfile(MEDIA .. "/client/" .. name .. ".lua"))() end
    end
    KP = MinidoracatKnoxPass
    fire("OnGameBoot")
    fire("OnSGlobalObjectSystemInit")
end
local function restart()
    saveWorld()
    bootMod()
end
local function freshWorld(mode)
    MODE = mode or "server"
    W = newWorld()
    for k in pairs(SAVE) do SAVE[k] = nil end
    SandboxVars = { MinidoracatKnoxPass = {} }
    bootMod()
end

-- ===== 測試工具 =====
local failures = 0
local function check(ok, label)
    if ok then out("  PASS  " .. label)
    else failures = failures + 1; out("  FAIL  " .. label) end
end

local function step(fn)
    nowMs = nowMs + 250
    -- 車庫門 client 回送的狀態到伺服器：伺服器照單全收，整條鏈照回送的開關與鑰匙鎖改（GameServer.java:2969-2987、
    -- D:1772-1774、1798-1822）。回送把開著的門關上的次數記在 W.echoClosed
    local echo = W.echo
    W.echo = nil
    for _, e in ipairs(echo or {}) do
        local chain = garageChain(e[1])
        if chain[1]._open and not e[3] then W.echoClosed = W.echoClosed + 1 end
        for _, p in ipairs(chain) do
            p._locked, p._lockedByKey, p._open = e[2], e[2], e[3]
            if p._closedName then p._spriteObj = namedSprite(p._open and p._openName or p._closedName) end
        end
    end
    if fn then fn() end
    fire("OnTick")
end
local function runMs(ms, fn)
    for _ = 1, math.floor(ms / 250) do step(fn) end
end

-- 送 client 指令；回傳最後一則 result 與 state
local function cmd(player, command, args)
    local from = #W.sent + 1
    fire("OnClientCommand", "MinidoracatKnoxPass", command, player, args)
    local res, st
    for i = from, #W.sent do
        local s = W.sent[i]
        if s.cmd == "result" then res = s.args elseif s.cmd == "state" then st = s.args end
    end
    return res or {}, st
end

-- 在 (x, 100) 放門（或雙開門），擁有者站旁邊安裝讀頭
local function gate(x, opts)
    opts = opts or {}
    local door, clicked
    if opts.garage then
        local gg = makeGarage(x, 100)
        door, clicked = gg.pieces[1], gg.pieces[opts.click or 1]
    elseif opts.double then
        local g = makeDouble(opts.cls or "IsoDoor", x, 100)
        door, clicked = g.pieces[1], g.pieces[opts.click or 1]
    else
        door = makeDoor(opts.cls or "IsoDoor", x, 100, opts)
        clicked = door
    end
    if opts.power ~= false then square(x, 100, 0)._grid = true end
    local owner = opts.owner or newPlayer(opts.name or ("owner" .. x), x, 102, { sid = opts.sid })
    local reader = owner._inv:AddItem(opts.reader or READER)
    local res = cmd(owner, "install", { x = clicked._square._x, y = 100, z = 0, index = clicked:getObjectIndex(), itemId = reader:getID() })
    local g = { door = door, key = res.key, owner = owner, res = res, group = door._group or door._gg }
    local rec = KP.Ledger.get(res.key)
    if rec then g.cx, g.cy = rec.cx, rec.cy end
    return g
end
local function rec(g) return KP.Ledger.get(g.key) end
local function car(g, d, opts) return makeVehicle(g.cx, g.cy + d, opts) end
local function register(g, v) return cmd(g.owner, "register", { key = g.key, vehicleId = v:getId() }) end
local function driver(v, name)
    local p = newPlayer(name or ("driver" .. v._id), 0, 0)
    seat(p, v, 0)
    return p
end
local function charge(v) return v._parts.KnoxPassTag._item:getCurrentUsesFloat() end
local function near(a, b) return math.abs(a - b) < 1e-6 end
local function pieces(g)
    if g.group then return g.group.pieces end
    return { g.door }
end
local function allPieces(g, fn)
    for _, p in ipairs(pieces(g)) do if not fn(p) then return false end end
    return true
end
local function clean(from, label)
    check(W.nilToggles == 0 and not logHas("failed", from), label .. "：沒有 ToggleDoor(nil)、沒有被吞掉的例外")
end

-- ===== 情境 =====
local function scenarioParts()
    out("情境：感應盒零件槽注入")
    freshWorld()
    local car1 = newScript("Base.CarNormal", { "Engine", "SeatFrontLeft" }, { { "Battery", "Engine" } }, nil, GEO_CAR)
    W.scripts = { car1 }
    local from = #logLines + 1
    fire("OnGameBoot")
    check(car1:getPartById("KnoxPassTag") == nil and logHas("ABORT", from), "沒有 template 時不注入並記 ABORT")

    W.template = templateScript()
    local van = newScript("Base.Van", { "TruckBed", "Engine" }, { { "Battery", "Engine" } }, nil,
        { scale = 1.82, mo = { 0, 0.6699, 0 }, ext = { 1.7001, 1.32, 4.2401 }, com = { 0, 0.6599, 0 }, seat = { 0.35, -0.18, 0.77 } })
    local weird = newScript("Mod.Weird", { "Bad-Area", "Rear_Seat" }, { { "Battery", "Engine" } })
    local bike = newScript("Base.Bicycle", { "SeatFrontLeft" }, {})
    local foreign = newScript("Mod.Foreign", { "SeatFrontLeft" }, { { "Battery", "Engine" }, { "KnoxPassTag", "Trunk" } })
    local foreignPart = foreign:getPartById("KnoxPassTag")
    local big = newScript("Mod.Big", { "Engine" }, { { "Battery", "Engine" } }, 253, GEO_CAR)    -- 254 → 255
    local huge = newScript("Mod.Huge", { "Engine" }, { { "Battery", "Engine" } }, 254)  -- 255 → 256
    local noArea = newScript("Mod.NoArea", {}, { { "Battery", "Engine" } })
    local noSeat = newScript("Mod.NoSeat", { "Engine" }, { { "Battery", "Engine" } }, nil,
        { scale = 1.82, mo = { 0, 0.5, 0 }, ext = { 1.6, 1.2, 4.7 }, com = { 0, 0.55, 0 }, seat = nil })
    local edge127 = newScript("Mod.Edge127", { "Engine" }, { { "Battery", "Engine" } }, 126, GEO_CAR)  -- 新槽索引 127
    local edge128 = newScript("Mod.Edge128", { "Engine" }, { { "Battery", "Engine" } }, 127, GEO_CAR)  -- 新槽索引 128
    local nose = newScript("Mod.Nose", { "Engine" }, { { "Battery", "Engine" } }, nil,
        { scale = 1.82, mo = { 0, 0.4899, 0 }, ext = { 1.62, 1.1801, 4.74 }, com = { 0, 0.55, 0 }, seat = { 0.32, -0.25, 3.0 } })
    local function geoFile(file)
        local g = {}
        for k, v in pairs(GEO_CAR) do g[k] = v end
        g.file = file
        return g
    end
    local sedan = newScript("Base.CarNormal", { "SeatFrontLeft" }, { { "Battery", "Engine" } }, nil, geoFile("Vehicles_CarNormal"))
    local modCar = newScript("Mod.Car", { "SeatFrontLeft" }, { { "Battery", "Engine" } }, nil, geoFile("ModCar_Body"))
    -- MOD 車：93fordF350 的模型腳本 93fordF350Base → mesh（E2E 範本伺服器有載入，實機可對照）
    local F350_MESH = "vehicles/Vehicles_93fordF350_Body|f350_crewcab_body"
    local f350 = newScript("Base.93fordF350", { "SeatFrontLeft" }, { { "Battery", "Engine" } }, nil, geoFile("93fordF350Base"))
    W.modelScripts = { ["93fordF350Base"] = F350_MESH }
    W.scripts = { car1, noSeat, van, weird, bike, foreign, big, huge, noArea, edge127, edge128, nose, sedan, modCar, f350 }
    from = #logLines + 1
    fire("OnGameBoot")
    local function area(s)
        local p = s:getPartById("KnoxPassTag")
        return p and p.area
    end
    check(area(car1) == "SeatFrontLeft", "有電瓶的車注入，area 優先 SeatFrontLeft")
    check(area(van) == "Engine", "沒有 SeatFrontLeft 時用 Engine")
    check(area(weird) == "Rear_Seat", "都沒有時取第一個識別字形狀的 area（跳過 Bad-Area）")
    check(bike:getPartById("KnoxPassTag") == nil, "沒有電瓶的腳本不注入")
    check(foreign:getPartById("KnoxPassTag") == foreignPart and foreignPart.area == "Trunk" and logHas("CONFLICT", from),
        "已有別人的 KnoxPassTag：記 CONFLICT、原零件不動")
    check(big:getPartCount() == 255 and area(big) == "Engine", "注入後剛好 255 個零件仍可注入")
    check(huge:getPartById("KnoxPassTag") == nil and huge:getPartCount() == 255, "超過 255 個零件上限的腳本跳過")
    check(noArea:getPartById("KnoxPassTag") == nil, "沒有任何合法 area 的腳本跳過")

    -- 擋風玻璃上的固定座模型：offset＝(目標點－模型 offset)/車輛 scale、scale＝1/車輛 scale（Parts.lua KP.dockPlacement）。
    -- 第 1 個回傳值：這個車型裝上黑色感應盒後 KP.syncDock 有沒有顯示 Dock_Black（掛不掛模型）；位置取米白 Dock
    local function dock(s)
        local p = s:getPartById("KnoxPassTag")
        if not p then return nil end
        local v = makeVehicle(0, 0, { vscript = s, tag = 0.5, tagType = TAG .. "_Black" })
        local part = v._parts.KnoxPassTag
        KP.syncDock(v, part)
        local m = p.models.Dock
        return part._shown ~= nil and part._shown.Dock_Black == true, m.offset, m.scale, m.rotate
    end
    local function close(a, b) return a ~= nil and math.abs(a - b) < 0.0002 end
    local vis, off, sc, rot = dock(car1)
    -- CarNormal：高 0.55+1.1801/2-0.15=0.99005、前後 0.16+0.2*1.1801+0.043=0.43902（42.21 實測腳本值）
    check(vis == true and close(off[1], 0) and close(off[2], (0.99005 - 0.4899) / 1.82) and close(off[3], 0.43902 / 1.82)
        and close(sc, 1 / 1.82) and close(rot[1], -20), "轎車（model 沒寫 file）：offset／scale 由駕駛座、extents、車輛 scale 推算，傾角 -20")
    -- 查表：DockSpots.lua 的 Vehicles_CarNormal = { 0.2738, 0.2556, 49.2 }（重跑 dock_spots.py 換了值就同步改這裡）
    vis, off, sc, rot = dock(sedan)
    check(vis == true and close(off[1], 0) and close(off[2], 0.2738) and close(off[3], 0.2556) and close(sc, 1 / 1.82)
        and close(rot[1], -49.2) and rot[2] == 0 and rot[3] == 0, "原版車：查 DockSpots 表（offset 直接用表值、rotate.x＝負的玻璃後傾角）")
    local _, off2 = dock(car1)
    vis, off, sc, rot = dock(modCar)
    check(vis == true and close(off[2], off2[2]) and close(off[3], off2[3]) and close(rot[1], -20),
        "表裡沒有的 model file（MOD 車）退回腳本幾何公式")
    -- MOD 車查表：鍵＝模型腳本的 mesh（Parts.lua KP.dockPlacement → KP.DOCK_SPOTS_MOD）
    local want = KP.DOCK_SPOTS_MOD[F350_MESH]
    vis, off, sc, rot = dock(f350)
    check(want ~= nil and vis == true and close(off[1], 0) and close(off[2], want[1]) and close(off[3], want[2])
        and close(sc, 1 / 1.82) and close(rot[1], -want[3]), "MOD 車：model file → 模型腳本 mesh 查 DOCK_SPOTS_MOD（93fordF350）")
    local function formula(s)   -- 同一份幾何走公式的結果（modCar 的 file 沒有模型腳本）
        local _, y, z, _, rx = KP.dockPlacement(s)
        return close(y, off2[2]) and close(z, off2[3]) and close(rx, -20)
    end
    W.modelScripts = { ["93fordF350Base"] = "vehicles/SomeOtherMod_Body|body" }
    check(formula(f350), "同名不同 MOD：model 名一樣但 mesh 不同 → 不用表、退回公式")
    W.modelScripts = {}
    check(formula(f350), "MOD 車的 model 名查不到模型腳本 → 退回公式")
    W.modelScripts = { ["93fordF350Base"] = true }
    check(formula(f350), "模型腳本沒有 mesh（getMeshName 回 nil）→ 退回公式、不炸")
    W.modelScripts = { ["93fordF350Base"] = F350_MESH }
    vis, off = dock(van)
    check(vis == true and close(off[2], (0.6599 + 0.66 - 0.15 - 0.6699) / 1.82) and close(off[3], (0.77 + 0.264 + 0.043) / 1.82),
        "廂型車：每個車型有自己的 offset（template 改寫後各自複製）")
    check(dock(noSeat) == false, "推算不出位置（駕駛座沒有 inside）→ 有槽但不掛模型，不沿用上一台的設定")
    check(noSeat:getPartById("KnoxPassTag") ~= nil and dock(weird) == false, "沒有幾何的車型照樣有槽、不掛模型")
    check(dock(edge127) == true, "新槽索引 127：仍掛模型（有號 byte 上限，VehiclePartModels.java:31）")
    check(edge128:getPartById("KnoxPassTag") ~= nil and dock(edge128) == false and dock(big) == false,
        "新槽索引 ≥128：有槽但不掛模型，避免零件模型封包索引溢位")
    vis, off = dock(nose)
    check(vis == true and close(off[3], (4.74 / 2 - 0.3) / 1.82), "駕駛座推算超過車頭時夾在 extents 前緣後 0.3 m")
    check(logHas("nomodel=4", from), "log 記錄有槽但不掛模型的車型數")
    -- 7 色的 model 都寫到同一組位置、各自指向該色的模型腳本；setAllModelsVisible 一律 false（引擎不自動全開）
    local seven = true
    for _, s in ipairs({ car1, van, sedan, modCar, f350, nose, edge127, noSeat }) do
        local p = s:getPartById("KnoxPassTag")
        local base, n = p.models.Dock, 0
        for _ in pairs(p.models) do n = n + 1 end
        seven = seven and p.visible == false and n == #KP.COLORS
        for c = 0, #KP.COLORS - 1 do
            local m = p.models[KP.dockModelId(c)]
            seven = seven and m ~= nil and m.file == "MinidoracatKnoxPass.KnoxPassTagDock" .. KP.COLORS[c + 1].suffix
                and m.offset[1] == base.offset[1] and m.offset[2] == base.offset[2] and m.offset[3] == base.offset[3]
                and m.rotate[1] == base.rotate[1] and m.scale == base.scale
        end
    end
    check(seven and car1:getPartById("KnoxPassTag").models.Dock_Red.offset[2] ~= 0,
        "注入：7 個 Dock model 都寫到同一組 offset／rotate／scale、file 指向該色模型、setAllModelsVisible=false")
    check(#W.npe == 0, "沒有顯示過 file 是 nil 的零件模型")

    local copies, counts = W.copyCalls, {}
    for i, s in ipairs(W.scripts) do counts[i] = s:getPartCount() end
    fire("OnGameBoot")
    local same = W.copyCalls == copies
    for i, s in ipairs(W.scripts) do same = same and s:getPartCount() == counts[i] end
    check(same and area(car1) == "SeatFrontLeft", "第二次 OnGameBoot 冪等：不再複製、零件數不變")

    local part = setmetatable({}, Part)
    KP.onPartCreate(nil, part)
    check(part._condition == 100 and part._item == nil, "新零件槽是空的、condition 100")
end

-- 車上 Dock 模型跟著感應盒顏色（Parts.lua KP.syncDock）：7 個 model 只顯示裝著的那一色。
-- 呼叫點照引擎：template lua.init（addToWorld 與 repair 換了物品之後）、安裝／拆下 complete、零件 update
local function scenarioDock()
    out("情境：車上 Dock 模型跟著感應盒顏色")
    freshWorld()
    local from = #logLines + 1
    local tmpl = templateScript()
    local tp, files = tmpl:getPartById("KnoxPassTag"), true
    for c = 0, #KP.COLORS - 1 do
        local m = tp.models and tp.models[KP.dockModelId(c)]
        files = files and m ~= nil and m.file == "MinidoracatKnoxPass.KnoxPassTagDock" .. KP.COLORS[c + 1].suffix
    end
    check(files and tp.visible == false, "template：7 個 Dock<後綴> model 都寫了 file（該色模型腳本）、setAllModelsVisible=false")
    local init = templateHook("init")
    check(init == KP.syncDock and templateHook("create") == KP.onPartCreate and templateHook("update") == KP.onPartUpdate,
        "template 的 lua.init／create／update 指到 MOD 的函式")
    init = init or function() end   -- 沒接上時後面的載入／repair 斷言照樣跑、照樣 FAIL
    W.template = tmpl
    local sedan = newScript("Base.CarNormal", { "SeatFrontLeft" }, { { "Battery", "Engine" } }, nil, GEO_CAR)
    local noSeat = newScript("Mod.NoSeat", { "Engine" }, { { "Battery", "Engine" } }, nil,
        { scale = 1.82, mo = { 0, 0.5, 0 }, ext = { 1.6, 1.2, 4.7 }, com = { 0, 0.55, 0 }, seat = nil })
    W.scripts = { sedan, noSeat }
    fire("OnGameBoot")
    local function shown(part)
        local ids = {}
        for id in pairs(part._shown or {}) do ids[#ids + 1] = id end
        table.sort(ids)
        return table.concat(ids, ",")
    end

    -- 安裝黑色 → 只有 Dock_Black；拆下 → 全關；換裝橘色 → 只有 Dock_Orange（原版先換物品再呼叫 complete）
    local v = makeVehicle(0, 0, { vscript = sedan })
    local part = v._parts.KnoxPassTag
    local black = newItem(TAG .. "_Black", 0.5)
    part._item = black
    KP.onTagInstalled(v, part)
    check(shown(part) == "Dock_Black", "裝上黑色感應盒：只顯示 Dock_Black")
    part._item = nil
    KP.onTagUninstalled(v, part, black)
    check(shown(part) == "", "拆下：7 個 Dock 全關")
    part._item = newItem(TAG .. "_Orange", 0.5)
    KP.onTagInstalled(v, part)
    check(shown(part) == "Dock_Orange", "換裝橘色：只顯示 Dock_Orange")
    local flags = W.modelFlags
    KP.onPartUpdate(v, part, 1)
    init(v, part)
    check(shown(part) == "Dock_Orange" and W.modelFlags == flags, "顏色沒變：update／init 不改顯示、不標記模型同步")

    -- 管理員修車：VehiclePart.repair 直接 setInventoryItem 再呼叫 lua.init（VehiclePart.java:956-971），不走 complete
    part._item = newItem(TAG .. "_Red", 1)
    check(shown(part) == "Dock_Orange", "（前提）只換物品、沒有掛勾時顯示還是舊色")
    init(v, part)
    check(shown(part) == "Dock_Red" and W.modelFlags == flags + 2, "repair 後的 init：改成 Dock_Red（關舊色、開新色各一次同步）")
    part._item = newItem(TAG .. "_Navy", 1)
    KP.onPartUpdate(v, part, 1)
    check(shown(part) == "Dock_Navy", "其他 MOD 直接換物品：下一次零件 update 改成 Dock_Navy")
    part._item = newItem(READER)
    init(v, part)
    check(shown(part) == "", "槽裡不是感應盒（讀頭也有顏色）：全關")

    -- 載入既有車輛：存檔的物品已在槽裡、模型清單是空的（顯示狀態不存檔），addToWorld → init
    local loaded = makeVehicle(10, 0, { vscript = sedan, tag = 0.4, tagType = TAG .. "_Graphite" })
    init(loaded, loaded._parts.KnoxPassTag)
    check(shown(loaded._parts.KnoxPassTag) == "Dock_Graphite", "載入：init 顯示存檔裡那顆的顏色")
    local cream = makeVehicle(20, 0, { vscript = sedan, tag = 0.4 })
    init(cream, cream._parts.KnoxPassTag)
    check(shown(cream._parts.KnoxPassTag) == "Dock", "米白：model id 就是 Dock（KP.DOCK_MODEL_ID）")

    -- 零件模型封包索引是有號 byte（VehiclePartModels.java:31、:52）：索引 >127 全關；推算不出位置的車型也全關
    local i127 = makeVehicle(30, 0, { vscript = sedan, tag = 0.4, tagType = TAG .. "_Black", index = 127 })
    local i128 = makeVehicle(40, 0, { vscript = sedan, tag = 0.4, tagType = TAG .. "_Black", index = 128 })
    init(i127, i127._parts.KnoxPassTag)
    init(i128, i128._parts.KnoxPassTag)
    check(shown(i127._parts.KnoxPassTag) == "Dock_Black" and shown(i128._parts.KnoxPassTag) == "",
        "零件索引 127 顯示、128 全關")
    local ns = makeVehicle(50, 0, { vscript = noSeat, tag = 0.4, tagType = TAG .. "_Black" })
    init(ns, ns._parts.KnoxPassTag)
    check(shown(ns._parts.KnoxPassTag) == "", "推算不出位置的車型：有槽但全關")

    -- MP 客戶端：整車封包不含已顯示的零件模型，init 在客戶端也要自己算；update 只在伺服器
    MODE = "client"
    local remote = makeVehicle(60, 0, { vscript = sedan, tag = 0.4, tagType = TAG .. "_Olive" })
    init(remote, remote._parts.KnoxPassTag)
    remote._parts.KnoxPassTag._item = newItem(TAG .. "_Red", 1)
    KP.onPartUpdate(remote, remote._parts.KnoxPassTag, 1)
    MODE = "server"
    check(shown(remote._parts.KnoxPassTag) == "Dock_Olive", "MP 客戶端：init 自己顯示該色、update 不動（等伺服器封包）")
    check(#W.npe == 0, "沒有顯示過 file 是 nil 的零件模型（客戶端不會 NPE）")
    clean(from, "車上 Dock 模型")
end

local function scenarioDetection()
    out("情境：偵測開門")
    freshWorld()
    local from = #logLines + 1

    -- 範圍內開門＋扣電
    local a = gate(100)
    local va = car(a, 7, { tag = 0.5 })
    check(register(a, va).ok == true, "擁有者登記範圍內的車")
    check(not a.door:IsOpen(), "沒人駕駛時不開")
    driver(va)
    local deltas = W.partDeltas
    step()
    check(a.door:IsOpen() and rec(a).open == true, "駕駛在 ReadRange 內 → 開門並記入帳本")
    check(near(charge(va), 0.49) and W.partDeltas == deltas + 1, "開一次扣 1%×TagDrainPercent 並 transmitPartUsedDelta")
    runMs(2000)
    check(near(charge(va), 0.49), "門開著時不重複扣電")

    -- 範圍外停著
    local b = gate(200)
    local vb = car(b, 9, { tag = 0.5 })
    register(b, vb)
    driver(vb)
    runMs(3000)
    check(not b.door:IsOpen() and near(charge(vb), 0.5), "停在 ReadRange 外不開、不扣電")

    -- 行進預測：LeadSeconds=2 時提早開
    local c = gate(300)
    local vc = car(c, 10, { tag = 0.5 })
    register(c, vc)
    moveCar(vc, c.cx, c.cy + 30)
    driver(vc)
    local openAt
    for _ = 1, 20 do
        step(function() moveCar(vc, vc._x, vc._y - 2.5) end)   -- 每秒 10 格朝大門
        if c.door:IsOpen() then
            openAt = vc._y - c.cy
            break
        end
    end
    check(openAt ~= nil and openAt > 8, "朝大門行進時提早開門（開門時距離 " .. tostring(openAt) .. " > ReadRange 8）")

    -- LeadSeconds=0：同樣速度要進到 ReadRange 才開
    SandboxVars.MinidoracatKnoxPass.LeadSeconds = 0
    local d = gate(400)
    local vd = car(d, 10, { tag = 0.5 })
    register(d, vd)
    moveCar(vd, d.cx, d.cy + 30)
    driver(vd)
    openAt = nil
    for _ = 1, 20 do
        step(function() moveCar(vd, vd._x, vd._y - 2.5) end)
        if d.door:IsOpen() then
            openAt = vd._y - d.cy
            break
        end
    end
    check(openAt ~= nil and openAt <= 8, "LeadSeconds=0 時進到 ReadRange 才開（距離 " .. tostring(openAt) .. "）")
    SandboxVars.MinidoracatKnoxPass.LeadSeconds = nil

    -- 遠離大門不延伸
    local e = gate(500)
    local ve = car(e, 9, { tag = 0.5 })
    register(e, ve)
    driver(ve)
    runMs(3000, function() moveCar(ve, ve._x, ve._y + 2.5) end)
    check(not e.door:IsOpen(), "從 ReadRange 外往遠離方向開，預測不延伸、不開門")

    -- 只有乘客
    local f = gate(600)
    local vf = car(f, 3, { tag = 0.5 })
    register(f, vf)
    seat(newPlayer("passenger", 0, 0), vf, 1)
    runMs(3000)
    check(not f.door:IsOpen(), "只有乘客沒有駕駛 → 不開")

    -- 未登記的感應盒
    local g = gate(700)
    local vg = car(g, 3, { tag = 0.5 })
    driver(vg)
    runMs(3000)
    check(not g.door:IsOpen(), "感應盒沒登記 → 不開")

    -- 物品類型不對（同一個 ID 的別種物品）
    local h = gate(800)
    local vh = car(h, 3, { tag = 0.5 })
    register(h, vh)
    local fake = newItem("Base.CarBattery1", 1)
    fake._id = vh._parts.KnoxPassTag._item._id
    vh._parts.KnoxPassTag._item = fake
    driver(vh)
    runMs(3000)
    check(not h.door:IsOpen(), "零件裡的物品類型不是感應盒（即使 ID 相同）→ 不開")

    -- 沒電
    local i = gate(900)
    local vi = car(i, 3, { tag = 0 })
    register(i, vi)
    driver(vi)
    runMs(3000)
    check(not i.door:IsOpen(), "感應盒沒電 → 不開")

    -- RequirePower
    local j = gate(1000, { power = false })
    local vj = car(j, 3, { tag = 0.5 })
    register(j, vj)
    driver(vj)
    runMs(6000)
    check(not j.door:IsOpen() and near(charge(vj), 0.5), "RequirePower=true 且沒電網／發電機 → 不開、不扣電")
    SandboxVars.MinidoracatKnoxPass.RequirePower = false
    runMs(3500)
    check(j.door:IsOpen(), "RequirePower=false → 沒供電也開")
    SandboxVars.MinidoracatKnoxPass.RequirePower = nil

    -- 耗電倍率
    SandboxVars.MinidoracatKnoxPass.TagDrainPercent = 50
    local k = gate(1100)
    local vk = car(k, 3, { tag = 0.5 })
    register(k, vk)
    driver(vk)
    step()
    check(k.door:IsOpen() and near(charge(vk), 0.495), "TagDrainPercent=50 → 每次扣 0.5%")
    SandboxVars.MinidoracatKnoxPass.TagDrainPercent = 5
    local l = gate(1200)
    local vl = car(l, 3, { tag = 0.5 })
    register(l, vl)
    driver(vl)
    step()
    check(l.door:IsOpen() and charge(vl) < 0.5, "TagDrainPercent=5（小於一格 UseDelta）仍至少扣一格，不會變成免費")
    SandboxVars.MinidoracatKnoxPass.TagDrainPercent = 0
    local m = gate(1300)
    local vm = car(m, 3, { tag = 0.5 })
    register(m, vm)
    driver(vm)
    step()
    check(m.door:IsOpen() and near(charge(vm), 0.5), "TagDrainPercent=0 → 不扣電")
    clean(from, "偵測")
end

local function scenarioAutoClose()
    out("情境：自動關門")
    freshWorld()
    local from = #logLines + 1

    -- 延遲關門；範圍內一直有登記的駕駛就不關；沒登記的車不算
    local a = gate(100)
    local va = car(a, 3, { tag = 0.5 })
    register(a, va)
    local pa = driver(va)
    step()
    check(a.door:IsOpen(), "開門")
    runMs(10000)
    check(a.door:IsOpen(), "登記車還在範圍內 → 10 秒後仍開著")
    moveCar(va, va._x, va._y + 40)
    local stranger = car(a, 3, { tag = 0.5 })
    driver(stranger)
    runMs(1750)
    check(a.door:IsOpen(), "登記車離開未滿 CloseDelay（預設 2 秒）不關")
    runMs(500)
    check(not a.door:IsOpen() and rec(a).open == nil, "滿 CloseDelay 關門（範圍內沒登記的車不算）")
    check(not KP.Ledger.openKeys()[a.key], "關好後移出待關清單")

    -- 駕駛下車也算離開
    moveCar(va, a.cx, a.cy + 3)
    step()
    check(a.door:IsOpen(), "登記車回來重開")
    unseat(pa)
    runMs(5500)
    check(not a.door:IsOpen(), "駕駛下車後滿 CloseDelay 關門")

    -- 門口有玩家就不關；殭屍不擋（跟著車進門的殭屍不能讓門一直開著，2026-10-07 使用者決定）
    local b = gate(200)
    local vb = car(b, 3, { tag = 0.5 })
    register(b, vb)
    driver(vb)
    step()
    moveCar(vb, vb._x, vb._y + 40)
    local walker = newPlayer("walker", 200, 99)
    runMs(8000)
    check(b.door:IsOpen(), "門另一側那格有玩家 → 不關")
    walker._x, walker._y = 200.5, 100.5
    runMs(3000)
    check(b.door:IsOpen(), "門框格有玩家 → 不關")
    walker._x = 210.5
    runMs(2250)
    check(not b.door:IsOpen(), "門口淨空後 2 秒內重試關上")
    local bz = gate(250)
    local vbz = car(bz, 3, { tag = 0.5 })
    register(bz, vbz)
    driver(vbz)
    step()
    moveCar(vbz, vbz._x, vbz._y + 40)
    newZombie(250, 100)
    newZombie(250, 99)
    runMs(2250)
    check(not bz.door:IsOpen() and rec(bz).open == nil, "門框格與另一側有殭屍 → 照延遲關上")
    W.zombies = {}

    -- 引擎判定擋住：2 秒後重試
    local c = gate(300)
    local vc = car(c, 3, { tag = 0.5 })
    register(c, vc)
    driver(vc)
    step()
    moveCar(vc, vc._x, vc._y + 40)
    c.door._obstructed = true
    local checks = W.obstructChecks
    for _ = 1, 40 do
        step()
        if W.obstructChecks > checks then break end
    end
    check(W.obstructChecks > checks and c.door:IsOpen(), "引擎判定擋住 → 不關")
    c.door._obstructed = false
    runMs(1750)
    check(c.door:IsOpen(), "擋住後 1.75 秒內不重試")
    step()
    check(not c.door:IsOpen(), "擋住解除後第 2 秒重試關上")

    -- 有人用手開著的門不接手、不關
    local d = gate(400)
    d.door:ToggleDoor(newPlayer("hand", 400, 101))
    check(d.door:IsOpen(), "玩家用手開門")
    local vd = car(d, 3, { tag = 0.5 })
    register(d, vd)
    driver(vd)
    step()
    moveCar(vd, vd._x, vd._y + 40)
    runMs(10000)
    check(d.door:IsOpen() and rec(d).open == nil, "Knox Pass 只關自己開的門：手開的門保持開著")

    -- 開著時被人手動關上 → 收尾鎖回
    local e = gate(500, { keyId = 777, lockedByKey = true })
    local ve = car(e, 3, { tag = 0.5 })
    register(e, ve)
    driver(ve)
    step()
    check(e.door:IsOpen() and not e.door:isLockedByKey(), "鑰匙鎖的門：解鎖後開門")
    e.door:ToggleDoor(newPlayer("closer", 500, 101))
    check(not e.door:IsOpen() and not e.door:isLockedByKey(), "玩家手動關上（還沒上鎖）")
    moveCar(ve, ve._x, ve._y + 40)
    runMs(5500)
    check(e.door:isLockedByKey() and e.door._view.lockedByKey and rec(e).open == nil, "手動關上的門也收尾：鑰匙鎖鎖回並同步")

    -- 伺服器重啟後仍會關
    local f = gate(600)
    local vf = car(f, 3, { tag = 0.5 })
    register(f, vf)
    cmd(f.owner, "lock", { key = f.key, on = true })
    driver(vf)
    step()
    check(f.door:IsOpen(), "重啟前開門")
    moveCar(vf, vf._x, vf._y + 40)
    restart()
    check(rec(f) and rec(f).open == true, "重啟後帳本仍記得門開著")
    runMs(6000)
    check(not f.door:IsOpen() and f.door._modData.CustomLock == true and rec(f).open == nil, "重啟後照樣關門並鎖回")
    clean(from, "自動關門")
end

local function scenarioLocks()
    out("情境：門鎖")
    freshWorld()
    local from = #logLines + 1

    -- IsoDoor 鑰匙鎖：開前解、關後鎖回、keyId 不換
    local a = gate(100, { keyId = 4242, lockedByKey = true })
    local va = car(a, 3, { tag = 0.5 })
    register(a, va)
    local stranger = newPlayer("stranger", 100, 101)
    a.door:ToggleDoor(stranger)
    check(not a.door:IsOpen(), "（引擎）沒鑰匙的人打不開鑰匙鎖")
    driver(va)
    step()
    check(a.door:IsOpen() and not a.door:isLockedByKey(), "Knox Pass 開門前解除鑰匙鎖")
    moveCar(va, va._x, va._y + 40)
    runMs(5500)
    check(not a.door:IsOpen() and a.door:isLockedByKey() and a.door._view.lockedByKey == true and a.door:getKeyId() == 4242,
        "關好後鑰匙鎖鎖回、明確同步給 client、keyId 不變")

    -- Knox 門鎖（雙開 IsoDoor）
    local b = gate(200, { double = true, click = 3 })
    check(b.key == "200,100,0N" and rec(b).kind == "Double", "點第 3 片安裝，錨點是第 1 片")
    check(cmd(b.owner, "lock", { key = b.key, on = true }).ok == true, "擁有者開啟門鎖")
    local keyId = b.door:getKeyId()
    check(allPieces(b, function(p) return p._modData.CustomLock == true and p._view.modData.CustomLock == true end),
        "四片都設 CustomLock 並 transmitModData")
    check(keyId ~= -1 and allPieces(b, function(p) return p:getKeyId() == keyId end), "整組配同一把非 -1 的 keyId")
    check(b.door._modData.KnoxPassLock == true, "錨點標記門鎖開啟")
    local blank = newPlayer("blank", 202, 101)
    blank._inv:AddItem(newKey(-1))
    b.group.pieces[2]:ToggleDoor(blank)
    check(not b.door:IsOpen(), "（引擎）空白鑰匙打不開 Knox 門鎖")
    local vb = car(b, 3, { tag = 0.5 })
    register(b, vb)
    local old2, old3 = b.group.pieces[2], b.group.pieces[3]
    driver(vb)
    step()
    check(b.door:IsOpen() and b.group.pieces[2] ~= old2 and b.group.pieces[3] ~= old3, "開門（第 2、3 片被重建）")
    moveCar(vb, vb._x, vb._y + 40)
    runMs(5500)
    check(not b.door:IsOpen(), "關門")
    check(allPieces(b, function(p) return p._modData.CustomLock == true and p:getKeyId() == keyId end),
        "關好後連重建的第 2、3 片都有 CustomLock、keyId 不變")
    b.group.pieces[3]:ToggleDoor(blank)
    check(not b.door:IsOpen(), "（引擎）關好後沒鑰匙的人仍打不開")
    check(cmd(b.owner, "lock", { key = b.key, on = false }).ok == true
        and allPieces(b, function(p) return p._modData.CustomLock == nil and p._view.modData.CustomLock == nil end),
        "關閉門鎖拿掉所有 CustomLock 並同步")
    check(b.door._modData.KnoxPassLock == nil, "錨點標記門鎖關閉")

    -- 鑰匙鎖＋Knox 門鎖：關閉門鎖只拿掉 CustomLock
    local c = gate(300, { keyId = 5151, lockedByKey = true })
    cmd(c.owner, "lock", { key = c.key, on = true })
    check(c.door:getKeyId() == 5151 and c.door._modData.CustomLock == true, "已有 keyId 的門沿用原本 keyId")
    local vc = car(c, 3, { tag = 0.5 })
    register(c, vc)
    driver(vc)
    step()
    check(c.door:IsOpen(), "開門")
    moveCar(vc, vc._x, vc._y + 40)
    runMs(5500)
    check(c.door:isLockedByKey() and c.door._modData.CustomLock == true, "關好後鑰匙鎖與 Knox 門鎖都回來")
    cmd(c.owner, "lock", { key = c.key, on = false })
    check(c.door:isLockedByKey() and c.door._modData.CustomLock == nil, "關閉門鎖只拿掉 CustomLock，鑰匙鎖還在")

    -- 可跨越的柵欄門：強制解鎖不影響 CustomLock
    local d = gate(400, { hoppable = true })
    cmd(d.owner, "lock", { key = d.key, on = true })
    d.door:ToggleDoor(newPlayer("hopper", 400, 101))
    check(not d.door:IsOpen(), "柵欄門的 Knox 門鎖擋得住沒鑰匙的人")

    -- 門開著時切換門鎖：先記下，關好後才套用
    local e = gate(500)
    local ve = car(e, 3, { tag = 0.5 })
    register(e, ve)
    driver(ve)
    step()
    cmd(e.owner, "lock", { key = e.key, on = true })
    check(e.door:IsOpen() and e.door._modData.CustomLock == nil and rec(e).lock == true, "門開著時開啟門鎖：只記下")
    moveCar(ve, ve._x, ve._y + 40)
    runMs(5500)
    check(not e.door:IsOpen() and e.door._modData.CustomLock == true, "關好後套用門鎖")

    -- IsoThumpable：門鎖用 lockedByKey
    local f = gate(600, { cls = "IsoThumpable" })
    check(f.key ~= nil, "玩家建造的門可安裝")
    cmd(f.owner, "lock", { key = f.key, on = true })
    check(f.door:isLockedByKey() and f.door._view.lockedByKey == true and f.door:getKeyId() ~= -1
        and f.door._view.keyId == f.door:getKeyId(), "IsoThumpable 門鎖：lockedByKey＋配 keyId 並同步")
    f.door:ToggleDoor(newPlayer("outsider", 600, 101))
    check(not f.door:IsOpen(), "（引擎）室外沒鑰匙的人打不開")
    local vf = car(f, 3, { tag = 0.5 })
    register(f, vf)
    driver(vf)
    step()
    check(f.door:IsOpen(), "Knox Pass 開 IsoThumpable 門")
    moveCar(vf, vf._x, vf._y + 40)
    runMs(5500)
    check(not f.door:IsOpen() and f.door:isLockedByKey() and f.door._view.lockedByKey == true, "關好後鎖回並同步")
    cmd(f.owner, "lock", { key = f.key, on = false })
    check(not f.door:isLockedByKey() and f.door._view.lockedByKey == false, "關閉門鎖 → unlockKnox 解鎖並同步")

    -- IsoThumpable 雙開門
    local g = gate(700, { cls = "IsoThumpable", double = true })
    cmd(g.owner, "lock", { key = g.key, on = true })
    local vg = car(g, 3, { tag = 0.5 })
    register(g, vg)
    driver(vg)
    step()
    check(g.door:IsOpen(), "Knox Pass 開 IsoThumpable 雙開門")
    moveCar(vg, vg._x, vg._y + 40)
    runMs(5500)
    check(not g.door:IsOpen() and allPieces(g, function(p) return p:isLockedByKey() and p._view.lockedByKey end),
        "關好後四片（含重建片）都鎖回並同步")
    clean(from, "門鎖")
end

local function scenarioCommands()
    out("情境：指令")
    freshWorld()
    local from = #logLines + 1

    -- 安裝
    local door = makeDoor("IsoDoor", 100, 100)
    square(100, 100, 0)._grid = true
    local owner = newPlayer("owner", 100, 102)
    local reader = owner._inv:AddItem(READER)
    local junk = owner._inv:AddItem("Base.Hammer")
    local function install(p, item, x)
        return cmd(p, "install", { x = x or 100, y = 100, z = 0, index = door:getObjectIndex(), itemId = item:getID() })
    end
    check(install(owner, junk).why == "NoReader", "安裝要用讀頭（別的物品回 NoReader）")
    local far = newPlayer("far", 100, 105)
    far._inv:AddItem(reader)
    check(install(far, reader).why == "TooFar", "離門 4 格以上回 TooFar")
    owner._inv:AddItem(reader)
    check(install(owner, reader, 101).why == "NoGate", "格子上沒有門回 NoGate")
    local v0 = makeVehicle(100.5, 102.5)
    seat(owner, v0, 0)
    check(install(owner, reader).why == "InVehicle", "在車上不能安裝")
    unseat(owner)
    owner._x, owner._y = 100.5, 102.5
    W.safehouse[square(100, 100, 0)] = { someoneElse = true }
    check(install(owner, reader).why == "Safehouse", "別人的安全屋內不能安裝")
    W.safehouse[square(100, 100, 0)] = nil
    local res = install(owner, reader)
    local key = res.key
    local r = KP.Ledger.get(key)
    check(res.ok == true and r ~= nil and r.owner == "owner", "安裝成功並建立帳本記錄")
    check(countType(owner._inv, READER) == 0 and W.removeSent == 1, "讀頭被消耗並同步移除")
    check(door._modData.KnoxPassReader == "owner" and door._view.modData.KnoxPassReader == "owner", "錨點標記擁有者並同步")
    local other = newPlayer("other", 100, 101)
    local reader2 = other._inv:AddItem(READER)
    check(install(other, reader2).why == "AlreadyInstalled" and countType(other._inv, READER) == 1, "重複安裝被拒、讀頭不扣")

    -- 身分
    check(cmd(other, "lock", { key = key, on = true }).why == "NotOwner", "非擁有者不能管理")
    local admin = newPlayer("admin", 100, 101, { caps = { CanOpenLockedDoors = true } })
    check(cmd(admin, "lock", { key = key, on = true }).ok == true, "管理員可以管理")
    cmd(admin, "lock", { key = key, on = false })
    local split = newPlayer("owner", 100, 101, { num = 1 })
    check(cmd(split, "lock", { key = key, on = true }).why == "NotOwner", "分割畫面第 2 位（同名）不能冒充擁有者")
    local splitReader = split._inv:AddItem(READER)
    local door2 = makeDoor("IsoDoor", 103, 100)
    check(cmd(split, "install", { x = 103, y = 100, z = 0, index = 0, itemId = splitReader:getID() }).why == "Unverified",
        "分割畫面玩家無法驗證身分，不能安裝")
    local _, st = cmd(other, "query", { key = key })
    check(st and st.manager == false and st.tags == nil and st.owner == "owner", "非擁有者查詢只拿到基本狀態")
    _, st = cmd(owner, "query", { key = key })
    check(st and st.manager == true and type(st.tags) == "table", "擁有者查詢拿到完整狀態")

    -- 距離
    owner._y = 104.5
    check(cmd(owner, "query", { key = key }).why == "TooFar", "擁有者離門太遠回 TooFar")
    owner._y, owner._z = 102.5, 1
    check(cmd(owner, "lock", { key = key, on = true }).why == "TooFar", "不同樓層回 TooFar")
    owner._z = 0

    -- 登記
    local cx, cy = r.cx, r.cy
    local vNear = makeVehicle(cx, cy + 10, { tag = 0.5 })
    local vFar = makeVehicle(cx, cy + 20, { tag = 0.5 })
    local vBare = makeVehicle(cx + 3, cy + 5)
    check(cmd(owner, "register", { key = key, vehicleId = vNear:getId() }).ok == true
        and r.tags[vNear._parts.KnoxPassTag._item:getID()] ~= nil, "登記 15 格內裝著感應盒的車")
    check(cmd(owner, "register", { key = key, vehicleId = vFar:getId() }).why == "VehicleTooFar", "車太遠回 VehicleTooFar")
    check(cmd(owner, "register", { key = key, vehicleId = vBare:getId() }).why == "NoTag", "車上沒有感應盒回 NoTag")
    check(cmd(owner, "register", { key = key, vehicleId = "1" }).why == "BadArgs", "vehicleId 不是整數回 BadArgs")
    check(cmd(other, "register", { key = key, vehicleId = vNear:getId() }).why == "NotOwner", "非擁有者不能登記")
    for id = 1, 63 do KP.Ledger.addTag(key, r, id, { serial = "x" }) end
    local vMore = makeVehicle(cx - 3, cy + 5, { tag = 0.5 })
    check(cmd(owner, "register", { key = key, vehicleId = vMore:getId() }).why == "TooMany", "超過 64 個感應盒回 TooMany")
    check(cmd(owner, "register", { key = key, vehicleId = vNear:getId() }).ok == true, "已登記的再登記一次不受上限影響")
    for id = 1, 63 do KP.Ledger.removeTag(key, r, id) end

    -- 註銷
    local tagId = vMore._parts.KnoxPassTag._item:getID()
    check(cmd(owner, "register", { key = key, vehicleId = vMore:getId() }).ok == true, "清出空位後可登記")
    check(cmd(owner, "unregister", { key = key, tagId = tagId }).ok == true and r.tags[tagId] == nil, "註銷感應盒")
    moveCar(vMore, cx, cy + 3)
    driver(vMore)
    runMs(2000)
    check(not door:IsOpen(), "註銷後的感應盒不能開門")
    unseat(vMore._seats[0])

    -- 步行開門
    local walker = newPlayer("walker", 100, 101)
    check(cmd(walker, "open", { key = key }).why == "NotAllowed", "非擁有者沒帶感應盒不能開")
    local empty = walker._inv:AddItem(newItem(TAG, 0))
    KP.Ledger.addTag(key, r, empty:getID(), { serial = "e" })
    check(cmd(walker, "open", { key = key }).why == "NotAllowed", "帶著已登記但沒電的感應盒不能開")
    local tag = vNear._parts.KnoxPassTag._item
    vNear._parts.KnoxPassTag._item = nil
    walker._inv:AddItem(tag)
    local stats = W.itemStats
    check(cmd(walker, "open", { key = key }).ok == true and door:IsOpen(), "帶著已登記且有電的感應盒可以開")
    check(near(tag:getCurrentUsesFloat(), 0.49) and W.itemStats == stats + 1, "步行開門扣電並 sendItemStats")
    runMs(6000)
    check(not door:IsOpen(), "步行開的門也會自動關")
    check(cmd(owner, "open", { key = key }).ok == true and door:IsOpen(), "擁有者不用感應盒也能開")
    runMs(6000)

    -- 拆除
    cmd(owner, "lock", { key = key, on = true })
    check(cmd(other, "uninstall", { key = key }).why == "NotOwner", "非擁有者不能拆")
    check(cmd(owner, "uninstall", { key = key }).ok == true and KP.Ledger.get(key) == nil, "擁有者拆除，帳本記錄刪除")
    check(countType(owner._inv, READER) == 1 and W.addSent == 1, "讀頭還給擁有者並同步")
    check(door._modData.KnoxPassReader == nil and door._modData.CustomLock == nil and door._view.modData.CustomLock == nil,
        "拆除後清掉標記與 Knox 門鎖")

    -- Steam 身分
    W.steam = true
    local d3 = makeDoor("IsoDoor", 200, 100)
    local sOwner = newPlayer("steamer", 200, 102, { sid = 76561 })
    local sReader = sOwner._inv:AddItem(READER)
    local sKey = cmd(sOwner, "install", { x = 200, y = 100, z = 0, index = d3:getObjectIndex(), itemId = sReader:getID() }).key
    check(KP.Ledger.get(sKey).sid == 76561, "Steam 伺服器記下安裝者 SteamID")
    local impostor = newPlayer("steamer", 200, 101, { sid = 99999 })
    check(cmd(impostor, "lock", { key = sKey, on = true }).why == "NotOwner", "同名但 SteamID 不同 → NotOwner")
    check(cmd(sOwner, "lock", { key = sKey, on = true }).ok == true, "同名同 SteamID → 可以管理")
    W.steam = false

    -- 速率限制
    local spam = newPlayer("spam", 100, 101)
    local d4 = makeDoor("IsoDoor", 300, 100)
    local o4 = newPlayer("o4", 300, 102)
    local k4 = cmd(o4, "install", { x = 300, y = 100, z = 0, index = d4:getObjectIndex(), itemId = o4._inv:AddItem(READER):getID() }).key
    spam._x = 300.5
    local okCount = 0
    for _ = 1, 20 do
        local res20, st20 = cmd(spam, "query", { key = k4 })
        if st20 and not res20.why then okCount = okCount + 1 end
    end
    check(okCount == 20, "10 秒內前 20 個指令正常")
    check(cmd(spam, "query", { key = k4 }).why == "RateLimited", "第 21 個指令回 RateLimited")
    nowMs = nowMs + 10001
    local _, st2 = cmd(spam, "query", { key = k4 })
    check(st2 ~= nil, "過了 10 秒視窗恢復")
    check(W.sendServerCalls > 0 and #W.sent > 0, "MP 回覆走 sendServerCommand")
    clean(from, "指令")
end

local function scenarioSinglePlayer()
    out("情境：單機（SP）")
    freshWorld("sp")
    local from = #logLines + 1
    local got = {}
    KP.clientReceive = function(command, args) got[#got + 1] = { cmd = command, args = args } end
    local door = makeDoor("IsoDoor", 100, 100)
    square(100, 100, 0)._grid = true
    local me = newPlayer("me", 100, 102)
    W.locals = { me }
    local reader = me._inv:AddItem(READER)
    fire("OnClientCommand", "MinidoracatKnoxPass", "install", me, { x = 100, y = 100, z = 0, index = 0, itemId = reader:getID() })
    local result
    for _, g in ipairs(got) do if g.cmd == "result" then result = g.args end end
    check(result and result.ok == true and result.key ~= nil, "SP 回覆直接呼叫 MinidoracatKnoxPass.clientReceive")
    check(W.sendServerCalls == 0 and #W.sent == 0, "SP 不依賴 sendServerCommand（它在 SP 是 no-op）")
    check(getOnlinePlayers():size() == 0, "（假引擎）SP 的 getOnlinePlayers 是空的")
    local rec1 = KP.Ledger.get(result.key)
    local v = makeVehicle(rec1.cx, rec1.cy + 10, { tag = 0.5 })
    fire("OnClientCommand", "MinidoracatKnoxPass", "register", me, { key = result.key, vehicleId = v:getId() })
    moveCar(v, rec1.cx, rec1.cy + 3)
    seat(me, v, 0)
    step()
    check(door:IsOpen(), "SP 走本機玩家清單偵測，駕駛靠近會開門")
    moveCar(v, v._x, v._y + 40)
    runMs(5500)
    check(not door:IsOpen(), "SP 自動關門")
    clean(from, "SP")
end

local function scenarioLedger()
    out("情境：帳本")
    freshWorld()
    local from = #logLines + 1

    local a = gate(100)
    local va = car(a, 3, { tag = 0.5 })
    register(a, va)
    cmd(a.owner, "lock", { key = a.key, on = true })
    local tagId = va._parts.KnoxPassTag._item:getID()
    local inst = SGlobalObjects.getSystemByIndex(0):getModData()
    inst.junk = "not whitelisted"
    restart()
    inst = SGlobalObjects.getSystemByIndex(0):getModData()
    local r = rec(a)
    check(r and r.owner == a.owner:getUsername() and r.lock == true and r.tags[tagId] ~= nil, "重啟後記錄（擁有者、門鎖、感應盒）都還在")
    check(inst.junk == nil, "白名單以外的鍵重啟後消失（證明假存檔只存白名單）")
    driver(va)
    step()
    check(a.door:IsOpen(), "重啟後 byTag 索引重建，登記的車照樣開門")
    moveCar(va, va._x, va._y + 40)
    runMs(5500)
    check(not a.door:IsOpen() and a.door._modData.CustomLock == true, "重啟後關門並鎖回")

    -- 門沒經過移除事件就不見（例：地圖重置、存檔不同步）：格子載入時滿 30 秒才刪記錄。
    -- 經過移除事件的拆門／打壞下一個 tick 就刪（ReaderPost.lua，scenarioReaderPost）
    local b = gate(200)
    local vb = car(b, 3, { tag = 0.5 })
    register(b, vb)
    driver(vb)
    step()
    check(b.door:IsOpen(), "開門")
    moveCar(vb, vb._x, vb._y + 40)
    local bsq = b.door._square._objects
    for i, o in ipairs(bsq) do if o == b.door then table.remove(bsq, i) break end end
    runMs(2000 + 29500)   -- 關門延遲（預設 2 秒）到了才去找門，找不到起算 30 秒
    check(rec(b) ~= nil, "門不見未滿 30 秒不刪記錄")
    runMs(1000)
    check(rec(b) == nil and logHas("gate missing", from), "門不見滿 30 秒刪除記錄")
    check(KP.Ledger.gatesForTag(vb._parts.KnoxPassTag._item:getID())[b.key] == nil, "刪除記錄時同步清掉 byTag 索引")

    -- 格子沒載入不算不見
    local c = gate(300)
    local vc = car(c, 3, { tag = 0.5 })
    register(c, vc)
    driver(vc)
    step()
    moveCar(vc, vc._x, vc._y + 40)
    W.unloaded["300,100,0"] = true
    runMs(60000)
    check(rec(c) ~= nil and rec(c).open == true, "格子沒載入 60 秒：記錄保留、仍等著關")
    W.unloaded["300,100,0"] = nil
    runMs(2500)
    check(not c.door:IsOpen() and rec(c).open == nil, "格子重新載入後關門")
    clean(from, "帳本")
end

local function scenarioReopen()
    out("情境：Knox Pass 開的門被手動關上")
    freshWorld()
    local from = #logLines + 1
    local a = gate(100, { double = true })
    cmd(a.owner, "lock", { key = a.key, on = true })
    local va = car(a, 3, { tag = 0.5 })
    register(a, va)
    driver(va)
    step()
    check(a.door:IsOpen() and near(charge(va), 0.49), "開門扣一次電")
    a.door:ToggleDoor(newPlayer("closer", 99, 101))
    check(not a.door:IsOpen() and rec(a).open == true, "玩家手動關上（帳本仍記開著）")
    local deltas = W.partDeltas
    step()
    check(a.door:IsOpen() and rec(a).open == true, "下一次掃描重新開門，帳本仍記開著")
    check(near(charge(va), 0.48) and W.partDeltas == deltas + 1, "重開扣電一次並同步")
    runMs(2000)
    check(near(charge(va), 0.48) and a.door:IsOpen(), "之後的掃描不再扣電")

    -- 重開不成（沒供電）：照關好的規則鎖回，帳本不再記開著
    local c = gate(300)
    cmd(c.owner, "lock", { key = c.key, on = true })
    local vc = car(c, 3, { tag = 0.5 })
    register(c, vc)
    driver(vc)
    step()
    c.door:ToggleDoor(newPlayer("closer2", 299, 101))
    square(300, 100, 0)._grid = false
    step()
    check(not c.door:IsOpen() and c.door:isLockedByKey() and c.door._modData.CustomLock == true and rec(c).open == nil,
        "重開不成（沒供電）：照關好的規則鎖回，帳本不再記開著")

    local b = gate(200)
    b.door:ToggleDoor(newPlayer("hand", 200, 101))
    local vb = car(b, 3, { tag = 0.5 })
    register(b, vb)
    driver(vb)
    runMs(2000)
    check(b.door:IsOpen() and rec(b).open == nil and near(charge(vb), 0.5), "反面：別人手動開著的門不接手、不扣電")
    clean(from, "手動關上後重開")
end

local function scenarioUninstallOpen()
    out("情境：門開著時拆讀頭")
    freshWorld()
    local from = #logLines + 1
    local function openBy(g)
        local v = car(g, 3, { tag = 0.5 })
        register(g, v)
        driver(v)
        step()
    end
    local function uninstall(g) return cmd(g.owner, "uninstall", { key = g.key }).ok == true and KP.Ledger.get(g.key) == nil end

    local a = gate(100, { keyId = 888, lockedByKey = true })
    cmd(a.owner, "lock", { key = a.key, on = true })
    openBy(a)
    check(a.door:IsOpen() and rec(a).keyed == 2, "Knox Pass 開著（原本是鑰匙鎖，記成 2）")
    check(uninstall(a), "拆讀頭成功")
    check(not a.door:IsOpen(), "沒被擋 → 關門")
    check(a.door:isLockedByKey() and a.door._view.lockedByKey == true and a.door:getKeyId() == 888, "關好後鎖回原本的鑰匙鎖並同步")
    check(a.door._modData.CustomLock == nil and a.door._view.modData.CustomLock == nil, "門鎖模式的 CustomLock 移除並同步")

    local b = gate(200)
    cmd(b.owner, "lock", { key = b.key, on = true })
    openBy(b)
    check(uninstall(b) and not b.door:IsOpen() and not b.door:isLockedByKey() and b.door._modData.CustomLock == nil,
        "原本沒鑰匙鎖：關門、不加鑰匙鎖、CustomLock 移除")

    local c = gate(300, { keyId = 889, lockedByKey = true })
    cmd(c.owner, "lock", { key = c.key, on = true })
    openBy(c)
    c.door._obstructed = true
    check(uninstall(c), "被擋住時仍可拆")
    check(c.door:IsOpen() and not c.door:isLockedByKey() and c.door._modData.CustomLock == nil, "被擋住：門留著開、不鎖、CustomLock 移除")
    c.door._obstructed = false
    runMs(10000)
    check(c.door:IsOpen(), "拆掉後 Knox Pass 不再管這扇門")

    local d = gate(400, { cls = "IsoThumpable", keyId = 990, lockedByKey = true })
    cmd(d.owner, "lock", { key = d.key, on = true })
    openBy(d)
    check(d.door:IsOpen() and not d.door:isLockedByKey(), "Knox Pass 開著玩家建造的門（原本有鑰匙鎖）")
    check(uninstall(d) and not d.door:IsOpen(), "拆讀頭並關門")
    check(d.door:isLockedByKey() and d.door._view.lockedByKey == true and d.door:getKeyId() == 990,
        "IsoThumpable：拿掉門鎖後仍鎖回 lockedByKey 並同步")
    clean(from, "門開著時拆讀頭")
end

local function scenarioGarage()
    out("情境：車庫門")
    freshWorld()
    local from = #logLines + 1
    local a = gate(100, { garage = true, click = 2 })
    local r = rec(a)
    check(a.key == "100,100,0N" and r and r.kind == "Garage", "點中間片安裝，錨點是第 1 片、類型 Garage")
    local adapter = KP.Gates.byId(r.adapter)
    local ps = KP.Gates.pieces(adapter, a.door)
    local orig = { a.group.pieces[1], a.group.pieces[2], a.group.pieces[3] }
    check(#ps == 3 and ps[1] == orig[1] and ps[2] == orig[2] and ps[3] == orig[3], "整組三片（第 1 片 → 中間片 → 最後一片）")
    orig[2]:ToggleDoor(newPlayer("outside", 101, 103))
    check(not a.door:IsOpen(), "（引擎）地圖車庫門關著是鎖的，外側的人打不開")
    check(cmd(a.owner, "lock", { key = a.key, on = true }).ok == true, "擁有者開啟門鎖")
    local keyId = a.door:getKeyId()
    check(keyId ~= -1 and allPieces(a, function(p) return p._modData.CustomLock == true and p:getKeyId() == keyId end),
        "門鎖套到整組三片、同一把非 -1 keyId")
    local va = car(a, 3, { tag = 0.5 })
    register(a, va)
    driver(va)
    step()
    check(allPieces(a, function(p)
        return p:IsOpen() and not p:isLocked() and not p:isLockedByKey() and p._modData.CustomLock == nil
    end), "開門前解除整組的鎖，三片一起開")
    check(rec(a).keyed == 1, "記下原本只有 locked（車庫門的內外側鎖，記成 1）")
    -- 另一台車跨在門線上（中間片的格子＋北側那格）：Knox Pass 關門前自己查到擋車、不呼叫 ToggleDoor。
    -- 交給引擎的話，引擎拒關時會對開關者播 Blocked 音＋顯示 HaloNote（D:1583-1586），每次重試洗一次畫面
    local blocker = makeVehicle(101.5, 100.0)
    blocker._cover = { ["101,100,0"] = true, ["101,99,0"] = true }
    check(KP.Gates.isBlocked(adapter, a.door) == true, "isBlocked：車身同時壓到門格與門線另一側 → 擋住（同引擎 D:3396-3457）")
    moveCar(va, va._x, va._y + 40)
    local blocked, q = W.garageBlocked, W.vehicleQueries
    for _ = 1, 40 do
        step()
        if W.vehicleQueries > q then break end
    end
    check(W.vehicleQueries > q and a.door:IsOpen() and W.garageBlocked == blocked,
        "延遲到了先查擋車 → 不呼叫 ToggleDoor（引擎沒有拒關、沒有擋住提示），門留著開")
    blocker._cover = { ["101,100,0"] = true }
    check(KP.Gates.isBlocked(adapter, a.door) == false, "車只壓到門內側那格、沒跨線 → 不算擋")
    runMs(1750)
    check(a.door:IsOpen(), "擋車後 1.75 秒內不重試")
    step()
    check(not a.door:IsOpen() and W.garageBlocked == blocked, "第 2 秒重試關上")
    check(allPieces(a, function(p)
        return not p:IsOpen() and p:isLockedByKey() and p._view.locked == true and p._view.lockedByKey == true
            and p._modData.KnoxPassLocked == 1 and p._modData.CustomLock == true and p._view.modData.CustomLock == true
    end), "關好後整組鎖回：Knox 門鎖是鑰匙鎖（車庫門 client 只收得到鑰匙鎖），原本的 locked 記成 1，並同步")
    step()   -- 關門時 client 回送的鑰匙鎖到伺服器（Door:syncIsoObject），之後才有人動手
    local holder = newPlayer("holder", 101, 103)
    holder._inv:AddItem(newKey(keyId))
    orig[2]:ToggleDoor(holder)
    step()   -- 開與關之間至少隔一個 tick：開門的回送先到
    orig[2]:ToggleDoor(holder)
    check(not a.door:IsOpen() and not a.door:isLockedByKey() and not a.door:isLocked(), "（引擎）有鑰匙的人用手開關：鎖被清掉")
    runMs(5250)
    check(allPieces(a, function(p) return p:isLockedByKey() and p._view.locked == true and p._modData.KnoxPassLocked == 1 end),
        "5 秒內補回鑰匙鎖並同步，原本的鎖仍記成 1")
    check(cmd(a.owner, "lock", { key = a.key, on = false }).ok == true and allPieces(a, function(p)
        return p._modData.KnoxPassLocked == nil and p._modData.CustomLock == nil
    end), "關閉門鎖：拿掉 CustomLock 與標記")
    step()
    check(allPieces(a, function(p) return not p:isLocked() and not p:isLockedByKey() and p._view.locked == false end),
        "MP 車庫門回不到只有 locked：client 把 locked=false 回送伺服器，整組沒鎖（引擎同步語意，zombielock-mp Z6）")
    check(a.group.pieces[1] == orig[1] and a.group.pieces[2] == orig[2] and a.group.pieces[3] == orig[3]
        and W.recreated == 0, "開關不重建物件")
    clean(from, "車庫門")
end

-- 實機 E2E 回歸：雙開門打開時第 2、3 片移到別格重建，門口要看「關著時」各片的格子（rec.doorway）
local function scenarioDoubleDoorway()
    out("情境：雙開門門口（關著時的格子）")
    freshWorld()
    local from = #logLines + 1
    local function openDouble(x, cls)
        local g = gate(x, { double = true, cls = cls })
        cmd(g.owner, "lock", { key = g.key, on = true })
        local v = car(g, 3, { tag = 0.5 })
        register(g, v)
        driver(v)
        step()
        moveCar(v, v._x, v._y + 40)
        return g
    end
    local function locked(g)
        return allPieces(g, function(p)
            if instanceof(p, "IsoThumpable") then return p:isLockedByKey() and p._view.lockedByKey == true end
            return p._modData.CustomLock == true
        end)
    end

    -- IsoDoor：玩家站在第 2 片關著時的格子
    local a = openDouble(100, "IsoDoor")
    local d = rec(a).doorway
    check(a.door:IsOpen() and type(d) == "table" and #d == 4 and d[2].x == 101 and d[2].y == 100 and d[2].n == true,
        "IsoDoor 雙開門：開門前記下四片關著時的格子（含 north）")
    check(a.group.pieces[2]._square._y == 99, "（假引擎）開著時第 2 片已移到別格")
    local stander = newPlayer("stander", 101, 100)
    runMs(5500)
    check(a.door:IsOpen(), "第 2 片關著時的格子有人 → 過了關門延遲也不關")
    runMs(2000)
    check(a.door:IsOpen(), "2 秒後重試仍不關")
    stander._x = 130.5
    runMs(2250)
    check(not a.door:IsOpen() and locked(a), "人走開後關上並鎖回（四片 CustomLock）")
    check(rec(a).doorway == nil and rec(a).open == nil, "關好後清掉 rec.doorway")

    -- IsoThumpable：玩家站在第 2 片關著時的格子另一側（殭屍不擋，見 scenarioAutoClose）
    local b = openDouble(200, "IsoThumpable")
    check(b.door:IsOpen() and rec(b).doorway and rec(b).doorway[2].x == 201, "IsoThumpable 雙開門：開門並記下門口格")
    local stander2 = newPlayer("stander2", 201, 99)
    runMs(5500)
    check(b.door:IsOpen(), "第 2 片門線另一側那格有人 → 過了關門延遲也不關")
    runMs(2000)
    check(b.door:IsOpen(), "2 秒後重試仍不關")
    stander2._x = 230.5
    runMs(2250)
    check(not b.door:IsOpen() and locked(b), "人走開後關上並鎖回（四片 lockedByKey 並同步）")
    check(rec(b).doorway == nil, "關好後清掉 rec.doorway")

    -- 重啟：rec.doorway 存在帳本白名單內
    local c = openDouble(300, "IsoDoor")
    restart()
    d = rec(c).doorway
    check(c.door:IsOpen() and type(d) == "table" and #d == 4 and d[3].x == 302 and d[3].y == 100,
        "重啟後 rec.doorway 仍在")
    local stander3 = newPlayer("stander3", 302, 100)
    runMs(7500)
    check(c.door:IsOpen(), "重啟後第 3 片關著時的格子有人 → 不關")
    stander3._x = 330.5
    runMs(2250)
    check(not c.door:IsOpen() and locked(c) and rec(c).doorway == nil, "人走開後關上、鎖回、清掉 rec.doorway")
    clean(from, "雙開門門口")
end

-- 家族 AutoDrive 自駕車：伺服器以全域 MDAD.isAutoUsageActive(vehicle) 認車；大門中心在 AutoDriveAhead 格內、
-- 與車頭朝向（getForwardVector）夾角 ≤12° 就開，停著也算。一般車仍用平滑速度的線段預判：
-- v = (舊 v + 本次位置差速度)/2，間隔 ≥2 秒或第一次見到時歸零
local function scenarioAutoDrive()
    out("情境：AutoDrive 自駕車提早開門")
    freshWorld()
    local from = #logLines + 1
    local auto, calls = {}, 0
    MDAD = { isAutoUsageActive = function(v)
        calls = calls + 1
        return auto[v] == true
    end }
    local SPEED = 20 / 3.6   -- 20 km/h ≈ 5.56 格/秒（1 格 = 1 公尺）
    -- 登記一台車並讓人坐上駕駛座，停在大門南方 dist 格、往東偏 dx 格
    local function ready(g, dist, isAuto, dx)
        local v = car(g, 3, { tag = 0.5 })
        register(g, v)
        auto[v] = isAuto or nil
        driver(v)
        moveCar(v, g.cx + (dx or 0), g.cy + dist)
        return v
    end
    local function dist(g, v) return math.sqrt((v._x - g.cx) ^ 2 + (v._y - g.cy) ^ 2) end
    -- 等速行駛 seconds 秒，車頭朝行進方向。deg：相對「正北」（朝大門）偏幾度，180 = 遠離。
    -- batch：伺服器位置一批一批到，每兩次掃描才前進一次（一次走兩步），平均速度不變。
    -- 回傳開門時與大門的距離（沒開回 nil）與 OnTick 拋出的錯誤
    local function drive(g, v, seconds, deg, batch)
        local rad = math.rad(deg or 0)
        local ux, uy = math.sin(rad), -math.cos(rad)
        v._fx, v._fy = ux, uy
        for i = 1, math.floor(seconds * 4) do
            local k = SPEED / 4
            if batch then k = (i % 2 == 0) and SPEED / 2 or 0 end
            local ok, err = pcall(step, function() moveCar(v, v._x + ux * k, v._y + uy * k) end)
            if not ok then return nil, err end
            if g.door:IsOpen() then return dist(g, v) end
        end
        return nil
    end
    local function fmt(d) return d and string.format("%.1f", d) or "nil" end

    -- 1. 直行：自駕車在 AutoDriveAhead（預設 150）內就開，一般車要靠近才開
    local a = gate(100)
    local va = ready(a, 200, true)
    local openAt = drive(a, va, 30)
    check(openAt ~= nil and openAt <= 150 and openAt > 120, "自駕車 20 km/h 從 200 格外直行：在 120–150 格間開門（" .. fmt(openAt) .. "）")
    check(calls > 0, "有向 MDAD.isAutoUsageActive 詢問")
    unseat(va._seats[0])
    runMs(6000)
    check(not a.door:IsOpen(), "自駕車離開駕駛座後關門")
    local vn = ready(a, 200, false)
    openAt = drive(a, vn, 40)
    check(openAt ~= nil and openAt < 25, "一般車同樣速度：約 LeadSeconds×速度＋8 格才開（" .. fmt(openAt) .. "）")
    unseat(vn._seats[0])

    -- 2. 夾角（車頭朝向）：偏 8° 開；偏 20°、或平行路上大門一直在 20° 以外 → 不開
    local b = gate(300)
    local vb = ready(b, 200, true)
    openAt = drive(b, vb, 30, 8)
    check(openAt ~= nil and openAt <= 150 and openAt > 120, "自駕車行進方向偏 8°：在 150 格內開（" .. fmt(openAt) .. "）")
    local c = gate(500)
    local vc = ready(c, 200, true)
    openAt = drive(c, vc, 50, 20)
    check(openAt == nil and not c.door:IsOpen(), "自駕車行進方向偏 20°（最近距離約 68 格）：整段都不開")
    local c2 = gate(700)
    local vc2 = ready(c2, 200, true, 51)
    openAt = drive(c2, vc2, 50, 0)
    check(openAt == nil and not c2.door:IsOpen(), "平行路（橫向 51 格，150 格處夾角約 20°）直行經過：不開")

    -- 反方向、停著（看車頭朝向，不要求在動）
    local d = gate(900)
    local vd = ready(d, 20, true)
    drive(d, vd, 5, 180)
    check(not d.door:IsOpen(), "自駕車朝反方向開（從 20 格外，車頭背對大門）：不開")
    local e = gate(1100)
    local ve = ready(e, 9, true)
    ve._fx, ve._fy = 0, 1
    runMs(3000)
    check(not e.door:IsOpen(), "自駕車停在 ReadRange 外 1 格、車頭背對大門：不開")
    moveCar(ve, ve._x, e.cy + 7.5)
    runMs(1000)
    check(e.door:IsOpen(), "自駕車停著（車頭背對）進到 ReadRange：圓形範圍照開")
    local e2 = gate(1200)
    ready(e2, 100, true)
    runMs(500)
    check(e2.door:IsOpen(), "自駕車停在 100 格外（ReadRange 外、150 格內）、車頭對著大門：開")

    -- 3. AutoDriveAhead 調整
    SandboxVars.MinidoracatKnoxPass.AutoDriveAhead = 60
    local f = gate(1300)
    local vf = ready(f, 200, true)
    openAt = drive(f, vf, 40)
    check(openAt ~= nil and openAt <= 60 and openAt > 25, "AutoDriveAhead=60：在 60 格內開（" .. fmt(openAt) .. "）")
    SandboxVars.MinidoracatKnoxPass.AutoDriveAhead = 0
    local f0 = gate(1500)
    local vf0 = ready(f0, 200, true)
    openAt = drive(f0, vf0, 40)
    check(openAt ~= nil and openAt < 25, "AutoDriveAhead=0：自駕車和一般車一樣（" .. fmt(openAt) .. "）")
    SandboxVars.MinidoracatKnoxPass.AutoDriveAhead = nil

    -- 4. 平滑：位置一批一批到（每兩次掃描前進一次）。自駕車看車頭朝向、不受速度抖動影響；
    --    平滑本身由一般車的線段預判把關（不平滑時速度忽然翻倍，2 秒預判會延伸太遠）
    local h = gate(1700)
    local vh = ready(h, 200, true)
    openAt = drive(h, vh, 30, 0, true)
    check(openAt ~= nil and openAt <= 150 and openAt > 100, "位置一批一批到：自駕車照車頭朝向在 100–150 格間開（" .. fmt(openAt) .. "）")
    local h2 = gate(1900)
    local vh2 = ready(h2, 200, false)
    openAt = drive(h2, vh2, 40, 0, true)
    check(openAt ~= nil and openAt < 25, "位置一批一批到：一般車照樣開（" .. fmt(openAt) .. "）")

    -- 5. MDAD 缺席或壞掉：當一般車，OnTick 不崩
    MDAD = nil
    local m1 = gate(2100)
    openAt = drive(m1, ready(m1, 200, true), 40)
    check(openAt ~= nil and openAt < 25, "沒裝 AutoDrive（MDAD 不存在）：當一般車（" .. fmt(openAt) .. "）")
    MDAD = { isAutoUsageActive = true }
    local m2 = gate(2300)
    openAt = drive(m2, ready(m2, 200, true), 40)
    check(openAt ~= nil and openAt < 25, "MDAD.isAutoUsageActive 不是函式：當一般車（" .. fmt(openAt) .. "）")
    MDAD = 42
    local m3 = gate(2500)
    local err
    openAt, err = drive(m3, ready(m3, 200, true), 40)
    check(err == nil and openAt ~= nil and openAt < 25, "MDAD 不是 table：OnTick 不崩、當一般車（" .. fmt(openAt) .. "）")
    local throws = 0
    MDAD = { isAutoUsageActive = function()
        throws = throws + 1
        error("boom")
    end }
    local m4 = gate(2700)
    local v4 = ready(m4, 200, true)
    local m5 = gate(2900)
    local v5 = ready(m5, 40, true)   -- 同一輪掃描裡的另一台車（排在 v4 之後掃），也會讓 MDAD 丟錯
    openAt, err = drive(m4, v4, 40)
    check(err == nil and throws > 0, "MDAD.isAutoUsageActive 丟錯（" .. throws .. " 次）：OnTick 不崩")
    check(openAt ~= nil and openAt < 25, "MDAD.isAutoUsageActive 丟錯：當一般車（" .. fmt(openAt) .. "）")
    local at5
    at5, err = drive(m5, v5, 10)
    check(err == nil and at5 ~= nil and at5 < 25, "同一輪掃描的其他車照開（" .. fmt(at5) .. "）")
    MDAD = nil
    check(vecOut == 0, "BaseVehicle.allocVector3f／releaseVector3f 有借有還")
    clean(from, "AutoDrive")
end

-- 伺服器剛載入有讀頭大門的 chunk（LoadChunk，IsoChunk.java:3969）：節流歸零，下一個 tick 就掃描
local function scenarioLoadChunk()
    out("情境：載入有讀頭大門的 chunk 立刻掃描")
    freshWorld()
    local from = #logLines + 1
    local auto = {}
    MDAD = { isAutoUsageActive = function(v) return auto[v] == true end }
    local SPEED = 20 / 3.6
    local TICK = 33   -- 一個遊戲 tick（約 30 fps），遠小於 250 ms 掃描間隔
    local plain = makeDoor("IsoDoor", 900, 100)   -- 沒有讀頭標記的一般門
    -- 自駕車以 20 km/h 朝門直行，最後一次完整掃描時剛好在 150.1 格（AutoDriveAhead 外）
    local function approach(g)
        local v = car(g, 3, { tag = 0.5 })
        register(g, v)
        auto[v] = true
        driver(v)
        moveCar(v, g.cx, g.cy + 150.1 + 12 * SPEED / 4)
        for _ = 1, 12 do step(function() moveCar(v, v._x, v._y - SPEED / 4) end) end
        return v
    end
    -- 時間只前進 ms，期間載入 sq 所在的 chunk，再跑一次 OnTick
    local function tickAfter(v, ms, sq)
        nowMs = nowMs + ms
        moveCar(v, v._x, v._y - SPEED * ms / 1000)
        if sq then loadChunk(sq:getX(), sq:getY()) end
        fire("OnTick")
    end

    local a = gate(100)
    check(a.door:hasModData() and a.door._modData.KnoxPassReader ~= nil, "錨點有讀頭標記")
    local va = approach(a)
    check(not a.door:IsOpen() and va._y - a.cy > 150, "最後一次掃描時在 150 格外，門關著")
    tickAfter(va, TICK, a.door:getSquare())
    check(a.door:IsOpen() and va._y - a.cy < 150,
        "載入錨點所在的 chunk 後下一個 tick（33 ms）就掃描並開門（" .. string.format("%.1f", va._y - a.cy) .. " 格）")

    local b = gate(300)
    local vb = approach(b)
    tickAfter(vb, TICK, plain:getSquare())
    check(not b.door:IsOpen(), "反面：載入的 chunk 只有沒裝讀頭的門 → 33 ms 後不掃描、不開")
    tickAfter(vb, TICK, square(1000, 1000, 0))
    check(not b.door:IsOpen(), "反面：載入空的 chunk → 66 ms 後仍不掃描")
    tickAfter(vb, 250 - 2 * TICK)
    check(b.door:IsOpen(), "滿 250 ms 照常掃描並開門")

    local c = gate(500)
    local vc = approach(c)
    W.unloaded["496,96,0"] = true   -- 這個 chunk 的 (0, 0, 0) 格不存在
    tickAfter(vc, TICK, c.door:getSquare())
    W.unloaded["496,96,0"] = nil
    check(c.door:IsOpen(), "chunk 的 (0, 0, 0) 格不存在：用其他格算出 chunk，照樣下一個 tick 就掃描")
    MDAD = nil
    clean(from, "LoadChunk")
end

-- 感應盒換車：登記清單顯示「最後一次看到這顆感應盒時所在的車」（Server.lua buildState、Sensor.lua S.open 兩個更新點）
local function scenarioTagScript()
    out("情境：感應盒換車後更新車型")
    freshWorld()
    local from = #logLines + 1
    local CAR, TRUCK, SPORT = "Base.CarNormal", "Base.PickUpTruck", "Base.SportsCar"
    local function moveTag(src, dst)
        dst._parts.KnoxPassTag._item = src._parts.KnoxPassTag._item
        src._parts.KnoxPassTag._item = nil
        return dst._parts.KnoxPassTag._item:getID()
    end
    local function nearbyOf(st, vid)
        for _, n in ipairs(st.nearby or {}) do if n.vid == vid then return n end end
        return nil
    end

    -- A. 換到 B 車、停在 15 格內 → 擁有者 query 更新
    local a = gate(100)
    local va = car(a, 3, { tag = 0.5 })
    register(a, va)
    local vb = makeVehicle(a.cx, a.cy + 10, { script = TRUCK })
    local id = moveTag(va, vb)
    moveCar(va, va._x, va._y + 40)
    local stranger = makeVehicle(a.cx + 4, a.cy + 6, { tag = 0.5, script = SPORT })   -- 沒登記的感應盒
    local strangerId = stranger._parts.KnoxPassTag._item:getID()
    check(rec(a).tags[id].script == CAR, "登記時記下 A 車車型")
    local other = newPlayer("other", 100, 101)
    local _, st = cmd(other, "query", { key = a.key })
    check(st and st.manager == false and rec(a).tags[id].script == CAR, "反面：非擁有者 query 不改帳本車型")
    _, st = cmd(a.owner, "query", { key = a.key })
    check(st and st.tags and #st.tags == 1 and st.tags[1].script == TRUCK, "擁有者 query：已登記清單顯示 B 車車型")
    local nb = nearbyOf(st, vb:getId())
    check(nb ~= nil and nb.registered == true and nb.script == TRUCK, "附近車輛有 B 車且標記已登記")
    check(rec(a).tags[id].script == TRUCK, "帳本 rec.tags[id].script 已改成 B 車")
    local ns = nearbyOf(st, stranger:getId())
    check(ns ~= nil and ns.registered == false and rec(a).tags[strangerId] == nil, "反面：沒登記的感應盒在附近不新增帳本項目")

    -- B1. 門已經開著，B 車緊跟著開過去 → 更新
    local b = gate(300)
    local lead = car(b, 3, { tag = 0.5 })
    register(b, lead)
    local vOld = car(b, 5, { tag = 0.5 })
    register(b, vOld)
    local truck = makeVehicle(b.cx, b.cy + 60, { script = TRUCK })
    local idB = moveTag(vOld, truck)
    moveCar(vOld, vOld._x, vOld._y + 80)
    driver(lead)
    step()
    check(b.door:IsOpen() and rec(b).tags[idB].script == CAR, "另一台登記車先開門（B 車的感應盒還記著舊車型）")
    driver(truck)
    moveCar(truck, b.cx, b.cy + 5)
    runMs(500)
    check(b.door:IsOpen() and rec(b).tags[idB].script == TRUCK, "門已開著，B 車開過大門 → 帳本車型改成 B 車")

    -- B2. 門關著，B 車開過去開門 → 更新
    local c = gate(500)
    local vOld2 = car(c, 3, { tag = 0.5 })
    register(c, vOld2)
    local sport = makeVehicle(c.cx, c.cy + 60, { script = SPORT })
    local idC = moveTag(vOld2, sport)
    moveCar(vOld2, vOld2._x, vOld2._y + 80)
    driver(sport)
    moveCar(sport, c.cx, c.cy + 5)
    step()
    check(c.door:IsOpen() and rec(c).tags[idC].script == SPORT, "門關著，B 車開過去開門 → 帳本車型改成 B 車")

    -- C. 步行開門不改車型
    local d = gate(700)
    local vd = car(d, 3, { tag = 0.5 })
    register(d, vd)
    local walker = newPlayer("walker", 700, 101)
    local tagD = vd._parts.KnoxPassTag._item
    vd._parts.KnoxPassTag._item = nil
    walker._inv:AddItem(tagD)
    rec(d).tags[tagD:getID()].script = SPORT
    check(cmd(walker, "open", { key = d.key }).ok == true and d.door:IsOpen(), "非擁有者帶著感應盒步行開門")
    check(rec(d).tags[tagD:getID()].script == SPORT, "反面：步行開門（沒有車）不改帳本車型")

    -- D. 重啟後仍是 B 車
    restart()
    check(rec(a).tags[id].script == TRUCK and rec(b).tags[idB].script == TRUCK and rec(c).tags[idC].script == SPORT,
        "重啟後帳本車型仍是 B 車")
    clean(from, "感應盒換車")
end

-- 零件安裝／拆下完成的掛勾（vehicle_knoxpass_parts.txt 的 complete → KP.onTagInstalled／onTagUninstalled）
local function scenarioTagHooks()
    out("情境：感應盒裝上／拆下掛勾")
    freshWorld()
    local from = #logLines + 1
    local TRUCK, SPORT = "Base.PickUpTruck", "Base.SportsCar"
    local a, a2 = gate(100), gate(110)
    local vA = makeVehicle(105.5, 112.5, { tag = 0.5 })
    register(a, vA)
    register(a2, vA)
    local item = vA._parts.KnoxPassTag._item
    local id = item:getID()
    local function scripts() return rec(a).tags[id] and rec(a).tags[id].script, rec(a2).tags[id] and rec(a2).tags[id].script end
    local function tagCount(g)
        local n = 0
        for _ in pairs(rec(g).tags) do n = n + 1 end
        return n
    end
    local s1, s2 = scripts()
    check(s1 == "Base.CarNormal" and s2 == "Base.CarNormal", "同一顆感應盒登記在兩扇門，記著 A 車車型")

    -- 裝進 B 車（遠離大門，被動更新碰不到）
    local vB = makeVehicle(300.5, 300.5, { script = TRUCK })
    vA._parts.KnoxPassTag._item = nil
    vB._parts.KnoxPassTag._item = item
    KP.onTagInstalled(vB, vB._parts.KnoxPassTag)
    s1, s2 = scripts()
    check(s1 == TRUCK and s2 == TRUCK, "onTagInstalled：登記的每扇門車型都改成 B 車")
    local vX = makeVehicle(320.5, 300.5, { tag = 0.5, script = SPORT })
    local n1, n2 = tagCount(a), tagCount(a2)
    KP.onTagInstalled(vX, vX._parts.KnoxPassTag)
    check(rec(a).tags[vX._parts.KnoxPassTag._item:getID()] == nil and tagCount(a) == n1 and tagCount(a2) == n2,
        "反面：沒登記的感應盒裝上車不新增帳本項目")

    -- 拆下（原版先清空零件再呼叫 complete）
    vB._parts.KnoxPassTag._item = nil
    KP.onTagUninstalled(vB, vB._parts.KnoxPassTag, item)
    s1, s2 = scripts()
    check(s1 == nil and s2 == nil and rec(a).tags[id] ~= nil and rec(a2).tags[id] ~= nil,
        "onTagUninstalled：每扇門車型清空、登記保留")
    local _, st = cmd(a.owner, "query", { key = a.key })
    check(st and st.tags and #st.tags == 1 and st.tags[1].id == id and st.tags[1].script == nil, "擁有者查詢：已登記清單車型為 nil（未裝在車上）")

    -- 掛勾漏掉時的保險：感應盒回到 B 車、B 停到門邊，擁有者查詢就改回來
    vB._parts.KnoxPassTag._item = item
    moveCar(vB, a.cx, a.cy + 10)
    _, st = cmd(a.owner, "query", { key = a.key })
    check(st and st.tags[1].script == TRUCK and rec(a).tags[id].script == TRUCK, "被動更新：B 車停到門邊、擁有者查詢後變回 B 車")
    check(rec(a2).tags[id].script == nil, "沒查詢的另一扇門維持 nil")

    restart()
    s1, s2 = scripts()
    check(s1 == TRUCK and s2 == nil and rec(a2).tags[id] ~= nil, "重啟後車型狀態保留（B 車／nil）")
    clean(from, "掛勾")
end

-- 推送已授權大門（Sensor.lua pushPasses）與客戶端 API KnoxPassAPI.willOpenFor（Gates.lua）
local function passesSince(p, mark)
    local list = {}
    for i = mark + 1, #W.sent do
        local s = W.sent[i]
        if s.cmd == "passes" and s.player == p then list[#list + 1] = s.args end
    end
    return list
end
local function keySet(args)   -- 照 Client.lua:72-76 把推送轉成 KP.passes 的形狀
    local keys, n = {}, 0
    for _, key in pairs(args.keys) do
        keys[key] = true
        n = n + 1
    end
    return keys, n
end
local function sameKeys(args, want)
    local keys, n = keySet(args)
    if n ~= #want then return false end
    for _, k in ipairs(want) do if not keys[k] then return false end end
    return true
end

local function scenarioPasses()
    out("情境：推送已授權大門")
    freshWorld()
    local from = #logLines + 1
    local a, b = gate(100), gate(110)
    local v = makeVehicle(105.5, 112.5, { tag = 0.5 })
    register(a, v)
    local item = v._parts.KnoxPassTag._item
    local id = item:getID()
    local p = driver(v)
    local plain = makeVehicle(300.5, 300.5)
    local q = driver(plain)
    local mark = #W.sent
    step()
    local got = passesSince(p, mark)
    check(#got == 1 and got[1].tag == id and sameKeys(got[1], { a.key }), "駕駛上了有登記感應盒的車：推送 tag 與登記的大門")
    check(#passesSince(q, mark) == 0, "反面：一般車（沒有感應盒）不推送")

    mark = #W.sent
    runMs(4500)
    check(#passesSince(p, mark) == 0, "沒變動時 5 秒內不重推")
    runMs(500)
    check(#passesSince(p, mark) == 1, "滿 5 秒補推")

    mark = #W.sent
    register(b, v)
    step()
    got = passesSince(p, mark)
    check(#got == 1 and sameKeys(got[1], { a.key, b.key }), "擁有者登記另一扇門：下一輪掃描就重推（不等 5 秒）")

    local other = newItem(TAG, 0.5)
    v._parts.KnoxPassTag._item = other
    mark = #W.sent
    step()
    got = passesSince(p, mark)
    check(#got == 1 and got[1].tag == other:getID() and sameKeys(got[1], {}), "換一顆感應盒：立刻推新的 tag（沒登記任何門）")
    v._parts.KnoxPassTag._item = item
    step()

    cmd(a.owner, "unregister", { key = a.key, tagId = id })
    mark = #W.sent
    step()
    got = passesSince(p, mark)
    check(#got == 1 and got[1].tag == id and sameKeys(got[1], { b.key }), "取消登記：重推的 keys 不含那扇門")
    clean(from, "推送")
end

local function scenarioWillOpenFor()
    out("情境：KnoxPassAPI.willOpenFor")
    freshWorld()
    local from = #logLines + 1
    local api = KnoxPassAPI.willOpenFor
    check(KnoxPassAPI.VERSION == 3 and type(api) == "function" and type(KnoxPassAPI.whyText) == "function",
        "KnoxPassAPI.VERSION 3 提供 willOpenFor 與 whyText")
    local a = gate(100)
    local c = gate(104, { power = false })
    local d = gate(108, { double = true })
    local n = gate(114)                        -- 有讀頭但沒登記這顆感應盒
    local plainDoor = makeDoor("IsoDoor", 120, 100)
    local v = makeVehicle(106.5, 110.5, { tag = 0.5 })
    local function both(o) -- willOpenFor 的兩個回傳值合成一個字串，方便比對
        local r, why = api(v, o)
        return tostring(r) .. "/" .. tostring(why)
    end
    register(a, v)
    register(c, v)
    register(d, v)
    local p = driver(v)
    local mark = #W.sent
    step()
    local got = passesSince(p, mark)
    check(#got == 1 and sameKeys(got[1], { a.key, c.key, d.key }), "推送三扇登記的門")
    KP.passes = { tag = got[1].tag, keys = (keySet(got[1])) }
    check(not d.door:IsOpen(), "（前提）雙開門關著")

    check(both(a.door) == "true/nil", "登記、有電、有供電 → true，不帶原因")
    check(both(n.door) == "false/NotRegistered", "有讀頭但沒登記這顆感應盒 → false, NotRegistered")
    check(both(plainDoor) == "false/nil", "沒有讀頭的一般門 → false，不帶原因")
    local item = v._parts.KnoxPassTag._item
    item:setCurrentUsesFloat(0)
    check(both(a.door) == "false/TagEmpty", "感應盒沒電 → false, TagEmpty")
    item:setCurrentUsesFloat(0.5)
    v._parts.KnoxPassTag._item = newItem(TAG, 0.5)
    check(both(a.door) == "false/nil", "換了別顆感應盒、還沒收到它的推送 → false，不帶原因")
    v._parts.KnoxPassTag._item = nil
    check(both(a.door) == "false/NoTag" and both(plainDoor) == "false/nil",
        "車上沒有感應盒：有讀頭的門 NoTag、一般門不帶原因")
    v._parts.KnoxPassTag._item = item
    check(both(c.door) == "false/NoPower", "RequirePower 且門沒供電 → false, NoPower")
    SandboxVars.MinidoracatKnoxPass.RequirePower = false
    check(both(c.door) == "true/nil", "RequirePower=false 時沒供電也 true")
    SandboxVars.MinidoracatKnoxPass.RequirePower = nil
    check(both(v) == "false/nil", "非門物件（車輛）→ false，不帶原因")
    check(api(v, d.group.pieces[2]) == true and api(v, d.group.pieces[3]) == true and api(v, d.group.pieces[4]) == true,
        "雙開門第 2、3、4 片解析到同一扇門 → true")
    KP.passes = nil
    check(both(a.door) == "false/nil", "KP.passes 為 nil → false，不帶原因")
    local realGetText = getText
    getText = function(key)
        if key == "IGUI_KnoxPass_Why_NoPower" then return "no power" end
        if key == "IGUI_KnoxPass_Why_Error" then return "error" end
        return key
    end
    check(KnoxPassAPI.whyText("NoPower") == "no power" and KnoxPassAPI.whyText("Bogus") == "error"
        and KnoxPassAPI.whyText(nil) == "error", "whyText：認得的代碼回翻譯、不認得的回通用說法")
    getText = realGetText
    clean(from, "willOpenFor")
end

local function scenarioCharging()
    out("情境：充電")
    freshWorld()
    local v = makeVehicle(0, 0, { tag = 0.5, battery = 0.5 })
    local part = v._parts.KnoxPassTag
    local deltas = W.partDeltas
    KP.onPartUpdate(v, part, 1)
    check(near(charge(v), 0.503) and W.partDeltas == deltas + 1, "電瓶 >10%：每遊戲分鐘充 20%/60 並 transmitPartUsedDelta")
    part._item:setCurrentUsesFloat(0.5)
    KP.onPartUpdate(v, part, 600)
    check(near(charge(v), 0.517), "離線補償單次最多算 5 分鐘")
    part._item:setCurrentUsesFloat(0.5)
    v._battery = 0.1
    deltas = W.partDeltas
    KP.onPartUpdate(v, part, 5)
    check(near(charge(v), 0.5) and W.partDeltas == deltas, "電瓶 ≤10% 不充電、不同步")
    v._battery = 0.11
    KP.onPartUpdate(v, part, 5)
    check(charge(v) > 0.5, "電瓶 11% 會充")
    part._item:setCurrentUsesFloat(0.5)
    v._battery = 0.8
    MODE = "client"
    KP.onPartUpdate(v, part, 5)
    MODE = "server"
    check(near(charge(v), 0.5), "MP client 端不充電")
    part._item:setCurrentUsesFloat(1)
    deltas = W.partDeltas
    KP.onPartUpdate(v, part, 5)
    check(near(charge(v), 1) and W.partDeltas == deltas, "滿電不再同步")
    part._item = newItem("Base.CarBattery1", 0.5)
    KP.onPartUpdate(v, part, 5)
    check(near(part._item:getCurrentUsesFloat(), 0.5), "槽裡不是感應盒就不碰")
end

-- ===== 抬升閘門 =====
local KIT = "MinidoracatKnoxPass.BoomBarrierKit"
-- entity 建造：照 ISBuildIsoEntity.setInfo 逐格 IsoThumpable.new → AddSpecialObject → 每格拷一份 need: 材料 → OnCreate。
-- 車道放的是替代 tile（真車道＋160），格子排法同 entity_knoxpass_barrier.txt：N 一列沿 +x（機箱、車道 1-3）；
-- W 四列沿 +y（車道 3、2、1、機箱）；S 一列沿 +x（車道 1-3、機箱）；E 四列沿 +y（機箱、車道 3、2、1）。
-- 回傳表以真 tile 編號為鍵：車道 0-5／80-85（OnCreate 換成的 IsoDoor）、機箱 6、7、86、87
local BARRIER_FACES = {
    N = { { 0, 0, 6 }, { 1, 0, 160 }, { 2, 0, 161 }, { 3, 0, 162 } },
    W = { { 0, 0, 165 }, { 0, 1, 164 }, { 0, 2, 163 }, { 0, 3, 7 } },
    S = { { 0, 0, 240 }, { 1, 0, 241 }, { 2, 0, 242 }, { 3, 0, 86 } },
    E = { { 0, 0, 87 }, { 0, 1, 245 }, { 0, 2, 244 }, { 0, 3, 243 } },
}
local function buildBarrier(x, y, face, builder)
    local made, ent = {}, { size = #BARRIER_FACES[face] }
    for _, t in ipairs(BARRIER_FACES[face]) do
        local lane = t[3] >= 160
        -- _north 一律 false：entity 游標不更新 self.north，create 收到的 north 永遠是 false（barrier-mp 2026-10-05 實踩）
        local th = new("IsoThumpable", Thump, {
            _open = false, _locked = false, _lockedByKey = false, _keyId = -1, _modData = {}, _north = false,
            _obstructed = false, _view = { modData = {} }, _spriteObj = barrierSprite(t[3]),
            _isDoor = lane, _buildMaterials = { [KIT] = 1 }, _entityMulti = true, _entity = ent,
        })
        ent[#ent + 1] = th
        syncView(th)
        square(x + t[1], y + t[2], 0):AddSpecialObject(th)
        local res = KP.Barrier.onCreate({ thumpable = th, character = builder, facing = face })
        made[lane and t[3] - 160 or t[3]] = res and res.replaceObject and res.object or th
    end
    return made
end
local function present(o) return o._square ~= nil end

local function scenarioBarrier()
    out("情境：抬升閘門（建造、內建讀頭、開關、擋車、拆除）")
    freshWorld()
    local from = #logLines + 1
    local builder = newPlayer("builder", 201, 103, { sid = 77 })
    local n = buildBarrier(200, 100, "N", builder)
    check(instanceof(n[0], "IsoDoor") and instanceof(n[1], "IsoDoor") and instanceof(n[2], "IsoDoor")
        and n[0]._square == square(201, 100, 0) and n[2]._square == square(203, 100, 0), "N 向：三格車道換成 IsoDoor（x+1..x+3）")
    check(instanceof(n[6], "IsoThumpable") and n[6]._square == square(200, 100, 0) and #square(201, 100, 0)._objects == 1,
        "機箱留著 IsoThumpable；車道格的 thumpable 已移走")
    check(not n[0]:isLocked() and not n[0]:isLockedByKey() and not n[2]:isLocked(), "IsoDoor 建構子上的鎖已解（車庫門的 locked 看站位）")
    check(n[6]:getBuildMaterials()[KIT] == 1 and n[0].getBuildMaterials == nil, "只有機箱帶一份組件（車道的 thumpable 連材料一起換掉）")
    check(KP.Ledger.get("201,100,0N") == nil, "建造當下還不登記（等整條鏈到齊）")
    step()
    local r = KP.Ledger.get("201,100,0N")
    check(r ~= nil and r.owner == "builder" and r.sid == nil and r.builtin == true and r.kind == "Barrier"
        and near(r.cx, 202.5) and near(r.cy, 100.5), "下一個 tick 自動登記：擁有者是建造者、內建讀頭、類型 Barrier、中心在中間車道")
    check(n[0]._modData[KP.MARKER_OWNER] == "builder" and n[0]._view.modData[KP.MARKER_OWNER] == "builder", "錨點（車道 1）標記擁有者並同步")
    local ad, an = KP.Gates.resolve(n[2])
    local ps = KP.Gates.pieces(ad, an)
    check(an == n[0] and #ps == 3 and ps[1] == n[0] and ps[2] == n[1] and ps[3] == n[2], "點車道 3 也找得到錨點車道 1，整組三片")
    check(KP.Gates.resolve(n[6]) == nil, "機箱不是門")

    local w = buildBarrier(300, 100, "W", builder)
    step()
    local rw = KP.Ledger.get("300,102,0W")
    local wad, wan = KP.Gates.resolve(w[5])
    check(rw ~= nil and rw.builtin == true and wan == w[3] and #KP.Gates.pieces(wad, wan) == 3 and w[7]._square == square(300, 103, 0),
        "W 向：錨點是車道 1（y+2，鏈的最大 y），機箱在 y+3，整組三片")

    local g = { key = "201,100,0N", owner = builder }
    square(201, 100, 0)._grid = true
    local v = makeVehicle(202.5, 103.5, { tag = 0.5 })
    check(register(g, v).ok == true, "擁有者登記車輛")
    driver(v)
    nowMs = nowMs + 33
    fire("OnTick")
    local early = n[0]:IsOpen()
    loadChunk(201, 100)
    fire("OnTick")
    check(not early and n[0]:IsOpen() and n[1]:IsOpen() and n[2]:IsOpen() and KP.barrierIndex(n[0]) == 8 and KP.barrierIndex(n[2]) == 10,
        "已登記的車接近：閘門所在的 chunk 載入後下一個 tick 就掃描（不等 250 ms），三片一起開，換成開啟 sprite（＋8）")
    local blocker = makeVehicle(202.5, 100.0)
    blocker._cover = { ["202,100,0"] = true, ["202,99,0"] = true }
    moveCar(v, v._x, v._y + 40)
    local blocked = W.garageBlocked
    runMs(9000)
    check(n[0]:IsOpen() and W.garageBlocked == blocked, "車停在桿下、跨過門線：不關，也不呼叫 ToggleDoor（不洗擋住提示）")
    blocker._cover = { ["250,250,0"] = true }
    runMs(2250)
    check(not n[0]:IsOpen() and not n[2]:IsOpen() and KP.barrierIndex(n[0]) == 0, "車開走後關上，換回關閉 sprite")
    moveCar(v, 202.5, 100.5)
    step()
    check(n[0]:IsOpen(), "車停在門格上（沒跨線）照樣開：車庫門開門不查擋車（D:1583 只在關門時查）")

    local res = cmd(builder, "uninstall", { key = g.key })
    check(res.ok == false and res.why == "BuiltIn" and KP.Ledger.get(g.key) ~= nil and countType(builder._inv, READER) == 0,
        "內建讀頭不能單獨拆：BuiltIn、帳本還在、沒有多出讀頭")

    ISDismantleAction.complete({ thumpable = n[6] })
    check(not present(n[6]) and not present(n[0]) and not present(n[1]) and not present(n[2]), "拆除機箱：整座閘門一起移除")
    check(W.dropped[KIT] == 1, "只退一個組件")
    check(KP.Ledger.get(g.key) == nil, "帳本記錄一起刪")
    step()

    ISDestroyStuffAction.complete({ item = w[5] })
    check(not present(w[5]) and not present(w[4]) and not present(w[3]) and not present(w[7])
        and KP.Ledger.get("300,102,0W") == nil and W.dropped[KIT] == 1, "大錘敲車道 3：整座移除、帳本刪除、不退組件")

    local d = buildBarrier(400, 100, "N", builder)
    step()
    fire("OnDestroyIsoThumpable", d[6], nil)
    check(not present(d[0]) and not present(d[2]) and not present(d[6]) and KP.Ledger.get("401,100,0N") == nil,
        "機箱被打壞：整座移除、帳本刪除")
    -- 另外兩個方向的查找：N 向從車道找機箱（x-1）、W 向從機箱找車道 1（y-1）
    local nb = buildBarrier(700, 100, "N", builder)
    local wb = buildBarrier(800, 100, "W", builder)
    step()
    ISDestroyStuffAction.complete({ item = nb[1] })
    fire("OnDestroyIsoThumpable", wb[7], nil)
    check(not present(nb[6]) and not present(nb[0]) and not present(nb[2]) and KP.Ledger.get("701,100,0N") == nil
        and not present(wb[3]) and not present(wb[5]) and KP.Ledger.get("800,102,0W") == nil,
        "N 向大錘敲車道 2 連機箱一起移除；W 向機箱被打壞連車道一起移除")
    -- 殭屍／武器打壞車道：IsoDoor.destroyGarageDoor 逐片 destroy → transmitRemoveItemFromSquare（D:3460-3499、1385-1388），
    -- 原版只拆車道鏈；機箱、帳本、Sensor 狀態靠 OnObjectAboutToBeRemoved 記下、下一個 tick 收掉
    local z = buildBarrier(900, 100, "N", builder)
    step()
    local forgot, forget = {}, KP.Sensor.forget
    KP.Sensor.forget = function(key) forgot[#forgot + 1] = key; return forget(key) end
    local kits = W.dropped[KIT]
    for i = 0, 2 do z[i]._square:transmitRemoveItemFromSquare(z[i]) end
    step()
    KP.Sensor.forget = forget
    check(not present(z[6]) and KP.Ledger.get("901,100,0N") == nil and forgot[1] == "901,100,0N" and W.dropped[KIT] == kits,
        "車道被打壞：下一個 tick 機箱一起移除、帳本與 Sensor 狀態清掉、不退組件")

    -- 反面：一般門與原版車庫門照原版行為，不會被當成閘門整組移除
    local plain = makeDoor("IsoThumpable", 500, 100)
    plain._buildMaterials = { ["Base.Plank"] = 2 }
    local gg = makeGarage(510, 100)
    local before = W.removedObjs
    ISDismantleAction.complete({ thumpable = plain })
    ISDestroyStuffAction.complete({ item = gg.pieces[2] })
    check(not present(plain) and present(gg.pieces[1]) and present(gg.pieces[3]) and W.removedObjs == before + 2
        and W.dropped["Base.Plank"] == 2, "一般門照原版拆、原版車庫門大錘只少一片")
    check(KP.Gates.kind(KP.Gates.byId("vanilla.IsoDoor"), gg.pieces[1]) == "Garage", "原版車庫門類型仍是 Garage")

    local couch = newPlayer("couch", 601, 103, { num = 1 })
    local s = buildBarrier(600, 100, "N", couch)
    step()
    local rs = KP.Ledger.get("601,100,0N")
    check(rs ~= nil and rs.owner == nil and rs.builtin == true and s[0]._modData[KP.MARKER_OWNER] == "",
        "建造者身分無法驗證（分割畫面）：仍登記成閘門、沒有擁有者（只有管理員能管），標記非 nil")
    clean(from, "抬升閘門")
end

local function scenarioBarrierAnim()
    out("情境：抬升閘門動畫補播（SP 與 MP client）")
    freshWorld("sp")
    local from = #logLines + 1
    local me = newPlayer("me", 201, 103)
    W.locals = { me }
    local a = buildBarrier(200, 100, "N", me)[0]
    step()
    check(KP.Ledger.get("201,100,0N").owner == "me", "SP：建造者就是擁有者")
    local function smTime(o) return W.spriteModels[o._smName]._time end   -- 錨點目前通道的 animationTime
    a:ToggleDoor(me)   -- 車庫門本機 toggle 不播動畫（D:1582-1596）；假引擎同樣不設 animating
    step()
    check(a:isAnimating() and a._smName == "MinidoracatKnoxPass_barrier_16" and smTime(a) < 0.02,
        "SP 開門：設 animating，用抬起組（綠燈）第一個通道 16，從關的姿勢起步")
    local times, sets = { smTime(a) }, W.smSets
    for _ = 1, 7 do
        step()
        times[#times + 1] = smTime(a)
    end
    local inc = true
    for i = 2, #times do inc = inc and times[i] > times[i - 1] end
    check(inc and W.smSets - sets == 7 and a._smName == "MinidoracatKnoxPass_barrier_16",
        "每個 tick 都往前推一格（同一個通道，只改時間）：不是每半秒跳一個姿勢")
    check(math.abs(smTime(a) - 0.4375) < 0.011, "1.75 秒：時間 0.4375（1.75／4）")
    a:ToggleDoor(me)
    step()
    check(a._smName == "MinidoracatKnoxPass_barrier_48" and math.abs(smTime(a) - 0.5) < 0.011
        and W.spriteModels["MinidoracatKnoxPass_barrier_16"]._time >= 0.4375,
        "2 秒時改成放下：換放下組（紅燈）通道 48，從目前姿勢（0.5）接著往回走，不跳回端點")
    local inv = W.invalidated
    runMs(2000)
    check(a._smName == nil and not a:isAnimating() and W.invalidated > inv, "走完：清掉姿勢、停止 animating、重畫 chunk")
    local sa = buildBarrier(300, 100, "S", me)[80]
    local ea = buildBarrier(220, 110, "E", me)[83]   -- 離本機玩家 120 格內才追（BarrierAnim FAR）
    local na = buildBarrier(240, 120, "N", me)[0]
    step()
    sa:ToggleDoor(me)
    ea:ToggleDoor(me)
    a:ToggleDoor(me)
    na:ToggleDoor(me)
    step()
    check(sa._smName == "MinidoracatKnoxPass_barrier_96" and ea._smName == "MinidoracatKnoxPass_barrier_112",
        "S／E 向（轉 180°）錨點：通道從 96／112 起（N／W 的＋80）")
    local chans = { [a._smName or ""] = true, [na._smName or ""] = true }
    check(chans["MinidoracatKnoxPass_barrier_16"] and chans["MinidoracatKnoxPass_barrier_17"],
        "兩座同款同方向的閘門同時抬起：各用一個通道（16、17），不會互相蓋掉時間")
    runMs(4250)
    sa:ToggleDoor(me)
    step()
    check(sa._smName == "MinidoracatKnoxPass_barrier_128" and smTime(sa) > 0.95, "S 向放下：紅燈那組（96＋32＝128）從開的姿勢起步")
    local sets = W.smSets
    for _ = 1, 5 do   -- 不對齊 1/96 的時間點：每幀 7 ms，一格是 41.7 ms
        nowMs = nowMs + 7
        fire("OnTick")
    end
    local q = smTime(sa) * 96
    check(math.abs(q - math.floor(q + 0.5)) < 1e-9 and W.smSets - sets <= 1,
        "時間量化成 1/96（引擎的骨架矩陣快取每個模型最多 97 筆），同一格的幾幀不重複設定")
    clean(from, "閘門動畫（SP）")

    freshWorld("client")
    from = #logLines + 1
    local p = newPlayer("viewer", 201, 103)
    W.locals = { p }
    local lanes = {}
    for i = 0, 2 do
        local d = IsoDoor.new(nil, nil, barrierSprite(i), true)
        d._locked, d._lockedByKey = false, false
        square(201 + i, 100, 0):AddSpecialObject(d)
        lanes[i] = d
    end
    local cb = W.onLoadSprite["MinidoracatKnoxPass_barrier_0"]
    local anchorsOk = cb ~= nil
    for _, i in ipairs({ 8, 3, 11, 80, 88, 83, 91 }) do
        anchorsOk = anchorsOk and W.onLoadSprite["MinidoracatKnoxPass_barrier_" .. i] == cb
    end
    check(anchorsOk and W.onLoadSprite["MinidoracatKnoxPass_barrier_1"] == nil and W.onLoadSprite["MinidoracatKnoxPass_barrier_81"] == nil,
        "區塊載入只收錨點（N／W／S／E × 關／開八種 sprite）")
    cb(lanes[0])
    cb(lanes[1])   -- 不是錨點：不追
    lanes[0]:ToggleDoor(p)
    lanes[0]:setAnimating(true)   -- 錨點被同步：引擎自己 PlayAnimation（D:1657-1664、1795-1805）
    step()
    check(lanes[0]._smName == nil, "引擎已在播（錨點被同步）：不插手")
    lanes[0]:setAnimating(false)
    lanes[2]:ToggleDoor(p)       -- 有人點車道 3：錨點只在片段迴圈裡換 sprite、不播（D:1812-1834）
    step()
    check(lanes[0]:isAnimating() and lanes[0]._smName == "MinidoracatKnoxPass_barrier_48"
        and W.spriteModels[lanes[0]._smName]._time > 0.95 and lanes[1]._smName == nil,
        "非錨點被同步、錨點沒播：補播（放下組紅燈通道 48，從開的姿勢往下放），非錨點不動")
    square(201, 100, 0):transmitRemoveItemFromSquare(lanes[0])
    runMs(1000)
    check(lanes[0]._smName == nil and not lanes[0]:isAnimating(), "錨點被移走：1 秒內（每秒掃一次）停止追蹤並還原")
    local ch = W.spriteModels["MinidoracatKnoxPass_barrier_48"]
    local d2 = IsoDoor.new(nil, nil, barrierSprite(0), true)
    d2._locked, d2._lockedByKey = false, false
    square(301, 100, 0):AddSpecialObject(d2)
    cb(d2)
    d2:ToggleDoor(p)
    step()
    runMs(4250)
    d2:ToggleDoor(p)
    step()
    check(d2._smName == "MinidoracatKnoxPass_barrier_48" and ch._time > 0.95, "移走時放掉的通道可以給下一座用（放下組 48）")
    runMs(5000)
    local idle = W.smSets
    runMs(2000)
    check(d2._smName == nil and W.smSets == idle, "動畫走完：閒置時不再設定時間")
    clean(from, "閘門動畫（MP client）")
end

-- 駕駛預警（client/DriveWarn.lua）：自己開車、前方 20 格內有關著且 willOpenFor 回 false+原因的大門，提示一次。
-- 用伺服器模式建門（cmd 讀 W.sent），再手動載入這個 client 檔；KP.passes 照推送內容自己設
local function scenarioDriveWarn()
    out("情境：駕駛預警")
    freshWorld()
    local from = #logLines + 1
    local a = gate(100)                         -- 登記了這顆感應盒：會開
    local n = gate(110)                         -- 有讀頭、沒登記：不會開（NotRegistered）
    local plainDoor = makeDoor("IsoDoor", 120, 100)
    local behind = gate(140)
    local ad = gate(160)
    local unknown = gate(180)
    local pairL, pairR = gate(200), gate(202)   -- 並排、都沒登記：一次開過去只該跳一則
    assert(loadfile(MEDIA .. "/client/MinidoracatKnoxPass/DriveWarn.lua"))()
    local said = {}
    KP.Client = { say = function(_, text, bad, halo) said[#said + 1] = { text = text, bad = bad, halo = halo } end }
    local realGetText = getText
    getText = function(key, arg)
        if arg then return key .. "|" .. arg end
        if key:find("_Why_", 1, true) then return "why:" .. key end
        return key
    end
    local v = makeVehicle(100.5, 112.5, { tag = 0.5 })   -- 登記要在大門 15 格內
    check(register(a, v).ok == true, "（前提）登記 a")
    local p = driver(v)
    W.locals = { p }
    local mark = #W.sent
    step()
    local got = passesSince(p, mark)
    KP.passes = { tag = got[1].tag, keys = (keySet(got[1])) }
    -- 沿 x 北行（y 減少）每 250 ms 走 2.5 格（36 km/h）到 toY；回傳第一次提示時與門線 y=100 的距離
    local function drive(x, fromY, toY)
        moveCar(v, x, fromY)
        local n0, at = #said, nil
        step()
        local y = fromY
        while y > toY do
            y = math.max(toY, y - 2.5)
            moveCar(v, x, y)
            step()
            if not at and #said > n0 then at = y - 100 end
        end
        return at, #said - n0
    end

    -- 伺服器預判會在 20 格前就開門；這段讓它到門口才開，驗的是 willOpenFor 回 true 這條路
    SandboxVars.MinidoracatKnoxPass.ReadRange, SandboxVars.MinidoracatKnoxPass.LeadSeconds = 1, 0
    local _, cnt = drive(100.5, 130.5, 103.5)
    check(not a.door:IsOpen() and cnt == 0, "會開的門（登記、有電）關著也不提示")
    SandboxVars.MinidoracatKnoxPass.ReadRange, SandboxVars.MinidoracatKnoxPass.LeadSeconds = nil, nil
    local at
    at, cnt = drive(110.5, 130.5, 101.5)
    check(cnt == 1, "不會開的門：一次接近只提示一次（" .. cnt .. " 次）")
    check(at ~= nil and at > 17 and at <= 21, "約 20 格前提示（" .. tostring(at) .. "）")
    local s = said[#said]
    check(s and s.text == "IGUI_KnoxPass_AheadWarn|why:IGUI_KnoxPass_Why_NotRegistered" and s.bad == true and s.halo == true,
        "提示文字帶原因（whyText），Toast＋頭上：" .. tostring(s and s.text))
    runMs(3000)
    check(#said == 1, "停在門前不重複提示")
    moveCar(v, 110.5, 145.5)                    -- 開到 30 格外（往南，門在後方）
    step()
    step()
    _, cnt = drive(110.5, 130.5, 101.5)
    check(cnt == 1, "離開 30 格外再接近：重新提示一次")

    _, cnt = drive(140.5, 95.5, 70.5)
    check(cnt == 0, "門在後方（已開過門線往北走）不提示")

    local asked
    MDAD = { Drive = { isActive = function(pn) asked = pn; return true end } }
    _, cnt = drive(160.5, 130.5, 110.5)
    check(cnt == 0 and asked == 0, "AutoDrive 正在替這位玩家開（MDAD.Drive.isActive(playerNum)）不提示")
    MDAD = { Drive = { isActive = function() error("boom") end } }
    _, cnt = drive(160.5, 110.5, 101.5)
    check(cnt == 1, "MDAD.Drive.isActive 出錯：當自己開，照常提示")
    MDAD = nil

    _, cnt = drive(120.5, 130.5, 101.5)
    check(cnt == 0, "沒有讀頭的一般門（不帶原因）不提示")
    KP.passes = nil
    _, cnt = drive(180.5, 130.5, 101.5)
    check(cnt == 0 and unknown.key ~= nil, "還沒收到這顆感應盒的推送（不帶原因）不提示")
    KP.passes = { tag = got[1].tag, keys = (keySet(got[1])) }

    _, cnt = drive(201.5, 130.5, 101.5)
    check(cnt == 1 and pairL.key ~= pairR.key, "並排兩座不會開的門：同一次接近只提示一則（" .. cnt .. " 則）")

    local nOpen = #said
    n.door:ToggleDoor(n.owner)
    moveCar(v, 110.5, 145.5)
    step()
    step()
    _, cnt = drive(110.5, 130.5, 101.5)
    check(n.door:IsOpen() and cnt == 0 and #said == nOpen, "門開著時不提示")
    getText = realGetText
    clean(from, "駕駛預警")
end

-- 門柱上的讀頭模型（server/ReaderPost.lua）：宿主格＝西北角是那根門柱的格子；變體 0 N 西端、1 N 東端、2 W 北端、3 W 南端
local function scenarioReaderPost()
    out("情境：門柱上的讀頭模型（位置與變體、移除、自我修復）")
    freshWorld()
    local from = #logLines + 1
    local function postsAt(x, y)
        local list = {}
        for _, o in ipairs(square(x, y, 0)._objects) do
            local v = KP.readerPostIndex(o)
            if v then list[#list + 1] = v end
        end
        return table.concat(list, ",")
    end
    local function postObj(x, y)
        for _, o in ipairs(square(x, y, 0)._objects) do if KP.readerPostIndex(o) then return o end end
        return nil
    end
    local function install(obj, name)
        local sq = obj._square
        local p = newPlayer(name, sq._x, sq._y + 2)
        local res = cmd(p, "install", { x = sq._x, y = sq._y, z = 0, index = obj:getObjectIndex(), itemId = p._inv:AddItem(READER):getID() })
        return res.key, p
    end
    local function post(key) local r = KP.Ledger.get(key); return r and r.post end

    -- 1. 各類門：放在錨點那片的外端門柱（宿主格、變體），伺服器送給客戶端
    local single = gate(100)
    local p0 = post(single.key)
    check(postsAt(100, 100) == "0" and p0 and p0.x == 100 and p0.y == 100 and p0.i == 0 and W.postTx == 1,
        "N 單門：鉸鏈（西端）門柱，宿主＝門格、變體 0，transmitCompleteItemToClients")
    gate(110, { cls = "IsoThumpable" })
    check(postsAt(110, 100) == "0", "玩家建造的門（IsoThumpable）：同單門")
    local dbl = gate(120, { double = true, click = 3 })
    check(postsAt(120, 100) == "0" and postsAt(123, 100) == "" and postsAt(124, 100) == "", "N 雙開門（點第 3 片）：錨點第 1 片西端")
    local gar = gate(130, { garage = true, click = 3 })
    check(postsAt(130, 100) == "0" and postsAt(132, 100) == "", "N 車庫門（點第 3 片）：第 1 片西端")
    local half = makeDouble("IsoDoor", 140, 100)
    removeObj(half.pieces[1])
    half.pieces[1] = nil
    local kHalf = install(half.pieces[4], "half")
    check(post(kHalf) and postsAt(144, 100) == "1" and postsAt(143, 100) == "",
        "N 雙開門只剩第 4 片：錨點第 4 片東端，宿主＝東邊那格、變體 1")
    local w1 = makePiece("IsoDoor", 150, 100, false)
    local kW1 = install(w1, "w1")
    check(postsAt(150, 100) == "2", "W 單門：鉸鏈（北端）門柱、變體 2")
    local wd = { pieces = {}, cls = "IsoDoor" }   -- W 雙開門第 1 片在最大 y（IsoDoor.java:128）
    for i = 1, 4 do
        local p = makePiece("IsoDoor", 160, 103 - (i - 1), false)
        p._group, p._index = wd, i
        wd.pieces[i] = p
    end
    local kWd = install(wd.pieces[2], "wd")
    check(postsAt(160, 104) == "3" and postsAt(160, 103) == "" and postsAt(160, 100) == "",
        "W 雙開門：錨點第 1 片（最大 y）南端，宿主＝南邊那格、變體 3")
    local wg = {}
    for i = 1, 3 do   -- W 車庫門第 1 片在最大 y（getGarageDoorPrev 往 y+1，IsoDoor.java:3252-3253）
        local p = makePiece("IsoDoor", 170, 102 - (i - 1), false)
        p._garage = i
        wg[i] = p
    end
    install(wg[3], "wg")
    check(postsAt(170, 103) == "3" and postsAt(170, 102) == "", "W 車庫門（點第 3 片）：第 1 片南端、變體 3")
    local builder = newPlayer("builder", 301, 103)
    buildBarrier(300, 100, "N", builder)
    step()
    local nb = 0
    for x = 299, 305 do for y = 99, 101 do if postsAt(x, y) ~= "" then nb = nb + 1 end end end
    local rb = KP.Ledger.get("301,100,0N")
    check(rb and rb.post == nil and nb == 0, "抬升閘門（機箱頂已有讀頭）不放")
    check(KP.Ledger.get(single.key).post ~= nil and #square(100, 100, 0)._objects == 2, "反面：一般門一扇只放一個")

    -- 2. 雙開門開關：第 2、3 片搬格重建，錨點與讀頭模型不動、帳本不受影響
    local dprop = postObj(120, 100)
    local recreated = W.recreated
    dbl.door:ToggleDoor(dbl.owner)
    step()
    dbl.door:ToggleDoor(dbl.owner)
    step()
    check(W.recreated == recreated + 4 and postObj(120, 100) == dprop and present(dprop) and KP.Ledger.get(dbl.key) ~= nil,
        "雙開門開關兩次：第 2、3 片重建 4 次，讀頭模型同一個物件、帳本還在")

    -- 3. 拆讀頭：帳本刪除，模型一起移除（MP 送移除）
    local removed = W.removedObjs
    local res = cmd(single.owner, "uninstall", { key = single.key })
    check(res.ok == true and postsAt(100, 100) == "" and W.removedObjs == removed + 1 and present(single.door),
        "拆讀頭：模型以 transmitRemoveItemFromSquare 移除，門還在")

    -- 4. 門被打壞（車庫門整條鏈 destroy）、被拆（玩家建造的門）：下一個 tick 帳本與模型一起刪
    local forgot, forget = {}, KP.Sensor.forget
    KP.Sensor.forget = function(key) forgot[#forgot + 1] = key; return forget(key) end
    for i = 3, 1, -1 do local p = gar.group.pieces[i]; p._square:transmitRemoveItemFromSquare(p) end
    check(KP.Ledger.get(gar.key) ~= nil, "移除事件當下不刪（handler 裡不能移物件，等下一個 tick 確認）")
    step()
    KP.Sensor.forget = forget
    check(KP.Ledger.get(gar.key) == nil and postsAt(130, 100) == "" and forgot[1] == gar.key and logHas("gate removed", from),
        "車庫門被打壞：下一個 tick 帳本、Sensor 狀態、門柱模型一起刪")
    local thumpGate = KP.Ledger.get("110,100,0N")
    ISDismantleAction.complete({ thumpable = square(110, 100, 0)._objects[1] })
    step()
    check(thumpGate and KP.Ledger.get("110,100,0N") == nil and postsAt(110, 100) == "", "玩家建造的門被拆：帳本與模型一起刪")
    check(KP.Ledger.get(kWd) ~= nil and postsAt(160, 104) == "3", "反面：其他門的記錄與模型不受影響")
    local w1b = makePiece("IsoDoor", 150, 100, false)   -- 同一 tick 換成新物件（同格同向、標記帶過去）
    w1b._modData = w1._modData
    removeObj(w1)
    step()
    check(KP.Ledger.get(kW1) ~= nil and postsAt(150, 100) == "2", "反面：移除後錨點位置上還有這扇門（G.findAt 找得到）就不刪")

    -- 5. 自我修復
    local w1prop = postObj(150, 100)
    removeObj(w1prop)   -- 例：舊版本被大錘敲掉
    step()
    check(KP.Ledger.get(kW1) ~= nil and postsAt(150, 100) == "", "模型被移走不影響帳本（不是門）")
    loadChunk(150, 100)
    check(postsAt(150, 100) == "", "LoadChunk 當下不改（等下一個 tick）")
    step()
    check(postsAt(150, 100) == "2", "宿主格載入：帳本有、格上沒有 → 補上")
    local orphan = IsoObject.new(nil, nil, "MinidoracatKnoxPass_reader_0")
    square(500, 500, 0):AddTileObject(orphan)
    W.onLoadSprite["MinidoracatKnoxPass_reader_0"](orphan)
    step()
    check(not present(orphan) and logHas("not in ledger", from), "孤兒模型（帳本沒有）：區塊載入時移除")
    local extra, dup = IsoObject.new(nil, nil, "MinidoracatKnoxPass_reader_2"), IsoObject.new(nil, nil, "MinidoracatKnoxPass_reader_0")
    square(120, 100, 0):AddTileObject(extra)
    square(120, 100, 0):AddTileObject(dup)
    loadChunk(120, 100)
    step()
    check(postsAt(120, 100) == "0" and present(dprop), "宿主格上變體不對、重複的移除，帳本那一個留著")
    local lonely = postObj(144, 100)
    KP.Ledger.get(kHalf).post = nil   -- 更新前裝的讀頭：帳本沒有 post、格上沒有模型
    removeObj(lonely)
    removeObj(postObj(150, 100))      -- 帳本有 post、模型不見：重開後不等 LoadChunk，開機對齊就補
    restart()
    W.unloaded["140,100,0"], W.unloaded["143,100,0"], W.unloaded["144,100,0"] = true, true, true
    step()
    check(KP.Ledger.get(kHalf).post == nil and postsAt(144, 100) == "", "重開：錨點格還沒載入的舊記錄先不動")
    check(postsAt(120, 100) == "0" and postsAt(160, 104) == "3" and postsAt(150, 100) == "2" and KP.Ledger.get(kWd).post.i == 3,
        "重開：已載入的格在帳本載入後第一個 tick 對齊（缺的補上），post 隨存檔保留、模型不重複")
    W.unloaded["140,100,0"], W.unloaded["143,100,0"], W.unloaded["144,100,0"] = nil, nil, nil
    loadChunk(143, 100)
    step()
    check(KP.Ledger.get(kHalf).post and KP.Ledger.get(kHalf).post.i == 1 and postsAt(144, 100) == "1",
        "舊記錄：錨點格載入時補算門柱位置並放上模型")
    loadChunk(999, 999)
    step()
    check(postsAt(999, 999) == "", "反面：載入無關的格不放")

    -- 6. 大錘游標不列出讀頭模型（client UI）；其他物件照原版
    check(ISDestroyCursor.canDestroy({}, postObj(120, 100)) == false and ISDestroyCursor.canDestroy({}, dbl.door) == true,
        "大錘游標：讀頭模型不能選，門照原版")
    clean(from, "門柱讀頭模型")

    -- 7. SP：同樣放上，不送網路
    freshWorld("sp")
    from = #logLines + 1
    local me = newPlayer("me", 100, 102)
    W.locals = { me }
    KP.clientReceive = function() end
    makeDoor("IsoDoor", 100, 100)
    fire("OnClientCommand", "MinidoracatKnoxPass", "install", me, { x = 100, y = 100, z = 0, index = 0, itemId = me._inv:AddItem(READER):getID() })
    check(postsAt(100, 100) == "0" and W.postTx == 0, "SP：放上模型、沒有網路傳送")
    clean(from, "門柱讀頭模型（SP）")

    -- 8. MP client 也載入 server 資料夾：只掛大錘過濾，不掛伺服器事件
    freshWorld("client")
    check(KP.ReaderPost == nil and ISDestroyCursor.canDestroy({}, IsoObject.new(nil, nil, "MinidoracatKnoxPass_reader_3")) == false,
        "MP client：沒有伺服器邏輯，大錘過濾照樣生效")
end

-- 外殼顏色（KP.COLORS）與重新上色（Server.lua H.recolor／H.recolorReader、Ledger.lua L.renameTag、ReaderPost.lua 顏色×8＋變體）
local function scenarioColors()
    out("情境：外殼顏色與重新上色")
    freshWorld()
    local from = #logLines + 1
    local function postsAt(x, y)
        local list = {}
        for _, o in ipairs(square(x, y, 0)._objects) do
            local n = KP.readerPostIndex(o)
            if n then list[#list + 1] = n end
        end
        return table.concat(list, ",")
    end
    local function painter(p, paints, brush)   -- 身上放油漆（滿桶 10 格）與刷子
        for _, c in ipairs(paints) do p._inv:AddItem(PAINTS[c + 1]) end
        if brush ~= false then p._inv:AddItem("Base.Paintbrush") end
    end
    local function paintLeft(p, c)   -- 身上這色油漆剩幾格（所有罐子合計）
        local n = 0
        for _, it in ipairs(p._inv._items) do if it._type == PAINTS[c + 1] then n = n + it._uses end end
        return n
    end

    -- 1. 7 色都認得；其他物品不算
    local all = true
    for i, c in ipairs(KP.COLORS) do
        local t, r = newItem(TAG .. c.suffix), newItem(READER .. c.suffix)
        all = all and KP.isTag(t) and not KP.isReader(t) and KP.isReader(r) and not KP.isTag(r)
            and KP.colorOf(t) == i - 1 and KP.colorOf(r) == i - 1 and KP.colorType(TAG, i - 1) == t._type
            and c.paint == PAINTS[i] and (i == 1 or c.suffix == "_" .. COLOR_IDS[i - 1])
    end
    check(#KP.COLORS == 7 and all, "7 色感應盒與讀頭都認得、顏色索引與油漆照順序")
    check(KP.colorOf(newItem("Base.Hammer")) == nil and not KP.isTag(nil) and not KP.isReader(newItem("Base.Hammer"))
        and KP.isColor(6) and not KP.isColor(7) and not KP.isColor(-1) and not KP.isColor(1.5), "反面：其他物品、nil、越界索引都不算")

    -- 2. 黑色讀頭：帳本記黑色、門柱用黑色 tile、錨點標記顏色；黑色感應盒登記後開車與步行都開
    local g = gate(100, { reader = READER .. "_Black" })
    check(g.res.ok == true and rec(g).color == 1 and postsAt(100, 100) == "8", "黑色讀頭安裝：rec.color=1、門柱 tile 1×8＋0")
    check(g.door._modData.KnoxPassColor == 1 and g.door._view.modData.KnoxPassColor == 1, "錨點標記顏色並同步（選單列其他顏色用）")
    local v = car(g, 7, { tag = 0.5, tagType = TAG .. "_Black" })
    check(register(g, v).ok == true, "黑色感應盒可登記")
    driver(v)
    step()
    check(g.door:IsOpen(), "黑色感應盒開車到門前 → 開門")
    local res = cmd(g.owner, "lock", { key = g.key, on = true })
    check(res.ok == true and g.door._modData.KnoxPassColor == 1, "上鎖重寫標記時顏色保留")
    res = cmd(g.owner, "uninstall", { key = g.key })
    check(res.ok == true and countType(g.owner._inv, READER .. "_Black") == 1 and countType(g.owner._inv, READER) == 0
        and postsAt(100, 100) == "" and g.door._modData.KnoxPassColor == nil, "拆下退回黑色讀頭、門柱模型與標記一起拿掉")
    local old = gate(150)
    rec(old).color = nil   -- 更新前裝的讀頭：帳本沒有 color
    cmd(old.owner, "uninstall", { key = old.key })
    check(countType(old.owner._inv, READER) == 1, "舊記錄（沒有 color）拆下退回米白")

    -- 3. 物品欄的感應盒換色：電量、狀態、容器、登記跟著走，舊 ID 失效
    local gt = gate(200)
    local vt = car(gt, 7, { tag = 0.37 })
    register(gt, vt)
    local tag = vt._parts.KnoxPassTag._item
    local oldId = tag:getID()
    tag:setCondition(64)
    vt._parts.KnoxPassTag._item = nil   -- 用維修面板拆下來放進物品欄
    local owner = gt.owner
    owner._inv:AddItem(tag)
    painter(owner, { 5 })
    local ver, adds, removes = KP.Ledger.version(), W.addSent, W.removeSent
    res = cmd(owner, "recolor", { itemId = oldId, color = 5 })
    local fresh = owner._inv:getFirstTypeRecurse(TAG .. "_Orange")
    check(res.ok == true and fresh ~= nil and countType(owner._inv, TAG) == 0 and fresh._container == owner._inv,
        "感應盒換成安全橘：換 type、留在同一個容器")
    check(fresh and near(fresh:getCurrentUsesFloat(), 0.37) and fresh:getCondition() == 64, "電量與狀態保留")
    local r = rec(gt)
    check(fresh and r.tags[fresh:getID()] ~= nil and r.tags[oldId] == nil and r.tags[fresh:getID()].serial == KP.serial(fresh:getID())
        and KP.Ledger.gatesForTag(fresh:getID())[gt.key] == true and next(KP.Ledger.gatesForTag(oldId) or {}) == nil,
        "登記改記新 ID（序號跟著換）、索引重建、舊 ID 查不到")
    check(KP.Ledger.version() > ver and W.addSent == adds + 1 and W.removeSent == removes + 1, "帳本版本加一（重推 passes）、MP 同步增刪")
    check(paintLeft(owner, 5) == 9 and W.paintUses == 1, "用掉一格油漆")
    local walker = newPlayer("walker", 200, 102)
    local forged = walker._inv:AddItem(newItem(TAG, 1))
    forged._id = oldId   -- 舊 ID 的感應盒（不該再有效）
    check(cmd(walker, "open", { key = gt.key }).why == "NotAllowed", "舊 ID 不再能開門")
    walker._inv:DoRemoveItem(forged)
    walker._inv:AddItem(fresh)
    check(cmd(walker, "open", { key = gt.key }).ok == true, "新 ID（換色後的感應盒）可以開門")
    restart()
    check(rec(gt).tags[fresh:getID()] ~= nil and KP.Ledger.gatesForTag(fresh:getID()) ~= nil, "重開後登記仍是新 ID")

    -- 4. 物品欄的讀頭換色（沒有登記可改）
    local rd = owner._inv:AddItem(READER)
    painter(owner, { 1 }, false)   -- 刷子已有
    res = cmd(owner, "recolor", { itemId = rd:getID(), color = 1 })
    check(res.ok == true and countType(owner._inv, READER) == 0 and countType(owner._inv, READER .. "_Black") == 1 and paintLeft(owner, 1) == 9,
        "讀頭換成黑色、用掉一格")

    -- 5. 拒絕：缺油漆、缺刷子、不在身上、裝在車上、顏色不合法；被拒時物品與油漆都不動
    local bare = newPlayer("bare", 200, 102)
    local t2 = bare._inv:AddItem(newItem(TAG, 0.8))
    painter(bare, {}, true)
    check(cmd(bare, "recolor", { itemId = t2:getID(), color = 2 }).why == "NoPaint" and bare._inv:getFirstTypeRecurse(TAG) == t2, "缺油漆 → NoPaint")
    local empty = bare._inv:AddItem(PAINTS[3])
    empty._uses = 0
    check(cmd(bare, "recolor", { itemId = t2:getID(), color = 2 }).why == "NoPaint", "油漆用完（0 格）→ NoPaint")
    local nobrush = newPlayer("nobrush", 200, 102)
    local t3 = nobrush._inv:AddItem(newItem(TAG, 0.8))
    painter(nobrush, { 2 }, false)
    check(cmd(nobrush, "recolor", { itemId = t3:getID(), color = 2 }).why == "NoBrush" and paintLeft(nobrush, 2) == 10, "缺刷子 → NoBrush，油漆不扣")
    painter(bare, { 2 }, false)
    check(cmd(bare, "recolor", { itemId = t3:getID(), color = 2 }).why == "NotCarried", "別人身上的物品 → NotCarried")
    local vi = car(gt, 9, { tag = 0.5 })
    check(cmd(bare, "recolor", { itemId = vi._parts.KnoxPassTag._item:getID(), color = 2 }).why == "NotCarried"
        and vi._parts.KnoxPassTag._item._type == TAG, "裝在車上的感應盒 → NotCarried（要先拆下）")
    local hammer = bare._inv:AddItem("Base.Hammer")
    check(cmd(bare, "recolor", { itemId = hammer:getID(), color = 2 }).why == "NotCarried", "不是感應盒或讀頭 → NotCarried")
    check(cmd(bare, "recolor", { itemId = t2:getID(), color = 0 }).why == "BadColor"
        and cmd(bare, "recolor", { itemId = t2:getID(), color = 7 }).why == "BadColor"
        and cmd(bare, "recolor", { itemId = t2:getID(), color = "2" }).why == "BadColor", "同色、越界、非整數 → BadColor")
    check(W.paintUses == 2 and bare._inv:getFirstTypeRecurse(TAG) == t2 and paintLeft(bare, 2) == 10, "反面：被拒的都沒扣油漆、沒換物品")

    -- 6. 已裝在門上的讀頭改色：登記保留、模型換色；非擁有者、缺料、閘門被拒
    local gd = gate(300)
    local vd = car(gd, 7, { tag = 0.5 })
    register(gd, vd)
    local tagId = vd._parts.KnoxPassTag._item:getID()
    local stranger = newPlayer("stranger", 300, 102)
    painter(stranger, { 1 })
    check(cmd(stranger, "recolorReader", { key = gd.key, color = 1 }).why == "NotOwner" and paintLeft(stranger, 1) == 10, "非擁有者 → NotOwner")
    check(cmd(gd.owner, "recolorReader", { key = gd.key, color = 1 }).why == "NoBrush", "擁有者缺刷子 → NoBrush")
    gd.owner._inv:AddItem("Base.Paintbrush")
    check(cmd(gd.owner, "recolorReader", { key = gd.key, color = 1 }).why == "NoPaint", "擁有者缺油漆 → NoPaint")
    painter(gd.owner, { 1 }, false)
    check(cmd(gd.owner, "recolorReader", { key = gd.key, color = 0 }).why == "BadColor"
        and cmd(gd.owner, "recolorReader", { key = gd.key, color = 9 }).why == "BadColor", "同色、越界 → BadColor")
    local far = newPlayer("far", 300, 110)
    painter(far, { 1 })
    check(cmd(far, "recolorReader", { key = gd.key, color = 1 }).why == "TooFar", "離門太遠 → TooFar")
    local post0 = postsAt(300, 100)
    res = cmd(gd.owner, "recolorReader", { key = gd.key, color = 1 })
    check(res.ok == true and rec(gd).color == 1 and post0 == "0" and postsAt(300, 100) == "8", "改成黑色：rec.color=1、門柱 tile 0 → 8（只有一個）")
    check(rec(gd).tags[tagId] ~= nil and gd.door._modData.KnoxPassColor == 1 and paintLeft(gd.owner, 1) == 9, "登記保留、標記改色、用掉一格")
    driver(vd)
    step()
    check(gd.door:IsOpen(), "改色後登記的車照樣開門")
    local builder = newPlayer("builder", 401, 102)
    buildBarrier(400, 100, "N", builder)
    step()
    painter(builder, { 1 })
    check(cmd(builder, "recolorReader", { key = "401,100,0N", color = 1 }).why == "BarrierColor"
        and paintLeft(builder, 1) == 10, "抬升閘門內建讀頭 → BarrierColor")

    -- 7. 對齊（heal）把顏色不對的模型換掉；孤兒的彩色 tile 也認得
    rec(gd).color = 3   -- 例：存檔不同步，帳本是軍綠、格上是黑色
    loadChunk(300, 100)
    step()
    check(postsAt(300, 100) == "24" and logHas("not in ledger", from), "宿主格載入：黑色換成帳本的軍綠（3×8＋0）")
    local orphan = IsoObject.new(nil, nil, "MinidoracatKnoxPass_reader_49")   -- 紅色（6）變體 1
    square(600, 600, 0):AddTileObject(orphan)
    local cb = W.onLoadSprite["MinidoracatKnoxPass_reader_49"]
    if cb then cb(orphan) end
    step()
    check(cb ~= nil and not present(orphan), "孤兒的彩色讀頭模型：區塊載入時移除")
    restart()
    step()
    check(rec(gd).color == 3 and postsAt(300, 100) == "24", "重開：顏色隨帳本保留、模型不重複")
    clean(from, "外殼顏色與重新上色")

    -- 8. SP：同樣換色，不送網路
    freshWorld("sp")
    from = #logLines + 1
    local me = newPlayer("me", 100, 102)
    W.locals = { me }
    local got
    KP.clientReceive = function(command, args) if command == "result" then got = args end end
    local st = me._inv:AddItem(newItem(TAG, 0.6))
    painter(me, { 6 })
    fire("OnClientCommand", "MinidoracatKnoxPass", "recolor", me, { itemId = st:getID(), color = 6 })
    local red = me._inv:getFirstTypeRecurse(TAG .. "_Red")
    check(got and got.ok == true and red and near(red:getCurrentUsesFloat(), 0.6) and W.addSent == 0 and paintLeft(me, 6) == 9,
        "SP：換成紅色、電量保留、沒有網路傳送")
    clean(from, "外殼顏色與重新上色（SP）")
end

-- 搜刮（server/Items/MinidoracatKnoxPass_Distributions.lua）：表裡只放米白一筆、權重不拆；生成後米白隨機換成 7 色之一，
-- 電量與狀態照抄；搜刮關掉時任何顏色都移除；MP client 與壞掉的 event 參數不動
local function scenarioLoot()
    out("情境：搜刮表與生成後隨機換色")
    freshWorld()
    local from = #logLines + 1
    local LISTS = { "GasStorageMechanics", "GasStorageCombo", "CarSupplyTools", "MechanicShelfElectric", "ElectronicStoreMisc",
        "ElectricianTools", "CrateElectronics", "ToolStoreMisc" }
    ProceduralDistributions = { list = {} }
    for _, n in ipairs(LISTS) do ProceduralDistributions.list[n] = { items = { "Base.Wrench", 4 } } end
    fire("OnPostDistributionMerge")
    fire("OnPostDistributionMerge")   -- 回主選單換存檔再合併一次：不疊加
    local seen, colored, wrench = {}, 0, 0
    for _, n in ipairs(LISTS) do
        local items = ProceduralDistributions.list[n].items
        for i = 1, #items, 2 do
            local t = items[i]
            if t == TAG or t == READER then seen[n .. "|" .. t] = (seen[n .. "|" .. t] or 0) + 1
            elseif t == "Base.Wrench" then wrench = wrench + 1
            elseif string.find(t, "MinidoracatKnoxPass", 1, true) then colored = colored + 1 end
        end
    end
    local mse = ProceduralDistributions.list.MechanicShelfElectric.items
    check(colored == 0 and wrench == #LISTS and seen["GasStorageMechanics|" .. TAG] == 1 and seen["ElectricianTools|" .. READER] == 1
        and seen["MechanicShelfElectric|" .. TAG] == 1 and seen["MechanicShelfElectric|" .. READER] == 1
        and mse[4] == 2 and mse[6] == 0.5, "搜刮表只放米白各一筆、權重照原值（不拆成 7 色）、重複合併不疊加")

    -- 1. 生成後隨機換色：數量不變、7 色都出現、米白約 1/7；電量與狀態照抄；已經是彩色的與其他物品不動
    SandboxVars.MinidoracatKnoxPass.SpawnLoot = true
    local crate = newContainer()
    local hammer = crate:AddItem("Base.Hammer")
    local preBlack = crate:AddItem(newItem(TAG .. "_Black", 0.9))
    for _ = 1, 350 do
        crate:AddItem(newItem(TAG, 0.37)):setCondition(64)
        crate:AddItem(READER)
    end
    fire("OnFillContainer", "garagestorage", "crate", crate)
    local tags, readers, kept, n = {}, {}, true, 0
    for _, it in ipairs(crate._items) do
        local c = KP.colorOf(it)
        if KP.isTag(it) then
            tags[c] = (tags[c] or 0) + 1
            n = n + 1
            if it ~= preBlack then kept = kept and near(it:getCurrentUsesFloat(), 0.37) and it:getCondition() == 64 end
        elseif KP.isReader(it) then
            readers[c] = (readers[c] or 0) + 1
            n = n + 1
        end
    end
    local every = true
    for c = 0, 6 do every = every and (tags[c] or 0) > 0 and (readers[c] or 0) > 0 end
    check(n == 701 and every and hammer._container == crate and preBlack._container == crate and preBlack._type == TAG .. "_Black",
        "生成的感應盒與讀頭數量不變、7 色都出現；鐵鎚與原本就是黑色的不動")
    check((tags[0] or 0) >= 20 and (tags[0] or 0) <= 90 and (readers[0] or 0) >= 20 and (readers[0] or 0) <= 90,
        "米白也是 7 選 1（350 個裡約 50 個）")
    check(kept, "換色後電量與狀態照抄")

    -- 2. 巢狀背包一起處理
    local shelf = newContainer()
    local bag = new("InventoryContainer", Item, { _id = 9, _type = "Base.Bag_Schoolbag", _inv = newContainer() })
    bag.getInventory = function(self) return self._inv end
    shelf:AddItem(bag)
    for _ = 1, 70 do bag._inv:AddItem(READER) end
    fire("OnFillContainer", "garagestorage", "shelf", shelf)
    local bagColors, bagCount = {}, 0
    for _, it in ipairs(bag._inv._items) do
        if KP.isReader(it) then bagColors[KP.colorOf(it)] = true; bagCount = bagCount + 1 end
    end
    local distinct = 0
    for _ in pairs(bagColors) do distinct = distinct + 1 end
    check(bagCount == 70 and distinct >= 4, "巢狀背包裡的讀頭也隨機換色")

    -- 3. 搜刮關掉：任何顏色都移除（含巢狀背包），其他物品留著
    SandboxVars.MinidoracatKnoxPass.SpawnLoot = false
    local off = newContainer()
    local wrenchItem = off:AddItem("Base.Wrench")
    off:AddItem(newItem(TAG, 1))
    off:AddItem(READER .. "_Navy")
    local bag2 = new("InventoryContainer", Item, { _id = 10, _type = "Base.Bag_Schoolbag", _inv = newContainer() })
    bag2.getInventory = function(self) return self._inv end
    off:AddItem(bag2)
    bag2._inv:AddItem(newItem(TAG .. "_Orange", 1))
    fire("OnFillContainer", "garagestorage", "crate", off)
    check(#off._items == 2 and wrenchItem._container == off and bag2._container == off and #bag2._inv._items == 0,
        "搜刮關掉：任何顏色的感應盒與讀頭都移除（含背包裡的），其他物品留著")

    -- 4. 反面：MP client 不處理（伺服器才生成）；背包分支傳來的不是 ItemContainer 時直接略過
    SandboxVars.MinidoracatKnoxPass.SpawnLoot = true
    local raw = newContainer()
    local cream = raw:AddItem(READER)
    local ok = pcall(fire, "OnFillContainer", "garagestorage", "bag", {})
    MODE = "client"
    fire("OnFillContainer", "garagestorage", "crate", raw)
    MODE = "server"
    check(ok and cream._container == raw and cream._type == READER, "MP client 不換色、壞掉的 event 參數不出錯")
    clean(from, "搜刮與隨機換色")
end

-- 轉 180° 的抬升閘門（Barrier.lua）：S／E 向的門線在這一列南邊／這一行東邊，門只能在 N／W 邊，車道門片建在下一列／下一行；
-- 機箱在車道 3 那端。建造放的是替代 tile（真車道＋160），OnCreate 換成真車道
local function scenarioBarrierMirror()
    out("情境：轉 180° 的抬升閘門（S／E 向）")
    freshWorld()
    local from = #logLines + 1
    local builder = newPlayer("builder", 1001, 103, { sid = 77 })
    local s = buildBarrier(1000, 100, "S", builder)
    check(instanceof(s[80], "IsoDoor") and instanceof(s[82], "IsoDoor") and s[80]._square == square(1000, 101, 0)
        and s[82]._square == square(1002, 101, 0) and s[80]._north == true
        and #square(1000, 100, 0)._objects == 0 and #square(1002, 100, 0)._objects == 0,
        "S 向：車道門片建在下一列（北向門），原列的替代 tile 移走")
    check(KP.barrierIndex(s[80]) == 80 and KP.barrierIndex(s[82]) == 82 and s[80]._health == 1000 and s[82]._health == 1000
        and not s[80]:isLocked() and not s[82]:isLockedByKey() and instanceof(s[86], "IsoThumpable")
        and s[86]._square == square(1003, 100, 0), "S 向：真車道 80-82、耐久 1000、不上鎖；機箱 86 留在原列東端")
    check(KP.Barrier.onCreate({ thumpable = s[86] }) == nil
        and KP.Barrier.onCreate({ thumpable = { getSprite = function() return barrierSprite(166) end } }) == nil,
        "機箱與不是車道的替代編號不換門")
    step()
    local r = KP.Ledger.get("1000,101,0N")
    check(r ~= nil and r.builtin == true and r.kind == "Barrier" and r.owner == "builder" and near(r.cx, 1001.5) and near(r.cy, 101.5),
        "S 向：下一個 tick 登記內建讀頭，錨點是西端的車道 1")
    square(1000, 101, 0)._grid = true
    local v = makeVehicle(1001.5, 105.5, { tag = 0.5 })
    check(register({ key = r.key, owner = builder }, v).ok == true, "擁有者登記車輛")
    driver(v)
    step()
    check(s[80]:IsOpen() and s[82]:IsOpen() and KP.barrierIndex(s[80]) == 88 and KP.barrierIndex(s[82]) == 90,
        "S 向：登記的車接近，三片一起開（開啟 sprite 88-90）")
    ISDismantleAction.complete({ thumpable = s[86] })
    check(not present(s[86]) and not present(s[80]) and not present(s[81]) and not present(s[82])
        and KP.Ledger.get(r.key) == nil and W.dropped[KIT] == 1, "S 向：拆除機箱整座移除、退一個組件、刪帳本")
    step()

    local e = buildBarrier(1100, 100, "E", builder)
    step()
    local re = KP.Ledger.get("1101,103,0W")
    local ead, ean = KP.Gates.resolve(e[85])
    check(e[83]._square == square(1101, 103, 0) and e[85]._square == square(1101, 101, 0) and e[83]._north == false
        and e[87]._square == square(1100, 100, 0) and #square(1100, 103, 0)._objects == 0
        and re ~= nil and ean == e[83] and #KP.Gates.pieces(ead, ean) == 3,
        "E 向：車道門片建在東邊一行（西向門）、錨點是南端的車道 1（鏈的最大 y），機箱 87 留在北端")
    local function leftovers(x0, y0)
        local n = 0
        for x = x0 - 1, x0 + 4 do
            for y = y0 - 1, y0 + 4 do
                for _, o in ipairs(square(x, y, 0)._objects) do
                    if (KP.barrierIndex(o) or 0) >= KP.BARRIER_PLACEHOLDER then n = n + 1 end
                end
            end
        end
        return n
    end
    local sw = buildBarrier(1400, 100, "W", builder)
    local sn = buildBarrier(1500, 100, "N", builder)
    check(leftovers(1100, 100) == 0 and leftovers(1400, 100) == 0 and leftovers(1500, 100) == 0
        and present(sw[7]) and present(sn[6]) and present(e[87]),
        "四個方向都不留替代 tile、機箱都在（替代 tile 只移自己：整組 safelyRemove 會在最後一格連機箱一起移掉）")
    for i = 83, 85 do e[i]._square:transmitRemoveItemFromSquare(e[i]) end
    step()
    check(not present(e[87]) and KP.Ledger.get("1101,103,0W") == nil and W.dropped[KIT] == 1,
        "E 向：車道被打壞，下一個 tick 機箱一起移除（從車道找到機箱）、不退組件")

    local s2 = buildBarrier(1200, 100, "S", builder)
    local e2 = buildBarrier(1300, 100, "E", builder)
    step()
    ISDestroyStuffAction.complete({ item = s2[81] })
    fire("OnDestroyIsoThumpable", e2[87], nil)
    check(not present(s2[86]) and not present(s2[80]) and KP.Ledger.get("1200,101,0N") == nil
        and not present(e2[83]) and not present(e2[85]) and KP.Ledger.get("1301,103,0W") == nil,
        "S 向大錘敲車道 2 連機箱一起移除；E 向機箱被打壞連車道一起移除")
    clean(from, "轉 180° 的抬升閘門")
end

-- 車庫捲門（Barrier.lua KP.RollDoor）：替代 tile 編號＝款式×16＋格位，OnCreate 換成原版捲門片（IsoDoor），不內建讀頭
local function scenarioRollDoor()
    out("情境：車庫捲門（替代 tile 換成原版車庫門片）")
    freshWorld()
    local from = #logLines + 1
    local R = KP.RollDoor
    local function name(i)
        local n, north = R.sprite(i)
        return tostring(n) .. (north == true and "N" or north == false and "W" or "")
    end
    check(name(0) == "industry_trucks_01_35N" and name(2) == "industry_trucks_01_37N" and name(3) == "industry_trucks_01_32W"
        and name(5) == "industry_trucks_01_34W", "3 格寬：北向 0-2＝第 1-3 片、西向 3-5＝第 1-3 片")
    check(name(8) == "industry_trucks_01_35N" and name(9) == "industry_trucks_01_36N" and name(10) == "industry_trucks_01_36N"
        and name(11) == "industry_trucks_01_37N" and name(12) == "industry_trucks_01_32W" and name(15) == "industry_trucks_01_34W",
        "4 格寬：門片 1、2、2、3（中間片重複）")
    local six = {}
    for i = 16, 27 do six[#six + 1] = name(i) end
    check(table.concat(six, ",") == "industry_trucks_01_35N,industry_trucks_01_36N,industry_trucks_01_36N,industry_trucks_01_36N,"
        .. "industry_trucks_01_36N,industry_trucks_01_37N,industry_trucks_01_32W,industry_trucks_01_33W,industry_trucks_01_33W,"
        .. "industry_trucks_01_33W,industry_trucks_01_33W,industry_trucks_01_34W", "6 格寬：門片 1、2×4、3")
    check(name(32) == "industry_trucks_01_35N" and name(36) == "industry_trucks_01_36N" and name(40) == "industry_trucks_01_37N"
        and name(41) == "industry_trucks_01_32W" and name(49) == "industry_trucks_01_34W", "9 格寬：門片 1、2×7、3")
    check(name(64) == "walls_garage_01_19N" and name(67) == "walls_garage_01_16W" and name(128) == "walls_garage_01_51N"
        and name(131) == "walls_garage_01_48W", "綠色、白色兩款各自的第 1 片（款式×64）")
    check(R.sprite(6) == nil and R.sprite(7) == nil and R.sprite(28) == nil and R.sprite(50) == nil and R.sprite(63) == nil
        and R.sprite(192) == nil, "空格與不存在的款式回 nil")

    -- 照 ISBuildIsoEntity 逐格放替代 tile 再呼叫 OnCreate；rows＝{ dx, dy, 替代 tile 編號 }
    local function build(x, y, rows, builder)
        local made, ent = {}, { size = #rows }
        for _, t in ipairs(rows) do
            local th = new("IsoThumpable", Thump, {
                _open = false, _locked = false, _lockedByKey = false, _keyId = -1, _modData = {}, _north = false,
                _obstructed = false, _view = { modData = {} }, _isDoor = true, _entityMulti = true, _entity = ent,
                _spriteObj = namedSprite(KP.ROLLDOOR_TILESET .. "_" .. t[3]), _buildMaterials = { ["Base.SheetMetal"] = 4 },
            })
            ent[#ent + 1] = th
            syncView(th)
            square(x + t[1], y + t[2], 0):AddSpecialObject(th)
            local res = R.onCreate({ thumpable = th, character = builder, facing = "N" })
            made[#made + 1] = res and res.replaceObject and res.object or th
        end
        return made
    end
    local owner = newPlayer("owner", 301, 102)
    local n = build(200, 100, { { 0, 0, 64 }, { 1, 0, 65 }, { 2, 0, 66 } }, owner)   -- 綠色 3 格寬、北向
    check(instanceof(n[1], "IsoDoor") and n[1]._north == true and n[1]:getSprite():getName() == "walls_garage_01_19"
        and n[3]:getSprite():getName() == "walls_garage_01_21" and n[1]._square == square(200, 100, 0)
        and #square(200, 100, 0)._objects == 1, "北向：每格換成原版門片（同一格，替代 tile 移走）")
    check(not n[1]:isLocked() and not n[1]:isLockedByKey() and n[1]._health == 1000 and n[3]._health == 1000,
        "不上鎖、耐久 1000")
    local ad, an = KP.Gates.resolve(n[3])
    check(an == n[1] and #KP.Gates.pieces(ad, an) == 3 and KP.Gates.kind(ad, an) == "Garage",
        "整組三片、錨點是第 1 片（最小 x）、類型 Garage")
    local w = build(300, 100, { { 0, 0, 143 }, { 0, 1, 142 }, { 0, 2, 141 }, { 0, 3, 140 } }, owner)   -- 白色 4 格寬、西向
    local wad, wan = KP.Gates.resolve(w[1])
    check(w[4]._north == false and w[1]:getSprite():getName() == "walls_garage_01_50"
        and w[2]:getSprite():getName() == "walls_garage_01_49" and w[3]:getSprite():getName() == "walls_garage_01_49"
        and w[4]:getSprite():getName() == "walls_garage_01_48" and wan == w[4] and #KP.Gates.pieces(wad, wan) == 4,
        "西向 4 格寬：北到南門片 3、2、2、1，整組四片、錨點在最南（鏈的最大 y）")
    local odd = build(400, 100, { { 0, 0, 6 } }, owner)
    check(instanceof(odd[1], "IsoThumpable") and KP.Barrier.onCreate({ thumpable = n[1] }) == nil,
        "不是門片的編號不換；閘門的 OnCreate 不碰捲門")
    local rows9 = {}
    for k = 1, 9 do rows9[k] = { k - 1, 0, 31 + k } end
    local nine = build(500, 100, rows9, owner)   -- 工業白 9 格寬、北向
    local nad, nan = KP.Gates.resolve(nine[9])
    check(nan == nine[1] and #KP.Gates.pieces(nad, nan) == 9 and nine[1]._health == 2000 and nine[9]._health == 2000,
        "9 格寬（三台車）：整條鏈九片、錨點第 1 片、耐久 2000")
    local rows6 = {}
    for k = 1, 6 do rows6[k] = { k - 1, 0, 79 + k } end
    local sixDoor = build(600, 100, rows6, owner)   -- 綠色 6 格寬、北向
    check(#KP.Gates.pieces(KP.Gates.resolve(sixDoor[6])) == 6 and sixDoor[1]._health == 1500, "6 格寬（兩台車）：六片、耐久 1500")

    for y = 100, 103 do square(300, y, 0)._grid = true end
    local reader = owner._inv:AddItem(READER)
    local res = cmd(owner, "install", { x = 300, y = 101, z = 0, index = w[2]:getObjectIndex(), itemId = reader:getID() })
    check(res.ok == true and res.key == "300,103,0W" and KP.Ledger.get(res.key).kind == "Garage"
        and KP.Ledger.get(res.key).builtin == nil, "捲門照一般車庫門裝讀頭（不內建）")
    local v = makeVehicle(305.5, 101.5, { tag = 0.5 })
    register({ key = res.key, owner = owner }, v)
    driver(v)
    step()
    check(w[1]:IsOpen() and w[4]:IsOpen() and w[4]:getSprite():getName() == "walls_garage_01_56",
        "登記的車接近：四片一起開（原版開啟 sprite＋8）")
    clean(from, "車庫捲門")
end

-- 每扇門的設定（Server.lua H.settings、Core.lua KP.gateRange／gateDelay）：擁有者或管理員、站在門邊；
-- 值夾在沙盒上下限內，"default" 改回跟著沙盒預設；生效值每次用時再夾一次（服主之後縮小範圍也照新範圍）
local function scenarioSettings()
    out("情境：每扇門的感應距離與關門延遲")
    freshWorld()
    local from = #logLines + 1
    local a = gate(100)
    local res, st = cmd(a.owner, "settings", { key = a.key, range = 12, delay = 0 })
    check(res.ok == true and rec(a).range == 12 and rec(a).closeDelay == 0 and st and st.range == 12 and st.rangeSet == 12
        and st.delay == 0 and st.delaySet == 0, "擁有者設 12 格、0 秒：寫進帳本，state 帶生效值與設定值")
    check(st.rangeMin == 2 and st.rangeMax == 30 and st.rangeDefault == 8 and st.delayMin == 0 and st.delayMax == 30
        and st.delayDefault == 2 and near(st.cx, a.cx) and near(st.cy, a.cy), "state 帶沙盒上下限、預設值與範圍圈的圓心")
    res = cmd(a.owner, "settings", { key = a.key, range = 99 })
    check(res.ok == true and rec(a).range == 30 and rec(a).closeDelay == 0, "超過上限夾到 30；沒送的延遲不動")
    cmd(a.owner, "settings", { key = a.key, range = 1 })
    check(rec(a).range == 2, "低於下限夾到 2")
    local bad = 0
    for _, v in ipairs({ 3.5, "12", true, {} }) do
        local r = cmd(a.owner, "settings", { key = a.key, range = v })
        if r.ok ~= false or r.why ~= "BadArgs" or r.key ~= a.key then bad = bad + 1 end
    end
    check(bad == 0 and rec(a).range == 2 and cmd(a.owner, "settings", { key = a.key, delay = 0 / 0 }).why == "BadArgs",
        "小數、字串、布林、表、NaN → BadArgs（帶 key），帳本不動")
    res, st = cmd(a.owner, "settings", { key = a.key, range = "default", delay = "default" })
    check(res.ok == true and rec(a).range == nil and rec(a).closeDelay == nil and st.range == 8 and st.rangeSet == nil
        and st.delay == 2 and st.delaySet == nil, "\"default\"：改回跟著沙盒預設（帳本不存值）")
    local other = newPlayer("other", 100, 101)
    res = cmd(other, "settings", { key = a.key, range = 20 })
    check(res.ok == false and res.why == "NotOwner" and rec(a).range == nil, "非擁有者不能改")
    local admin = newPlayer("admin", 100, 101, { caps = { CanOpenLockedDoors = true } })
    check(cmd(admin, "settings", { key = a.key, range = 20 }).ok == true and rec(a).range == 20, "管理員可以改")
    a.owner._y = 110.5
    res = cmd(a.owner, "settings", { key = a.key, range = 5 })
    check(res.ok == false and res.why == "TooFar" and res.key == a.key and rec(a).range == 20, "離門太遠：TooFar（帶 key），帳本不動")
    a.owner._y = 102.5
    local sb = SandboxVars.MinidoracatKnoxPass
    sb.ReadRangeMax = 10
    check(KP.gateRange(rec(a)) == 10 and rec(a).range == 20, "服主把上限縮到 10：生效值照新上限，帳本原值保留")
    sb.ReadRangeMin, sb.ReadRangeMax = 25, 15
    local lo, hi = KP.settingBounds("ReadRange")
    check(lo == 15 and hi == 25 and KP.gateRange(rec(a)) == 20, "上下限填反：自動對調")
    sb.ReadRangeMin, sb.ReadRangeMax = nil, nil

    -- 生效：範圍 3 的門停在 5 格不開；範圍 12 的門停在 10 格就開（沙盒預設 8）
    local b = gate(200)
    cmd(b.owner, "settings", { key = b.key, range = 3 })
    local vb = car(b, 5, { tag = 0.5 })
    register(b, vb)
    driver(vb)
    runMs(1000)
    check(not b.door:IsOpen(), "感應距離 3 格：停在 5 格不開")
    local c = gate(300)
    cmd(c.owner, "settings", { key = c.key, range = 12, delay = 6 })
    local vc = car(c, 10, { tag = 0.5 })
    register(c, vc)
    driver(vc)
    step()
    check(c.door:IsOpen(), "感應距離 12 格：停在 10 格就開")
    moveCar(vc, vc._x, vc._y + 40)
    runMs(5750)
    check(c.door:IsOpen(), "關門延遲 6 秒：離開範圍 5.75 秒還開著")
    runMs(500)
    check(not c.door:IsOpen(), "滿 6 秒關門")

    -- 步行開門：延遲再短也先開 5 秒（S.WALK_MS），人才走得到門口
    sb.CloseDelay = 0
    local d = gate(400)
    check(cmd(d.owner, "open", { key = d.key }).ok == true and d.door:IsOpen(), "步行開門（關門延遲 0）")
    runMs(4750)
    check(d.door:IsOpen(), "步行開的門至少開 5 秒")
    runMs(500)
    check(not d.door:IsOpen(), "滿 5 秒關上")
    sb.CloseDelay = nil

    -- 延遲 0：撐著門的車還在範圍內就一直開著（同一個 tick 剛撐住的門不判關門），一離開範圍下一輪就關
    local e = gate(500)
    cmd(e.owner, "settings", { key = e.key, delay = 0 })
    local ve = car(e, 5, { tag = 0.5 })
    register(e, ve)
    driver(ve)
    local shut = 0
    for _ = 1, 8 do
        step()
        if not e.door:IsOpen() then shut = shut + 1 end
    end
    check(shut == 0, "關門延遲 0：登記車停在範圍內，每一輪掃描門都開著（關過 " .. shut .. " 次）")
    moveCar(ve, ve._x, ve._y + 40)
    step()
    check(not e.door:IsOpen(), "關門延遲 0：車一離開範圍，下一輪就關")
    clean(from, "每扇門設定")
end

-- 整台通過就不再撐門（Sensor.lua holds）：車和拖車的中心都到門線另一側、而且都沒壓到門口格，就照延遲關，
-- 即使車還停在範圍內；掉頭朝門開回來才重新算一趟
local function scenarioPassThrough()
    out("情境：車和拖車整台通過後關門")
    freshWorld()
    local from = #logLines + 1
    -- 往北開 0.5 格／步，到 stopY 停下（門線 y = 100）
    local function driveNorth(v, stopY, trailer, gap, onStep)
        while v._y > stopY do
            step(function()
                moveCar(v, v._x, math.max(stopY, v._y - 0.5))
                if trailer then moveCar(trailer, trailer._x, v._y + gap) end
            end)
            if onStep then onStep() end
        end
    end

    local a = gate(100)
    local va = car(a, 4, { tag = 0.5 })
    register(a, va)
    driver(va)
    step()
    check(a.door:IsOpen(), "登記的車從南邊接近：開門")
    local closedWhile = nil
    driveNorth(va, 95.5, nil, nil, function()
        if not a.door:IsOpen() and va._y >= 98.5 then closedWhile = va._y end
    end)
    check(closedWhile == nil and a.door:IsOpen(), "通過門口途中（車身還壓在門口格）一直開著")
    runMs(1750)
    check(not a.door:IsOpen() and rec(a).open == nil, "整台通過、停在範圍內（5 格）：照延遲 2 秒關門")
    runMs(5000)
    check(not a.door:IsOpen(), "停在門內不會讓門重開")

    -- 掉頭朝門開回來：重新算一趟
    local reopenedAt = nil
    for _ = 1, 12 do
        step(function() moveCar(va, va._x, va._y + 0.5) end)
        if a.door:IsOpen() then
            reopenedAt = va._y
            break
        end
    end
    check(reopenedAt ~= nil and reopenedAt < 99, "掉頭往門開：車到門口前就重開（y=" .. tostring(reopenedAt) .. "）")

    -- 拖車：車頭通過但拖車還壓在門口格就撐著
    local b = gate(200)
    local vb = car(b, 4, { tag = 0.5 })
    local tr = makeVehicle(vb._x, vb._y + 3)
    vb._towing = tr
    register(b, vb)
    driver(vb)
    step()
    driveNorth(vb, 96.5, tr, 3)
    check(tr._y == 99.5, "（前提）車停在 96.5，拖車壓在門線另一側那格")
    runMs(4000)
    check(b.door:IsOpen(), "拖車還壓在門口：過了延遲也不關")
    moveCar(tr, tr._x, 97.5)
    runMs(1750)
    check(b.door:IsOpen(), "拖車剛離開門口：延遲還沒到")
    runMs(500)
    check(not b.door:IsOpen(), "拖車也通過：滿延遲關門")

    -- 倒車回門：拖車在前、車心離門線還遠（實機 r3-mp 1007d：車心 6.6 格、拖車尾 1.5 格），
    -- 車或拖車往前看會回到原側就重開；只看車心時拖車會先頂到關著的門
    moveCar(vb, vb._x, 93.5)
    moveCar(tr, tr._x, 97.0)
    runMs(2500)   -- 停穩，平滑速度歸零
    check(not b.door:IsOpen(), "（前提）車與拖車停在門內（範圍內）：門關著")
    local backAt = nil
    for _ = 1, 10 do
        step(function()
            moveCar(vb, vb._x, vb._y + 0.5)
            moveCar(tr, tr._x, tr._y + 0.5)
        end)
        if b.door:IsOpen() then
            backAt = tr._y
            break
        end
    end
    check(backAt ~= nil and backAt < 99, "倒車回門（拖車在前）：拖車到門口前就重開（拖車 y=" .. tostring(backAt) .. "）")

    -- 反面：沒通過（停在原本那一側）就照舊撐著
    local c = gate(300)
    local vc = car(c, 2, { tag = 0.5 })
    register(c, vc)
    driver(vc)
    runMs(10000)
    check(c.door:IsOpen(), "停在門前（原本那一側）：一直開著")
    clean(from, "整台通過後關門")
end

-- 會開門的殭屍與 Knox Pass 門鎖（2026-10-08 玩家回報：閘門被殭屍升起後放不下來）。Gates.lua IsoDoor 段：
-- 門鎖＝CustomLock＋locked（殭屍只看 locked）；Sensor.lua S.relock 每 5 秒替關著的上鎖門補回 locked；
-- Server.lua H.close＋右鍵「用 Knox Pass 關門」：門被有鑰匙的人打開時，CustomLock 讓原版「關門」灰掉，這是關回去的路
local function scenarioZombieLock()
    out("情境：會開門的殭屍與 Knox Pass 門鎖")
    freshWorld()
    local from = #logLines + 1
    local zb = newZombie(100, 99)
    local stranger = newPlayer("stranger", 100, 101)

    local a = gate(100)
    zombieThump(a.door, zb)
    check(a.door:IsOpen(), "（引擎基準）沒上鎖的門，會開門的殭屍打得開")
    a.door:ToggleDoor(a.owner)
    check(cmd(a.owner, "lock", { key = a.key, on = true }).ok == true and a.door._lockedByKey and a.door._view.locked == true
        and a.door._modData.CustomLock == true and a.door._modData.KnoxPassLocked == true,
        "開啟門鎖：CustomLock＋鑰匙鎖（記下原本沒鎖）並同步給 client")
    zombieThump(a.door, zb)
    check(not a.door:IsOpen(), "上了 Knox 門鎖：client 上的殭屍打不開")

    -- 回報的情境：抬升閘門上鎖後，殭屍拍任一片車道都升不起來
    local builder = newPlayer("builder", 201, 103)
    local n = buildBarrier(200, 100, "N", builder)
    step()
    check(cmd(builder, "lock", { key = "201,100,0N", on = true }).ok == true
        and n[0]._view.locked and n[1]._view.locked and n[2]._view.locked, "閘門開啟門鎖：client 看到三片車道都上鎖")
    zombieThump(n[1], zb)
    check(not n[0]:IsOpen() and not n[2]:IsOpen(), "上鎖的閘門：殭屍拍車道升不起來")

    -- 舊存檔只有 CustomLock、沒有鎖：5 秒內補上
    local c = gate(300)
    cmd(c.owner, "lock", { key = c.key, on = true })
    c.door._locked, c.door._lockedByKey, c.door._modData.KnoxPassLocked = false, false, nil
    syncView(c.door)
    runMs(5250)
    check(c.door._lockedByKey and c.door._view.locked == true and c.door._modData.KnoxPassLocked == true,
        "舊存檔只有 CustomLock 的門：5 秒內補上鑰匙鎖並同步")
    local syncs = 0
    local realSync = c.door.syncIsoObject
    c.door.syncIsoObject = function(self, ...) syncs = syncs + 1; return realSync(self, ...) end
    runMs(10250)
    c.door.syncIsoObject = nil
    check(syncs == 0, "已經鎖好的門不重複同步（" .. syncs .. " 次）")
    -- Knox Pass 開過再關上：補的鎖照樣記成 Knox Pass 的（不當成原本的鎖），關閉門鎖後門回到沒上鎖
    local vc = car(c, 3, { tag = 0.5 })
    register(c, vc)
    driver(vc)
    step()
    check(c.door:IsOpen(), "Knox Pass 開門")
    moveCar(vc, vc._x, vc._y + 40)
    runMs(2250)
    check(not c.door:IsOpen() and c.door._locked and c.door._modData.KnoxPassLocked == true,
        "關好後鎖回，仍記成 Knox Pass 補的鎖")
    cmd(c.owner, "lock", { key = c.key, on = false })
    c.door:ToggleDoor(stranger)
    check(c.door:IsOpen(), "Knox Pass 開關過的門，關閉門鎖後誰都能開")

    -- 可跨越的柵欄門：有人試開時引擎清掉 locked，5 秒內補回
    local d = gate(400, { hoppable = true })
    cmd(d.owner, "lock", { key = d.key, on = true })
    d.door:ToggleDoor(newPlayer("climber", 400, 101))
    check(not d.door:IsOpen() and not d.door._locked, "（引擎）柵欄門有人試開：門關著，但 locked 被清掉")
    runMs(5250)
    zombieThump(d.door, zb)
    check(d.door._locked and not d.door:IsOpen(), "5 秒內補回 locked，殭屍又打不開")

    -- 有鑰匙的人用手打開：原版「關門」對其他人灰掉，用 Knox Pass 關門
    local holder = newPlayer("holder", 100, 101)
    holder._inv:AddItem(newKey(a.door:getKeyId()))
    a.door:ToggleDoor(holder)
    check(a.door:IsOpen() and rec(a).open == nil, "（引擎）有鑰匙的人打開上鎖的門（不是 Knox Pass 開的）")
    local res = cmd(stranger, "close", { key = a.key })
    check(res.ok == false and res.why == "NotAllowed" and a.door:IsOpen(), "沒帶登記感應盒的人不能用 Knox Pass 關門")
    a.owner._x, a.owner._y = 100.5, 100.5
    res = cmd(a.owner, "close", { key = a.key })
    check(res.ok == false and res.why == "Blocked" and a.door:IsOpen(), "站在門口：Blocked，門不關")
    a.owner._x, a.owner._y = 101.5, 102.5
    res = cmd(a.owner, "close", { key = a.key })
    check(res.ok == true and not a.door:IsOpen() and a.door._locked and a.door._modData.CustomLock == true,
        "擁有者用 Knox Pass 關門：關上並鎖回")
    local va = car(a, 3, { tag = 0.5 })
    register(a, va)
    a.door:ToggleDoor(holder)
    local tagHolder = newPlayer("tagger", 101, 101)
    tagHolder._inv:AddItem(va._parts.KnoxPassTag._item)
    check(cmd(tagHolder, "close", { key = a.key }).ok == true and not a.door:IsOpen(), "身上帶登記感應盒的人也能用 Knox Pass 關門")
    local driverP = driver(va)
    driverP._x, driverP._y = 100.5, 103.5
    check(cmd(driverP, "close", { key = a.key }).why == "InVehicle", "坐在車上：InVehicle")
    unseat(driverP)
    moveCar(va, va._x, va._y + 40)

    -- 關閉門鎖：Knox Pass 補的鑰匙鎖拿掉，門回到誰都能開
    a.door:ToggleDoor(stranger)
    check(not a.door:IsOpen() and a.door._lockedByKey, "（引擎）沒鑰匙的人試開：門不開，鑰匙鎖還在")
    cmd(a.owner, "lock", { key = a.key, on = false })
    check(not a.door._locked and not a.door._lockedByKey and a.door._view.lockedByKey == false
        and a.door._modData.CustomLock == nil and a.door._modData.KnoxPassLocked == nil,
        "關閉門鎖：Knox Pass 補的鑰匙鎖拿掉並同步")
    a.door:ToggleDoor(stranger)
    check(a.door:IsOpen(), "關閉門鎖後誰都能開")

    -- 玩家建造的門（Knox 門鎖＝鑰匙鎖）：有鑰匙的人用手開關後，5 秒內鎖回
    local t = gate(500, { cls = "IsoThumpable" })
    cmd(t.owner, "lock", { key = t.key, on = true })
    local th = newPlayer("thholder", 500, 101)
    th._inv:AddItem(newKey(t.door:getKeyId()))
    t.door:ToggleDoor(th)
    t.door:ToggleDoor(th)
    check(not t.door:IsOpen() and not t.door._lockedByKey, "（引擎）有鑰匙的人開關玩家建造的門：鎖被清掉")
    runMs(5250)
    check(t.door._lockedByKey and t.door._view.lockedByKey == true, "5 秒內鎖回 lockedByKey 並同步")

    -- 原本只有 locked 的一般門（非車庫門，client 直接套用欄位、不回送）：Knox 門鎖補成鑰匙鎖，關閉門鎖後回到只有 locked
    local m = gate(700, { locked = true })
    cmd(m.owner, "lock", { key = m.key, on = true })
    check(m.door._lockedByKey and m.door._modData.KnoxPassLocked == 1, "原本只有 locked 的門：補上鑰匙鎖，記成 1")
    cmd(m.owner, "lock", { key = m.key, on = false })
    step()
    check(m.door._locked and not m.door._lockedByKey and m.door._view.locked == true and m.door._modData.KnoxPassLocked == nil,
        "關閉門鎖：一般門回到原本只有 locked 並同步")
    clean(from, "會開門的殭屍與 Knox Pass 門鎖")
end

-- 實機回報（2026-10-08）：上鎖的閘門被登記車撐著時連續重開、感應盒電量瞬間用完，AutoDrive 卡在門前。
-- 車庫門鏈的鎖一同步，client 就把鏈上其他片當下的開關回送伺服器（echoChain、step）：開門前先同步解鎖，回送的是「關著」，
-- 伺服器把剛開的門關上，Sensor 下一輪又開、又扣電。被人用手關上後先鎖回再重開也一樣
local function scenarioLockHold()
    out("情境：上鎖的閘門被登記車撐著")
    freshWorld()
    local from = #logLines + 1
    local builder = newPlayer("builder", 201, 103)
    local n = buildBarrier(200, 100, "N", builder)
    step()
    local key = "201,100,0N"
    check(cmd(builder, "lock", { key = key, on = true }).ok == true and n[2]._view.lockedByKey == true, "閘門開啟門鎖")
    local r = KP.Ledger.get(key)
    square(201, 100, 0)._grid = true
    local v = makeVehicle(r.cx, r.cy + 6, { tag = 1 })
    check(cmd(builder, "register", { key = key, vehicleId = v:getId() }).ok == true, "登記停在 6 格外的車")
    step()   -- 上鎖時 client 回送的鑰匙鎖先到（門關著，回送的也是關著）
    driver(v)
    runMs(10000)
    check(W.echoClosed == 0 and n[0]:IsOpen() and n[0]._view.open,
        "駕駛坐在範圍內 10 秒：門一直開著，client 的回送沒有把它關上（" .. W.echoClosed .. " 次）")
    check(math.abs(charge(v) - 0.99) < 1e-4, string.format("只開一次、只扣一次電（%.3f）", charge(v)))
    n[1]:ToggleDoor(newPlayer("passer", 202, 101))
    check(not n[0]:IsOpen(), "（引擎）有人用手把門關上")
    runMs(2000)
    check(W.echoClosed == 0 and n[0]:IsOpen() and n[0]._view.open,
        "下一輪直接重開、不先鎖回：之後門一直開著（回送關門 " .. W.echoClosed .. " 次）")
    check(math.abs(charge(v) - 0.98) < 1e-4, string.format("重開再扣一次電（%.3f）", charge(v)))
    moveCar(v, v._x, v._y + 40)
    runMs(5000)
    check(not n[0]:IsOpen() and n[0]:isLockedByKey() and n[2]:isLockedByKey() and n[2]._view.lockedByKey == true
        and W.echoClosed == 0, "開走後照延遲關上並鎖回，client 也看到鎖")
    clean(from, "上鎖的閘門被登記車撐著")
end

-- 模型門（Core.lua KP.MODEL_GATES、Barrier.lua KP.ModelGate）：entity 建造照 build_model_gates.py faces_rows——
-- N／S 一列沿 +x [A] 車道 1..L [B]，W／E 沿 +y [B] 車道 L..1 [A]；車道放替代 tile（格位 16＋k−1），兩端是格位 3／4。
-- 回傳 { lanes = { [k] = 物件 }, A = 端 A, B = 端 B }
local function buildModelGate(tileset, block, width, face, ends, x, y, builder)
    local slots = {}
    for k = 1, width do slots[k] = 15 + k end
    if ends then
        table.insert(slots, 1, 3)
        slots[#slots + 1] = 4
    end
    local row = face == "N" or face == "S"
    if not row then
        local r = {}
        for i = #slots, 1, -1 do r[#r + 1] = slots[i] end
        slots = r
    end
    local made, ent = { lanes = {} }, { size = #slots }
    for j, slot in ipairs(slots) do
        local th = new("IsoThumpable", Thump, {
            _open = false, _locked = false, _lockedByKey = false, _keyId = -1, _modData = {}, _north = false,
            _obstructed = false, _view = { modData = {} }, _spriteObj = namedSprite(tileset .. "_" .. (block * 64 + slot)),
            _isDoor = slot >= 16, _buildMaterials = { ["Base.MetalPipe"] = 4 }, _entityMulti = true, _entity = ent,
        })
        ent[#ent + 1] = th
        syncView(th)
        square(x + (row and j - 1 or 0), y + (row and 0 or j - 1), 0):AddSpecialObject(th)
        local res = KP.ModelGate.onCreate({ thumpable = th, character = builder, facing = face })
        local o = res and res.replaceObject and res.object or th
        if slot >= 16 then made.lanes[slot - 15] = o elseif slot == 3 then made.A = o else made.B = o end
    end
    return made
end

local function scenarioModelGates()
    out("情境：模型門（雙桿閘門、兩層樓捲門、兩層樓大門）")
    freshWorld()
    local from = #logLines + 1
    local G = KP.Gates
    local builder = newPlayer("builder", 104, 103)
    local function all(g, fn)
        for k = 1, #g.lanes do if not fn(g.lanes[k], k) then return false end end
        return true
    end
    local function gone(g) return not present(g.A) and not present(g.B) and all(g, function(p) return not present(p) end) end

    local b6 = buildModelGate("MinidoracatKnoxPass_barrier2", 0, 6, "N", true, 100, 100, builder)
    check(all(b6, function(p, k)
        return instanceof(p, "IsoDoor") and p._north and p._square == square(100 + k, 100, 0) and p._health == 1500
            and p:getSprite():getName() == "MinidoracatKnoxPass_barrier2_" .. (k == 1 and 0 or k == 6 and 2 or 1)
    end) and instanceof(b6.A, "IsoThumpable") and b6.A._square == square(100, 100, 0) and b6.B._square == square(107, 100, 0)
        and #square(101, 100, 0)._objects == 1, "雙桿閘門 6 格 N：六片換成門片 1、2×4、3（耐久 1500），兩端留著機箱")
    local ad, an = G.resolve(b6.lanes[6])
    check(an == b6.lanes[1] and #G.pieces(ad, an) == 6 and G.kind(ad, an) == "Barrier" and KP.Ledger.get("101,100,0N") == nil,
        "點第 6 片找得到錨點第 1 片，整組六片、類型 Barrier；建造當下還不登記")
    step()
    local r = KP.Ledger.get("101,100,0N")
    check(r and r.builtin == true and r.owner == "builder" and near(r.cx, 104.0) and near(r.cy, 100.5),
        "下一個 tick 登記內建讀頭：擁有者是建造者、中心在六片中間")
    check(KP.Barrier.parts(b6.A) and #KP.Barrier.parts(b6.A) == 8 and KP.isGateEnd(b6.B) and not KP.isGateEnd(b6.lanes[1]),
        "從 A 端找得到整座（六片＋兩端）；兩端算整座一起移除的端點，車道不算")

    local b9 = buildModelGate("MinidoracatKnoxPass_barrier2", 3, 9, "W", true, 200, 100, builder)
    step()
    check(b9.B._square == square(200, 100, 0) and b9.lanes[9]._square == square(200, 101, 0)
        and b9.lanes[1]._square == square(200, 109, 0) and b9.A._square == square(200, 110, 0) and not b9.lanes[1]._north
        and b9.lanes[1]:getSprite():getName() == "MinidoracatKnoxPass_barrier2_192" and KP.Ledger.get("200,109,0W") ~= nil
        and b9.lanes[1]._health == 2000, "雙桿閘門 9 格 W：北到南 B、車道 9..1、A，錨點在最南、耐久 2000、登記在錨點")

    local rf = buildModelGate("MinidoracatKnoxPass_roll2f_green", 2, 4, "N", false, 300, 100, builder)
    step()
    local rad, ran = G.resolve(rf.lanes[3])
    check(ran == rf.lanes[1] and #G.pieces(rad, ran) == 4 and G.kind(rad, ran) == "Garage" and rf.A == nil
        and rf.lanes[1]._health == 1500 and rf.lanes[1]:getSprite():getName() == "MinidoracatKnoxPass_roll2f_green_128"
        and KP.Ledger.get("300,100,0N") == nil and KP.Barrier.parts(rf.lanes[2]) == nil,
        "兩層樓捲門 4 格：四片、類型 Garage、耐久 1500、不自動登記，也不歸 Barrier 整座移除（照一般車庫門）")

    local gc = buildModelGate("MinidoracatKnoxPass_gate_c", 2, 6, "S", true, 400, 100, builder)
    step()
    local gad, gan = G.resolve(gc.lanes[4])
    check(all(gc, function(p, k) return p._square == square(400 + k, 101, 0) and p._north end)
        and gc.A._square == square(400, 100, 0) and gc.B._square == square(407, 100, 0) and gan == gc.lanes[1]
        and G.kind(gad, gan) == "Gate" and gc.lanes[1]._health == 2000 and KP.Ledger.get("401,101,0N") == nil,
        "兩層樓大門 6 格 S：門片在擺放列的下一列（北邊門），錨點最西、類型 Gate、耐久 2000、不自動登記")

    local ge = buildModelGate("MinidoracatKnoxPass_gate_e", 7, 9, "E", true, 500, 100, builder)
    check(ge.B._square == square(500, 100, 0) and ge.A._square == square(500, 110, 0) and ge.lanes[1]._square == square(501, 109, 0)
        and ge.lanes[9]._square == square(501, 101, 0) and not ge.lanes[1]._north and ge.lanes[1]._health == 2500,
        "兩層樓大門 9 格 E：門片在擺放行的東邊一行（西邊門），錨點最南、耐久 2500")

    -- 柱面讀頭：大門裝讀頭 → A 端門柱那格放 readerpillar（顏色×32＋外觀×4＋方向序），不放門柱讀頭；改色換 tile
    local function readersAt(x, y)
        local list = {}
        for _, o in ipairs(square(x, y, 0)._objects) do
            local n = string.match(o:getSprite():getName(), "^MinidoracatKnoxPass_reader(%a*_%d+)$")
            if n then list[#list + 1] = n end
        end
        return table.concat(list, ",")
    end
    square(401, 101, 0)._grid = true
    local owner = newPlayer("gateowner", 403, 103)
    local reader = owner._inv:AddItem(READER)
    local res = cmd(owner, "install", { x = 403, y = 101, z = 0, index = gc.lanes[3]:getObjectIndex(), itemId = reader:getID() })
    local key = res.key
    check(res.ok == true and key == "401,101,0N" and KP.Ledger.get(key).post.i == 8 + 2 * 4 + 2 and readersAt(400, 100) == "pillar_10"
        and readersAt(401, 101) == "" and readersAt(401, 102) == "", "大門裝讀頭：柱面讀頭放在 A 端門柱那格（外觀 C、S 向＝10），不放門柱讀頭")
    owner._inv:AddItem(PAINTS[4])
    owner._inv:AddItem("Base.Paintbrush")
    check(cmd(owner, "recolorReader", { key = key, color = 3 }).ok == true and readersAt(400, 100) == "pillar_106",
        "改成橄欖綠：柱面讀頭換成 3×32＋10")

    -- 感應：登記的車接近，六片一起開；開走後關上
    local v = makeVehicle(404.0, 104.5, { tag = 0.5 })
    check(cmd(owner, "register", { key = key, vehicleId = v:getId() }).ok == true, "登記車輛")
    driver(v)
    step()
    check(all(gc, function(p) return p:IsOpen() end) and gc.lanes[1]:getSprite():getName() == "MinidoracatKnoxPass_gate_c_136",
        "登記的車接近：六片一起開，錨點換成開啟 sprite（＋8）")
    moveCar(v, v._x, v._y + 40)
    runMs(3000)
    check(not gc.lanes[1]:IsOpen() and not gc.lanes[6]:IsOpen(), "車開走後關上")

    -- 拆除與打壞：整座一起移除、帳本刪除、柱面讀頭拿掉；拆除只退被拆那一端的材料
    local pipes = W.dropped["Base.MetalPipe"] or 0
    ISDismantleAction.complete({ thumpable = gc.A })
    check(gone(gc) and KP.Ledger.get(key) == nil and readersAt(400, 100) == "" and W.dropped["Base.MetalPipe"] == pipes + 4,
        "拆除大門 A 端門柱：整座移除、帳本刪除、柱面讀頭拿掉，只退一端的材料")
    ISDestroyStuffAction.complete({ item = b9.lanes[5] })
    check(gone(b9) and KP.Ledger.get("200,109,0W") == nil, "大錘敲雙桿閘門第 5 片：整座移除、內建讀頭的帳本刪除")
    fire("OnDestroyIsoThumpable", b6.B, nil)
    check(gone(b6) and KP.Ledger.get("101,100,0N") == nil, "雙桿閘門 B 端機箱被打壞：整座移除")
    for k = 1, 9 do ge.lanes[k]._square:transmitRemoveItemFromSquare(ge.lanes[k]) end
    check(present(ge.A) and present(ge.B), "（引擎）門片被打壞只拆門片鏈")
    step()
    check(not present(ge.A) and not present(ge.B) and W.dropped["Base.MetalPipe"] == pipes + 4,
        "大門的門片被打壞：下一個 tick 兩端門柱一起移除、不退料")
    clean(from, "模型門")

    -- 動畫補播（SP）：錨點姿勢是區塊起點＋32（打開）、＋48（關上）
    freshWorld("sp")
    from = #logLines + 1
    local me = newPlayer("me", 301, 103)
    W.locals = { me }
    local a = buildModelGate("MinidoracatKnoxPass_roll2f_white", 2, 4, "N", false, 300, 100, me).lanes[1]
    step()
    check(W.onLoadSprite["MinidoracatKnoxPass_gate_e_448"] ~= nil and W.onLoadSprite["MinidoracatKnoxPass_gate_e_456"] ~= nil
        and W.onLoadSprite["MinidoracatKnoxPass_gate_e_449"] == nil, "區塊載入收模型門的錨點（關、開），中間片不收")
    a:ToggleDoor(me)
    step()
    local function smTime(o) return W.spriteModels[o._smName]._time end
    check(a:isAnimating() and a._smName == "MinidoracatKnoxPass_roll2f_white_160" and smTime(a) < 0.1,
        "SP 開兩層樓捲門：錨點換成區塊起點＋32 的通道，從關的姿勢起步")
    runMs(1750)
    check(a._smName == "MinidoracatKnoxPass_roll2f_white_160" and math.abs(smTime(a) - 0.4375) < 0.011,
        "1.75 秒：同一個通道、時間 0.4375（1.75／4）")
    a:ToggleDoor(me)
    step()
    check(a._smName == "MinidoracatKnoxPass_roll2f_white_176" and math.abs(smTime(a) - 0.5) < 0.011,
        "2 秒時改成關：放下那組（＋48）的通道，從目前姿勢（0.5）接著往回走")
    runMs(2250)
    check(a._smName == nil and not a:isAnimating(), "走完：清掉姿勢、停止 animating")
    clean(from, "模型門動畫（SP）")
end

local tests = {
    scenarioParts, scenarioDock, scenarioDetection, scenarioAutoClose, scenarioLocks, scenarioCommands,
    scenarioSinglePlayer, scenarioLedger, scenarioCharging, scenarioReopen, scenarioUninstallOpen, scenarioGarage,
    scenarioDoubleDoorway, scenarioAutoDrive, scenarioLoadChunk, scenarioTagScript,
    scenarioTagHooks, scenarioPasses, scenarioWillOpenFor, scenarioBarrier, scenarioBarrierAnim, scenarioDriveWarn,
    scenarioReaderPost, scenarioColors, scenarioLoot, scenarioBarrierMirror, scenarioRollDoor, scenarioSettings,
    scenarioPassThrough, scenarioZombieLock, scenarioLockHold, scenarioModelGates,
}
for _, t in ipairs(tests) do t() end

out("")
if failures > 0 then
    out(failures .. " 項失敗")
    os.exit(1)
end
out("全部通過")
