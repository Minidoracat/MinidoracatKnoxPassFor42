-- Minidoracat Knox Pass 共用核心：常數、沙盒、感應盒、供電、玩家走訪、幾何、身分。
-- client 與 server（含 SP）都載入；這裡不改世界狀態。
MinidoracatKnoxPass = MinidoracatKnoxPass or {}
local KP = MinidoracatKnoxPass

KP.MODULE = "MinidoracatKnoxPass"                 -- sendClientCommand 模組、沙盒頁、物品 module
KP.TAG_TYPE = "MinidoracatKnoxPass.VehicleTag"
KP.READER_TYPE = "MinidoracatKnoxPass.GateReader"
KP.PART_ID = "KnoxPassTag"
KP.MARKER_OWNER = "KnoxPassReader"                -- 大門錨點 modData：讀頭擁有者名稱（只給右鍵選單用，伺服器不信它）
KP.MARKER_LOCK = "KnoxPassLock"                   -- 大門錨點 modData：Knox Pass 門鎖是否開啟（同上）
KP.MANAGE_RANGE = 3                               -- 操作讀頭要站在大門幾格內（同樓層）
KP.REGISTER_RANGE = 15                            -- 登記時車要在大門幾格內
KP.CHARGE_PER_HOUR = 0.2                          -- 裝在車上、車在跑、電瓶高於 10% 時每遊戲小時充電量
KP.CHARGE_MIN_BATTERY = 0.1
KP.DRAIN_PER_OPEN = 0.01                          -- 每次開門耗電（再乘沙盒耗電倍率）

function KP.log(msg)
    print("[MinidoracatKnoxPassFor42] " .. tostring(msg))
end

local DEFAULTS = {
    ReadRange = 8, LeadSeconds = 2.0, AutoDriveAhead = 150, CloseDelay = 5, RequirePower = true,
    TagDrainPercent = 100, AllowCraft = true, SpawnLoot = true,
}

function KP.sandbox(key)
    local page = SandboxVars and SandboxVars[KP.MODULE]
    local value = page and page[key]
    if value == nil then return DEFAULTS[key] end
    return value
end

-- 配方 OnTest（recipes_knoxpass.txt）：引擎對每個候選輸入呼叫，全部 false 時配方無法執行
function KP.canCraft()
    return KP.sandbox("AllowCraft") == true
end

function KP.isInt(v)
    return type(v) == "number" and v == v and v == math.floor(v) and v > -2147483649 and v < 2147483648
end

-- ── 感應盒 ──────────────────────────────────────────────────────────────

function KP.isTag(item)
    return item ~= nil and item:getFullType() == KP.TAG_TYPE
end

-- 顯示用序號：由伺服器分配的物品 ID 換算。憑證本身是物品 ID，不是這個字串
function KP.serial(id)
    local n = math.floor(math.abs(id)) % 1000000
    return string.format("KP %04d-%02d", math.floor(n / 100), n % 100)
end

-- DrainableComboItem：getCurrentUsesFloat／setCurrentUsesFloat（DrainableComboItem.java:83-90），
-- 設定值會量化到 UseDelta 一格（0.001，items_knoxpass.txt），所以每次變動至少要一格
function KP.charge(item)
    return item:getCurrentUsesFloat()
end

function KP.setCharge(item, value)
    item:setCurrentUsesFloat(math.max(0, math.min(1, value)))
end

function KP.drainScale()
    return (tonumber(KP.sandbox("TagDrainPercent")) or 100) / 100
end

-- 車上裝著的感應盒（物品類型正確才算），回傳 item, part
function KP.vehicleTag(vehicle)
    local part = vehicle and vehicle:getPartById(KP.PART_ID)
    local item = part and part:getInventoryItem()
    if KP.isTag(item) then return item, part end
    return nil, part
end

-- ── 供電 ────────────────────────────────────────────────────────────────

-- 發電機（haveElectricity，IsoGridSquare.java:9696）或電網（hasGridPower，:11799）都算。
-- 刻意不照原版室外電器要求 getRoom()（ISWorldObjectContextMenu.lua:460-461）：大門在室外，照原版就永遠吃不到電網
function KP.squarePowered(sq)
    return sq ~= nil and (sq:haveElectricity() or sq:hasGridPower())
end

-- ── 玩家 ────────────────────────────────────────────────────────────────

-- server 走在線清單；SP 的 getOnlinePlayers 回空清單（LuaManager.java:4453-4463），改走本機玩家
function KP.eachPlayer(fn)
    if isServer() then
        local list = getOnlinePlayers()
        for i = 0, list:size() - 1 do fn(list:get(i)) end
    else
        for i = 0, getNumActivePlayers() - 1 do
            local p = getSpecificPlayer(i)
            if p then fn(p) end
        end
    end
end

-- 站在 (x,y,z) 那格的 range 格內、同一層
function KP.near(player, x, y, z, range)
    return player ~= nil and math.floor(player:getZ()) == z
        and math.abs(player:getX() - (x + 0.5)) <= range + 0.5
        and math.abs(player:getY() - (y + 0.5)) <= range + 0.5
end

-- 伺服器端身分（家族 conventions「玩家身分」的最小版）：分割畫面第 2–4 位和主玩家共用 SteamID、無從驗證→nil；
-- Steam 伺服器另回 SteamID 數值，只拿來和安裝讀頭時記下的值比對（數值會捨入到 16 的倍數，仍足以擋冒名）。
-- SP 沒有擁有權問題，回本機名字
function KP.principal(player)
    if not player then return nil end
    local name = player:getUsername()
    if type(name) ~= "string" or name == "" then return nil end
    if not isServer() then return name, nil end
    if player:getPlayerNum() ~= 0 then return nil end
    local sid = nil
    if getSteamModeActive and getSteamModeActive() then sid = player:getSteamID() end
    return name, sid
end

-- 伺服器上的管理員：角色有 CanOpenLockedDoors（Capability 已曝露，LuaManager.java:2460；IsoPlayer.getRole 可能為 nil）
function KP.isAdmin(player)
    if not isServer() or not player or not Capability then return false end
    local ok, yes = pcall(function()
        local role = player:getRole()
        return role ~= nil and role:hasCapability(Capability.CanOpenLockedDoors)
    end)
    return ok and yes == true
end

-- ── 幾何 ────────────────────────────────────────────────────────────────

-- 點 (px,py) 到線段 (ax,ay)-(bx,by) 的距離平方
function KP.segDistSq(px, py, ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    local len2 = dx * dx + dy * dy
    local t = 0
    if len2 > 0 then
        t = ((px - ax) * dx + (py - ay) * dy) / len2
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
    end
    local ex, ey = ax + t * dx - px, ay + t * dy - py
    return ex * ex + ey * ey
end
