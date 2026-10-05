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
        vehicleQueries = 0, postTx = 0,
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
}
function getCell() return cell end
function getGameTime() return { getWorldAgeHours = function() return W.hours end } end
function getSteamModeActive() return W.steam end
function ZombRand(a, b)
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
local USE_DELTA = { [TAG] = 0.001, ["Base.CarBattery1"] = 0.00001 }

local Item = {}
Item.__index = Item
function Item:getID() return self._id end
function Item:getFullType() return self._type end
function Item:getContainer() return self._container end
local Drain = setmetatable({}, { __index = Item })
Drain.__index = Drain
function Drain:getUseDelta() return self._useDelta end
function Drain:getCurrentUsesFloat() return self._uses * self._useDelta end
function Drain:setCurrentUsesFloat(v)   -- 量化到一格（Math.round）
    v = math.max(0, math.min(1, v))
    self._uses = math.floor(v / self._useDelta + 0.5)
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
    return new("InventoryItem", Item, { _id = id, _type = fullType })
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
function Container:getItemWithIDRecursiv(id)
    for _, it in ipairs(self._items) do if it._id == id then return it end end
    return nil
end
function Container:haveThisKeyId(id)   -- ItemContainer.java:3242-3255
    for _, it in ipairs(self._items) do if it._keyId == id then return it end end
    return nil
end
function Container:getAllTypeRecurse(t)
    local list = {}
    for _, it in ipairs(self._items) do if it._type == t then list[#list + 1] = it end end
    return javaList(list)
end
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
        },
    }, { _x = x + 0.5, _y = y + 0.5 })
    W.zombies[#W.zombies + 1] = zb
    return zb
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
function Base:sync() syncView(self) end
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
function Square:RemoveTileObject(o) if o._square == self then removeObj(o) end end
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

-- 閘門 tile 的 sprite（只要 getName）
local Sprite = {}
Sprite.__index = Sprite
function Sprite:getName() return self._name end
local function barrierSprite(i) return setmetatable({ _name = "MinidoracatKnoxPass_barrier_" .. i }, Sprite) end

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
function Door:syncIsoObject(bRemote) if not bRemote then syncView(self) end end
-- 車庫門：整條鏈一起翻，物件不重建；server 只 sync 被點的那片，client 依片段清單更新整組（D:3344-3393、1795-1815）。
-- 鏈照引擎的 First／Next 走（D:3282-3342）；閘門的片開關時換成 index±8 的 sprite（D:793-805）
local function garageChain(o)
    local out = {}
    local p = IsoDoor.getGarageDoorFirst(o) or o
    while p do
        out[#out + 1] = p
        p = IsoDoor.getGarageDoorNext(p)
    end
    return out
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
local function toggleGarage(o)
    local chain = garageChain(o)
    for _, p in ipairs(chain) do
        p._open = not p._open
        p:setLockedByKey(false)
        if p._tile then p._spriteObj = barrierSprite(p._tile + (p._open and 8 or 0)) end
    end
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
    -- IsoDoor(cell, sq, IsoSprite, north)（D:789-805）：不加進格子（呼叫端 AddSpecialObject）；
    -- 建構子照沙盒 lockedHouses 可能上鎖（D:820-840），這裡一律鎖上，證明 MOD 有解
    new = function(_, _sq, sprite, north)
        local i = tonumber(string.match(sprite:getName(), "_(%d+)$"))
        local tile = i >= 8 and i - 8 or i
        local d = new("IsoDoor", Door, {
            _open = i >= 8, _locked = true, _lockedByKey = true, _keyId = -1, _modData = {}, _north = north,
            _obstructed = false, _view = { modData = {} }, _spriteObj = sprite, _tile = tile, _garage = tile % 3 + 1,
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

local Vehicle = {}
Vehicle.__index = Vehicle
function Vehicle:getX() return self._x end
function Vehicle:getY() return self._y end
function Vehicle:getZ() return self._z end
function Vehicle:getId() return self._id end
function Vehicle:getDriver() return self._seats[0] end
function Vehicle:getPartById(id) return self._parts[id] end
function Vehicle:getScriptName() return self._script end
function Vehicle:getBatteryCharge() return self._battery end
function Vehicle:transmitPartUsedDelta() if isServer() then W.partDeltas = W.partDeltas + 1 end end   -- BaseVehicle.java:8235-8244
function Vehicle:isIntersectingSquare(x, y, z) return vehicleCovers(self, x, y, z) end
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
    if opts.tag then v._parts.KnoxPassTag._item = newItem(TAG, opts.tag) end
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
function VScript:copyPartsFrom(tmpl, id)   -- 同 id 整個換成 copy、新 id 就 add（VehicleScript.java:~1270）
    W.copyCalls = W.copyCalls + 1
    local src = tmpl:getPartById(id)
    local copy = { id = src.id, area = src.area, visible = src.visible, offset = src.offset, scale = src.scale, rotate = src.rotate }
    for i, p in ipairs(self._parts) do
        if p.id == id then
            self._parts[i] = copy
            return
        end
    end
    self._parts[#self._parts + 1] = copy
end
-- 對既有 part／model 只覆寫出現的欄位（VehicleScript.java:909-951、:693-722）；area 不是識別字就像 ScriptParser 一樣炸
function VScript:Load(_, body)
    local id = string.match(body, "part%s+([%w_]+)")
    local part = self:getPartById(id)
    for k, v in string.gmatch(body, "([%w_]+)%s*=%s*([^,\n]+),") do
        if k == "area" or k == "mechanicArea" then
            if not string.find(v, "^%a[%w_]*$") then error("ScriptParser: bad value " .. v) end
            if k == "area" then part.area = v end
        elseif k == "setAllModelsVisible" then
            part.visible = v == "true"
        elseif k == "offset" then
            local x, y, z = string.match(v, "^(%S+) (%S+) (%S+)$")
            part.offset = { tonumber(x), tonumber(y), tonumber(z) }
        elseif k == "rotate" then
            local x, y, z = string.match(v, "^(%S+) (%S+) (%S+)$")
            part.rotate = { tonumber(x), tonumber(y), tonumber(z) }
        elseif k == "scale" then
            part.scale = tonumber(v)
        end
    end
end
function getScriptManager()
    return {
        getVehicleTemplate = function(_, name)
            if name == "Base.KnoxPassParts" and W.template then return { getScript = function() return W.template end } end
            return nil
        end,
        getAllVehicleScripts = function() return javaList(W.scripts) end,
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
    "MinidoracatKnoxPass/Barrier", "MinidoracatKnoxPass/ReaderPost",
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
    local reader = owner._inv:AddItem(READER)
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

    W.template = newScript("Base.KnoxPassParts", { "Engine" }, { { "KnoxPassTag", "Engine" } })
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
    W.scripts = { car1, noSeat, van, weird, bike, foreign, big, huge, noArea, edge127, edge128, nose, sedan, modCar }
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

    -- 擋風玻璃上的固定座模型：offset＝(目標點－模型 offset)/車輛 scale、scale＝1/車輛 scale（Parts.lua KP.dockPlacement）
    local function dock(s)
        local p = s:getPartById("KnoxPassTag")
        return p and p.visible, p and p.offset, p and p.scale, p and p.rotate
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
    runMs(4500)
    check(a.door:IsOpen(), "登記車離開未滿 CloseDelay 不關")
    runMs(1000)
    check(not a.door:IsOpen() and rec(a).open == nil, "滿 CloseDelay 關門（範圍內沒登記的車不算）")
    check(not KP.Ledger.openKeys()[a.key], "關好後移出待關清單")

    -- 駕駛下車也算離開
    moveCar(va, a.cx, a.cy + 3)
    step()
    check(a.door:IsOpen(), "登記車回來重開")
    unseat(pa)
    runMs(5500)
    check(not a.door:IsOpen(), "駕駛下車後滿 CloseDelay 關門")

    -- 門口有角色
    local b = gate(200)
    local vb = car(b, 3, { tag = 0.5 })
    register(b, vb)
    driver(vb)
    step()
    moveCar(vb, vb._x, vb._y + 40)
    newZombie(200, 100)
    runMs(8000)
    check(b.door:IsOpen(), "門框格有殭屍 → 不關")
    W.zombies = {}
    local walker = newPlayer("walker", 200, 99)
    runMs(3000)
    check(b.door:IsOpen(), "門另一側那格有玩家 → 不關")
    walker._x = 210.5
    runMs(2250)
    check(not b.door:IsOpen(), "門口淨空後 2 秒內重試關上")

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
    runMs(5000 + 29500)
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
    local tx, deltas = W.customLockTx, W.partDeltas
    step()
    check(W.customLockTx - tx == 4, "下一次掃描先照關好的規則鎖回：四片都送出 CustomLock")
    check(a.door:IsOpen() and rec(a).open == true, "接著重新開門，帳本仍記開著")
    check(near(charge(va), 0.48) and W.partDeltas == deltas + 1, "重開扣電一次並同步")
    runMs(2000)
    check(near(charge(va), 0.48) and a.door:IsOpen(), "之後的掃描不再扣電")

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
        return not p:IsOpen() and p:isLocked() and not p:isLockedByKey() and p._view.locked == true
            and p._view.lockedByKey == false and p._modData.CustomLock == true and p._view.modData.CustomLock == true
    end), "關好後整組照原樣鎖回 locked（不升級成鑰匙鎖）＋門鎖並同步")
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

    -- IsoThumpable：殭屍站在第 2 片關著時的格子
    local b = openDouble(200, "IsoThumpable")
    check(b.door:IsOpen() and rec(b).doorway and rec(b).doorway[2].x == 201, "IsoThumpable 雙開門：開門並記下門口格")
    newZombie(201, 100)
    runMs(5500)
    check(b.door:IsOpen(), "第 2 片關著時的格子有殭屍 → 過了關門延遲也不關")
    runMs(2000)
    check(b.door:IsOpen(), "2 秒後重試仍不關")
    W.zombies = {}
    runMs(2250)
    check(not b.door:IsOpen() and locked(b), "殭屍離開後關上並鎖回（四片 lockedByKey 並同步）")
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

-- 伺服器剛載入有讀頭的大門格（LoadGridsquare，IsoChunk.java:3835）：節流歸零，下一個 tick 就掃描
local function scenarioLoadGridsquare()
    out("情境：載入有讀頭的格子立刻掃描")
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
    -- 時間只前進 ms，期間觸發 LoadGridsquare(sq)，再跑一次 OnTick
    local function tickAfter(v, ms, sq)
        nowMs = nowMs + ms
        moveCar(v, v._x, v._y - SPEED * ms / 1000)
        if sq then fire("LoadGridsquare", sq) end
        fire("OnTick")
    end

    local a = gate(100)
    check(a.door:hasModData() and a.door._modData.KnoxPassReader ~= nil, "錨點有讀頭標記")
    local va = approach(a)
    check(not a.door:IsOpen() and va._y - a.cy > 150, "最後一次掃描時在 150 格外，門關著")
    tickAfter(va, TICK, a.door:getSquare())
    check(a.door:IsOpen() and va._y - a.cy < 150,
        "載入錨點格後下一個 tick（33 ms）就掃描並開門（" .. string.format("%.1f", va._y - a.cy) .. " 格）")

    local b = gate(300)
    local vb = approach(b)
    tickAfter(vb, TICK, plain:getSquare())
    check(not b.door:IsOpen(), "反面：載入的是沒有讀頭標記的門格 → 33 ms 後不掃描、不開")
    tickAfter(vb, TICK, square(1000, 1000, 0))
    check(not b.door:IsOpen(), "反面：載入空格 → 66 ms 後仍不掃描")
    tickAfter(vb, 250 - 2 * TICK)
    check(b.door:IsOpen(), "滿 250 ms 照常掃描並開門")
    MDAD = nil
    clean(from, "LoadGridsquare")
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
-- N 面一列四格沿 +x（機箱、車道 1-3）；W 面四列沿 +y（車道 3、2、1、機箱）——同 entity_knoxpass_barrier.txt
local function buildBarrier(x, y, north, builder)
    local tiles = north and { { 0, 0, 6 }, { 1, 0, 0 }, { 2, 0, 1 }, { 3, 0, 2 } }
        or { { 0, 0, 5 }, { 0, 1, 4 }, { 0, 2, 3 }, { 0, 3, 7 } }
    local made = {}
    for _, t in ipairs(tiles) do
        -- _north 一律 false：entity 游標不更新 self.north，create 收到的 north 永遠是 false（barrier-mp 2026-10-05 實踩）
        local th = new("IsoThumpable", Thump, {
            _open = false, _locked = false, _lockedByKey = false, _keyId = -1, _modData = {}, _north = false,
            _obstructed = false, _view = { modData = {} }, _spriteObj = barrierSprite(t[3]),
            _isDoor = t[3] ~= 6 and t[3] ~= 7, _buildMaterials = { [KIT] = 1 }, _entityMulti = true,
        })
        syncView(th)
        square(x + t[1], y + t[2], 0):AddSpecialObject(th)
        local res = KP.Barrier.onCreate({ thumpable = th, character = builder, facing = north and "N" or "W" })
        made[t[3]] = res and res.replaceObject and res.object or th
    end
    return made
end
local function present(o) return o._square ~= nil end

local function scenarioBarrier()
    out("情境：抬升閘門（建造、內建讀頭、開關、擋車、拆除）")
    freshWorld()
    local from = #logLines + 1
    local builder = newPlayer("builder", 201, 103, { sid = 77 })
    local n = buildBarrier(200, 100, true, builder)
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

    local w = buildBarrier(300, 100, false, builder)
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
    step()
    check(n[0]:IsOpen() and n[1]:IsOpen() and n[2]:IsOpen() and KP.barrierIndex(n[0]) == 8 and KP.barrierIndex(n[2]) == 10,
        "已登記的車接近：三片一起開，換成開啟 sprite（＋8）")
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

    local d = buildBarrier(400, 100, true, builder)
    step()
    fire("OnDestroyIsoThumpable", d[6], nil)
    check(not present(d[0]) and not present(d[2]) and not present(d[6]) and KP.Ledger.get("401,100,0N") == nil,
        "機箱被打壞：整座移除、帳本刪除")
    -- 另外兩個方向的查找：N 向從車道找機箱（x-1）、W 向從機箱找車道 1（y-1）
    local nb = buildBarrier(700, 100, true, builder)
    local wb = buildBarrier(800, 100, false, builder)
    step()
    ISDestroyStuffAction.complete({ item = nb[1] })
    fire("OnDestroyIsoThumpable", wb[7], nil)
    check(not present(nb[6]) and not present(nb[0]) and not present(nb[2]) and KP.Ledger.get("701,100,0N") == nil
        and not present(wb[3]) and not present(wb[5]) and KP.Ledger.get("800,102,0W") == nil,
        "N 向大錘敲車道 2 連機箱一起移除；W 向機箱被打壞連車道一起移除")
    -- 殭屍／武器打壞車道：IsoDoor.destroyGarageDoor 逐片 destroy → transmitRemoveItemFromSquare（D:3460-3499、1385-1388），
    -- 原版只拆車道鏈；機箱、帳本、Sensor 狀態靠 OnObjectAboutToBeRemoved 記下、下一個 tick 收掉
    local z = buildBarrier(900, 100, true, builder)
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
    local s = buildBarrier(600, 100, true, couch)
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
    local a = buildBarrier(200, 100, true, me)[0]
    step()
    check(KP.Ledger.get("201,100,0N").owner == "me", "SP：建造者就是擁有者")
    a:ToggleDoor(me)   -- 車庫門本機 toggle 不播動畫（D:1582-1596）；假引擎同樣不設 animating
    step()
    check(a:isAnimating() and a._smName == "MinidoracatKnoxPass_barrier_16", "SP 開門：設 animating，從關的姿勢（16）起步")
    runMs(1750)
    check(a._smName == "MinidoracatKnoxPass_barrier_20", "約 2 秒：中間姿勢（20）")
    a:ToggleDoor(me)
    step()
    check(a._smName == "MinidoracatKnoxPass_barrier_52", "抬到一半改成放下：從目前姿勢接著走（換紅燈那組 52），不跳回端點")
    local inv = W.invalidated
    runMs(2000)
    check(a._smName == nil and not a:isAnimating() and W.invalidated > inv, "走完：清掉姿勢、停止 animating、重畫 chunk")
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
    check(cb ~= nil and W.onLoadSprite["MinidoracatKnoxPass_barrier_8"] == cb and W.onLoadSprite["MinidoracatKnoxPass_barrier_3"] == cb
        and W.onLoadSprite["MinidoracatKnoxPass_barrier_11"] == cb and W.onLoadSprite["MinidoracatKnoxPass_barrier_1"] == nil,
        "區塊載入只收錨點（N／W × 關／開四種 sprite）")
    cb(lanes[0])
    cb(lanes[1])   -- 不是錨點：不追
    lanes[0]:ToggleDoor(p)
    lanes[0]:setAnimating(true)   -- 錨點被同步：引擎自己 PlayAnimation（D:1657-1664、1795-1805）
    step()
    check(lanes[0]._smName == nil, "引擎已在播（錨點被同步）：不插手")
    lanes[0]:setAnimating(false)
    lanes[2]:ToggleDoor(p)       -- 有人點車道 3：錨點只在片段迴圈裡換 sprite、不播（D:1812-1834）
    step()
    check(lanes[0]:isAnimating() and lanes[0]._smName == "MinidoracatKnoxPass_barrier_56" and lanes[1]._smName == nil,
        "非錨點被同步、錨點沒播：補播（從開的姿勢往下放，紅燈那組 56），非錨點不動")
    square(201, 100, 0):transmitRemoveItemFromSquare(lanes[0])
    step()
    check(lanes[0]._smName == nil and not lanes[0]:isAnimating(), "錨點被移走：停止追蹤並還原")
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
    buildBarrier(300, 100, true, builder)
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
    fire("LoadGridsquare", square(150, 100, 0))
    check(postsAt(150, 100) == "", "LoadGridsquare 當下不改（等下一個 tick）")
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
    fire("LoadGridsquare", square(120, 100, 0))
    step()
    check(postsAt(120, 100) == "0" and present(dprop), "宿主格上變體不對、重複的移除，帳本那一個留著")
    local lonely = postObj(144, 100)
    KP.Ledger.get(kHalf).post = nil   -- 更新前裝的讀頭：帳本沒有 post、格上沒有模型
    removeObj(lonely)
    removeObj(postObj(150, 100))      -- 帳本有 post、模型不見：重開後不等 LoadGridsquare，開機對齊就補
    restart()
    W.unloaded["140,100,0"], W.unloaded["143,100,0"], W.unloaded["144,100,0"] = true, true, true
    step()
    check(KP.Ledger.get(kHalf).post == nil and postsAt(144, 100) == "", "重開：錨點格還沒載入的舊記錄先不動")
    check(postsAt(120, 100) == "0" and postsAt(160, 104) == "3" and postsAt(150, 100) == "2" and KP.Ledger.get(kWd).post.i == 3,
        "重開：已載入的格在帳本載入後第一個 tick 對齊（缺的補上），post 隨存檔保留、模型不重複")
    W.unloaded["140,100,0"], W.unloaded["143,100,0"], W.unloaded["144,100,0"] = nil, nil, nil
    fire("LoadGridsquare", square(143, 100, 0))
    step()
    check(KP.Ledger.get(kHalf).post and KP.Ledger.get(kHalf).post.i == 1 and postsAt(144, 100) == "1",
        "舊記錄：錨點格載入時補算門柱位置並放上模型")
    fire("LoadGridsquare", square(999, 999, 0))
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

local tests = {
    scenarioParts, scenarioDetection, scenarioAutoClose, scenarioLocks, scenarioCommands,
    scenarioSinglePlayer, scenarioLedger, scenarioCharging, scenarioReopen, scenarioUninstallOpen, scenarioGarage,
    scenarioDoubleDoorway, scenarioAutoDrive, scenarioLoadGridsquare, scenarioTagScript,
    scenarioTagHooks, scenarioPasses, scenarioWillOpenFor, scenarioBarrier, scenarioBarrierAnim, scenarioDriveWarn,
    scenarioReaderPost,
}
for _, t in ipairs(tests) do t() end

out("")
if failures > 0 then
    out(failures .. " 項失敗")
    os.exit(1)
end
out("全部通過")
