-- Knox Pass 駕駛預警：本機玩家自己開車（AutoDrive 沒在替他開）時，行進方向前方約 20 格內有關著、
-- 不會替這台車開的 Knox Pass 大門或閘門（KnoxPassAPI.willOpenFor 回 false 且帶原因），頭上＋右上提示一次。
-- 不帶原因（一般門、還沒收到這顆感應盒的推送）不提示；同一扇門要離開 LEAVE 格以上再回來才會再提示。
-- 行進方向用兩次掃描之間的位置差（倒車也對）；每 SCAN_MS 掃一次前方 AHEAD×(2×HALF_WIDTH+1) 格的 special objects。
require "MinidoracatKnoxPass/Core"
require "MinidoracatKnoxPass/Gates"
local KP = MinidoracatKnoxPass
local G = KP.Gates

local D = {}
KP.DriveWarn = D
D.SCAN_MS = 250
D.AHEAD = 20       -- 往前看幾格
D.HALF_WIDTH = 2   -- 行進線左右各看幾格
D.LEAVE = 30       -- 離門超過幾格就當這次接近結束
D.MIN_SPEED = 1    -- 格／秒（約 3.6 km/h）；更慢不算在接近

local state = {}   -- playerNum → { v, x, y, t, warned = { key → { x, y } } }
local lastScan = 0

-- 家族 AutoDrive 正在替這位本機玩家開車：它自己會提示大門（AutoDrive 1005e 起），這裡不重複。
-- MinidoracatAutoDriveFor42 client/MDAD_Driver.lua:41-42（MDAD.Drive = Drive）、:1341-1343
-- （Drive.isActive(playerNum)＝有自駕 session 或行程準備中）。沒裝 AutoDrive 或對方出錯就當自己開
local function autoDriving(playerNum)
    local drive = type(MDAD) == "table" and MDAD.Drive
    local fn = type(drive) == "table" and drive.isActive
    if type(fn) ~= "function" then return false end
    local ok, yes = pcall(fn, playerNum)
    return ok and yes == true
end

-- 回傳 true＝這扇門會擋住這台車（關著、不會開、有原因）。quiet＝同一輪已經提示過更近的門，只記下不再提示：
-- 並排的閘門或大門一次開過去只跳一則（訊息本來就是「前方的大門」）
local function warn(player, st, v, adapter, anchor, key, quiet)
    if G.isOpen(adapter, anchor) then return false end
    local ok, why = KnoxPassAPI.willOpenFor(v, anchor)
    if ok or not why then return false end
    local sq = anchor:getSquare()
    st.warned[key] = { x = sq:getX() + 0.5, y = sq:getY() + 0.5 }
    KP.log("drive warn " .. key .. " why=" .. tostring(why) .. (quiet and " quiet" or ""))
    if not quiet then
        KP.Client.say(player, getText("IGUI_KnoxPass_AheadWarn", KnoxPassAPI.whyText(why)), true, true)
    end
    return true
end

local function scan(player, st, v, ux, uy)
    local cell = getCell()
    local x, y, z = v:getX(), v:getY(), math.floor(v:getZ())
    local seen, said = {}, false
    for d = 1, D.AHEAD do
        for s = -D.HALF_WIDTH, D.HALF_WIDTH do
            local sq = cell:getGridSquare(math.floor(x + ux * d - uy * s), math.floor(y + uy * d + ux * s), z)
            local list = sq and sq:getSpecialObjects()
            for i = 0, (list and list:size() or 0) - 1 do
                local adapter, anchor = G.resolve(list:get(i))
                if adapter then
                    local key = G.key(anchor)
                    if not seen[key] and not st.warned[key] then
                        seen[key] = true
                        if warn(player, st, v, adapter, anchor, key, said) then said = true end
                    end
                end
            end
        end
    end
end

local function update(player, now)
    local pn = player:getPlayerNum()
    local v = player:getVehicle()
    if not v or v:getDriver() ~= player or autoDriving(pn) then
        state[pn] = nil
        return
    end
    local st = state[pn]
    if not st or st.v ~= v then
        state[pn] = { v = v, x = v:getX(), y = v:getY(), t = now, warned = {} }
        return
    end
    local x, y = v:getX(), v:getY()
    for key, at in pairs(st.warned) do
        local dx, dy = at.x - x, at.y - y
        if dx * dx + dy * dy > D.LEAVE * D.LEAVE then st.warned[key] = nil end
    end
    local dt = (now - st.t) / 1000
    local dx, dy = x - st.x, y - st.y
    st.x, st.y, st.t = x, y, now
    if dt <= 0 then return end
    local dist = math.sqrt(dx * dx + dy * dy)
    if dist / dt < D.MIN_SPEED then return end
    scan(player, st, v, dx / dist, dy / dist)
end

function D.tick()
    local now = getTimestampMs()
    if now - lastScan < D.SCAN_MS then return end
    lastScan = now
    for i = 0, getNumActivePlayers() - 1 do
        local p = getSpecificPlayer(i)
        if p then update(p, now) end
    end
end

Events.OnTick.Add(D.tick)
