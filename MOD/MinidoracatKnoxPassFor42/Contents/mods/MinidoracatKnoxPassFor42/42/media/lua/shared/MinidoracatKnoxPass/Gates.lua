-- 門轉接器：判斷物件是不是 Knox Pass 能開的門、整組門有哪些片、怎麼開關與上鎖。
-- 原版兩種：IsoDoor（地圖上所有門、柵欄門、雙開門、車庫門）、IsoThumpable 且 isDoor()（玩家與多數 MOD 建造的門）。
-- 其他做法的 MOD 門由該 MOD 呼叫 KnoxPassAPI.registerGateAdapter 註冊，比對時排在原版之前。
-- 開關與上鎖只在伺服器（含 SP）呼叫；判斷與找錨點 client 也會用（右鍵選單）。
require "MinidoracatKnoxPass/Core"
local KP = MinidoracatKnoxPass

local G = {}
KP.Gates = G

local custom = {}

local function each(pieces, fn)
    for i = 1, #pieces do fn(pieces[i]) end
end

-- 雙開門第 2、3 片每次開關都會被刪掉、在別格重建（IsoDoor.java:2855-2922），整組資料一律綁第 1 片（沒有就第 4 片）
local function doubleAnchor(obj)
    return IsoDoor.getDoubleDoorObject(obj, 1) or IsoDoor.getDoubleDoorObject(obj, 4) or obj
end

local function doublePieces(anchor)
    local out = {}
    for i = 1, 4 do
        local p = IsoDoor.getDoubleDoorObject(anchor, i)
        if p then out[#out + 1] = p end
    end
    return out
end

-- 車庫門：第 1 片 → 中間片（index 2，可能多片）→ 最後一片（index 3），開關時不重建（IsoDoor.java:3212-3338）
local function garagePieces(anchor)
    local out = {}
    local p = IsoDoor.getGarageDoorFirst(anchor) or anchor
    while p and #out < 32 do
        out[#out + 1] = p
        p = IsoDoor.getGarageDoorNext(p)
    end
    return out
end

-- 車庫門關門前的擋車檢查：引擎的 isGarageDoorObstructed 是私有的（IsoDoor.java:3396-3457），照它的判斷重寫：
-- 任一片的格子上有車、而且同一台車也壓到門線另一側那格（N 向 y-1、W 向 x-1）才算擋住。
-- 不先查的話 ToggleDoor 會拒關，並對開關者播 Blocked 音、顯示 HaloNote（:1583-1586），Sensor 每次重試都洗一次畫面。
-- getVehicleContainer 只回該格第一台相交的車（IsoGridSquare.java:9872-9893），同格兩台車的情況不管
local function garageBlocked(anchor)
    local north = anchor:getNorth()
    for _, p in ipairs(garagePieces(anchor)) do
        local sq = p:getSquare()
        local v = sq and sq:getVehicleContainer()
        if v and v:isIntersectingSquare(sq:getX() - (north and 0 or 1), sq:getY() - (north and 1 or 0), sq:getZ()) then
            return true
        end
    end
    return false
end

local function isGarage(obj) return IsoDoor.getGarageDoorIndex(obj) ~= -1 end
local function isDouble(obj) return IsoDoor.getDoubleDoorIndex(obj) ~= -1 end

-- 空白鑰匙的 keyId 是 -1，會配到 keyId 為 -1 的上鎖門（ItemContainer.haveThisKeyId，ItemContainer.java:3242-3255；
-- Key.java:23）。上 Knox Pass 門鎖前替整組配一把沒人有的 keyId；已有 keyId 的門不動，玩家原本的鑰匙照用
local function ensureKeyId(pieces, setter)
    for i = 1, #pieces do
        if pieces[i]:getKeyId() ~= -1 then return end
    end
    local id = ZombRand(1, 100000000)
    each(pieces, function(p) setter(p, id) end)
end

-- ── IsoDoor ─────────────────────────────────────────────────────────────
-- 伺服器上 setLockedByKey 不會自動同步（IsoDoor.java:2009-2024），照 ISLockDoor.lua:50-72 手動 syncIsoObject。
-- Knox Pass 門鎖＝原版預留的 modData.CustomLock（IsoDoor.java:1491,1553：關著時沒有鑰匙的玩家打不開）＋鑰匙鎖。
-- CustomLock 只擋玩家。會開門的殭屍（認知 1）歸擁有牠的客戶端模擬，拍門與開門都在客戶端跑、只看客戶端那份 locked
-- （IsoDoor.java:1179-1183、1577-1580），開了再送 SyncIsoObject，伺服器照單全收。只設 CustomLock 的門被殭屍打開後，
-- 玩家又因 CustomLock 用手關不了（couldBeOpen，ISWorldObjectContextMenuLogic.java:2296-2301；2026-10-08 玩家回報：
-- 閘門被殭屍升起後放不下來）。鎖要用 lockedByKey：車庫門的 SyncIsoObject 在客戶端逐片 setLockedByKey(bLockedByKey)，
-- 連帶把 locked 蓋成同一個值（IsoDoor.java:1811-1822、2013-2016），只設 locked 的話客戶端看到的是沒鎖
-- （zombielock-mp 1008a 實踩）。
-- KNOX_LOCKED 記 Knox Pass 補鎖前這片原本的鎖：true＝沒鎖、1＝只有 locked；原本就是鑰匙鎖的片不補、不記。
-- 解鎖與拿掉門鎖時照它還原，引擎在有人試開時把 locked 補成的鑰匙鎖（IsoDoor.java:1529-1532）也就不會被當成原本的鎖。
-- 車庫門在 MP 回不到「只有 locked」：客戶端收到後鏈上其他片的鑰匙鎖由 true 變 false，setLockedByKey 會把 locked=false
-- 回送伺服器（IsoDoor.java:2017-2022），原版地圖車庫門解鑰匙鎖也一樣（zombielock-mp Z6）；一般門與 SP 照常還原
-- 引擎會在別的路徑清掉鎖（柵欄門有人試開、有鑰匙的人開關，IsoDoor.java:1517-1520、1562-1565），Sensor 每 5 秒補回（S.relock）
local KNOX_LOCKED = "KnoxPassLocked"

local function syncDoor(p) p:syncIsoObject(false, 0, nil, nil) end

local doorAdapter = {
    id = "vanilla.IsoDoor",
    match = function(obj) return instanceof(obj, "IsoDoor") end,
    anchor = function(obj)
        if isGarage(obj) then return IsoDoor.getGarageDoorFirst(obj) or obj end
        if isDouble(obj) then return doubleAnchor(obj) end
        return obj
    end,
    pieces = function(anchor)
        if isGarage(anchor) then return garagePieces(anchor) end
        if isDouble(anchor) then return doublePieces(anchor) end
        return { anchor }
    end,
    kind = function(anchor)
        if isGarage(anchor) then return KP.gateKind(anchor) or "Garage" end
        if isDouble(anchor) then return "Double" end
        return "Door"
    end,
    isOpen = function(anchor) return anchor:IsOpen() end,
    -- ToggleDoor 必須傳真的 IsoPlayer：IsoDoor 傳 nil 什麼都不做（IsoDoor.java:1501），車庫門分支還會 NPE（:1593）
    setOpen = function(anchor, open, player)
        if anchor:IsOpen() ~= open then anchor:ToggleDoor(player) end
        return anchor:IsOpen() == open
    end,
    isBlocked = function(anchor)
        if isDouble(anchor) then return IsoDoor.isDoubleDoorObstructed(anchor) end
        if isGarage(anchor) then return garageBlocked(anchor) end
        return anchor:isObstructed()
    end,
    -- 開門前解除整組的鑰匙鎖與 Knox Pass 門鎖，回傳原本的鎖別（關好後照原樣鎖回）：
    -- 2＝鑰匙鎖；1＝只有 locked（地圖車庫門預設如此，內側能開、外側要鑰匙，IsoDoor.java:1568-1580、CellLoader.java:101-104）。
    -- locked 也要清：ToggleDoorActual 會把「locked 且有 keyId」補成 lockedByKey（IsoDoor.java:1529-1532）。
    -- Knox Pass 補過鎖的片，原本的鎖看 KNOX_LOCKED。
    -- 車庫門只改伺服器上的值、不另外同步：接著開門的 toggleGarageDoor 會送整條鏈開著、沒鎖（IsoDoor.java:3352,3384-3386）。
    -- 先同步的話，客戶端解開鏈上其他片的鑰匙鎖時會把那片「關著」回送伺服器（IsoDoor.java:1811-1822、2017-2022），
    -- 伺服器照單全收、把剛開的門關上，Sensor 下一輪又開、又扣一次電（2026-10-08 玩家回報：上鎖的閘門連續重開、電量瞬間用完）
    unlock = function(anchor, pieces)
        local was = nil
        local sync = not isGarage(anchor)
        each(pieces, function(p)
            local md = p:getModData()
            local own = md[KNOX_LOCKED]
            if own == nil then
                own = p:isLockedByKey() and 2 or p:isLocked() and 1 or nil
            elseif own ~= 1 then
                own = nil
            end
            if own == 2 then was = 2 elseif own == 1 and was == nil then was = 1 end
            p:setLocked(false)
            p:setLockedByKey(false)
            if sync then syncDoor(p) end
            if md.CustomLock ~= nil or md[KNOX_LOCKED] ~= nil then
                md.CustomLock, md[KNOX_LOCKED] = nil, nil
                p:transmitModData()
            end
        end)
        return was
    end,
    -- 先還原原本的鎖（keyed），再上 Knox Pass 門鎖：不是鑰匙鎖的片補上鑰匙鎖，KNOX_LOCKED 記下補之前的鎖。
    -- 只在狀態真的變了才傳送與同步：Sensor 每 5 秒對關著的上鎖門呼叫一次（S.relock）
    lock = function(anchor, pieces, knoxLock, keyed)
        if knoxLock then
            -- 先沿用建築的 keyId（IsoDoor.java:2372-2398），房屋門上原本的鑰匙才不會失效
            each(pieces, function(p) p:checkKeyId() end)
            ensureKeyId(pieces, function(p, id) p:setKeyId(id) end)
        end
        each(pieces, function(p)
            local md, changed, tx = p:getModData(), false, false
            if keyed == 2 and not p:isLockedByKey() then
                p:setLockedByKey(true)
                changed = true
            elseif keyed == 1 and not p:isLocked() then
                p:setLocked(true)
                changed = true
            end
            if knoxLock then
                if md.CustomLock ~= true then md.CustomLock, tx = true, true end
                if not p:isLockedByKey() then
                    if md[KNOX_LOCKED] == nil then md[KNOX_LOCKED], tx = p:isLocked() and 1 or true, true end
                    p:setLockedByKey(true)
                    changed = true
                end
            end
            if tx then p:transmitModData() end
            if changed then syncDoor(p) end
        end)
    end,
    -- 只拿掉 Knox Pass 門鎖（擁有者關閉門鎖、拆讀頭）：Knox Pass 補的鑰匙鎖照 KNOX_LOCKED 還原，原本的鑰匙鎖不動
    unlockKnox = function(anchor, pieces)
        each(pieces, function(p)
            local md = p:getModData()
            local own = md[KNOX_LOCKED]
            if own ~= nil then
                p:setLockedByKey(false)   -- 連帶清 locked（IsoDoor.java:2013-2016）
                if own == 1 then p:setLocked(true) end
                syncDoor(p)
            end
            if md.CustomLock ~= nil or own ~= nil then
                md.CustomLock, md[KNOX_LOCKED] = nil, nil
                p:transmitModData()
            end
        end)
    end,
}

-- ── IsoThumpable（玩家建造的門）─────────────────────────────────────────
-- 鎖只在開門者站在室外格、身上沒有鑰匙時生效（IsoThumpable.java:1258-1274），Knox Pass 門鎖就用 lockedByKey；
-- 擁有對應鑰匙的人照樣能用手開。引擎不支援 IsoThumpable 車庫門（IsoDoor.java:3369-3380），不接手

local thumpAdapter = {
    id = "vanilla.IsoThumpable",
    match = function(obj)
        return instanceof(obj, "IsoThumpable") and obj:isDoor() and not isGarage(obj)
    end,
    anchor = function(obj)
        if isDouble(obj) then return doubleAnchor(obj) end
        return obj
    end,
    pieces = function(anchor)
        if isDouble(anchor) then return doublePieces(anchor) end
        return { anchor }
    end,
    kind = function(anchor)
        if isDouble(anchor) then return "Double" end
        return "Door"
    end,
    isOpen = function(anchor) return anchor:IsOpen() end,
    -- chr 為 nil 會在狀態翻轉後、同步前 NPE（IsoThumpable.java:1297,1310,1313）
    setOpen = function(anchor, open, player)
        if anchor:IsOpen() ~= open then anchor:ToggleDoor(player) end
        return anchor:IsOpen() == open
    end,
    isBlocked = function(anchor)
        if isDouble(anchor) then return IsoDoor.isDoubleDoorObstructed(anchor) end
        return anchor:isObstructed()
    end,
    unlock = function(anchor, pieces)
        local was = nil
        each(pieces, function(p)
            if p:isLockedByKey() then was = 2 elseif p:isLocked() and was == nil then was = 1 end
            p:setIsLocked(false)
            p:setLockedByKey(false)
            p:syncIsoThumpable()
        end)
        return was
    end,
    -- 已經是該鎖別就不動（Sensor 每 5 秒對關著的上鎖門呼叫一次，S.relock）
    lock = function(anchor, pieces, knoxLock, keyed)
        if knoxLock then
            ensureKeyId(pieces, function(p, id) p:setKeyId(id, true) end)
        end
        each(pieces, function(p)
            if knoxLock or keyed == 2 then
                if p:isLockedByKey() then return end
                p:setLockedByKey(true)
            elseif keyed == 1 then
                if p:isLocked() then return end
                p:setIsLocked(true)
            else
                return
            end
            p:syncIsoThumpable()
        end)
    end,
    -- 玩家建造的門只有一種鎖，Knox Pass 門鎖就是鑰匙鎖：關閉門鎖等於解鎖
    unlockKnox = function(anchor, pieces)
        each(pieces, function(p)
            p:setLockedByKey(false)
            p:syncIsoThumpable()
        end)
    end,
}

-- ── 查詢 ────────────────────────────────────────────────────────────────

local function call(adapter, name, ...)
    local fn = adapter[name]
    if not fn then return false, nil end
    return pcall(fn, ...)
end

function G.adapterFor(obj)
    if not obj then return nil end
    for i = 1, #custom do
        local ok, yes = pcall(custom[i].match, obj)
        if ok and yes then return custom[i] end
    end
    if doorAdapter.match(obj) then return doorAdapter end
    if thumpAdapter.match(obj) then return thumpAdapter end
    return nil
end

-- 回傳 adapter, anchor；不是門回 nil
function G.resolve(obj)
    local adapter = G.adapterFor(obj)
    if not adapter then return nil end
    local ok, anchor = pcall(adapter.anchor, obj)
    if not ok or not anchor or not anchor:getSquare() then return nil end
    return adapter, anchor
end

function G.byId(id)
    if id == doorAdapter.id then return doorAdapter end
    if id == thumpAdapter.id then return thumpAdapter end
    for i = 1, #custom do
        if custom[i].id == id then return custom[i] end
    end
    return nil
end

-- 帳本的鍵：錨點格座標＋朝向（同一格可能同時有北側與西側兩扇門）
function G.key(anchor)
    local sq = anchor:getSquare()
    local side = ""
    if anchor.getNorth then side = anchor:getNorth() and "N" or "W" end
    return sq:getX() .. "," .. sq:getY() .. "," .. sq:getZ() .. side
end

function G.pieces(adapter, anchor)
    local ok, pieces = call(adapter, "pieces", anchor)
    if ok and type(pieces) == "table" and #pieces > 0 then return pieces end
    return { anchor }
end

function G.kind(adapter, anchor)
    local ok, kind = call(adapter, "kind", anchor)
    if ok and type(kind) == "string" then return kind end
    return "Mod"
end

function G.isOpen(adapter, anchor)
    local ok, open = call(adapter, "isOpen", anchor)
    return ok and open == true
end

function G.setOpen(adapter, anchor, open, player)
    local ok, done = call(adapter, "setOpen", anchor, open, player)
    if not ok then KP.log("adapter " .. tostring(adapter.id) .. " setOpen failed: " .. tostring(done)) end
    return ok and done == true
end

function G.isBlocked(adapter, anchor)
    local ok, blocked = call(adapter, "isBlocked", anchor)
    return ok and blocked == true
end

function G.supportsLock(adapter)
    return adapter.unlock ~= nil and adapter.lock ~= nil and adapter.unlockKnox ~= nil
end

-- 回傳原本的鎖別，關好後原封不動傳回 lock；會存進帳本，只收純量
function G.unlock(adapter, anchor, pieces)
    local ok, was = call(adapter, "unlock", anchor, pieces)
    if ok and (type(was) == "number" or type(was) == "string" or was == true) then return was end
    return nil
end

function G.lock(adapter, anchor, pieces, knoxLock, keyed)
    call(adapter, "lock", anchor, pieces, knoxLock == true, keyed)
end

function G.unlockKnox(adapter, anchor, pieces)
    call(adapter, "unlockKnox", anchor, pieces)
end

-- 整組門的中心（算感應距離用）
function G.center(pieces)
    local x, y = 0, 0
    for i = 1, #pieces do
        local sq = pieces[i]:getSquare()
        x = x + sq:getX() + 0.5
        y = y + sq:getY() + 0.5
    end
    return x / #pieces, y / #pieces
end

function G.powered(pieces)
    for i = 1, #pieces do
        if KP.squarePowered(pieces[i]:getSquare()) then return true end
    end
    return false
end

-- 伺服器：依帳本記錄找回錨點。回傳 adapter, anchor, square；
-- 格子沒載入回 nil；格子載入了但門不在（被拆、被搬走）回 false
function G.findAt(rec)
    local sq = getCell():getGridSquare(rec.x, rec.y, rec.z)
    if not sq then return nil end
    local objects = sq:getObjects()
    for i = 0, objects:size() - 1 do
        local obj = objects:get(i)
        local adapter, anchor = G.resolve(obj)
        if adapter and anchor == obj and G.key(obj) == rec.key then return adapter, obj, sq end
    end
    return false, nil, sq
end

-- 公開給其他 MOD：註冊自己的門。必填 id、match、anchor、isOpen、setOpen；
-- 選填 pieces、kind、isBlocked；門鎖要 unlock(anchor, pieces)→原本的鎖別（純量，沒鎖回 nil）、
-- lock(anchor, pieces, knoxLock, keyed)（keyed 是 unlock 當初的回傳值）、unlockKnox(anchor, pieces) 三個都提供
KnoxPassAPI = KnoxPassAPI or {}
KnoxPassAPI.VERSION = 3

function KnoxPassAPI.registerGateAdapter(adapter)
    if type(adapter) ~= "table" or type(adapter.id) ~= "string" then return false, "id" end
    for _, name in ipairs({ "match", "anchor", "isOpen", "setOpen" }) do
        if type(adapter[name]) ~= "function" then return false, name end
    end
    for i = 1, #custom do
        if custom[i].id == adapter.id then
            custom[i] = adapter
            return true
        end
    end
    custom[#custom + 1] = adapter
    KP.log("gate adapter registered: " .. adapter.id)
    return true
end

-- 公開給其他 MOD（家族 AutoDrive 用）：obj 是一扇 Knox Pass 大門的任一片、而且 Knox Pass 會替這台車開它時回 true。
-- 條件：車上裝著有電的感應盒、這顆感應盒登記在這扇門（伺服器推送的清單，Sensor.lua pushPasses）、
-- 門需要供電時有電（KP.squarePowered 在客戶端可用：發電機看區塊資料、電網看沙盒，IsoGridSquare.java:9696,11799）。
-- 是預告不是保證：伺服器仍可能開不了（門片擺動範圍被擋、剛斷電、延遲），呼叫端要能在門前停住。
-- 裝了讀頭的門不會開時，第二個回傳值是原因代碼（whyText 轉成玩家語言）：NoTag、NotRegistered、TagEmpty、NoPower。
-- 一般門、或還沒收到這顆感應盒的推送（剛上車、剛換感應盒）時不帶原因，免得把「還不知道」說成「沒登記」。
-- 在 MP 客戶端與單機有效；專用伺服器沒有推送清單，一律 false。每次呼叫配置一個短字串與一個小 table
function KnoxPassAPI.willOpenFor(vehicle, obj)
    if not vehicle or not obj then return false end
    local adapter, anchor = G.resolve(obj)
    if not adapter then return false end
    local reader = anchor:hasModData() and anchor:getModData()[KP.MARKER_OWNER] ~= nil
    local tag = KP.vehicleTag(vehicle)
    if not tag then return false, reader and "NoTag" or nil end
    local passes = KP.passes
    if not passes or tag:getID() ~= passes.tag then return false end
    if not passes.keys[G.key(anchor)] then return false, reader and "NotRegistered" or nil end
    if KP.charge(tag) <= 0 then return false, "TagEmpty" end
    if KP.sandbox("RequirePower") == true and not G.powered(G.pieces(adapter, anchor)) then return false, "NoPower" end
    return true
end

-- 原因代碼 → 玩家語言的一句說明（willOpenFor 的第二個回傳值、伺服器拒絕的 why 共用）；不認得的代碼回通用說法
function KnoxPassAPI.whyText(why)
    local key = "IGUI_KnoxPass_Why_" .. tostring(why)
    local text = getText(key)
    if text == key then text = getText("IGUI_KnoxPass_Why_Error") end -- getText 找不到鍵回鍵本身
    return text
end
