-- 伺服器指令：client 只送意圖（sendClientCommand），這裡重查一切再改世界。
-- 指令：install、uninstall、register、unregister、lock、settings、managers、findPlayers、open、close、query、recolor、
-- recolorReader。回覆：state（只給能管理這扇門的人）、players（共同管理者候選）、result。
-- SP 的 sendServerCommand 是 no-op（LuaManager.java:8952-8970），回覆直接交給 client 的接收函式（家族 VM 同做法）。
if isClient() then return end
require "MinidoracatKnoxPass/Core"
require "MinidoracatKnoxPass/Gates"
require "MinidoracatKnoxPass/Parts"
require "MinidoracatKnoxPass/Ledger"
require "MinidoracatKnoxPass/Watch"
require "MinidoracatKnoxPass/Sensor"
require "MinidoracatKnoxPass/ReaderPost"
local KP = MinidoracatKnoxPass
local G = KP.Gates
local L = KP.Ledger
local S = KP.Sensor

local H = {}
KP.Handlers = H

local MAX_TAGS = 64     -- 每扇門最多登記幾項（車與地圖手錶模組合計）
local MAX_BATCH = 100   -- 整批登記／取消登記一次最多幾台：大門 15 格內放不下這麼多車，擋特製客戶端送的超長清單
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
-- ISUninstallVehiclePart.lua:65-67）：感應盒換車，它登記的每一扇門立刻改記新車；拆下來記成未裝在車上（script 留空）。
-- 車上的 Dock 模型也在這裡切成該色／全關（KP.syncDock，Parts.lua）
local function retag(id, script)
    for key in pairs(L.gatesForTag(id) or {}) do
        local rec = L.get(key)
        local info = rec and rec.tags[id]
        if info then info.script = script end
    end
end

function KP.onTagInstalled(vehicle, part)
    KP.syncDock(vehicle, part)
    local tag = part and part:getInventoryItem()
    if vehicle and KP.isTag(tag) then retag(tag:getID(), vehicle:getScriptName()) end
end

function KP.onTagUninstalled(vehicle, part, item)
    KP.syncDock(vehicle, part)
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

-- 伺服器管理員（KP.hasAdminRole）；SP 只有一位玩家、沒有角色，一律算。「不會被破壞」只有管理員能改（H.settings）
local function adminOf(player)
    return not isServer() or KP.hasAdminRole(player)
end

-- 擁有者（名字＋安裝時記下的 SteamID）或管理員：拆讀頭、改共同管理者名單只看這個；SP 沒有擁有權問題
local function ownerOrAdmin(player, rec)
    if adminOf(player) then return true end
    local name, sid = KP.principal(player)
    if not name or name ~= rec.owner then return false end
    return rec.sid == nil or sid == rec.sid
end

-- 共同管理者：rec.co[帳號]＝加入時伺服器記下的 SteamID（Ledger.lua L.userSid；非 Steam 伺服器是 true），
-- 或擁有者現在所在陣營的領袖或成員（rec.coFaction，以名字判定，同分享給陣營），
-- 或和擁有者同在一間勾選的安全屋（rec.coHouses 的 key＝原生 owner 字串，KP.sharesHouse；擁有者離開那間就不算）。
-- 擁有者本人的名字不算：同名但 SteamID 不同的冒名者要擋在 ownerOrAdmin
local function coManager(player, rec)
    local name, sid = KP.principal(player)
    if not name or name == rec.owner then return false end
    local entry = rec.co and rec.co[name]
    if entry ~= nil then return entry == true or entry == sid end
    if rec.coFaction == true and KP.inFactionOf(rec.owner, name) then return true end
    for key in pairs(rec.coHouses or {}) do
        if KP.sharesHouse(key, rec.owner, name) then return true end
    end
    return false
end

-- 能管理這扇門（開管理視窗、設定、登記、上鎖、重新上色）：擁有者、管理員、共同管理者
local function canManage(player, rec)
    return ownerOrAdmin(player, rec) or coManager(player, rec)
end

-- 擁有者把這扇門分享給的人（rec.share＝"faction"／"safehouse"／"both"）：擁有者現在所在陣營的領袖或成員
-- （KP.inFactionOf），或和擁有者同在一間安全屋（屋主或成員，SafeHouse.java:288-290、:795-803）。
-- 名單是原版的、以名字判定，跟著擁有者現在的陣營與安全屋走。擁有者本人的名字不算：同名但 SteamID 不同的冒名者要擋在 canManage
local function sharedWith(player, rec)
    local share = rec.share
    if not share or not rec.owner then return false end
    local name = KP.principal(player)
    if not name or name == rec.owner then return false end
    if share ~= "safehouse" and KP.inFactionOf(rec.owner, name) then return true end
    return share ~= "faction" and SafeHouse.isInSameSafehouse(rec.owner, name)
end

local function nearGate(player, rec)
    return KP.near(player, rec.x, rec.y, rec.z, KP.MANAGE_RANGE)
end

-- 名單 { [帳號] = 任何值 } → { [帳號] = true }；空名單回 nil（Kahlua 沒有 next）
local function nameSet(co)
    local out = nil
    for name in pairs(type(co) == "table" and co or {}) do
        out = out or {}
        out[name] = true
    end
    return out
end

-- 錨點標記（右鍵選單決定長相用，伺服器不信它）：照帳本寫；rec＝nil 時全部拿掉（拆讀頭）。
-- 共同管理者只帶名字，不帶 SteamID
local function mark(anchor, rec)
    local md = anchor:getModData()
    md[KP.MARKER_OWNER] = rec and (rec.owner or "") or nil
    md[KP.MARKER_LOCK] = rec and rec.lock or nil
    md[KP.MARKER_COLOR] = rec and rec.color ~= 0 and rec.color or nil   -- 只給右鍵選單列出「其他顏色」用
    md[KP.MARKER_SPEED] = rec and rec.speed == "fast" and "fast" or nil   -- client 選開關動畫（BarrierAnim.lua）
    md[KP.MARKER_CO] = rec and nameSet(rec.co) or nil
    md[KP.MARKER_COFACTION] = rec and rec.coFaction or nil
    md[KP.MARKER_COHOUSES] = rec and nameSet(rec.coHouses) or nil
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

-- 線上戴著 Knox Pass 模組的人：序號 → 玩家（不管有沒有電）。只在開視窗、每次操作與登記時算，線上人數一輪
local function wearers()
    local out = {}
    KP.eachPlayer(function(p)
        local s = KP.wornSerial(p)
        if s then out[s] = p end
    end)
    return out
end

-- 在大門 15 格內、同一層（和登記車輛同一個範圍：registerOne）
local function nearForRegister(obj, rec)
    return math.abs(obj:getZ() - rec.z) < 1
        and math.max(math.abs(obj:getX() - rec.cx), math.abs(obj:getY() - rec.cy)) <= KP.REGISTER_RANGE + 0.5
end

local function gateDist(obj, rec)
    return math.floor(math.max(math.abs(obj:getX() - rec.cx), math.abs(obj:getY() - rec.cy)))
end

-- 名字照字母序（不分大小寫）；專案禁用 table.sort（verify_mod.py），名單最多幾十個，用插入排序
local function sortedNames(set)
    local out = {}
    for name in pairs(set or {}) do
        local i = #out
        while i >= 1 and string.lower(out[i]) > string.lower(name) do
            out[i + 1] = out[i]
            i = i - 1
        end
        out[i + 1] = name
    end
    return out
end

local function factionName(owner)
    local f = owner and Faction.getPlayerFaction(owner)
    return f and f:getName() or nil
end

-- 這間的屋主與成員（跨每一塊、不重複）：帳號不能含 @（ServerWorldDatabase.java:770），含 @ 的是家族 Safehouse 的服務帳號，不算人
local function addMembers(sh, seen)
    local owner = sh:getOwner()
    if not string.find(owner, "@", 1, true) then seen[owner] = true end
    local players = sh:getPlayers()                              -- SafeHouse.java:640-642
    for i = 0, players:size() - 1 do
        local u = players:get(i)
        if not string.find(u, "@", 1, true) then seen[u] = true end
    end
end

-- 勾選的在前（還有效的再前），其餘照屋名（不分大小寫）
local function houseBefore(a, b)
    local ra, rb = a.on and (a.gone and 1 or 0) or 2, b.on and (b.gone and 1 or 0) or 2
    if ra ~= rb then return ra < rb end
    return string.lower(a.title or "") < string.lower(b.title or "")
end

-- 名單視窗的安全屋（state.houses）：擁有者現在所在的每一間（屋主或成員，同 KP.sharesHouse），同一個原生 owner 的每一塊算一間。
-- canEdit＝false（共同管理者）只列勾選的：擁有者還在哪些安全屋，不給他們看。勾著但找不到、或擁有者已不在裡面的列成 gone：
-- 勾選留著、擁有者回去就恢復，擁有者關掉才移除（使用者 2026-10-20）。帳本順手記下最新屋名，找不到時照它顯示。
-- 最多 KP.MAX_HOUSES 間；專案禁用 table.sort（verify_mod.py），用插入排序
local function ownerHouses(rec, canEdit)
    local picked, out, byKey, seen = rec.coHouses or {}, {}, {}, {}
    local list = SafeHouse.getSafehouseList()                    -- SafeHouse.java:652
    for i = 0, (rec.owner and list:size() or 0) - 1 do
        local sh = list:get(i)
        local key = sh:getOwner()
        if (canEdit or picked[key]) and sh:playerAllowed(rec.owner) then
            local h = byKey[key]
            if not h then
                h = { key = key, title = sh:getTitle() or "", on = picked[key] ~= nil,
                    owner = not string.find(key, "@", 1, true) and key or nil }   -- 家族 Safehouse：客戶端問它的 ownerName
                byKey[key], seen[key] = h, {}
                out[#out + 1] = h
            end
            addMembers(sh, seen[key])
        end
    end
    for _, h in ipairs(out) do
        local n = 0
        for _ in pairs(seen[h.key]) do n = n + 1 end
        h.members = n
        if h.on then picked[h.key] = h.title end
    end
    for key, title in pairs(picked) do
        if not byKey[key] then out[#out + 1] = { key = key, title = title, on = true, gone = true } end
    end
    for i = 2, #out do
        local h, j = out[i], i - 1
        while j >= 1 and houseBefore(h, out[j]) do
            out[j + 1] = out[j]
            j = j - 1
        end
        out[j + 1] = h
    end
    for i = #out, KP.MAX_HOUSES + 1, -1 do out[i] = nil end
    return out
end

-- 只有能管理這扇門的人拿得到（KP.sendState 先查 canManage）
local function buildState(player, key, rec)
    local rangeLo, rangeHi = KP.settingBounds("ReadRange")
    local delayLo, delayHi = KP.settingBounds("CloseDelay")
    -- 每扇門的設定：range／delay＝生效值；rangeSet／delaySet＝擁有者設的值（nil＝跟沙盒預設走）；上下限來自沙盒。
    -- cx／cy＝感應距離量起的中心（視窗在地上畫範圍圈）。共同管理者：個別帳號（照字母序）、陣營開關、擁有者現在的陣營名、
    -- 安全屋（ownerHouses：擁有者與管理員拿到全部候選，共同管理者只拿到勾選的）；
    -- ownerOrAdmin＝能改共同管理者名單、能拆讀頭；indestructible＝生效值（沙盒或這扇門），indestructibleAll＝沙盒對所有大門開著，
    -- isAdmin＝能替這扇門開關「不會被破壞」；indoor＝這扇門「算室內」，門載入時另帶 indoorSupport（Gates.lua G.indoorSupport）
    -- 與 indoorCut（模型門與閘門：勾了以後門片擋住角色時被切掉，說明多一句）
    local canEdit = ownerOrAdmin(player, rec)
    local state = {
        key = key, kind = rec.kind, owner = rec.owner, lock = rec.lock == true,
        open = rec.open == true, needPower = KP.sandbox("RequirePower") == true, cx = rec.cx, cy = rec.cy,
        range = KP.gateRange(rec), rangeSet = rec.range, rangeMin = rangeLo, rangeMax = rangeHi,
        rangeDefault = KP.clampSetting("ReadRange", tonumber(KP.sandbox("ReadRange")) or 8),
        delay = KP.gateDelay(rec), delaySet = rec.closeDelay, delayMin = delayLo, delayMax = delayHi,
        delayDefault = KP.clampSetting("CloseDelay", tonumber(KP.sandbox("CloseDelay")) or 2),
        speed = rec.speed == "fast" and "fast" or "default", share = rec.share or "none", maxTags = MAX_TAGS,
        walk = rec.walk ~= false, walkSupported = KP.watchSensing(),   -- 這扇門的手錶步行感應（沒有＝開）
        indoor = rec.indoor == true,
        ownerOrAdmin = canEdit, co = sortedNames(rec.co), coFaction = rec.coFaction == true,
        ownerFaction = factionName(rec.owner), maxManagers = KP.MAX_MANAGERS, houses = ownerHouses(rec, canEdit),
        indestructible = KP.gateIndestructible(rec), indestructibleAll = KP.sandbox("Indestructible") == true,
        isAdmin = adminOf(player),
    }
    local adapter, anchor = G.findAt(rec)
    if adapter then
        state.powered = G.powered(G.pieces(adapter, anchor))
        state.lockSupported = G.supportsLock(adapter)
        state.speedSupported = KP.speedSupported(anchor)
        state.lockAllowed = KP.lockAllowedAt(anchor:getSquare(), rec.owner)   -- 沙盒「安全屋外的讀頭」
        state.hp, state.hpFull = S.durability(adapter, anchor)   -- 耐久：剩下最少的那一片（不會被破壞時視窗不寫數字）
        state.indoorSupport = G.indoorSupport(adapter, anchor)
        state.indoorCut = KP.gateKind(anchor) ~= nil
    end
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
                dist = gateDist(v, rec),
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
    -- 手錶模組：正戴著它的線上玩家只給名字，不給位置；沒人戴時寫上次是誰、何時從這扇門通過。
    -- 附近＝15 格內戴著模組、這扇門還沒登記的人（active＝錶有電、槽位有效，現在就能用）
    local wearing = wearers()
    state.mods = {}
    for s, info in pairs(rec.mods or {}) do
        local p = wearing[s]
        state.mods[#state.mods + 1] = { id = s, serial = KP.serial(s), wearer = p and p:getUsername() or nil,
            lastBy = info.by, lastHours = info.last and (now - info.last) or nil }
    end
    state.nearMods = {}
    for s, p in pairs(wearing) do
        if not (rec.mods and rec.mods[s]) and nearForRegister(p, rec) then
            state.nearMods[#state.nearMods + 1] = { id = s, serial = KP.serial(s), name = p:getUsername(),
                dist = gateDist(p, rec), active = KP.watchSerial(p) == s }
        end
    end
    return state
end

-- 這扇門的設定與清單只送給能管理的人：所有回 state 的路徑（查詢、各項操作之後）都經過這裡
function KP.sendState(player, key)
    local rec = L.get(key)
    if rec and canManage(player, rec) then reply(player, "state", buildState(player, key, rec)) end
end

-- 寫帳本並在錨點留標記（安裝讀頭、建好抬升閘門共用）。builtin＝閘門內建讀頭，不能單獨拆（H.uninstall）。
-- color＝裝上去的讀頭顏色索引（拆下退回同色；閘門內建讀頭不記）。門柱上放讀頭模型（閘門不放：機箱頂已有圓頂讀頭）
function KP.registerReader(adapter, anchor, name, sid, builtin, color)
    local key = G.key(anchor)
    local asq = anchor:getSquare()
    local cx, cy = G.center(G.pieces(adapter, anchor))
    local rec = {
        key = key, x = asq:getX(), y = asq:getY(), z = asq:getZ(), cx = cx, cy = cy,
        adapter = adapter.id, kind = G.kind(adapter, anchor), owner = name, sid = sid, builtin = builtin or nil,
        color = color, tags = {}, created = getGameTime():getWorldAgeHours(),
    }
    L.put(key, rec)
    -- 建造者身分無法驗證（分割畫面第 2-4 位，KP.principal 回 nil）時閘門沒有擁有者、只有管理員能管；
    -- 標記仍要非 nil，client 才知道這扇門裝了讀頭（Client.lua onFillMenu、KnoxPassAPI.willOpenFor）
    mark(anchor, rec)
    KP.ReaderPost.attach(key, rec, adapter, anchor)
    S.shield(rec, adapter, anchor)   -- 沙盒「不會被破壞」開著時，新裝的門馬上墊高耐久
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
    if not KP.screwdriverOf(player) then return result(player, cmd, false, "NeedScrewdriver") end   -- 選單也查，這裡重驗
    local sq = getCell():getGridSquare(args.x, args.y, args.z)
    if not sq then return result(player, cmd, false, "NoGate") end
    if not SafeHouse.isSafehouseAllowInteract(sq, player) then return result(player, cmd, false, "Safehouse") end
    local adapter, anchor = doorAt(sq, args.index)
    if not adapter then return result(player, cmd, false, "NoGate") end
    local key = G.key(anchor)
    if L.get(key) then return result(player, cmd, false, "AlreadyInstalled", key) end
    -- 沙盒「安全屋外的讀頭」＝不能安裝：門要在安裝者自己的安全屋裡（屋主或成員）
    if not KP.installAllowedAt(anchor:getSquare(), name) then return result(player, cmd, false, "InstallSafehouseOnly") end
    local item = player:getInventory():getItemWithIDRecursiv(args.itemId)
    if not KP.isReader(item) then return result(player, cmd, false, "NoReader") end
    local container = item:getContainer()
    player:removeFromHands(item)
    container:DoRemoveItem(item)
    if isServer() then sendRemoveItemFromContainer(container, item) end
    KP.registerReader(adapter, anchor, name, sid, nil, KP.colorOf(item))
    result(player, cmd, true, nil, key)
    KP.sendState(player, key)
end

function H.uninstall(player, args)
    local cmd = "uninstall"
    if player:getVehicle() then return result(player, cmd, false, "InVehicle") end
    local rec, why = gateFor(player, args)
    if not rec then return result(player, cmd, false, why) end
    -- 拆讀頭只限擁有者與管理員：共同管理者回 OwnerOnly（讀頭會歸拆的人、全部登記一起清掉）
    if not ownerOrAdmin(player, rec) then
        return result(player, cmd, false, canManage(player, rec) and "OwnerOnly" or "NotOwner", args.key)
    end
    if rec.builtin then return result(player, cmd, false, "BuiltIn", args.key) end
    if not KP.screwdriverOf(player) then return result(player, cmd, false, "NeedScrewdriver", args.key) end
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
        S.shield(rec, adapter, anchor, false)   -- 不會被破壞的門還原耐久
        mark(anchor, nil)
        if rec.indoor then G.syncRegions(pieces) end   -- 算室內：照門現在的樣子重算，不留下記成牆的紀錄
    end
    L.remove(args.key)
    S.forget(args.key)
    local inv = player:getInventory()
    local item = inv:AddItem(KP.colorType(KP.READER_TYPE, rec.color or 0))   -- 退回同色；舊記錄沒有 color＝米白
    if item and isServer() then sendAddItemToContainer(inv, item) end
    KP.log("reader removed key=" .. args.key .. " by=" .. tostring(player:getUsername()))
    result(player, cmd, true, nil, args.key)
end

-- 管理視窗勾選的一批 ID：先整批驗型別，有一個不合格就整批不收（BadArgs）
local function batchOf(ids, valid)
    if type(ids) ~= "table" or #ids == 0 or #ids > MAX_BATCH then return nil end
    for i = 1, #ids do
        if not valid(ids[i]) then return nil end
    end
    return ids
end

local function vehicleIdOk(v) return KP.isInt(v) and v >= 0 and v <= 32767 end
local function serialOk(v) return KP.isInt(v) and v > 0 end

-- 送來的 ID 清單：沒送＝空；送了就要是合格的一批（batchOf）
local function idsOf(ids, valid)
    if ids == nil then return {} end
    return batchOf(ids, valid)
end

-- 登記一台：回傳 true（added＝這次新加）或 false, 原因。count＝這扇門目前登記了幾項
local function registerOne(key, rec, vid, count)
    local v = getVehicleById(vid)
    if not v or not nearForRegister(v, rec) then return false, "VehicleTooFar" end
    local tag = KP.vehicleTag(v)
    if not tag then return false, "NoTag" end
    local id = tag:getID()
    if rec.tags[id] then return true end   -- 已登記的再登記一次算成功，不受上限影響
    if count >= MAX_TAGS then return false, "TooMany" end
    L.addTag(key, rec, id, { serial = KP.serial(id), script = v:getScriptName(), at = getGameTime():getWorldAgeHours() })
    return true, nil, true
end

-- 登記一顆手錶模組：不信客戶端的清單，重查「這個序號正戴在 15 格內的人身上」才收（擁有者自己的模組也要登記）
local function registerModule(key, rec, serial, wearing, count)
    local p = wearing[serial]
    if not (p and nearForRegister(p, rec)) then return false, "WearerTooFar" end
    if rec.mods and rec.mods[serial] then return true end
    if count >= MAX_TAGS then return false, "TooMany" end
    L.addModule(key, rec, serial, { at = getGameTime():getWorldAgeHours() })
    return true, nil, true
end

-- 整批登記（vehicleIds 車、modIds 手錶模組序號，至少一項）：一個指令處理整批，頻率限制只算一次、state 只回一次。
-- 逐項檢查距離、感應盒與上限（車與模組合計），回覆帶 done＝成功幾項、failed＝沒成功幾項、why＝第一個沒成功的原因
function H.register(player, args)
    local cmd = "register"
    local rec, why = gateFor(player, args)
    if not rec then return result(player, cmd, false, why) end
    if not canManage(player, rec) then return result(player, cmd, false, "NotOwner", args.key) end
    local vids, mids = idsOf(args.vehicleIds, vehicleIdOk), idsOf(args.modIds, serialOk)
    if not (vids and mids) or #vids + #mids == 0 or #vids + #mids > MAX_BATCH then
        return result(player, cmd, false, "BadArgs", args.key)
    end
    local count = L.passCount(rec)
    local done, failed, first = 0, 0, nil
    local function tally(ok, reason, added)
        if ok then
            done = done + 1
            if added then count = count + 1 end
        else
            failed, first = failed + 1, first or reason
        end
    end
    for i = 1, #vids do tally(registerOne(args.key, rec, vids[i], count)) end
    local wearing = #mids > 0 and wearers() or nil
    for i = 1, #mids do tally(registerModule(args.key, rec, mids[i], wearing, count)) end
    reply(player, "result", { cmd = cmd, ok = done > 0, why = first, key = args.key, done = done, failed = failed })
    KP.sendState(player, args.key)
end

-- 整批取消登記（tagIds 感應盒、modIds 手錶模組序號）：不在這扇門的略過（已經不在了），done＝這次真的拿掉幾項
function H.unregister(player, args)
    local cmd = "unregister"
    local rec, why = gateFor(player, args)
    if not rec then return result(player, cmd, false, why) end
    if not canManage(player, rec) then return result(player, cmd, false, "NotOwner", args.key) end
    local tids, mids = idsOf(args.tagIds, KP.isInt), idsOf(args.modIds, serialOk)
    if not (tids and mids) or #tids + #mids == 0 or #tids + #mids > MAX_BATCH then
        return result(player, cmd, false, "BadArgs", args.key)
    end
    local done = 0
    for i = 1, #tids do
        if rec.tags[tids[i]] then
            L.removeTag(args.key, rec, tids[i])
            done = done + 1
        end
    end
    for i = 1, #mids do
        if rec.mods and rec.mods[mids[i]] then
            L.removeModule(args.key, rec, mids[i])
            done = done + 1
        end
    end
    reply(player, "result", { cmd = cmd, ok = true, key = args.key, done = done, failed = 0 })
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
    -- 沙盒「安全屋外的讀頭」＝不能上鎖（或不能安裝）：門要在讀頭擁有者的安全屋裡才能開門鎖；關掉門鎖不受限
    if args.on == true and not rec.lock and not KP.lockAllowedAt(anchor:getSquare(), rec.owner) then
        return result(player, cmd, false, "LockSafehouseOnly", args.key)
    end
    rec.lock = args.on == true or nil
    -- 門開著時只記下來，關好後由 Sensor 處理（settleClosed）；關著就馬上套用
    if not rec.open and not G.isOpen(adapter, anchor) then
        local pieces = G.pieces(adapter, anchor)
        if rec.lock then G.lock(adapter, anchor, pieces, true, false) else G.unlockKnox(adapter, anchor, pieces) end
        rec.unlockOnClose = nil
    else
        rec.unlockOnClose = not rec.lock or nil
    end
    mark(anchor, rec)
    result(player, cmd, true, nil, args.key)
    KP.sendState(player, args.key)
end

-- 每扇門的感應距離、關門延遲、開關速度、分享對象、手錶步行感應與不會被破壞（能管理這扇門的人、站在門邊；不會被破壞只限管理員）。
-- 值：整數＝新值（夾在沙盒上下限內），"default"＝改回跟著沙盒預設，沒送＝不改。回傳 ok, 值（false＝改回預設、nil＝不改）
local function settingArg(v)
    if v == nil then return true, nil end
    if v == "default" then return true, false end
    return KP.isInt(v), v
end

-- 開關速度："fast"＝加速、"default"＝改回正常、沒送＝不改
local function speedArg(v)
    if v == nil then return true, nil end
    if v == "default" then return true, false end
    return v == "fast", v
end

-- 分享對象（sharedWith）："faction"／"safehouse"／"both"、"none"＝不分享、沒送＝不改
local SHARES = { faction = true, safehouse = true, both = true }
local function shareArg(v)
    if v == nil then return true, nil end
    if v == "none" then return true, false end
    return SHARES[v] == true, v
end

function H.settings(player, args)
    local cmd = "settings"
    local rec, why = gateFor(player, args)
    if not rec then return result(player, cmd, false, why, args.key) end   -- 帶 key：視窗的下拉選單要回到原值
    if not canManage(player, rec) then return result(player, cmd, false, "NotOwner", args.key) end
    local okR, range = settingArg(args.range)
    local okD, delay = settingArg(args.delay)
    local okS, speed = speedArg(args.speed)
    local okH, share = shareArg(args.share)
    local okW = args.walk == nil or type(args.walk) == "boolean"   -- 手錶步行感應：true／false、沒送＝不改
    local okI = args.indestructible == nil or type(args.indestructible) == "boolean"   -- 不會被破壞：同上
    local okIn = args.indoor == nil or type(args.indoor) == "boolean"   -- 算室內：同上
    if not (okR and okD and okS and okH and okW and okI and okIn) then return result(player, cmd, false, "BadArgs", args.key) end
    -- 擁有者與共同管理者也改不了：誰都能替自己的門開的話，等於整台伺服器都開
    if args.indestructible ~= nil and not adminOf(player) then return result(player, cmd, false, "AdminOnly", args.key) end
    -- 速度存在帳本，也標在錨點給 client 選動畫；算室內當下就改室內紀錄。兩者都要門載入
    local adapter, anchor = nil, nil
    if speed ~= nil or args.indoor ~= nil then
        adapter, anchor = G.findAt(rec)
        if not adapter then return result(player, cmd, false, "NotLoaded", args.key) end
        if speed and not KP.speedSupported(anchor) then return result(player, cmd, false, "NoSpeedSupport", args.key) end
        -- 只有車庫門鏈能勾（管理視窗對其他門停用）；取消一律可以
        if args.indoor and G.indoorSupport(adapter, anchor) ~= "yes" then return result(player, cmd, false, "BadArgs", args.key) end
    end
    if range ~= nil then rec.range = range and KP.clampSetting("ReadRange", range) or nil end
    if delay ~= nil then rec.closeDelay = delay and KP.clampSetting("CloseDelay", delay) or nil end
    if share ~= nil then rec.share = share or nil end
    if args.walk == false then rec.walk = false elseif args.walk == true then rec.walk = nil end   -- 沒有＝開，舊存檔不用轉換
    if speed ~= nil then
        rec.speed = speed or nil
        mark(anchor, rec)
    end
    -- 算室內：勾了就把門片記成牆（開著也是），取消就照門現在的樣子重算（Gates.lua G.syncRegions）
    if args.indoor ~= nil then
        rec.indoor = args.indoor or nil
        G.syncRegions(G.pieces(adapter, anchor), rec.indoor)
    end
    if args.indestructible ~= nil then
        rec.indestructible = args.indestructible or nil
        local a, an = G.findAt(rec)
        if a then S.shield(rec, a, an) end   -- 門沒載入時由 Sensor 每 5 秒的巡檢補上
    end
    KP.log("settings key=" .. args.key .. " range=" .. tostring(rec.range) .. " delay=" .. tostring(rec.closeDelay)
        .. " speed=" .. tostring(rec.speed) .. " share=" .. tostring(rec.share) .. " walk=" .. tostring(rec.walk ~= false)
        .. " indestructible=" .. tostring(rec.indestructible == true) .. " indoor=" .. tostring(rec.indoor == true)
        .. " by=" .. tostring(player:getUsername()))
    result(player, cmd, true, nil, args.key)
    KP.sendState(player, args.key)
end

-- 身上帶著已登記、有電的感應盒
local function carriedTag(player, rec)
    local list = player:getInventory():getAllEvalRecurse(KP.isTag)   -- 7 色都算（ItemContainer.java:1936）
    for i = 0, list:size() - 1 do
        local item = list:get(i)
        if rec.tags[item:getID()] and KP.charge(item) > 0 then return item end
    end
    return nil
end

-- ── 重新上色：原版油漆一格＋油漆刷（KP.paintFor），動畫在 client 的計時動作 ──────────────

-- 身上（含背包）的感應盒或讀頭換成另一色：新物品放回同一個容器，電量與狀態照抄；感應盒的登記改記新 ID（L.renameTag）。
-- 裝在車上的感應盒不在玩家物品欄，找不到＝NotCarried（要先用維修面板拆下）
function H.recolor(player, args)
    local cmd = "recolor"
    if not (KP.isInt(args.itemId) and KP.isColor(args.color)) then return result(player, cmd, false, "BadColor") end
    local item = player:getInventory():getItemWithIDRecursiv(args.itemId)
    local from = KP.colorOf(item)
    if from == nil then return result(player, cmd, false, "NotCarried") end
    if from == args.color then return result(player, cmd, false, "BadColor") end
    local paint, why = KP.paintFor(player, args.color)
    if not paint then return result(player, cmd, false, why) end
    local isTag = KP.isTag(item)
    local container = item:getContainer()
    local fresh = container:AddItem(KP.colorType(isTag and KP.TAG_TYPE or KP.READER_TYPE, args.color))
    if not fresh then return result(player, cmd, false, "Error") end
    if isTag then KP.setCharge(fresh, KP.charge(item)) end
    fresh:setCondition(item:getCondition())
    player:removeFromHands(item)
    container:DoRemoveItem(item)
    if isServer() then
        sendRemoveItemFromContainer(container, item)
        sendAddItemToContainer(container, fresh)
    end
    local gates = isTag and L.renameTag(item:getID(), fresh:getID()) or 0
    paint:UseAndSync()   -- 用掉一格並同步（InventoryItem.java:1275-1277→DrainableComboItem.java:322-383；用完換成空桶）
    KP.log("recolor " .. tostring(item:getFullType()) .. " -> " .. tostring(fresh:getFullType()) .. " gates=" .. gates
        .. " by=" .. tostring(player:getUsername()))
    result(player, cmd, true)
end

-- 已裝在門上的讀頭改色：擁有者或管理員、站在門邊；帳本改 rec.color、門柱模型換色（ReaderPost.refresh），登記不動。
-- 抬升閘門的內建讀頭不分顏色
function H.recolorReader(player, args)
    local cmd = "recolorReader"
    if player:getVehicle() then return result(player, cmd, false, "InVehicle") end
    local rec, why = gateFor(player, args)
    if not rec then return result(player, cmd, false, why) end
    if not canManage(player, rec) then return result(player, cmd, false, "NotOwner", args.key) end
    if rec.builtin then return result(player, cmd, false, "BarrierColor", args.key) end
    if not KP.isColor(args.color) or args.color == (rec.color or 0) then return result(player, cmd, false, "BadColor", args.key) end
    local paint, pwhy = KP.paintFor(player, args.color)
    if not paint then return result(player, cmd, false, pwhy, args.key) end
    paint:UseAndSync()
    rec.color = args.color
    KP.ReaderPost.refresh(args.key, rec)
    local adapter, anchor = G.findAt(rec)
    if adapter then mark(anchor, rec) end
    KP.log("reader recolor key=" .. args.key .. " color=" .. KP.COLORS[rec.color + 1].id .. " by=" .. tostring(player:getUsername()))
    result(player, cmd, true, nil, args.key)
end

-- 右鍵「用 Knox Pass 開門」：擁有者、管理員、共同管理者、分享的陣營／安全屋成員，或身上帶已登記且有電的感應盒、
-- 戴著已登記且有作用的手錶模組（感應盒優先：開門扣它的電）。人還要走到門口，先撐著 S.WALK_MS
function H.open(player, args)
    local cmd = "open"
    if player:getVehicle() then return result(player, cmd, false, "InVehicle") end
    local rec, why = gateFor(player, args)
    if not rec then return result(player, cmd, false, why) end
    local tag, serial = nil, nil
    if not canManage(player, rec) and not sharedWith(player, rec) then
        tag = carriedTag(player, rec)
        if not tag then
            if not KP.wornPass(player, rec) then return result(player, cmd, false, "NotAllowed", args.key) end
            serial = KP.watchSerial(player)
        end
    end
    local ok, reason = S.open(args.key, rec, player, tag, nil, nil, getTimestampMs(), S.WALK_MS)
    if ok and serial then L.touchModule(rec, serial, player) end
    result(player, cmd, ok, reason, args.key)
end

-- 右鍵「用 Knox Pass 關門」：跟開門同樣的權限，關好照門鎖設定鎖回（S.close）
function H.close(player, args)
    local cmd = "close"
    if player:getVehicle() then return result(player, cmd, false, "InVehicle") end
    local rec, why = gateFor(player, args)
    if not rec then return result(player, cmd, false, why) end
    if not canManage(player, rec) and not sharedWith(player, rec) and not carriedTag(player, rec)
        and not KP.wornPass(player, rec) then
        return result(player, cmd, false, "NotAllowed", args.key)
    end
    local ok, reason = S.close(args.key, rec, player, getTimestampMs())
    result(player, cmd, ok, reason, args.key)
end

-- 查詢失敗也帶 key：管理視窗據此顯示原因並重讀（Window.lua Win.onResult）
local function keyOf(args) return type(args.key) == "string" and args.key or nil end

function H.query(player, args)
    local rec, why = gateFor(player, args)
    if not rec then return result(player, "query", false, why, keyOf(args)) end
    -- 沒有管理權：只回 NotOwner，不送這扇門的任何設定（管理視窗收到就關掉，Window.lua Win.onResult）
    if not canManage(player, rec) then return result(player, "query", false, "NotOwner", args.key) end
    KP.sendState(player, args.key)
end

-- ── 共同管理者 ─────────────────────────────────────────────────────────

-- 上線玩家的帳號（KP.principal 驗過的）；順手記進伺服器認得的玩家（Ledger.lua L.seen），剛上線的人不用等下一輪
local function onlineNames()
    local out = {}
    KP.eachPlayer(function(p)
        local name, sid = KP.principal(p)
        if name then
            out[name] = true
            L.seen(name, sid)
        end
    end)
    return out
end

local CANDIDATES = 20

-- 名單視窗輸入框的候選，順序同家族 Safehouse 的分享對象（Sharing.lua Sh.candidates）：帳號完全相符（分大小寫）的已知玩家、
-- 這位擁有者在自己每扇門加過的人、帳號含關鍵字（不分大小寫）的上線玩家，最多 20 位，rows＝{ name, online }。
-- 離線的玩家只在打完整帳號時列出：不能用關鍵字列出全服玩家。不列擁有者、查詢的人與已在名單上的人；只有能改名單的人能查
function H.findPlayers(player, args)
    local cmd = "findPlayers"
    local rec, why = gateFor(player, args)
    if not rec then return result(player, cmd, false, why, keyOf(args)) end
    if not ownerOrAdmin(player, rec) then return result(player, cmd, false, "OwnerOnly", args.key) end
    local query = args.query
    if type(query) ~= "string" or #query > KP.NAME_MAX then return result(player, cmd, false, "BadArgs", args.key) end
    local online = onlineNames()
    local needle, rows = string.lower(query), {}
    local skip = nameSet(rec.co) or {}
    skip[rec.owner or ""] = true
    skip[KP.principal(player) or ""] = true
    local function add(name)
        if #rows < CANDIDATES and not skip[name] then
            skip[name] = true
            rows[#rows + 1] = { name = name, online = online[name] == true }
        end
    end
    local function has(name) return string.find(string.lower(name), needle, 1, true) ~= nil end
    if query ~= "" and L.known(query) then add(query) end
    for _, name in ipairs(sortedNames(L.managersOf(rec.owner))) do
        if has(name) then add(name) end
    end
    for _, name in ipairs(sortedNames(online)) do
        if has(name) then add(name) end
    end
    reply(player, "players", { key = args.key, query = query, rows = rows })
end

local function isName(v) return type(v) == "string" and v ~= "" and #v <= KP.NAME_MAX end

-- 安全屋的 key＝原生 owner 字串：原版是帳號（≤ KP.NAME_MAX），家族 Safehouse 是 @MSH:<編號>
local HOUSE_KEY_MAX = 64
local function isHouseKey(v) return type(v) == "string" and v ~= "" and #v <= HOUSE_KEY_MAX end

-- 勾選時查：擁有者現在在這間（同一個 owner 的任何一塊）裡才回屋名，不在就是 NoHouse
local function houseTitle(key, owner)
    if not owner then return nil end
    local list = SafeHouse.getSafehouseList()
    for i = 0, list:size() - 1 do
        local sh = list:get(i)
        if sh:getOwner() == key and sh:playerAllowed(owner) then return sh:getTitle() or "" end
    end
    return nil
end

-- 改共同管理者名單（擁有者或管理員）：{ key, faction = true/false }、{ key, add = "帳號" }、{ key, remove = { "帳號"… } }、
-- { key, house = "原生 owner 字串", on = true/false }。加入只收伺服器認得的玩家（Ledger.lua L.known：上線過、或是讀頭擁有者），
-- 同時記下伺服器看過的 SteamID（L.userSid）。勾選安全屋只收擁有者現在所在的那幾間；取消一律收（已失效的也關得掉）
function H.managers(player, args)
    local cmd = "managers"
    local rec, why = gateFor(player, args)
    if not rec then return result(player, cmd, false, why, keyOf(args)) end
    if not ownerOrAdmin(player, rec) then
        return result(player, cmd, false, canManage(player, rec) and "OwnerOnly" or "NotOwner", args.key)
    end
    local add, remove, faction, house = args.add, args.remove, args.faction, args.house
    if (add ~= nil and not isName(add)) or (faction ~= nil and type(faction) ~= "boolean")
        or (remove ~= nil and not batchOf(remove, isName))
        or (house ~= nil and not (isHouseKey(house) and type(args.on) == "boolean")) then
        return result(player, cmd, false, "BadArgs", args.key)
    end
    if faction == true and not factionName(rec.owner) then return result(player, cmd, false, "NoFaction", args.key) end
    local title = house ~= nil and args.on and houseTitle(house, rec.owner)
    if house ~= nil and args.on and not title then return result(player, cmd, false, "NoHouse", args.key) end
    if add ~= nil then
        onlineNames()
        if add == rec.owner or not L.known(add) then return result(player, cmd, false, "UnknownPlayer", args.key) end
        local n = 0
        for name in pairs(rec.co or {}) do
            if name ~= add then n = n + 1 end
        end
        if n >= KP.MAX_MANAGERS then return result(player, cmd, false, "TooManyManagers", args.key) end
    end
    if faction ~= nil then rec.coFaction = faction or nil end
    if house ~= nil then
        rec.coHouses = rec.coHouses or {}
        rec.coHouses[house] = args.on and title or nil
        if not nameSet(rec.coHouses) then rec.coHouses = nil end
    end
    if add ~= nil then
        rec.co = rec.co or {}
        rec.co[add] = L.userSid(add)
    end
    for _, name in ipairs(remove or {}) do
        if rec.co then rec.co[name] = nil end
    end
    if not nameSet(rec.co) then rec.co = nil end
    local adapter, anchor = G.findAt(rec)
    if adapter then mark(anchor, rec) end
    KP.log("managers key=" .. args.key .. " add=" .. tostring(add) .. " faction=" .. tostring(faction)
        .. " house=" .. tostring(house) .. " on=" .. tostring(args.on) .. " by=" .. tostring(player:getUsername()))
    result(player, cmd, true, nil, args.key)
    KP.sendState(player, args.key)
end

local function onClientCommand(module, command, player, args)
    if module ~= KP.MODULE then return end
    local handler = H[command]
    if not handler or not player or type(args) ~= "table" then return end
    if limited(player) then return result(player, command, false, "RateLimited", keyOf(args)) end
    local ok, err = pcall(handler, player, args)
    if not ok then
        KP.log("command " .. tostring(command) .. " failed: " .. tostring(err))
        result(player, command, false, "Error", keyOf(args))
    end
end

Events.OnClientCommand.Add(onClientCommand)
