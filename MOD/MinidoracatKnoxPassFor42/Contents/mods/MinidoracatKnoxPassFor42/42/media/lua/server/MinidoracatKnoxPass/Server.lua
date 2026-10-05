-- 伺服器指令：client 只送意圖（sendClientCommand），這裡重查一切再改世界。
-- 指令：install、uninstall、register、unregister、lock、open、query。回覆：state、result。
-- SP 的 sendServerCommand 是 no-op（LuaManager.java:8952-8970），回覆直接交給 client 的接收函式（家族 VM 同做法）。
if isClient() then return end
require "MinidoracatKnoxPass/Core"
require "MinidoracatKnoxPass/Gates"
require "MinidoracatKnoxPass/Ledger"
require "MinidoracatKnoxPass/Sensor"
require "MinidoracatKnoxPass/ReaderPost"
local KP = MinidoracatKnoxPass
local G = KP.Gates
local L = KP.Ledger
local S = KP.Sensor

local H = {}
KP.Handlers = H

local MAX_TAGS = 64
local RATE_WINDOW_MS, RATE_MAX = 10000, 20
local hits = {}

local function reply(player, command, payload)
    if isServer() then
        sendServerCommand(player, KP.MODULE, command, payload)
    elseif KP.clientReceive then
        KP.clientReceive(command, payload)
    end
end

local function result(player, command, ok, why, key)
    reply(player, "result", { cmd = command, ok = ok, why = why, key = key })
end
KP.reply = reply   -- Sensor.lua 推送已授權大門也走這裡

-- 原版零件安裝／拆下完成時由伺服器呼叫（vehicle_knoxpass_parts.txt 的 complete；ISInstallVehiclePart.lua:95-98、
-- ISUninstallVehiclePart.lua:65-67）：感應盒換車，它登記的每一扇門立刻改記新車；拆下來記成未裝在車上（script 留空）
local function retag(id, script)
    for key in pairs(L.gatesForTag(id) or {}) do
        local rec = L.get(key)
        local info = rec and rec.tags[id]
        if info then info.script = script end
    end
end

function KP.onTagInstalled(vehicle, part)
    local tag = part and part:getInventoryItem()
    if vehicle and KP.isTag(tag) then retag(tag:getID(), vehicle:getScriptName()) end
end

function KP.onTagUninstalled(vehicle, part, item)
    if KP.isTag(item) then retag(item:getID(), nil) end
end

local function limited(player)
    local who = player:getUsername() or "?"
    local now = getTimestampMs()
    local h = hits[who]
    if not h or now - h.start > RATE_WINDOW_MS then
        h = { start = now, n = 0 }
        hits[who] = h
    end
    h.n = h.n + 1
    return h.n > RATE_MAX
end

-- 擁有者（名字＋安裝時記下的 SteamID）或管理員；SP 沒有擁有權問題
local function canManage(player, rec)
    if not isServer() then return true end
    if KP.isAdmin(player) then return true end
    local name, sid = KP.principal(player)
    if not name or name ~= rec.owner then return false end
    return rec.sid == nil or sid == rec.sid
end

local function nearGate(player, rec)
    return KP.near(player, rec.x, rec.y, rec.z, KP.MANAGE_RANGE)
end

local function mark(anchor, owner, lock)
    local md = anchor:getModData()
    md[KP.MARKER_OWNER] = owner
    md[KP.MARKER_LOCK] = lock or nil
    anchor:transmitModData()
end

-- 點到的物件：先用 client 給的物件索引；對不上時，格子上只有一扇門才接受
local function doorAt(sq, index)
    local objects = sq:getObjects()
    if KP.isInt(index) and index >= 0 and index < objects:size() then
        local adapter, anchor = G.resolve(objects:get(index))
        if adapter then return adapter, anchor end
    end
    local foundAdapter, found
    for i = 0, objects:size() - 1 do
        local adapter, anchor = G.resolve(objects:get(i))
        if adapter then
            if found and found ~= anchor then return nil end
            foundAdapter, found = adapter, anchor
        end
    end
    return foundAdapter, found
end

-- 指令帶的 key 必須是帳本裡的門，而且操作者站在旁邊
local function gateFor(player, args)
    if type(args.key) ~= "string" then return nil, "BadArgs" end
    local rec = L.get(args.key)
    if not rec then return nil, "NoReader" end
    if not nearGate(player, rec) then return nil, "TooFar" end
    return rec
end

local function nearbyVehicles(rec)
    local seen, out = {}, {}
    local cx, cy, r = math.floor(rec.cx), math.floor(rec.cy), KP.REGISTER_RANGE
    for x = cx - r, cx + r do
        for y = cy - r, cy + r do
            local sq = getCell():getGridSquare(x, y, rec.z)
            local v = sq and sq:getVehicleContainer()
            if v and not seen[v] then
                seen[v] = true
                out[#out + 1] = v
            end
        end
    end
    return out
end

local function buildState(player, key, rec)
    local manager = canManage(player, rec)
    local state = {
        key = key, kind = rec.kind, owner = rec.owner, manager = manager, lock = rec.lock == true,
        open = rec.open == true, needPower = KP.sandbox("RequirePower") == true,
    }
    local adapter, anchor = G.findAt(rec)
    if adapter then
        state.powered = G.powered(G.pieces(adapter, anchor))
        state.lockSupported = G.supportsLock(adapter)
    end
    if not manager then return state end
    local now = getGameTime():getWorldAgeHours()
    local near = {}
    state.nearby = {}
    for _, v in ipairs(nearbyVehicles(rec)) do
        local tag = KP.vehicleTag(v)
        if tag then
            local id = tag:getID()
            local charge = math.floor(KP.charge(tag) * 100 + 0.5)
            near[id] = charge
            -- 感應盒可以換車（登記跟著物品 ID 走）：登記清單顯示最後一次看到它時的車，在這裡看到就跟著改
            if rec.tags[id] then rec.tags[id].script = v:getScriptName() end
            state.nearby[#state.nearby + 1] = {
                vid = v:getId(), serial = KP.serial(id), script = v:getScriptName(), charge = charge,
                dist = math.floor(math.max(math.abs(v:getX() - rec.cx), math.abs(v:getY() - rec.cy))),
                registered = rec.tags[id] ~= nil,
            }
        end
    end
    state.tags = {}
    for id, info in pairs(rec.tags) do
        state.tags[#state.tags + 1] = {
            id = id, serial = info.serial, script = info.script, charge = near[id],
            lastHours = info.last and (now - info.last) or nil,
        }
    end
    return state
end

function KP.sendState(player, key)
    local rec = L.get(key)
    if rec then reply(player, "state", buildState(player, key, rec)) end
end

-- 寫帳本並在錨點留標記（安裝讀頭、建好抬升閘門共用）。builtin＝閘門內建讀頭，不能單獨拆（H.uninstall）。
-- 門柱上放讀頭模型（閘門不放：機箱頂已有圓頂讀頭）
function KP.registerReader(adapter, anchor, name, sid, builtin)
    local key = G.key(anchor)
    local asq = anchor:getSquare()
    local cx, cy = G.center(G.pieces(adapter, anchor))
    local rec = {
        key = key, x = asq:getX(), y = asq:getY(), z = asq:getZ(), cx = cx, cy = cy,
        adapter = adapter.id, kind = G.kind(adapter, anchor), owner = name, sid = sid, builtin = builtin or nil,
        tags = {}, created = getGameTime():getWorldAgeHours(),
    }
    L.put(key, rec)
    -- 建造者身分無法驗證（分割畫面第 2-4 位，KP.principal 回 nil）時閘門沒有擁有者、只有管理員能管；
    -- 標記仍要非 nil，client 才知道這扇門裝了讀頭（Client.lua onFillMenu、KnoxPassAPI.willOpenFor）
    mark(anchor, name or "", false)
    KP.ReaderPost.attach(key, rec, adapter, anchor)
    KP.log("reader installed key=" .. key .. " owner=" .. tostring(name) .. (builtin and " builtin" or ""))
    return key
end

function H.install(player, args)
    local cmd = "install"
    if not (KP.isInt(args.x) and KP.isInt(args.y) and KP.isInt(args.z) and KP.isInt(args.itemId)) then
        return result(player, cmd, false, "BadArgs")
    end
    if player:getVehicle() then return result(player, cmd, false, "InVehicle") end
    local name, sid = KP.principal(player)
    if not name then return result(player, cmd, false, "Unverified") end
    if not KP.near(player, args.x, args.y, args.z, KP.MANAGE_RANGE) then return result(player, cmd, false, "TooFar") end
    local sq = getCell():getGridSquare(args.x, args.y, args.z)
    if not sq then return result(player, cmd, false, "NoGate") end
    if not SafeHouse.isSafehouseAllowInteract(sq, player) then return result(player, cmd, false, "Safehouse") end
    local adapter, anchor = doorAt(sq, args.index)
    if not adapter then return result(player, cmd, false, "NoGate") end
    local key = G.key(anchor)
    if L.get(key) then return result(player, cmd, false, "AlreadyInstalled", key) end
    local item = player:getInventory():getItemWithIDRecursiv(args.itemId)
    if not item or item:getFullType() ~= KP.READER_TYPE then return result(player, cmd, false, "NoReader") end
    local container = item:getContainer()
    player:removeFromHands(item)
    container:DoRemoveItem(item)
    if isServer() then sendRemoveItemFromContainer(container, item) end
    KP.registerReader(adapter, anchor, name, sid)
    result(player, cmd, true, nil, key)
    KP.sendState(player, key)
end

function H.uninstall(player, args)
    local cmd = "uninstall"
    if player:getVehicle() then return result(player, cmd, false, "InVehicle") end
    local rec, why = gateFor(player, args)
    if not rec then return result(player, cmd, false, why) end
    if not canManage(player, rec) then return result(player, cmd, false, "NotOwner", args.key) end
    if rec.builtin then return result(player, cmd, false, "BuiltIn", args.key) end
    local adapter, anchor = G.findAt(rec)
    if adapter then
        local pieces = G.pieces(adapter, anchor)
        -- Knox Pass 開著的門：盡量關上（擋住就留著開，交給玩家），關好才鎖回原本的鑰匙鎖
        if rec.open and G.isOpen(adapter, anchor) and not G.isBlocked(adapter, anchor) then
            G.setOpen(adapter, anchor, false, player)
        end
        if G.supportsLock(adapter) then
            if rec.lock then G.unlockKnox(adapter, anchor, pieces) end
            if rec.keyed and not G.isOpen(adapter, anchor) then G.lock(adapter, anchor, pieces, false, rec.keyed) end
        end
        mark(anchor, nil, nil)
    end
    L.remove(args.key)
    S.forget(args.key)
    local inv = player:getInventory()
    local item = inv:AddItem(KP.READER_TYPE)
    if item and isServer() then sendAddItemToContainer(inv, item) end
    KP.log("reader removed key=" .. args.key .. " by=" .. tostring(player:getUsername()))
    result(player, cmd, true, nil, args.key)
end

function H.register(player, args)
    local cmd = "register"
    local rec, why = gateFor(player, args)
    if not rec then return result(player, cmd, false, why) end
    if not canManage(player, rec) then return result(player, cmd, false, "NotOwner", args.key) end
    if not (KP.isInt(args.vehicleId) and args.vehicleId >= 0 and args.vehicleId <= 32767) then
        return result(player, cmd, false, "BadArgs", args.key)
    end
    local v = getVehicleById(args.vehicleId)
    if not v or math.abs(v:getZ() - rec.z) >= 1
        or math.max(math.abs(v:getX() - rec.cx), math.abs(v:getY() - rec.cy)) > KP.REGISTER_RANGE + 0.5 then
        return result(player, cmd, false, "VehicleTooFar", args.key)
    end
    local tag = KP.vehicleTag(v)
    if not tag then return result(player, cmd, false, "NoTag", args.key) end
    local id = tag:getID()
    if not rec.tags[id] then
        local count = 0
        for _ in pairs(rec.tags) do count = count + 1 end
        if count >= MAX_TAGS then return result(player, cmd, false, "TooMany", args.key) end
        L.addTag(args.key, rec, id, { serial = KP.serial(id), script = v:getScriptName(),
            at = getGameTime():getWorldAgeHours() })
    end
    result(player, cmd, true, nil, args.key)
    KP.sendState(player, args.key)
end

function H.unregister(player, args)
    local cmd = "unregister"
    local rec, why = gateFor(player, args)
    if not rec then return result(player, cmd, false, why) end
    if not canManage(player, rec) then return result(player, cmd, false, "NotOwner", args.key) end
    if not KP.isInt(args.tagId) then return result(player, cmd, false, "BadArgs", args.key) end
    L.removeTag(args.key, rec, args.tagId)
    result(player, cmd, true, nil, args.key)
    KP.sendState(player, args.key)
end

function H.lock(player, args)
    local cmd = "lock"
    local rec, why = gateFor(player, args)
    if not rec then return result(player, cmd, false, why) end
    if not canManage(player, rec) then return result(player, cmd, false, "NotOwner", args.key) end
    local adapter, anchor = G.findAt(rec)
    if not adapter then return result(player, cmd, false, "NoGate", args.key) end
    if not G.supportsLock(adapter) then return result(player, cmd, false, "NoLockSupport", args.key) end
    rec.lock = args.on == true or nil
    -- 門開著時只記下來，關好後由 Sensor 鎖上；關著就馬上套用
    if not rec.open and not G.isOpen(adapter, anchor) then
        local pieces = G.pieces(adapter, anchor)
        if rec.lock then G.lock(adapter, anchor, pieces, true, false) else G.unlockKnox(adapter, anchor, pieces) end
    end
    mark(anchor, rec.owner or "", rec.lock)
    result(player, cmd, true, nil, args.key)
    KP.sendState(player, args.key)
end

-- 身上帶著已登記、有電的感應盒
local function carriedTag(player, rec)
    local list = player:getInventory():getAllTypeRecurse(KP.TAG_TYPE)
    for i = 0, list:size() - 1 do
        local item = list:get(i)
        if rec.tags[item:getID()] and KP.charge(item) > 0 then return item end
    end
    return nil
end

function H.open(player, args)
    local cmd = "open"
    if player:getVehicle() then return result(player, cmd, false, "InVehicle") end
    local rec, why = gateFor(player, args)
    if not rec then return result(player, cmd, false, why) end
    local tag = nil
    if not canManage(player, rec) then
        tag = carriedTag(player, rec)
        if not tag then return result(player, cmd, false, "NotAllowed", args.key) end
    end
    local ok, reason = S.open(args.key, rec, player, tag, nil, nil, getTimestampMs())
    result(player, cmd, ok, reason, args.key)
end

function H.query(player, args)
    local rec, why = gateFor(player, args)
    if not rec then return result(player, "query", false, why) end
    reply(player, "state", buildState(player, args.key, rec))
end

local function onClientCommand(module, command, player, args)
    if module ~= KP.MODULE then return end
    local handler = H[command]
    if not handler or not player or type(args) ~= "table" then return end
    if limited(player) then return result(player, command, false, "RateLimited") end
    local ok, err = pcall(handler, player, args)
    if not ok then
        KP.log("command " .. tostring(command) .. " failed: " .. tostring(err))
        result(player, command, false, "Error")
    end
end

Events.OnClientCommand.Add(onClientCommand)
