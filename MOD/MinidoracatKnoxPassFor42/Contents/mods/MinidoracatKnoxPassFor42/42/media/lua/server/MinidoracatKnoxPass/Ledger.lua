-- 讀頭帳本：伺服器私有、隨世界存檔。用沒有任何物件的 GOS 系統存（家族 VehicleManager 帳本同做法）。
-- 不用 GlobalModData：任何已登入的 client 都能整表索取（GlobalModDataRequestPacket.java:15,32）；
-- 不用一般 GOS 物件：座標會在連線時送給所有 client（SGlobalObjects.java:103-130），等於公開所有基地位置。
-- media/lua/server 的檔 MP client 也會載入，這裡只在 server／SP 執行。
if isClient() then return end
require "Map/SGlobalObjectSystem"
require "MinidoracatKnoxPass/Core"
local KP = MinidoracatKnoxPass

local L = {}
KP.Ledger = L

local byTag = {}     -- 感應盒物品 ID → { [gateKey] = true }
local openKeys = {}  -- Knox Pass 開著、等著關的門
local version = 0    -- 哪顆感應盒能開哪些門有變動就加一（Sensor.lua 據此重推已授權大門給駕駛）

local System = SGlobalObjectSystem:derive("MinidoracatKnoxPassLedger")

function System:new()
    return SGlobalObjectSystem.new(self, "MinidoracatKnoxPass")
end

function System:initSystem()
    SGlobalObjectSystem.initSystem(self)
    -- 只存白名單鍵：漏掉就是本場正常、重啟後整本消失（SGlobalObjectSystem.java:220）
    self.system:setModDataKeys({ "state" })
    self.system:setObjectModDataKeys({})
    self.system:setObjectSyncKeys({})
    if type(self.state) ~= "table" then self.state = { version = 1, gates = {} } end
    if type(self.state.gates) ~= "table" then self.state.gates = {} end
    -- 原版在 new() 回傳後才設 instance（SGlobalObjectSystem.lua:246），先設免得 rebuild 讀不到
    System.instance = self
    L.rebuild()
    KP.log("ledger loaded gates=" .. L.count())
end

function System:getInitialStateForClient() return nil end
function System:isValidIsoObject() return false end
function System:newLuaObject() error("Knox Pass ledger owns no global objects") end
function System:OnChunkLoaded() end
function System:OnClientCommand() end

SGlobalObjectSystem.RegisterSystemClass(System)

function L.gates()
    local inst = System.instance
    return inst and inst.state and inst.state.gates or nil
end

function L.get(key)
    local gates = L.gates()
    return gates and gates[key] or nil
end

local function index(key, rec)
    for id in pairs(rec.tags) do
        byTag[id] = byTag[id] or {}
        byTag[id][key] = true
    end
    if rec.open then openKeys[key] = true end
end

function L.rebuild()
    byTag, openKeys = {}, {}
    version = version + 1
    local gates = L.gates()
    if not gates then return end
    for key, rec in pairs(gates) do index(key, rec) end
end

function L.version()
    return version
end

function L.put(key, rec)
    L.gates()[key] = rec
    index(key, rec)
    version = version + 1
end

-- 所有刪除路徑（拆讀頭、門不見了、閘門移除）都經過這裡：門柱上的讀頭模型一起拿掉（ReaderPost.lua）
function L.remove(key)
    local rec = L.get(key)
    if not rec then return end
    if KP.ReaderPost then KP.ReaderPost.detach(key, rec) end
    for id in pairs(rec.tags) do
        if byTag[id] then byTag[id][key] = nil end
    end
    openKeys[key] = nil
    L.gates()[key] = nil
    version = version + 1
end

function L.addTag(key, rec, id, info)
    rec.tags[id] = info
    byTag[id] = byTag[id] or {}
    byTag[id][key] = true
    version = version + 1
end

function L.removeTag(key, rec, id)
    rec.tags[id] = nil
    if byTag[id] then byTag[id][key] = nil end
    version = version + 1
end

-- 感應盒重新上色＝換成另一個物品（新 ID）：它登記的每一扇門改記新 ID（序號跟著 ID 換），重建索引。
-- version 加一，Sensor.lua 下一輪掃描就重推已授權大門。回傳改了幾扇門
function L.renameTag(oldId, newId)
    local n = 0
    for key in pairs(byTag[oldId] or {}) do
        local rec = L.get(key)
        local info = rec and rec.tags[oldId]
        if info then
            info.serial = KP.serial(newId)
            rec.tags[newId], rec.tags[oldId] = info, nil
            n = n + 1
        end
    end
    L.rebuild()
    return n
end

function L.gatesForTag(id)
    return byTag[id]
end

function L.setOpen(key, rec, open)
    rec.open = open or nil
    openKeys[key] = open or nil
end

function L.openKeys()
    return openKeys
end

function L.count()
    local n = 0
    for _ in pairs(L.gates() or {}) do n = n + 1 end
    return n
end
