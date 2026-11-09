-- Knox Pass client：大門右鍵選單、裝拆讀頭的計時動作、伺服器回覆的提示。
-- client 只送意圖（sendClientCommand），一切驗證與世界變更在伺服器（server/MinidoracatKnoxPass/Server.lua）。
-- 錨點 modData 的擁有者／門鎖標記只用來決定選單長相，伺服器不信它。
require "MinidoracatKnoxPass/Core"
require "MinidoracatKnoxPass/Gates"
require "TimedActions/ISBaseTimedAction"
local KP = MinidoracatKnoxPass
local G = KP.Gates

local C = {}
KP.Client = C

-- Toast 屬於 MinidoracatUI（mod.info require=）；widget 檔不由 V1 載入，自己 pcall require，缺席時退回頭頂提示
if not (MinidoracatUI and MinidoracatUI.v1) then pcall(require, "MinidoracatUI/V1") end
pcall(require, "MinidoracatUI/Widgets/Toast")

-- 更新概要（框架 rev 24，WhatsNew）：玩家更新後第一次進遊戲，右上角跳一則本版重點。發布列車的 ready 用 regex
-- 讀這段：四欄寫字面字串、一欄一行；發版寫了新概要才把 since 改成本版（家族 conventions.md「遊戲內更新概要」）。
pcall(require, "MinidoracatUI/WhatsNew")
do
    local ui = MinidoracatUI and MinidoracatUI.v1
    if ui and ui.API_MAJOR == 1 and type(ui.API_REVISION) == "number" and ui.API_REVISION >= 24
        and ui.CAPABILITIES and ui.CAPABILITIES.whatsNew and ui.WhatsNew then
        ui.WhatsNew.register({
            modId = "MinidoracatKnoxPassFor42",
            since = "0.10.0",
            name = "ContextMenu_KnoxPass",
            text = "IGUI_KnoxPass_WhatsNew",
        })
    end
end

local INSTALL_TICKS, UNINSTALL_TICKS, DISMANTLE_TICKS = 150, 100, 200   -- 拆除照原版拆解的基本時間（ISDismantleAction.lua:102）
local HALO_TICKS = 250 -- 預設 128（IsoGameCharacter.java:604）

-- ── 送指令與提示 ────────────────────────────────────────────────────────

-- OnServerCommand 不帶收件人：提示掛在最後送指令的本機玩家頭上
function C.send(player, command, args)
    C.lastPlayer = player
    sendClientCommand(player, KP.MODULE, command, args)
end

-- Toast（CAPABILITIES.toast）優先；沒有就 setHaloNote(str, r, g, b, dispTime)（IsoGameCharacter.java:7001）。
-- halo＝true 時 Toast 之外頭上也提示（駕駛預警、手錶感應：開車、走路時視線在角色上）。英文的長原因約 4 行，Toast 給 5 行
function C.say(player, text, bad, halo)
    local UI = MinidoracatUI and MinidoracatUI.v1
    if UI and UI.CAPABILITIES and UI.CAPABILITIES.toast and UI.Toast
        and pcall(UI.Toast.show, { title = getText("IGUI_KnoxPass_Title"), message = text, holdMs = 3500, maxLines = 5 })
        and not halo then
        return
    end
    if not player then return end
    if bad then
        player:setHaloNote(text, 255, 110, 90, HALO_TICKS)
    else
        player:setHaloNote(text, 120, 230, 120, HALO_TICKS)
    end
end

local function onResult(args)
    if KP.Window then KP.Window.onResult(args) end
    local player = C.lastPlayer or getSpecificPlayer(0)
    -- 整批登記／取消登記（Server.lua H.register／H.unregister）：done＝成功幾台、failed＝沒成功幾台、why＝第一個原因
    if args.done ~= nil then
        if args.cmd == "unregister" then
            C.say(player, getText("IGUI_KnoxPass_UnregisterDone", tostring(args.done)), false)
        elseif (args.failed or 0) > 0 then
            C.say(player, getText("IGUI_KnoxPass_RegisterSome", tostring(args.done), tostring(args.failed),
                KnoxPassAPI.whyText(args.why)), args.done == 0)
        else
            C.say(player, getText("IGUI_KnoxPass_RegisterDone", tostring(args.done)), false)
        end
        return
    end
    if args.ok then
        if args.cmd == "install" then C.say(player, getText("IGUI_KnoxPass_Installed"), false)
        elseif args.cmd == "uninstall" then C.say(player, getText("IGUI_KnoxPass_Uninstalled"), false)
        elseif args.cmd == "dismantle" then C.say(player, getText("IGUI_KnoxPass_Dismantled"), false)
        elseif args.cmd == "recolor" or args.cmd == "recolorReader" then C.say(player, getText("IGUI_KnoxPass_Recolored"), false) end
        return
    end
    if args.cmd == "query" or args.cmd == "findPlayers" then return end   -- 管理視窗自己處理（Window.lua Win.onResult）
    if args.cmd == "walk" then   -- 手錶感應開不了（Sensor.lua walkOpen）：伺服器主動推，前面沒有本機送出的指令
        C.say(player, getText("IGUI_KnoxPass_WalkWarn", KnoxPassAPI.whyText(args.why)), true, true)
        return
    end
    C.say(player, KnoxPassAPI.whyText(args.why), true)
end

-- 伺服器回覆入口：MP 經 OnServerCommand；SP 由 Server.lua 的 reply 直接呼叫（SP 的 sendServerCommand 是 no-op）
function KP.clientReceive(command, args)
    if type(args) ~= "table" then return end
    if command == "result" then
        onResult(args)
    elseif command == "state" then
        if KP.Window then KP.Window.onState(args) end
    elseif command == "passes" then
        -- 伺服器推送：我現在這顆感應盒（開車時）與戴著的模組登記了哪些門（KnoxPassAPI.willOpenFor、小地圖讀，
        -- Sensor.lua pushPasses）。gates＝模組的門 { key, x, y, z, kind }；rev 換了小地圖就重建標記（MapLayer.lua）
        local keys, modKeys = {}, {}
        for _, key in pairs(type(args.keys) == "table" and args.keys or {}) do keys[key] = true end
        local gates = type(args.gates) == "table" and args.gates or {}
        for _, g in ipairs(gates) do modKeys[g.key] = true end
        KP.passesRev = (KP.passesRev or 0) + 1
        KP.passes = { tag = args.tag, keys = keys, mod = args.mod, modKeys = modKeys, gates = gates, rev = KP.passesRev }
    elseif command == "players" then
        if KP.Window then KP.Window.onPlayers(args) end   -- 共同管理者候選（Server.lua H.findPlayers）
    end
end

-- 簽名 (module, command, args)：ServerCommands.lua:207-217
Events.OnServerCommand.Add(function(module, command, args)
    if module ~= KP.MODULE then return end
    KP.clientReceive(command, args)
end)

-- ── 計時動作：裝／拆讀頭、拆除整座 ──────────────────────────────────────
-- 只繼承 ISBaseTimedAction、不定義 complete：LuaTimedActionNew 看 metatable 上沒有 complete 就不走
-- NetTimedAction（LuaTimedActionNew.java:78），動作只在本機跑，perform 送指令由伺服器重驗（AutoDrive
-- ISAutoDriveDeviceAction 同做法）。derive 只設父類的 __index（ISBaseObject），明確設自己的查找入口
local Action = ISBaseTimedAction:derive("KnoxPassReaderAction")
Action.__index = Action
C.Action = Action

function Action:isValid()
    local door = self.door
    if not door or not door:getSquare() or door:getObjectIndex() == -1 then return false end
    if self.command == "dismantle" then return KP.dismantleTool(self.character, door) ~= nil end
    local inv = self.character:getInventory()
    if not KP.screwdriverOf(self.character) then return false end -- ISWorldObjectContextMenu.lua:1243
    -- getItemWithIDRecursiv：ItemContainer.java:3125（SP／MP client 都用 ID 找，不比物件參照）
    return self.command ~= "install" or inv:getItemWithIDRecursiv(self.itemId) ~= nil
end

function Action:waitToStart()
    self.character:faceThisObject(self.door)
    return self.character:shouldBeTurning()
end

function Action:update()
    self.character:faceThisObject(self.door)
    self.character:setMetabolicTarget(Metabolics.LightWork)
end

function Action:start()
    self:setActionAnim(CharacterActionAnims.Disassemble) -- 螺絲起子拆裝，ISMoveablesAction.lua:183
end

function Action:perform()
    if self.command == "install" or self.command == "dismantle" then
        local sq = self.door:getSquare()
        C.send(self.character, self.command, { x = sq:getX(), y = sq:getY(), z = sq:getZ(),
            index = self.door:getObjectIndex(), itemId = self.itemId })
    else
        C.send(self.character, "uninstall", { key = self.key })
    end
    ISBaseTimedAction.perform(self)
end

function Action:new(character, door, command, ticks)
    local o = ISBaseTimedAction.new(self, character)
    o.door = door
    o.command = command
    o.maxTime = character:isTimedActionInstant() and 1 or ticks
    return o
end

-- 走到門邊（原版開關門／鎖門同款：ISWorldObjectContextMenu.lua:1510）→ 拿起子（:1371）→ 動作
local function queue(player, door, action)
    local screwdriver = KP.screwdriverOf(player)
    if not screwdriver then return end
    if not luautils.walkAdjWindowOrDoor(player, door:getSquare(), door) then return end
    ISWorldObjectContextMenu.equip(player, player:getPrimaryHandItem(), screwdriver, true, false)
    ISTimedActionQueue.add(action)
end

function C.queueInstall(player, door)
    local reader = player:getInventory():getFirstEvalRecurse(KP.isReader)   -- 任何顏色（ItemContainer.java:1539）
    if not reader then return end
    local action = Action:new(player, door, "install", INSTALL_TICKS)
    action.itemId = reader:getID()
    queue(player, door, action)
end

-- 拆讀頭走到錨點（伺服器量距離以錨點格為準）
function C.queueUninstall(player, anchor, key)
    local action = Action:new(player, anchor, "uninstall", UNINSTALL_TICKS)
    action.key = key
    queue(player, anchor, action)
end

-- 拆除整座（伺服器 H.dismantle 重驗權限、工具與距離）：走到那一端（機箱、門柱是實心的，走到旁邊的空格；兩層樓捲門的門片照門的走法）
-- → 拿工具（焊槍另外戴上面罩，同原版金屬拆解 ISMoveableSpriteProps.lua:3102-3118）→ 動作
function C.queueDismantle(player, target)
    local tool, mask = KP.dismantleTool(player, target)
    if not tool then return end
    local sq = target:getSquare()
    if instanceof(target, "IsoDoor") then
        if not luautils.walkAdjWindowOrDoor(player, sq, target) then return end
    elseif not luautils.walkAdj(player, sq) then
        return
    end
    ISWorldObjectContextMenu.equip(player, player:getPrimaryHandItem(), tool, true, false)
    if mask and not player:isEquippedClothing(mask) then ISInventoryPaneContextMenu.wearItem(mask, player:getPlayerNum()) end
    ISTimedActionQueue.add(Action:new(player, target, "dismantle", DISMANTLE_TICKS))
end

-- ── 計時動作：重新上色 ──────────────────────────────────────────────────
-- 同上不定義 complete，只在本機跑；perform 送意圖，伺服器重驗油漆、刷子、物品／擁有權後才換色並扣油漆
-- （Server.lua H.recolor／H.recolorReader）。動畫、手上模型、音效與時間照原版 ISPaintAction.lua:19-31、:87-93
local PAINT_TICKS = 100
local Paint = ISBaseTimedAction:derive("KnoxPassPaintAction")
Paint.__index = Paint
C.Paint = Paint

function Paint:isValid()
    if not KP.paintFor(self.character, self.color) then return false end
    local door = self.door
    if door then return door:getSquare() ~= nil and door:getObjectIndex() ~= -1 end
    return self.character:getInventory():getItemWithIDRecursiv(self.itemId) ~= nil
end

function Paint:waitToStart()
    if not self.door then return false end
    self.character:faceThisObject(self.door)
    return self.character:shouldBeTurning()
end

function Paint:update()
    if self.door then self.character:faceThisObject(self.door) end
    self.character:setMetabolicTarget(Metabolics.LightWork)
end

function Paint:start()
    self:setActionAnim(CharacterActionAnims.Paint)
    self:setOverrideHandModels("PaintBrush", nil)
    self.sound = self.character:playSound("Painting")
end

function Paint:stop()
    if self.sound then self.character:stopOrTriggerSound(self.sound) end
    ISBaseTimedAction.stop(self)
end

function Paint:perform()
    if self.sound then self.character:stopOrTriggerSound(self.sound) end
    if self.door then
        C.send(self.character, "recolorReader", { key = self.key, color = self.color })
    else
        C.send(self.character, "recolor", { itemId = self.itemId, color = self.color })
    end
    ISBaseTimedAction.perform(self)
end

function Paint:new(character, color)
    local o = ISBaseTimedAction.new(self, character)
    o.color = color
    o.maxTime = character:isTimedActionInstant() and 1 or PAINT_TICKS
    return o
end

-- target＝{ item = 物品欄的感應盒或讀頭 } 或 { door = 錨點, key = 帳本 key }（門上的讀頭：走到錨點，伺服器以錨點格量距離）
function C.queueRecolor(player, target, color)
    local action = Paint:new(player, color)
    if target.door then
        if not luautils.walkAdjWindowOrDoor(player, target.door:getSquare(), target.door) then return end
        action.door, action.key = target.door, target.key
    else
        action.itemId = target.item:getID()
    end
    ISTimedActionQueue.add(action)
end

-- ── 右鍵選單 ────────────────────────────────────────────────────────────

-- client 顯示用的管理權（規則同伺服器 Server.lua canManage／ownerOrAdmin，伺服器照樣重驗）：SP 一律可管；MP 看錨點標記上的
-- 擁有者、共同管理者（帳號名單、擁有者陣營的成員，或和擁有者同在一間勾選的安全屋）與管理員角色。
-- 回傳 能管理, 是擁有者或管理員（能拆讀頭、改名單）
local function access(player, md)
    if not isClient() then return true, true end
    local me, owner = player:getUsername(), md[KP.MARKER_OWNER]
    if me == owner or KP.hasAdminRole(player) then return true, true end
    local co = md[KP.MARKER_CO]
    if type(co) == "table" and co[me] then return true, false end
    if md[KP.MARKER_COFACTION] == true and KP.inFactionOf(owner, me) then return true, false end
    local houses = md[KP.MARKER_COHOUSES]
    for key in pairs(type(houses) == "table" and houses or {}) do
        if KP.sharesHouse(key, owner, me) then return true, false end
    end
    return false, false
end

local function tip(option, textKey)
    local t = ISWorldObjectContextMenu.addToolTip() -- 池化 tooltip，ISWorldObjectContextMenu.lua:2631
    t.description = getText(textKey)
    option.toolTip = t
end

local function disable(option, textKey)
    option.notAvailable = true
    if textKey then tip(option, textKey) end
end

local function onManage(player, anchor, key) KP.Window.open(player, anchor, key) end
local function onLock(player, key, on) C.send(player, "lock", { key = key, on = on }) end
-- 門開著時給「用 Knox Pass 關門」：門被會開門的殭屍或有鑰匙的人打開時，Knox Pass 門鎖讓原版的「關門」灰掉（couldBeOpen 看
-- CustomLock，ISWorldObjectContextMenuLogic.java:2375-2380），這是關回去的路。伺服器 H.open／H.close 重驗權限
local function onOpen(player, key) C.send(player, "open", { key = key }) end
local function onClose(player, key) C.send(player, "close", { key = key }) end
local function addOpenClose(sub, player, adapter, anchor, key)
    if G.isOpen(adapter, anchor) then return sub:addOption(getText("ContextMenu_KnoxPass_Close"), player, onClose, key) end
    return sub:addOption(getText("ContextMenu_KnoxPass_Open"), player, onOpen, key)
end

-- 「重新上色」子選單：列出 current 以外的顏色；缺刷子或該色油漆的灰掉並提示（原版 notAvailable＋池化 tooltip，
-- addTip＝該選單的 tooltip 池：ISWorldObjectContextMenu.lua:2631／ISInventoryPaneContextMenu.lua:3390）
local function recolorMenu(menu, player, current, addTip, target)
    local sub = ISContextMenu:getNew(menu)
    menu:addSubMenu(menu:addOption(getText("ContextMenu_KnoxPass_Recolor"), nil, nil), sub)
    for i, c in ipairs(KP.COLORS) do
        if i - 1 ~= current then
            local opt = sub:addOption(getText("IGUI_KnoxPass_Color_" .. c.id), player, C.queueRecolor, target, i - 1)
            local _, why = KP.paintFor(player, i - 1)
            if why then
                opt.notAvailable = true
                local t = addTip()
                t.description = why == "NoBrush" and getText("IGUI_KnoxPass_Why_NoBrush")
                    or getText("IGUI_KnoxPass_NeedPaint", getItemNameFromFullType(c.paint))   -- LuaManager.java:8539-8543
                opt.toolTip = t
            end
        end
    end
end

-- 右鍵點到的門。原版右鍵只把滑鼠下那一個物件交給選單：引擎照 2D 遮罩選（FBORenderObjectPicker.java:78），
-- 放開時 doRClick 只交出它（ISObjectClickHandler.lua:23-63）；原版的「門」另外掃它所在的格（ISWorldObjectContextMenuLogic.java:592-595）。
-- 閘門與模型門畫的是 3D 模型（2026-10-08 正式服回報雙桿閘門右鍵只有原版「門」；menupick-sp 1008d 實點）：
-- 1. 點門下的路面選到地板 → 照原版掃同格
-- 2. 點機箱或門柱選到那一端 → 沿整座找車道（KP.Barrier 在 server/Barrier.lua，客戶端也會載入 server 目錄，GameLoadingState.java:149）
-- 3. 模型門的車道片沒有 2D 圖，點在桿子或門扇上選到的是門線後面的地板（北邊 2 格）→ 從點到的格往鏡頭方向（+x +y）找車道門片，
--    滑鼠落在門線往上 BODY_FLOORS 層的範圍內就算。高度取關著時的外形加一點餘量；抬起的桿子上半段點不到，點機箱即可
local BODY_FLOORS = { Barrier = 0.6, Gate = 2.0, Garage = 2.2 }
local function onBody(door, floors, mx, my)
    local x, y, z = door:getX(), door:getY(), door:getZ()
    local x2, y2 = x + 1, y
    if not door:getNorth() then x2, y2 = x, y + 1 end
    local ax, ay = isoToScreenX(0, x, y, z), isoToScreenY(0, x, y, z)
    local bx, by = isoToScreenX(0, x2, y2, z), isoToScreenY(0, x2, y2, z)
    if mx < math.min(ax, bx) or mx > math.max(ax, bx) then return false end
    local base = ay + (by - ay) * (mx - ax) / (bx - ax)
    return my <= base + 4 and my >= base + isoToScreenY(0, x, y, z + floors) - ay
end
local function gateBody(squares, mx, my)
    for _, sq in ipairs(squares) do
        local x0, y0, z = sq:getX(), sq:getY(), sq:getZ()
        for d = 0, 7 do
            for _, o in ipairs({ { d, d }, { d + 1, d }, { d, d + 1 } }) do
                local s = getCell():getGridSquare(x0 + o[1], y0 + o[2], z)
                local objects = s and s:getObjects()
                for i = 0, (objects and objects:size() or 0) - 1 do
                    local obj = objects:get(i)
                    local floors = instanceof(obj, "IsoDoor") and BODY_FLOORS[KP.gateKind(obj)]
                    if floors and onBody(obj, floors, mx, my) then
                        local adapter, anchor = G.resolve(obj)
                        if adapter then return obj, adapter, anchor end
                    end
                end
            end
        end
    end
    return nil
end
local function findGate(playerIndex, worldobjects)
    local list, seen, squares, onSquare = {}, {}, {}, {}
    local function push(o)
        if o and not seen[o] then seen[o] = true; list[#list + 1] = o end
    end
    for _, o in ipairs(worldobjects) do push(o) end
    for _, o in ipairs(worldobjects) do
        local sq = o.getSquare and o:getSquare()
        if sq and not onSquare[sq] then
            onSquare[sq] = true
            squares[#squares + 1] = sq
            local objects = sq:getObjects()
            for i = 0, objects:size() - 1 do push(objects:get(i)) end
        end
    end
    for _, o in ipairs(list) do
        local adapter, anchor = G.resolve(o)
        if adapter then return o, adapter, anchor end
    end
    for _, o in ipairs(list) do
        if KP.isGateEnd(o) then
            for _, piece in ipairs(KP.Barrier.parts(o) or {}) do
                local adapter, anchor = G.resolve(piece)
                if adapter then return piece, adapter, anchor end
            end
        end
    end
    -- 滑鼠只屬於第 1 位玩家；手把開的選單（JoypadState，同原版 ISWorldObjectContextMenu.lua:956）不看滑鼠
    if playerIndex == 0 and not JoypadState.players[1] then return gateBody(squares, getMouseX(), getMouseY()) end
    return nil
end

-- 拆除要走去的那一片（伺服器 H.dismantle 以它的格子量距離、在那裡退料）：點到整座的一端就用它，點到車道或門身用離玩家近的
-- 那一端；兩層樓捲門沒有兩端，用點到的門片。不是本 MOD 蓋的閘門、大門（原版門、一層樓捲門）回 nil
local function dismantleTarget(player, door, worldobjects)
    local ends = {}
    for _, o in ipairs(KP.Barrier.parts(door) or {}) do
        if KP.isGateEnd(o) then ends[#ends + 1] = o end
    end
    if #ends == 0 then return KP.Barrier.dismantle(door) and door or nil end
    local best, bestD = nil, nil
    for _, e in ipairs(ends) do
        for _, o in ipairs(worldobjects) do
            if o == e then return e end
        end
        local dx, dy = e:getX() - player:getX(), e:getY() - player:getY()
        if not bestD or dx * dx + dy * dy < bestD then best, bestD = e, dx * dx + dy * dy end
    end
    return best
end

-- 「拆除整座閘門／大門」：裝了讀頭的只有擁有者與管理員能拆（allowed，伺服器 H.dismantle 回 OwnerOnly）；缺工具灰掉並寫缺什麼
local function addDismantle(sub, player, target, allowed)
    if not target then return end
    local label = KP.isBarrier(target) and "ContextMenu_KnoxPass_DismantleBarrier" or "ContextMenu_KnoxPass_DismantleGate"
    local opt = sub:addOption(getText(label), player, C.queueDismantle, target)
    local tool, why = KP.dismantleTool(player, target) -- 成功回 (工具, 面罩)，失敗回 (nil, 原因)
    if not allowed then
        disable(opt, "IGUI_KnoxPass_Why_OwnerOnly")
    elseif not tool then
        disable(opt, "IGUI_KnoxPass_Why_" .. why)
    else
        tip(opt, "IGUI_KnoxPass_DismantleTip")
    end
end

-- 42.22 撬棍「撬開」：裝了讀頭的門伺服器一律不讓撬（Server.lua 包 ISForceOpen.attempt），選單也不列。選項由 Java
-- ISContextMenuWrapper.addGetUpOption 建，參數排成 param1＝onForceOpen、param2＝worldobjects、param3＝門（ISContextMenuWrapper.java:150-164、
-- ISWorldObjectContextMenuLogic.java:2312-2319）；onSelect 是那份選單 rawget 到的 onGetUpAndThen，不拿來比。它在「門」子選單裡，
-- 子選單由 Java getNew 建、登記在根選單的 instanceMap（ISContextMenuWrapper.java:289-321）
local function hideForce(context)
    local force = ISWorldObjectContextMenu.onForceOpen
    if not force then return end   -- 42.21 沒有撬開
    local menus = { context }
    for _, m in pairs(context.instanceMap or {}) do menus[#menus + 1] = m end
    for _, m in ipairs(menus) do
        for i = #m.options, 1, -1 do
            local o = m.options[i]
            if o.param1 == force then
                local _, anchor = G.resolve(o.param3)
                if anchor and anchor:hasModData() and anchor:getModData()[KP.MARKER_OWNER] then m:removeOptionByName(o.name) end
            end
        end
    end
end

-- 事件簽名 (playerIndex, context, worldobjects, test)：ISWorldObjectContextMenu.lua:213；
-- 別人的保險屋內本來就不觸發（同檔 :211）
local function onFillMenu(playerIndex, context, worldobjects, test)
    if test then return end
    hideForce(context)
    local player = getSpecificPlayer(playerIndex)
    if not player then return end
    local door, adapter, anchor = findGate(playerIndex, worldobjects)
    if not door then return end

    local md = anchor:getModData()
    local owner = md[KP.MARKER_OWNER]
    local hasScrewdriver = KP.screwdriverOf(player) ~= nil
    local target = dismantleTarget(player, door, worldobjects)   -- 本 MOD 蓋的閘門、大門一律出選單（沒裝讀頭也拆得到）
    local carriesReader = player:getInventory():containsEvalRecurse(KP.isReader)   -- ItemContainer.java:1194
    if not owner and not target and not carriesReader then return end

    local root = context:addOption(getText("ContextMenu_KnoxPass"), nil, nil)
    local sub = ISContextMenu:getNew(context)
    context:addSubMenu(root, sub)

    if not owner then
        if carriesReader then
            local opt = sub:addOption(getText("ContextMenu_KnoxPass_Install"), player, C.queueInstall, door)
            if not hasScrewdriver then
                disable(opt, "IGUI_KnoxPass_NeedScrewdriver")
            elseif not KP.installAllowedAt(anchor:getSquare(), player:getUsername()) then
                disable(opt, "IGUI_KnoxPass_Why_InstallSafehouseOnly")   -- 沙盒「安全屋外的讀頭」＝不能安裝
            end
        end
        addDismantle(sub, player, target, true)   -- 沒裝讀頭照原版拆解：別人的安全屋裡本來就開不出選單（ISWorldObjectContextMenu.lua:211）
        return
    end

    local key = G.key(anchor)
    local manager, ownerOrAdmin = access(player, md)
    if not manager then
        disable(sub:addOption(getText("ContextMenu_KnoxPass_OtherOwner"), nil, nil), "IGUI_KnoxPass_OtherOwnerTip")
        tip(addOpenClose(sub, player, adapter, anchor, key), "IGUI_KnoxPass_OpenTip")
        addDismantle(sub, player, target, false)
        return
    end

    local manage = sub:addOption(getText("ContextMenu_KnoxPass_Manage"), player, onManage, anchor, key)
    if not KP.Window then disable(manage, "IGUI_KnoxPass_NeedFramework") end

    local locked = md[KP.MARKER_LOCK] == true
    local lock = sub:addOption(getText("ContextMenu_KnoxPass_Lock"), player, onLock, key, not locked)
    sub:setOptionChecked(lock, locked) -- ISContextMenu.lua:1084
    if not G.supportsLock(adapter) then
        disable(lock, "IGUI_KnoxPass_Why_NoLockSupport")
    elseif not locked and not KP.lockAllowedAt(anchor:getSquare(), owner) then
        disable(lock, "IGUI_KnoxPass_Why_LockSafehouseOnly")   -- 沙盒「安全屋外的讀頭」；已上鎖的照樣能關掉
    end

    addOpenClose(sub, player, adapter, anchor, key)

    -- 閘門的讀頭是內建的：不給拆（伺服器 H.uninstall 回 BuiltIn）、不分顏色，要拆整座閘門
    if not KP.isBarrier(anchor) then
        local remove = sub:addOption(getText("ContextMenu_KnoxPass_Remove"), player, C.queueUninstall, anchor, key)
        if not ownerOrAdmin then
            disable(remove, "IGUI_KnoxPass_Why_OwnerOnly")   -- 共同管理者不能拆讀頭（伺服器 H.uninstall 回 OwnerOnly）
        elseif not hasScrewdriver then
            disable(remove, "IGUI_KnoxPass_NeedScrewdriver")
        end
        recolorMenu(sub, player, md[KP.MARKER_COLOR] or 0, ISWorldObjectContextMenu.addToolTip, { door = anchor, key = key })
    end
    addDismantle(sub, player, target, ownerOrAdmin)
end

Events.OnFillWorldObjectContextMenu.Add(onFillMenu)

-- 物品欄右鍵：身上（含背包）的感應盒或讀頭可以重新上色。事件簽名 (playerIndex, context, items)：
-- ISInventoryPaneContextMenu.lua:935；items 混著物品與分組表，用 ISInventoryPane.getActualItems 攤平（ISInventoryPane.lua:915-936）。
-- 地上、別的容器、裝在車上的不給（伺服器 H.recolor 也只找玩家身上，isInPlayerInventory InventoryItem.java:2293-2296）
local function onFillInventoryMenu(playerIndex, context, items)
    local player = getSpecificPlayer(playerIndex)
    if not player then return end
    for _, item in ipairs(ISInventoryPane.getActualItems(items)) do
        local color = KP.colorOf(item)
        if color and item:isInPlayerInventory() then
            recolorMenu(context, player, color, ISInventoryPaneContextMenu.addToolTip, { item = item })
            return
        end
    end
end

Events.OnFillInventoryObjectContextMenu.Add(onFillInventoryMenu)
