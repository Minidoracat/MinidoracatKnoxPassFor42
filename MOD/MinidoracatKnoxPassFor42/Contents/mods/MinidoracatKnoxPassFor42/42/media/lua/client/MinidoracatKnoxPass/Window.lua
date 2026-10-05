-- Knox Pass 讀頭管理視窗（MinidoracatUIFor42 API rev 7：Window／Button／Checkbox／VirtualList，Dialog 選用）。
-- 畫面只顯示伺服器 state；所有變更送指令後等新的 state，不做樂觀更新。
-- 框架不足時整檔在這裡結束：KP.Window 不存在，右鍵「管理讀頭」改成停用並提示（Client.lua）。
require "MinidoracatKnoxPass/Client"
local KP = MinidoracatKnoxPass
local C = KP.Client

-- widget 檔不由 V1 載入，也不保證排在本檔之前（MinidoracatKnoxPass < MinidoracatUI），自己 pcall require
if not (MinidoracatUI and MinidoracatUI.v1) then pcall(require, "MinidoracatUI/V1") end
pcall(require, "MinidoracatUI/VirtualList")
pcall(require, "MinidoracatUI/Widgets/Controls")
pcall(require, "MinidoracatUI/Widgets/Window")
local UI = MinidoracatUI and MinidoracatUI.v1
local CAPS = UI and UI.CAPABILITIES
if not (UI and UI.API_MAJOR == 1 and UI.API_REVISION >= 7 and CAPS.window and CAPS.controls and CAPS.virtualList) then
    if UI then KP.log("manage window needs MinidoracatUIFor42 API rev 7, found rev " .. tostring(UI.API_REVISION)) end
    return
end

local theme = UI.Theme.create({ colors = { surface = { r = 0.04, g = 0.045, b = 0.05, a = 0.95 } } })
local COL = theme.colors
local FS = UIFont.Small
local PAD, GAP = 12, 6
local W = 460
local CLOSE_RANGE = 6
local LAYOUT = "MinidoracatKnoxPassWindow"

local function text(el, s, x, y, token)
    local c = COL[token]
    el:drawText(s, x, y, c.r, c.g, c.b, c.a, FS)
end

-- 截字只在綁定時做（UI.Text.fit 是 rev 11）；舊版框架不截
local function fit(s, w)
    if UI.Text and type(UI.Text.fit) == "function" then return UI.Text.fit(s, w, FS) end
    return s
end

-- 原版車名鍵（ISVehicleMechanics.lua:1155）；找不到鍵 getText 回鍵本身，退回短名。
-- 沒有車型＝感應盒拆下來了（Server.lua onTagUninstalled）
local function vehicleName(script)
    if script == nil then return getText("IGUI_KnoxPass_TagNotInstalled") end
    local short = tostring(script or "?"):gsub("^.-%.", "")
    local key = "IGUI_VehicleName" .. short
    local t = getText(key)
    if t == key then return short end
    return t
end

local function chargeText(charge)
    if charge == nil then return getText("IGUI_KnoxPass_ChargeAway") end
    return getText("IGUI_KnoxPass_Charge", tostring(charge))
end

local function agoText(hours)
    if type(hours) ~= "number" then return getText("IGUI_KnoxPass_LastNever") end
    if hours < 1 then return getText("IGUI_KnoxPass_AgoMinutes", tostring(math.max(1, math.floor(hours * 60)))) end
    if hours < 24 then return getText("IGUI_KnoxPass_AgoHours", tostring(math.floor(hours))) end
    return getText("IGUI_KnoxPass_AgoDays", tostring(math.floor(hours / 24)))
end

-- ── 清單列：兩行文字，字串在 bind 時算好，render 不配置 ──────────────────
local Cell = ISPanel:derive("KnoxPassCell")
function Cell:render()
    if not self.title then return end
    local list = self.list
    if list:isSelected(self.index) then
        theme:fill(self, 0, 0, self.width, self.height, "selected")
    elseif list:isMouseOver() and list:indexAt(list:getMouseX(), list:getMouseY()) == self.index then
        theme:fill(self, 0, 0, self.width, self.height, "hover")
    end
    local mid = math.floor(self.height / 2)
    text(self, self.title, 8, mid - self.fh - 1, self.titleToken)
    text(self, self.sub, 8, mid + 1, "textMuted")
end

local function newList(win, y, h, bind, onSelect)
    local fh = win.fh
    local list = UI.VirtualList.new({ x = PAD, y = y, width = W - PAD * 2, height = h, rowHeight = fh * 2 + 12, padding = 2,
        createCell = function(l)
            local c = Cell:new(0, 0, 0, 0)
            c.background = false
            c.list, c.fh = l, fh
            return c
        end,
        bindCell = function(_, c, row, index)
            c.index = index
            bind(c, row, c.width - 16)
        end,
        unbindCell = function(_, c) c.title = nil end,
        onSelect = onSelect,
        colors = { thumb = COL.textFaint, thumbHover = COL.textMuted, track = COL.hover } })
    list:initialise()
    win.body:addChild(list)
    return list
end

-- ── 內容區：prerender 檢查距離並畫清單底，render 畫資訊列與段落標題 ─────
local Body = ISPanel:derive("KnoxPassBody")
function Body:prerender()
    local w = self.kp
    local p = w.player
    -- 只做數值比較，不配置
    if not p or p:isDead() or math.floor(p:getZ()) ~= w.gz
        or math.abs(p:getX() - w.gx) > CLOSE_RANGE or math.abs(p:getY() - w.gy) > CLOSE_RANGE then
        w.win:close()
        return
    end
    theme:fill(self, PAD, w.tagsY, W - PAD * 2, w.listH, "well")
    theme:fill(self, PAD, w.nearY, W - PAD * 2, w.listH, "well")
end
function Body:render() self.kp:draw(self) end

local Win = {}
Win.__index = Win
KP.Window = Win

function Win.new()
    local self = setmetatable({ rows = {}, state = nil }, Win)
    local fh = getTextManager():getFontHeight(FS)
    local ch = fh + 10
    self.fh, self.lineH = fh, fh + 6
    self.listH = (fh * 2 + 14) * 3 + 2 -- 三列（rowHeight＋padding）
    -- 高度跟字型走：資訊四列＋門鎖＋兩段（標題列＋清單）＋頁尾
    local bodyH = PAD + self.lineH * 4 + ch + GAP + (ch + GAP + self.listH + PAD) * 2 + ch + PAD
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    self.win = UI.Window.new({ x = math.floor((sw - W) / 2), y = math.floor((sh - bodyH) / 2) - 20, width = W,
        height = bodyH + 40, title = getText("IGUI_KnoxPass_Title"), theme = theme })
    local top = self.win:contentTop()
    self.win:setHeight(top + bodyH)
    local body = Body:new(0, top, W, bodyH)
    body.background = false
    body.kp = self
    body:initialise()
    self.win:addChild(body)
    self.body = body

    local y = PAD
    self.infoY = y
    y = y + self.lineH * 4 -- 種類、擁有者、供電、門
    self.lock = UI.Checkbox.new({ x = PAD, y = y, width = W - PAD * 2, label = getText("IGUI_KnoxPass_Lock"),
        theme = theme, target = self, onChange = Win.onLock })
    body:addChild(self.lock)
    y = y + ch + GAP

    self.tagsHeadY = y
    self.btnRemoveTag = UI.Button.new({ x = 0, y = y, height = ch, title = getText("IGUI_KnoxPass_Unregister"),
        style = "danger", theme = theme, target = self, onClick = Win.onUnregister })
    self.btnRemoveTag:setX(W - PAD - self.btnRemoveTag.width)
    body:addChild(self.btnRemoveTag)
    y = y + ch + GAP
    self.tagsY = y
    self.tags = newList(self, y, self.listH, Win.bindTag, function() self:refreshButtons() end)
    y = y + self.listH + PAD

    self.nearHeadY = y
    self.btnRegister = UI.Button.new({ x = 0, y = y, height = ch, title = getText("IGUI_KnoxPass_Register"),
        style = "primary", theme = theme, target = self, onClick = Win.onRegister })
    self.btnRegister:setX(W - PAD - self.btnRegister.width)
    body:addChild(self.btnRegister)
    y = y + ch + GAP
    self.nearY = y
    self.near = newList(self, y, self.listH, Win.bindNear, function() self:refreshButtons() end)

    local footY = body.height - PAD - ch
    self.btnRemoveReader = UI.Button.new({ x = PAD, y = footY, height = ch, title = getText("IGUI_KnoxPass_RemoveReader"),
        style = "danger", theme = theme, target = self, onClick = Win.onRemoveReader })
    body:addChild(self.btnRemoveReader)
    local close = UI.Button.new({ x = 0, y = footY, height = ch, title = getText("IGUI_KnoxPass_Close"), theme = theme,
        onClick = function() self.win:close() end })
    close:setX(W - PAD - close.width)
    body:addChild(close)
    return self
end

function Win.bindTag(c, row, w)
    c.title, c.titleToken = fit(vehicleName(row.script), w), "text"
    c.sub = fit(tostring(row.serial) .. "   " .. chargeText(row.charge) .. "   "
        .. getText("IGUI_KnoxPass_LastPassed", agoText(row.lastHours)), w)
end

function Win.bindNear(c, row, w)
    local name = vehicleName(row.script)
    if row.registered then name = name .. "  " .. getText("IGUI_KnoxPass_Registered") end
    c.title, c.titleToken = fit(name, w), row.registered and "textMuted" or "text"
    c.sub = fit(tostring(row.serial) .. "   " .. getText("IGUI_KnoxPass_Distance", tostring(row.dist)) .. "   "
        .. chargeText(row.charge), w)
end

-- state 到達時算好資訊列字串（draw 每幀只畫）
function Win:apply(s)
    self.state = s
    local rows = self.rows
    rows[1] = getText("IGUI_KnoxPass_Kind_" .. tostring(s.kind))
    rows[2] = tostring(s.owner or "?")
    if not s.needPower then rows[3], self.powerToken = getText("IGUI_KnoxPass_PowerNotNeeded"), "textMuted"
    elseif s.powered then rows[3], self.powerToken = getText("IGUI_KnoxPass_Powered"), "text"
    else rows[3], self.powerToken = getText("IGUI_KnoxPass_NoPower"), "errorText" end
    rows[4] = getText(s.open and "IGUI_KnoxPass_DoorOpen" or "IGUI_KnoxPass_DoorClosed")
    self.tagsHead = getText("IGUI_KnoxPass_Registered_Title", tostring(s.tags and #s.tags or 0))
    self.lock:setChecked(s.lock == true, true)
    self.lock:setEnabled(s.manager == true and s.lockSupported ~= false)
    self.lock:setLabel(getText(s.lockSupported == false and "IGUI_KnoxPass_LockUnsupported" or "IGUI_KnoxPass_Lock"))
    self.tags:setItems(s.tags or {})
    self.near:setItems(s.nearby or {})
    self:refreshButtons()
end

function Win:refreshButtons()
    local manager = self.state ~= nil and self.state.manager == true
    local row = self.near:getSelectedItem()
    self.btnRemoveTag:setEnabled(manager and self.tags:getSelectedItem() ~= nil)
    self.btnRegister:setEnabled(manager and row ~= nil and not row.registered)
    -- 閘門的讀頭是內建的（伺服器 H.uninstall 回 BuiltIn）：拆整座閘門走拆除機箱
    self.btnRemoveReader:setEnabled(manager and self.state.kind ~= "Barrier")
end

local LABELS = { "IGUI_KnoxPass_Kind", "IGUI_KnoxPass_Owner", "IGUI_KnoxPass_Power", "IGUI_KnoxPass_Door" }

function Win:draw(el)
    local s = self.state
    if not s then
        text(el, self.loading, PAD, self.infoY, "textMuted")
        return
    end
    local valueX = PAD + self.labelW
    for i = 1, 4 do
        local y = self.infoY + (i - 1) * self.lineH
        text(el, self.labels[i], PAD, y, "textMuted")
        text(el, self.rows[i], valueX, y, i == 3 and self.powerToken or "text")
    end
    -- 段落標題與右側按鈕同高（按鈕高 fh+10，文字下移 5 置中）
    text(el, self.tagsHead, PAD, self.tagsHeadY + 5, "accent")
    text(el, self.nearHead, PAD, self.nearHeadY + 5, "accent")
    if not s.manager then
        text(el, self.notManager, PAD + 8, self.tagsY + 8, "textMuted")
    elseif #self.tags:getItems() == 0 then
        text(el, self.emptyTags, PAD + 8, self.tagsY + 8, "textFaint")
    end
    if s.manager and #self.near:getItems() == 0 then
        text(el, self.emptyNear, PAD + 8, self.nearY + 8, "textFaint")
    end
end

-- ── 按鈕 ────────────────────────────────────────────────────────────────

function Win:onLock(checked)
    C.send(self.player, "lock", { key = self.key, on = checked == true })
end

function Win:onUnregister()
    local row = self.tags:getSelectedItem()
    if row then C.send(self.player, "unregister", { key = self.key, tagId = row.id }) end
end

function Win:onRegister()
    local row = self.near:getSelectedItem()
    if row and not row.registered then C.send(self.player, "register", { key = self.key, vehicleId = row.vid }) end
end

function Win:onRemoveReader()
    local player, anchor, key = self.player, self.anchor, self.key
    local function go() C.queueUninstall(player, anchor, key) end
    if not CAPS.dialog then return go() end
    UI.Dialog.show({ title = getText("IGUI_KnoxPass_Title"), text = getText("IGUI_KnoxPass_ConfirmRemove"), theme = theme,
        confirmText = getText("UI_Ok"), cancelText = getText("UI_Cancel"), danger = true,
        onResult = function(ok) if ok then go() end end })
end

-- ── 入口（Client.lua 呼叫）──────────────────────────────────────────────

local function ensure()
    if Win.instance then return Win.instance end
    local w = Win.new()
    -- 固定字串建立時取一次，draw 不查譯文
    w.labels = {}
    w.labelW = 0
    for i, k in ipairs(LABELS) do
        w.labels[i] = getText(k)
        w.labelW = math.max(w.labelW, getTextManager():MeasureStringX(FS, w.labels[i]))
    end
    w.labelW = w.labelW + 16
    w.loading = getText("IGUI_KnoxPass_Loading")
    w.nearHead = getText("IGUI_KnoxPass_Nearby_Title")
    w.notManager = getText("IGUI_KnoxPass_NotManager")
    w.emptyTags = getText("IGUI_KnoxPass_NoTags")
    w.emptyNear = getText("IGUI_KnoxPass_NoNearby")
    w.win:addToUIManager()
    w.win:setVisible(false)
    ISLayoutManager.RegisterWindow(LAYOUT, w.win, w.win) -- Window 自帶 SaveLayout／RestoreLayout
    Win.instance = w
    return w
end

function Win.open(player, anchor, key)
    local w = ensure()
    local sq = anchor:getSquare()
    w.player, w.anchor, w.key = player, anchor, key
    w.gx, w.gy, w.gz = sq:getX() + 0.5, sq:getY() + 0.5, sq:getZ()
    w.state = nil
    w.tags:setItems({})
    w.near:setItems({})
    w.lock:setChecked(false, true)
    w.lock:setEnabled(false)
    w:refreshButtons()
    w.win:setVisible(true)
    w.win:bringToTop()
    C.send(player, "query", { key = key })
end

local function shown(key)
    local w = Win.instance
    if w and w.win:getIsVisible() and key == w.key then return w end
    return nil
end

function Win.onState(s)
    local w = shown(s.key)
    if w then w:apply(s) end
end

function Win.onResult(r)
    local w = shown(r.key)
    if not w then return end
    if r.ok and r.cmd == "uninstall" then
        w.win:close()
    elseif not r.ok and r.cmd == "lock" and w.state then
        w.lock:setChecked(w.state.lock == true, true) -- 被拒時開關回到伺服器狀態
    end
end
