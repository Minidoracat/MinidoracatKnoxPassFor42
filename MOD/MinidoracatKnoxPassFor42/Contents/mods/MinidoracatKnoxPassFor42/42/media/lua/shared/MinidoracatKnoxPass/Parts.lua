-- 感應盒零件槽：OnGameBoot 從 template 追加到每個有電瓶的車型（原版與 MOD 車），拆裝走原版維修面板。
-- OnGameBoot 在腳本載入後、建車之前（server GameServer.java:1447→:1496；client GameWindow.java:203→:670），
-- 回主選單／ResetLua 會再發（Core.java:3962、IngameState.java:1077），注入必須冪等。
-- client 與 server 都要注入，兩邊零件順序才一致（網路用 part index）。做法沿用家族 AutoDrive MDAD_DeviceParts.lua。
require "MinidoracatKnoxPass/Core"
local KP = MinidoracatKnoxPass

-- 42.21 的零件同步封包以 `& 255` 讀索引、255 當結束標記（VehiclePartItem.java:21、VehiclePartUsedDelta.java:29），
-- 加上這一槽後零件總數最多 255。只有零件模型封包用有號 byte（VehiclePartModels.java:31），這一槽沒有模型
local MAX_PARTS = 255
local injected = {}

-- 拆裝時站的位置：駕駛座那側（伸手貼擋風玻璃）優先，沒有就引擎區，再不然第一個合法 area
local function pickAreaId(script)
    if script:getAreaById("SeatFrontLeft") ~= nil then return "SeatFrontLeft" end
    if script:getAreaById("Engine") ~= nil then return "Engine" end
    for i = 1, script:getAreaCount() do
        local id = script:getArea(i - 1):getId()
        -- 這個字串要餵回 ScriptParser，限制成識別字避免語法注入
        if type(id) == "string" and string.find(id, "^%a[%w_]*$") ~= nil then return id end
    end
    return nil
end

-- Part.area 沒有 Lua setter；VehicleScript.Load 對既有 part 只覆寫出現的欄位（VehicleScript.java:909-951）
local function patchArea(tmpl, areaId)
    local body = "vehicle KnoxPassParts\n{\n    part " .. KP.PART_ID .. "\n    {\n"
        .. "        area = " .. areaId .. ",\n        mechanicArea = " .. areaId .. ",\n    }\n}\n"
    return pcall(function() tmpl:Load("KnoxPassParts", body) end)
end

function KP.injectParts()
    local sm = getScriptManager()
    local t = sm and sm:getVehicleTemplate("Base.KnoxPassParts")
    local tmpl = t and t:getScript()
    if not tmpl or not tmpl:getPartById(KP.PART_ID) then
        KP.log("ABORT: template KnoxPassParts missing, no tag slot injected")
        return
    end
    local scripts = sm:getAllVehicleScripts()
    local added, skipped, conflict = 0, 0, 0
    for i = 1, scripts:size() do
        local script = scripts:get(i - 1)
        if injected[script] and script:getPartById(KP.PART_ID) then
            added = added + 1
        elseif script:getPartById("Battery") == nil then
            skipped = skipped + 1   -- 自行車、拖車、殘骸
        elseif script:getPartById(KP.PART_ID) ~= nil then
            conflict = conflict + 1
            KP.log("CONFLICT script=" .. tostring(script:getFullName()) .. " already has part " .. KP.PART_ID)
        elseif script:getPartCount() + 1 > MAX_PARTS then
            skipped = skipped + 1
            KP.log("SKIP script=" .. tostring(script:getFullName()) .. " partCount=" .. tostring(script:getPartCount()))
        else
            local areaId = pickAreaId(script)
            local ok, err = false, "no area"
            if areaId then ok, err = patchArea(tmpl, areaId) end
            if ok then
                script:copyPartsFrom(tmpl, KP.PART_ID)
                injected[script] = true
                added = added + 1
            else
                skipped = skipped + 1
                KP.log("SKIP script=" .. tostring(script:getFullName()) .. " " .. tostring(err))
            end
        end
    end
    KP.log("tag slots side=" .. (isClient() and "client" or "authority") .. " added=" .. added
        .. " skipped=" .. skipped .. " conflict=" .. conflict)
end

-- 空槽：新車與舊存檔讀進來的車都不附感應盒（VehicleParts.java:229-250 只在 create 時呼叫）
function KP.onPartCreate(_, part)
    if part then part:setCondition(100) end
end

-- 充電。引擎只在 server／SP、而且車有人駕駛、引擎運轉或維修面板開著時呼叫零件 update
-- （VehicleParts.java:370-409、BaseVehicle.java:3507-3511），停著沒人的車不充電。
-- stream-in 後第一次呼叫會帶整段離線時間，單次最多算 5 分鐘
function KP.onPartUpdate(vehicle, part, elapsedMinutes)
    if isClient() then return end
    local item = part and part:getInventoryItem()
    if not KP.isTag(item) then return end
    local minutes = math.min(tonumber(elapsedMinutes) or 0, 5)
    if minutes <= 0 or vehicle:getBatteryCharge() <= KP.CHARGE_MIN_BATTERY then return end
    local before = KP.charge(item)
    if before >= 1 then return end
    KP.setCharge(item, before + KP.CHARGE_PER_HOUR * minutes / 60)
    if KP.charge(item) ~= before then vehicle:transmitPartUsedDelta(part) end
end

Events.OnGameBoot.Add(KP.injectParts)
