-- 感應盒零件槽：OnGameBoot 從 template 追加到每個有電瓶的車型（原版與 MOD 車），拆裝走原版維修面板。
-- OnGameBoot 在腳本載入後、建車之前（server GameServer.java:1447→:1496；client GameWindow.java:203→:670），
-- 回主選單／ResetLua 會再發（Core.java:3962、IngameState.java:1077），注入必須冪等。
-- client 與 server 都要注入，兩邊零件順序才一致（網路用 part index）。做法沿用家族 AutoDrive MDAD_DeviceParts.lua。
require "MinidoracatKnoxPass/Core"
require "MinidoracatKnoxPass/DockSpots"
local KP = MinidoracatKnoxPass

-- 42.21 的零件同步封包以 `& 255` 讀索引、255 當結束標記（VehiclePartItem.java:21、VehiclePartUsedDelta.java:29），
-- 加上這一槽後零件總數最多 255。零件模型封包的索引是有號 byte（VehiclePartModels.java:31、:52），
-- 索引超過 127 的車型照樣有槽、但 KP.syncDock 不顯示模型（42.21 實測最多 67 個零件，見 KP.dockPlacement）
local MAX_PARTS = 255
local MAX_MODEL_INDEX = 127
local injected = {}
local noDock = {}   -- 車型腳本 → true：推算不出位置或新槽索引 >127，有槽但不顯示模型

-- 擋風玻璃上的「固定座＋感應盒」：模型原點＝黏貼墊上緣中心，盒子往車內方向厚 1.75 cm（scripts/blender/build_models.py）。
-- 原版車：查 KP.DOCK_SPOTS（scripts/blender/dock_spots.py 從原版網格烘出，鍵＝車輛腳本 model 的 file）；
-- 常見 MOD 車：查 KP.DOCK_SPOTS_MOD（清單 scripts/blender/modcars.json，鍵＝模型腳本的 mesh，
-- getModelScript(file):getMeshName()：不同 MOD 撞同一個 model 名時 mesh 不同，不會誤用）。
-- 放在擋風玻璃外表面上緣中央：原版與 MOD 車的車窗都是不透明的，裝在內側看不到。
-- 兩張表都沒有的車用車輛腳本的幾何推算（加載後已乘車輛 scale，單位公尺，相對車身原點）：
--   高度＝extents 頂（centerOfMassOffset.y + extents.y/2）往下 ROOF_DROP
--   前後＝駕駛座 inside 位置 z ＋ PER_HEIGHT×車高 ＋ AHEAD
-- 係數用原版有網格的車型擬合，取「最多貼到玻璃內側、不穿出去」的保守值（中位數在玻璃後約 0.18 m），傾角 TILT 度。
KP.DOCK = { ROOF_DROP = 0.15, PER_HEIGHT = 0.20, AHEAD = 0.043, MIN_BEHIND_FRONT = 0.3, TILT = 20 }
KP.DOCK_MODEL_ID = "Dock"

-- 顏色 c（KP.COLORS 索引 0-6）的零件 model id：Dock＋後綴（米白就是 Dock），vehicle_knoxpass_parts.txt 每色一個
function KP.dockModelId(c) return KP.DOCK_MODEL_ID .. KP.COLORS[c + 1].suffix end

-- 回傳零件模型的 offset（x,y,z，車輛模型的未縮放單位）、scale 與 rotate.x（度）；推算不出來回 nil（不顯示模型）。
-- 渲染：車身矩陣＝底盤旋轉×T(模型 offset)×S(車輛 scale)，零件模型再乘 T(offset)×R×S(scale)（BaseVehicle.java:4387-4471），
-- 所以 offset＝(目標點－模型 offset)/車輛 scale，scale＝1/車輛 scale 才是 1:1 公尺。
-- R＝rotationXYZ(rotate.x, -rotate.y, -rotate.z)（:4418-4423）；網格 +Y 上、+Z 車頭，rotate.x 為負時上緣往車尾倒（玻璃後傾）
function KP.dockPlacement(script)
    local vs = script:getModelScale()
    local mo = script:getModelOffset()
    local seat = script:getPassengerCount() > 0 and script:getPassenger(0):getPositionById("inside")
    if not mo or not seat or not vs or vs <= 0 then return nil end
    local file = script:getModel():getFile()   -- model 區塊沒寫 file 時是 null
    local spot = file and KP.DOCK_SPOTS[file]
    if not spot and file then
        local ms = getScriptManager():getModelScript(file)   -- 不含點只查 Base 模組，MOD 車在別的模組會寫全名
        local mesh = ms and ms:getMeshName()
        spot = mesh and KP.DOCK_SPOTS_MOD[mesh]
    end
    if spot then return 0, spot[1], spot[2], 1 / vs, -spot[3] end
    local ext, com = script:getExtents(), script:getCenterOfMassOffset()
    local d = KP.DOCK
    local y = com:y() + ext:y() / 2 - d.ROOF_DROP
    local z = mo:z() + seat:getOffset():z() + d.PER_HEIGHT * ext:y() + d.AHEAD
    z = math.min(z, com:z() + ext:z() / 2 - d.MIN_BEHIND_FRONT)
    return 0, (y - mo:y()) / vs, (z - mo:z()) / vs, 1 / vs, -d.TILT
end

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

-- Part.area 與模型都沒有 Lua setter；VehicleScript.Load 對既有 part／model 只覆寫出現的欄位
-- （VehicleScript.java:909-951 LoadPart、:693-722 LoadModel），copyPartsFrom 再整份複製（:1271-1294、makeCopy :2381-2388）。
-- 7 色的 model 寫同一組位置；file 與 setAllModelsVisible = false 留用 template 的值
local function num(v) return string.format("%.4f", v) end
local function patchPart(tmpl, areaId, placement)
    local body = "vehicle KnoxPassParts\n{\n    part " .. KP.PART_ID .. "\n    {\n"
        .. "        area = " .. areaId .. ",\n        mechanicArea = " .. areaId .. ",\n"
    if placement then
        for c = 0, #KP.COLORS - 1 do
            body = body .. "        model " .. KP.dockModelId(c) .. "\n        {\n"
                .. "            offset = " .. num(placement[1]) .. " " .. num(placement[2]) .. " " .. num(placement[3]) .. ",\n"
                .. "            rotate = " .. num(placement[5]) .. " 0.0 0.0,\n"
                .. "            scale = " .. num(placement[4]) .. ",\n        }\n"
        end
    end
    body = body .. "    }\n}\n"
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
    local added, skipped, conflict, nomodel = 0, 0, 0, 0
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
            local placement = nil
            if script:getPartCount() <= MAX_MODEL_INDEX then   -- 新槽的索引＝目前零件數
                local ox, oy, oz, sc, rx = KP.dockPlacement(script)
                if ox then placement = { ox, oy, oz, sc, rx } end
            end
            local ok, err = false, "no area"
            if areaId then ok, err = patchPart(tmpl, areaId, placement) end
            if ok then
                script:copyPartsFrom(tmpl, KP.PART_ID)
                injected[script] = true
                added = added + 1
                if not placement then nomodel = nomodel + 1; noDock[script] = true end
            else
                skipped = skipped + 1
                KP.log("SKIP script=" .. tostring(script:getFullName()) .. " " .. tostring(err))
            end
        end
    end
    KP.log("tag slots side=" .. (isClient() and "client" or "authority") .. " added=" .. added
        .. " skipped=" .. skipped .. " conflict=" .. conflict .. " nomodel=" .. nomodel)
end

-- 7 個 Dock 只顯示裝著的那一色（setAllModelsVisible = false，引擎不會自己切換）；沒裝、車型不掛模型或索引超過 127 就全關。
-- 呼叫點：零件 lua.init（每次 addToWorld：新車、存檔載入、MP 客戶端收到整車封包，BaseVehicle.java:7964→:868-869，
-- VehicleParts.java:265-272；管理員修車換了物品也會呼叫，VehiclePart.java:956-971）、安裝／拆下的 complete（Server.lua）、
-- 零件 update（其他 MOD 直接換物品時補正）。create 緊接著就是 init（BaseVehicle.java:868-869），不另外接。
-- setModelVisible：已顯示再開、沒顯示再關都直接返回，不標記同步（BaseVehicle.java:1707-1754），所以 update 每次呼叫也便宜；
-- 真的變了才標記 updateFlags 64，伺服器下一輪車輛更新封包送給客戶端（VehiclePartModels.java）。
-- MP 客戶端也要在 init 自己算：整車封包只有 save／load，不含已顯示的零件模型（VehicleFullUpdatePacket.java:122-127、
-- VehicleManager.java:167-169 不帶 64），之後才進範圍的客戶端只能靠這裡。
function KP.syncDock(vehicle, part)
    if not (vehicle and part) then return end
    local item = part:getInventoryItem()
    local show = KP.isTag(item) and KP.colorOf(item)
    local script = vehicle:getScript()
    if part:getIndex() > MAX_MODEL_INDEX or (script and noDock[script]) then show = nil end
    for c = 0, #KP.COLORS - 1 do part:setModelVisible(KP.dockModelId(c), c == show) end
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
    KP.syncDock(vehicle, part)
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
