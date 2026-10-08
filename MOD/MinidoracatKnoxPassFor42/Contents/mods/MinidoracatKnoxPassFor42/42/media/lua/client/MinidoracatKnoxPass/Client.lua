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

local INSTALL_TICKS, UNINSTALL_TICKS = 150, 100
local HALO_TICKS = 250 -- 預設 128（IsoGameCharacter.java:592）

-- 原版同名區域函式（ISWorldObjectContextMenu.lua:49-51）
local function predicateNotBroken(item) return not item:isBroken() end

local function screwdriverOf(player)
    -- ISWorldObjectContextMenu.lua:1369 同款
    return player:getInventory():getFirstTagEvalRecurse(ItemTag.SCREWDRIVER, predicateNotBroken)
end

-- ── 送指令與提示 ────────────────────────────────────────────────────────

-- OnServerCommand 不帶收件人：提示掛在最後送指令的本機玩家頭上
function C.send(player, command, args)
    C.lastPlayer = player
    sendClientCommand(player, KP.MODULE, command, args)
end

-- Toast（CAPABILITIES.toast）優先；沒有就 setHaloNote(str, r, g, b, dispTime)（IsoGameCharacter.java:6965）。
-- halo＝true 時 Toast 之外頭上也提示（駕駛預警：開車時視線在車上）
function C.say(player, text, bad, halo)
    local UI = MinidoracatUI and MinidoracatUI.v1
    if UI and UI.CAPABILITIES and UI.CAPABILITIES.toast and UI.Toast
        and pcall(UI.Toast.show, { title = getText("IGUI_KnoxPass_Title"), message = text, holdMs = 3500, maxLines = 3 })
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
    if args.ok then
        if args.cmd == "install" then C.say(player, getText("IGUI_KnoxPass_Installed"), false)
        elseif args.cmd == "uninstall" then C.say(player, getText("IGUI_KnoxPass_Uninstalled"), false)
        elseif args.cmd == "recolor" or args.cmd == "recolorReader" then C.say(player, getText("IGUI_KnoxPass_Recolored"), false) end
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
        -- 伺服器推送：我現在這顆感應盒登記了哪些門（KnoxPassAPI.willOpenFor 讀，Sensor.lua pushPasses）
        local keys = {}
        for _, key in pairs(type(args.keys) == "table" and args.keys or {}) do keys[key] = true end
        KP.passes = { tag = args.tag, keys = keys }
    end
end

-- 簽名 (module, command, args)：ServerCommands.lua:201-212
Events.OnServerCommand.Add(function(module, command, args)
    if module ~= KP.MODULE then return end
    KP.clientReceive(command, args)
end)

-- ── 計時動作：裝／拆讀頭 ────────────────────────────────────────────────
-- 只繼承 ISBaseTimedAction、不定義 complete：LuaTimedActionNew 看 metatable 上沒有 complete 就不走
-- NetTimedAction（LuaTimedActionNew.java:78），動作只在本機跑，perform 送指令由伺服器重驗（AutoDrive
-- ISAutoDriveDeviceAction 同做法）。derive 只設父類的 __index（ISBaseObject），明確設自己的查找入口
local Action = ISBaseTimedAction:derive("KnoxPassReaderAction")
Action.__index = Action
C.Action = Action

function Action:isValid()
    local door = self.door
    if not door or not door:getSquare() or door:getObjectIndex() == -1 then return false end
    local inv = self.character:getInventory()
    if not inv:containsTagEvalRecurse(ItemTag.SCREWDRIVER, predicateNotBroken) then return false end -- ISWorldObjectContextMenu.lua:1244
    -- getItemWithIDRecursiv：ItemContainer.java:3094（SP／MP client 都用 ID 找，不比物件參照）
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
    if self.command == "install" then
        local sq = self.door:getSquare()
        C.send(self.character, "install", { x = sq:getX(), y = sq:getY(), z = sq:getZ(),
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

-- 走到門邊（原版開關門／鎖門同款：ISWorldObjectContextMenu.lua:1516）→ 拿起子（:1370）→ 動作
local function queue(player, door, action)
    local screwdriver = screwdriverOf(player)
    if not screwdriver then return end
    if not luautils.walkAdjWindowOrDoor(player, door:getSquare(), door) then return end
    ISWorldObjectContextMenu.equip(player, player:getPrimaryHandItem(), screwdriver, true, false)
    ISTimedActionQueue.add(action)
end

function C.queueInstall(player, door)
    local reader = player:getInventory():getFirstEvalRecurse(KP.isReader)   -- 任何顏色（ItemContainer.java:1491）
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

-- client 顯示用的管理權：SP 一律可管（伺服器 canManage 同規則）；MP 看標記上的擁有者或管理員角色
-- （Capability 已曝露 LuaManager.java:2460；IsoPlayer.getRole 可能為 nil，Role.java:185-187）
local function canManage(player, owner)
    if not isClient() then return true end
    if owner == player:getUsername() then return true end
    if not Capability then return false end
    local ok, yes = pcall(function()
        local role = player:getRole()
        return role ~= nil and role:hasCapability(Capability.CanOpenLockedDoors)
    end)
    return ok and yes == true
end

local function tip(option, textKey)
    local t = ISWorldObjectContextMenu.addToolTip() -- 池化 tooltip，ISWorldObjectContextMenu.lua:2595
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
-- CustomLock，ISWorldObjectContextMenuLogic.java:2296-2301），這是關回去的路。伺服器 H.open／H.close 重驗權限
local function onOpen(player, key) C.send(player, "open", { key = key }) end
local function onClose(player, key) C.send(player, "close", { key = key }) end
local function addOpenClose(sub, player, adapter, anchor, key)
    if G.isOpen(adapter, anchor) then return sub:addOption(getText("ContextMenu_KnoxPass_Close"), player, onClose, key) end
    return sub:addOption(getText("ContextMenu_KnoxPass_Open"), player, onOpen, key)
end

-- 「重新上色」子選單：列出 current 以外的顏色；缺刷子或該色油漆的灰掉並提示（原版 notAvailable＋池化 tooltip，
-- addTip＝該選單的 tooltip 池：ISWorldObjectContextMenu.lua:2595／ISInventoryPaneContextMenu.lua:3417）
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
                    or getText("IGUI_KnoxPass_NeedPaint", getItemNameFromFullType(c.paint))   -- LuaManager.java:8603-8607
                opt.toolTip = t
            end
        end
    end
end

-- 事件簽名 (playerIndex, context, worldobjects, test)：ISWorldObjectContextMenu.lua:213；
-- 別人的保險屋內本來就不觸發（同檔 :211）
local function onFillMenu(playerIndex, context, worldobjects, test)
    if test then return end
    local player = getSpecificPlayer(playerIndex)
    if not player then return end
    local door, adapter, anchor
    for _, o in ipairs(worldobjects) do
        adapter, anchor = G.resolve(o)
        if adapter then
            door = o
            break
        end
    end
    if not door then return end

    local md = anchor:getModData()
    local owner = md[KP.MARKER_OWNER]
    local hasScrewdriver = screwdriverOf(player) ~= nil
    if not owner and not player:getInventory():containsEvalRecurse(KP.isReader) then return end   -- ItemContainer.java:1146

    local root = context:addOption(getText("ContextMenu_KnoxPass"), nil, nil)
    local sub = ISContextMenu:getNew(context)
    context:addSubMenu(root, sub)

    if not owner then
        local opt = sub:addOption(getText("ContextMenu_KnoxPass_Install"), player, C.queueInstall, door)
        if not hasScrewdriver then disable(opt, "IGUI_KnoxPass_NeedScrewdriver") end
        return
    end

    local key = G.key(anchor)
    if not canManage(player, owner) then
        disable(sub:addOption(getText("ContextMenu_KnoxPass_OtherOwner"), nil, nil))
        tip(addOpenClose(sub, player, adapter, anchor, key), "IGUI_KnoxPass_OpenTip")
        return
    end

    local manage = sub:addOption(getText("ContextMenu_KnoxPass_Manage"), player, onManage, anchor, key)
    if not KP.Window then disable(manage, "IGUI_KnoxPass_NeedFramework") end

    local locked = md[KP.MARKER_LOCK] == true
    local lock = sub:addOption(getText("ContextMenu_KnoxPass_Lock"), player, onLock, key, not locked)
    sub:setOptionChecked(lock, locked) -- ISContextMenu.lua:1084
    if not G.supportsLock(adapter) then disable(lock, "IGUI_KnoxPass_Why_NoLockSupport") end

    addOpenClose(sub, player, adapter, anchor, key)

    -- 閘門的讀頭是內建的：不給拆（伺服器 H.uninstall 回 BuiltIn）、不分顏色，拆整座閘門走拆除機箱
    if KP.isBarrier(anchor) then return end
    local remove = sub:addOption(getText("ContextMenu_KnoxPass_Remove"), player, C.queueUninstall, anchor, key)
    if not hasScrewdriver then disable(remove, "IGUI_KnoxPass_NeedScrewdriver") end
    recolorMenu(sub, player, md[KP.MARKER_COLOR] or 0, ISWorldObjectContextMenu.addToolTip, { door = anchor, key = key })
end

Events.OnFillWorldObjectContextMenu.Add(onFillMenu)

-- 物品欄右鍵：身上（含背包）的感應盒或讀頭可以重新上色。事件簽名 (playerIndex, context, items)：
-- ISInventoryPaneContextMenu.lua:935；items 混著物品與分組表，用 ISInventoryPane.getActualItems 攤平（ISInventoryPane.lua:912-933）。
-- 地上、別的容器、裝在車上的不給（伺服器 H.recolor 也只找玩家身上，isInPlayerInventory InventoryItem.java:2278-2281）
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
