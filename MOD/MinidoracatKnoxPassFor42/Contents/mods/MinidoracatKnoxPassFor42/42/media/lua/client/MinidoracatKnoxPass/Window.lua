-- Knox Pass 讀頭管理視窗（MinidoracatUIFor42 API rev 7：Window／Button／Checkbox／Tabs／VirtualList，Dialog 選用；
-- 每扇門設定的下拉選單要 rev 14 的 Dropdown，沒有時只顯示數字）。
-- 畫面只顯示伺服器 state；所有變更送指令後等新的 state，不做樂觀更新。視窗開著時地上畫出這扇門的感應範圍。
-- 框架不足時整檔在這裡結束：KP.Window 不存在，右鍵「管理讀頭」改成停用並提示（Client.lua）。
require "MinidoracatKnoxPass/Client"
local KP = MinidoracatKnoxPass
local C = KP.Client

-- widget 檔不由 V1 載入，也不保證排在本檔之前（MinidoracatKnoxPass < MinidoracatUI），自己 pcall require
if not (MinidoracatUI and MinidoracatUI.v1) then pcall(require, "MinidoracatUI/V1") end
pcall(require, "MinidoracatUI/VirtualList")
pcall(require, "MinidoracatUI/Widgets/Controls")
pcall(require, "MinidoracatUI/Widgets/Window")
pcall(require, "MinidoracatUI/Widgets/Dropdown")
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
local DD_W = 210                                  -- 設定下拉選單寬度（英文「Server default (8 tiles)」放得下；右邊接著寫上下限）
local AMBER = { 0.91, 0.64, 0.24 }                -- 地上範圍圈＝Knox Pass 琥珀色 #e8a33d
local LAYOUT = "MinidoracatKnoxPassWindow"
local RETRY_MS = 2000                             -- 讀取失敗後，站進大門 3 格內每隔多久重讀一次

local function text(el, s, x, y, token)
    local c = COL[token]
    el:drawText(s, x, y, c.r, c.g, c.b, c.a, FS)
end

-- 截字只在綁定時做（UI.Text.fit 是 rev 11）；舊版框架不截
local function fit(s, w)
    if UI.Text and type(UI.Text.fit) == "function" then return UI.Text.fit(s, w, FS) end
    return s
end

-- 長句換行（UI.Text.wrap 是 rev 16，同樣的字與寬回同一張表）；舊版框架不換行
local function wrap(s, w)
    if UI.Text and type(UI.Text.wrap) == "function" then return UI.Text.wrap(s, w, FS) end
    return { s }
end

local function drawLines(el, lines, x, y, lineH, token)
    for i = 1, #lines do text(el, lines[i], x, y + (i - 1) * lineH, token) end
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

-- 專案禁用 table.sort（verify_mod.py）；清單最多約一百列，用插入排序（穩定：同值照伺服器給的順序）
local function sortRows(rows, before)
    for i = 2, #rows do
        local r, j = rows[i], i - 1
        while j >= 1 and before(r, rows[j]) do
            rows[j + 1] = rows[j]
            j = j - 1
        end
        rows[j + 1] = r
    end
    return rows
end

-- 已登記：最近通過的在前，沒通過過的（lastHours＝nil）在最後；附近：由近到遠
local function tagBefore(a, b) return (a.lastHours or 1e9) < (b.lastHours or 1e9) end
local function nearBefore(a, b) return a.dist < b.dist end

-- 勾選記 ID（已登記＝感應盒物品 ID，附近＝車輛 ID），不記列號：清單重排或更新後勾的還是同一台
local function rowId(row) return row.id or row.vid end

-- ── 清單列：勾選框＋兩行文字，字串與勾選在 bind 時算好，render 不配置 ────
local Cell = ISPanel:derive("KnoxPassCell")
function Cell:render()
    if not self.title then return end
    local list, F = self.list, UI.Focus
    if self.picked then
        theme:fill(self, 0, 0, self.width, self.height, "selected")
    elseif (list:isMouseOver() and list:indexAt(list:getMouseX(), list:getMouseY()) == self.index)
        or (list:isSelected(self.index) and F and F.isKeyboardFocused and F.isKeyboardFocused(list)) then
        theme:fill(self, 0, 0, self.width, self.height, "hover")   -- 滑鼠停留，或鍵盤移到的列
    end
    local mid = math.floor(self.height / 2)
    theme:border(self, 8, mid - 6, 12, 12, "textFaint", "rect")   -- 直角：12 px 的預設圓角會畫成圓圈，像單選
    if self.picked then theme:fill(self, 10, mid - 4, 8, 8, "accent", "rect") end
    text(self, self.title, 28, mid - self.fh - 1, "text")
    text(self, self.sub, 28, mid + 1, "textMuted")
end

-- ── 內容區：prerender 檢查距離、讀取失敗時重讀並畫清單底，render 畫資訊列與空清單說明 ─
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
    -- 讀取失敗：站進大門 3 格內（同伺服器 gateFor 的判定）就重讀，最多每 RETRY_MS 一次
    if w.failed and getTimestampMs() >= w.retryAt and KP.near(p, w.ax, w.ay, w.gz, KP.MANAGE_RANGE) then
        w.retryAt = getTimestampMs() + RETRY_MS
        C.send(p, "query", { key = w.key })
    end
    theme:fill(self, PAD, w.listY, W - PAD * 2, w.listH, "well")
end
function Body:render() self.kp:draw(self) end

local Win = {}
Win.__index = Win
KP.Window = Win

local LABELS = { "IGUI_KnoxPass_Kind", "IGUI_KnoxPass_Owner", "IGUI_KnoxPass_Power", "IGUI_KnoxPass_Door",
    "IGUI_KnoxPass_Range", "IGUI_KnoxPass_Delay", "IGUI_KnoxPass_Speed", "IGUI_KnoxPass_Share" }
-- 分享對象（伺服器 rec.share，沒分享是 "none"）的選項文字；順序就是下拉選單的順序
local SHARES = { { id = "none", key = "IGUI_KnoxPass_ShareNone" }, { id = "faction", key = "IGUI_KnoxPass_ShareFaction" },
    { id = "safehouse", key = "IGUI_KnoxPass_ShareSafehouse" }, { id = "both", key = "IGUI_KnoxPass_ShareBoth" } }

-- 地上的感應範圍圈（同原版除錯工具畫半徑的做法，ISSpawnHordeUI.lua:397-402；setScaleCircleTexture 讓 size＝半徑格數）。
-- 圓心＝整組門的中心（帳本 cx／cy，Sensor 也從這裡量），標記只能放在整格上，雙開門會偏半格。伺服器上回 nil，只在 client 畫
local function showRange(w, s)
    if w.marker then
        w.marker:setSize(s.range)
        return
    end
    local sq = getCell():getGridSquare(math.floor(s.cx or w.gx), math.floor(s.cy or w.gy), w.gz)
    if not sq then return end
    w.marker = getWorldMarkers():addGridSquareMarker(sq, AMBER[1], AMBER[2], AMBER[3], true, s.range)
    if w.marker then w.marker:setScaleCircleTexture(true) end
end

local function hideRange(w)
    if w.marker then w.marker:remove() end
    w.marker = nil
end

function Win.new()
    local self = setmetatable({ rows = {}, state = nil, page = "tags", picked = {}, tagRows = {}, nearRows = {} }, Win)
    local fh = getTextManager():getFontHeight(FS)
    local ch = fh + 10
    self.fh, self.lineH = fh, fh + 6
    self.listH = ((fh * 2 + 14) * 3 + 2) * 2 + ch + GAP + PAD -- 約七列：原本兩段各三列＋第二段的標題列，視窗高度不變
    -- 固定字串建立時取一次，draw 不查譯文
    self.labels, self.labelW = {}, 0
    for i, k in ipairs(LABELS) do
        self.labels[i] = getText(k)
        self.labelW = math.max(self.labelW, getTextManager():MeasureStringX(FS, self.labels[i]))
    end
    self.labelW = self.labelW + 16
    -- 標籤欄跟著語言變寬時（法文、德文…），視窗跟著加寬：設定列右邊的上下限、「不能調整」、分享說明與資訊列的供電說明都要放得下
    local tm = getTextManager()
    local aside, info = 0, 0
    for _, t in ipairs({ getText("IGUI_KnoxPass_CellsRange", "99", "99"), getText("IGUI_KnoxPass_SecondsRange", "99", "99"),
        getText("IGUI_KnoxPass_SpeedUnsupported"), getText("IGUI_KnoxPass_ShareHint") }) do
        aside = math.max(aside, tm:MeasureStringX(FS, t))
    end
    for _, k in ipairs({ "IGUI_KnoxPass_NoPower", "IGUI_KnoxPass_PowerNotNeeded" }) do
        info = math.max(info, tm:MeasureStringX(FS, getText(k)))
    end
    -- 分頁列：兩個分頁（數字取最寬的情況）、「全選」與動作鈕。按鈕寬取兩種標題較寬的，換標題不跳動
    local tabsW = tm:MeasureStringX(FS, getText("IGUI_KnoxPass_TabRegistered", "64", "64"))
        + tm:MeasureStringX(FS, getText("IGUI_KnoxPass_TabNearby", "99")) + 54   -- Tabs 每頁左右各 12、間隔 2、兩端各 2
    local allW = math.max(tm:MeasureStringX(FS, getText("IGUI_KnoxPass_SelectAll")),
        tm:MeasureStringX(FS, getText("IGUI_KnoxPass_SelectNone"))) + 20          -- Button 左右各 10
    local actW = math.max(tm:MeasureStringX(FS, getText("IGUI_KnoxPass_RegisterN", "99")),
        tm:MeasureStringX(FS, getText("IGUI_KnoxPass_UnregisterN", "64"))) + 20
    W = math.max(460, PAD * 2 + self.labelW + math.max(DD_W + 10 + aside, info), PAD * 2 + tabsW + GAP * 2 + allW + actW)
    -- 高度跟字型走：資訊四列＋門鎖與四列設定＋說明＋分頁列＋清單＋頁尾
    local bodyH = PAD + self.lineH * 4 + (ch + GAP) * 5 + self.lineH + GAP + ch + GAP + self.listH + PAD + ch + PAD
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    self.win = UI.Window.new({ x = math.floor((sw - W) / 2), y = math.floor((sh - bodyH) / 2) - 20, width = W,
        height = bodyH + 40, title = getText("IGUI_KnoxPass_Title"), theme = theme,
        onClose = function() hideRange(self) end })
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

    -- 每扇門的感應距離、關門延遲、開關速度與分享對象：距離與延遲只列沙盒上下限內的值；框架沒有 Dropdown 時 draw 只寫目前的值
    self.rangeY, self.delayY, self.speedY, self.shareY = y, y + ch + GAP, y + (ch + GAP) * 2, y + (ch + GAP) * 3
    if CAPS.dropdown then
        self.rangeDD = UI.Dropdown.new({ x = PAD + self.labelW, y = self.rangeY, width = DD_W, height = ch, font = FS,
            theme = theme, target = self, onChange = Win.onRange })
        self.delayDD = UI.Dropdown.new({ x = PAD + self.labelW, y = self.delayY, width = DD_W, height = ch, font = FS,
            theme = theme, target = self, onChange = Win.onDelay })
        self.speedDD = UI.Dropdown.new({ x = PAD + self.labelW, y = self.speedY, width = DD_W, height = ch, font = FS,
            theme = theme, target = self, onChange = Win.onSpeed })
        self.speedDD:setOptions({ { id = "default", label = getText("IGUI_KnoxPass_SpeedNormal") },
            { id = "fast", label = getText("IGUI_KnoxPass_SpeedFast") } })
        self.shareDD = UI.Dropdown.new({ x = PAD + self.labelW, y = self.shareY, width = DD_W, height = ch, font = FS,
            theme = theme, target = self, onChange = Win.onShare })
        local opts = {}
        for i, o in ipairs(SHARES) do opts[i] = { id = o.id, label = getText(o.key) } end
        self.shareDD:setOptions(opts)
        body:addChild(self.rangeDD)
        body:addChild(self.delayDD)
        body:addChild(self.speedDD)
        body:addChild(self.shareDD)
    end
    y = self.shareY + ch + GAP
    self.hintY = y
    self.hint = fit(getText("IGUI_KnoxPass_RangeHint"), W - PAD * 2)
    y = y + self.lineH + GAP

    -- 分頁（已登記／附近）共用一個清單；右邊「全選」與動作鈕（登記或取消登記，寫出勾了幾台）
    self.tabs = UI.Tabs.new({ x = PAD, y = y, height = ch, font = FS, theme = theme, target = self, onSelect = Win.onTab,
        items = { { id = "tags", label = "" }, { id = "near", label = "" } }, selected = "tags" })
    body:addChild(self.tabs)
    self.btnAct = UI.Button.new({ x = W - PAD - actW, y = y, width = actW, height = ch, title = "", theme = theme,
        target = self, onClick = Win.onAct })
    self.btnAll = UI.Button.new({ x = self.btnAct.x - GAP - allW, y = y, width = allW, height = ch, title = "",
        theme = theme, target = self, onClick = Win.onPickAll })
    body:addChild(self.btnAll)
    body:addChild(self.btnAct)
    y = y + ch + GAP
    self.listY = y
    self.list = UI.VirtualList.new({ x = PAD, y = y, width = W - PAD * 2, height = self.listH, rowHeight = fh * 2 + 12,
        padding = 2,
        createCell = function(l)
            local c = Cell:new(0, 0, 0, 0)
            c.background = false
            c.list, c.fh = l, fh
            return c
        end,
        bindCell = function(_, c, row, index) self:bindRow(c, row, index) end,
        unbindCell = function(_, c) c.title = nil end,
        onSelect = function(_, row) self:onPick(row) end,
        colors = { thumb = COL.textFaint, thumbHover = COL.textMuted, track = COL.hover } })
    self.list:initialise()
    body:addChild(self.list)

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

-- 列的字串與勾選在綁定時算好（勾選改了就 setItems 重綁）；文字從勾選框右邊（x＝28）開始
function Win:bindRow(c, row, index)
    local w = c.width - 36
    c.index, c.picked = index, self.picked[rowId(row)] == true
    c.title = fit(vehicleName(row.script), w)
    if self.page == "near" then
        c.sub = fit(tostring(row.serial) .. "   " .. getText("IGUI_KnoxPass_Distance", tostring(row.dist)) .. "   "
            .. chargeText(row.charge), w)
    else
        c.sub = fit(tostring(row.serial) .. "   " .. chargeText(row.charge) .. "   "
            .. getText("IGUI_KnoxPass_LastPassed", agoText(row.lastHours)), w)
    end
end

-- 下拉選項：第一個是「伺服器預設（值）」，其餘是上下限內的每個整數
local function settingOptions(lo, hi, default, unit)
    local opts = { { id = "default", label = getText("IGUI_KnoxPass_ServerDefault", getText(unit, tostring(default))) } }
    for v = lo, hi do opts[#opts + 1] = { id = v, label = getText(unit, tostring(v)) } end
    return opts
end

-- 設定四列跟著 state 走（被拒時也用來回到伺服器的值）：設了值就選生效值（上下限縮小後是夾過的值），沒設選預設。
-- 開關速度只有錨點有加速版模型的門能選（state.speedSupported），其他門停用並寫明；分享對象右邊寫分享出去的是什麼
function Win:applySettings(s)
    local rb = getText("IGUI_KnoxPass_CellsRange", tostring(s.rangeMin), tostring(s.rangeMax))
    local db = getText("IGUI_KnoxPass_SecondsRange", tostring(s.delayMin), tostring(s.delayMax))
    local fast = s.speed == "fast"
    local sb = s.speedSupported and "" or getText("IGUI_KnoxPass_SpeedUnsupported")
    local hb = getText("IGUI_KnoxPass_ShareHint")
    if not self.rangeDD then
        local shareKey = SHARES[1].key
        for _, o in ipairs(SHARES) do if o.id == s.share then shareKey = o.key end end
        self.rangeAside = getText("IGUI_KnoxPass_Cells", tostring(s.range)) .. "   " .. rb
        self.delayAside = getText("IGUI_KnoxPass_Seconds", tostring(s.delay)) .. "   " .. db
        self.speedAside = getText(fast and "IGUI_KnoxPass_SpeedFast" or "IGUI_KnoxPass_SpeedNormal") .. "   " .. sb
        self.shareAside = getText(shareKey) .. "   " .. hb
        return
    end
    self.rangeAside, self.delayAside, self.speedAside, self.shareAside = rb, db, sb, hb
    self.rangeDD:setOptions(settingOptions(s.rangeMin, s.rangeMax, s.rangeDefault, "IGUI_KnoxPass_Cells"))
    self.rangeDD:setSelected(s.rangeSet ~= nil and s.range or "default", true)
    self.rangeDD:setEnabled(s.manager == true)
    self.delayDD:setOptions(settingOptions(s.delayMin, s.delayMax, s.delayDefault, "IGUI_KnoxPass_Seconds"))
    self.delayDD:setSelected(s.delaySet ~= nil and s.delay or "default", true)
    self.delayDD:setEnabled(s.manager == true)
    self.speedDD:setSelected(fast and "fast" or "default", true)
    self.speedDD:setEnabled(s.manager == true and s.speedSupported == true)
    self.shareDD:setSelected(s.share or "none", true)
    self.shareDD:setEnabled(s.manager == true)
end

-- state 到達時算好資訊列字串與兩頁的列（draw 每幀只畫）
function Win:apply(s)
    self.state, self.failed = s, nil
    local rows = self.rows
    rows[1] = getText("IGUI_KnoxPass_Kind_" .. tostring(s.kind))
    rows[2] = tostring(s.owner or "?")
    if not s.needPower then rows[3], self.powerToken = getText("IGUI_KnoxPass_PowerNotNeeded"), "textMuted"
    elseif s.powered then rows[3], self.powerToken = getText("IGUI_KnoxPass_Powered"), "text"
    else rows[3], self.powerToken = getText("IGUI_KnoxPass_NoPower"), "errorText" end
    rows[4] = getText(s.open and "IGUI_KnoxPass_DoorOpen" or "IGUI_KnoxPass_DoorClosed")
    -- 不是管理者時伺服器不給兩份清單（Server.lua buildState）；附近只列還沒登記的車
    self.tagRows = sortRows(s.tags or {}, tagBefore)
    local near = {}
    for _, row in ipairs(s.nearby or {}) do
        if not row.registered then near[#near + 1] = row end
    end
    self.nearRows = sortRows(near, nearBefore)
    self.tabs:setItemLabel("tags", getText("IGUI_KnoxPass_TabRegistered", tostring(#self.tagRows), tostring(s.maxTags)))
    self.tabs:setItemLabel("near", getText("IGUI_KnoxPass_TabNearby", tostring(#self.nearRows)))
    self.lock:setChecked(s.lock == true, true)
    self.lock:setEnabled(s.manager == true and s.lockSupported ~= false)
    self.lock:setLabel(getText(s.lockSupported == false and "IGUI_KnoxPass_LockUnsupported" or "IGUI_KnoxPass_Lock"))
    self:applySettings(s)
    showRange(self, s)
    self:showPage()
end

-- 清單換成目前分頁的列；勾選只留還在這一頁的
function Win:showPage()
    local rows, keep = self.page == "near" and self.nearRows or self.tagRows, {}
    for _, row in ipairs(rows) do
        local id = rowId(row)
        if self.picked[id] then keep[id] = true end
    end
    self.picked = keep
    self.list:setItems(rows)
    self:refreshButtons()
end

-- 還沒有（或失去）這扇門的 state：清單清空、控制項停用，draw 只寫讀取中或失敗原因
function Win:reset()
    self.state, self.tagRows, self.nearRows, self.picked = nil, {}, {}, {}
    self.list:setItems({})
    self.lock:setChecked(false, true)
    self.lock:setEnabled(false)
    if self.rangeDD then
        self.rangeDD:setEnabled(false)
        self.delayDD:setEnabled(false)
        self.speedDD:setEnabled(false)
        self.shareDD:setEnabled(false)
    end
    hideRange(self)   -- 換一扇門或讀取失敗：等新 state 再畫範圍
    self:refreshButtons()
end

-- 分頁列只給管理者；「全選」在整頁都勾了時變「全不選」；動作鈕跟著分頁（登記／取消登記）並寫出勾了幾台
function Win:refreshButtons()
    local s = self.state
    local manager = s ~= nil and s.manager == true
    local rows, n = self.list:getItems(), 0
    for _, row in ipairs(rows) do
        if self.picked[rowId(row)] then n = n + 1 end
    end
    local near = self.page == "near"
    self.tabs:setVisible(manager)
    self.btnAll:setVisible(manager)
    self.btnAct:setVisible(manager)
    self.btnAll:setTitle(getText(n > 0 and n == #rows and "IGUI_KnoxPass_SelectNone" or "IGUI_KnoxPass_SelectAll"))
    self.btnAll:setEnabled(manager and #rows > 0)
    if n == 0 then
        self.btnAct:setTitle(getText(near and "IGUI_KnoxPass_Register" or "IGUI_KnoxPass_Unregister"))
    else
        self.btnAct:setTitle(getText(near and "IGUI_KnoxPass_RegisterN" or "IGUI_KnoxPass_UnregisterN", tostring(n)))
    end
    self.btnAct:setStyle(near and "primary" or "danger")
    self.btnAct:setEnabled(manager and n > 0)
    -- 閘門的讀頭是內建的（伺服器 H.uninstall 回 BuiltIn）：拆整座閘門走拆除機箱
    self.btnRemoveReader:setEnabled(manager and s.kind ~= "Barrier")
end

function Win:draw(el)
    local s = self.state
    -- 設定四列與下拉選單同高（高 fh+10，文字下移 5 置中）；標籤在讀取中與讀取失敗時也畫，停用的選單看得出是什麼
    text(el, self.labels[5], PAD, self.rangeY + 5, "textMuted")
    text(el, self.labels[6], PAD, self.delayY + 5, "textMuted")
    text(el, self.labels[7], PAD, self.speedY + 5, "textMuted")
    text(el, self.labels[8], PAD, self.shareY + 5, "textMuted")
    if not s then
        if self.failed then
            drawLines(el, self.failed, PAD, self.infoY, self.lineH, "errorText")
            text(el, self.retryHint, PAD, self.infoY + #self.failed * self.lineH, "textMuted")
        else
            text(el, self.loading, PAD, self.infoY, "textMuted")
        end
        return
    end
    local valueX = PAD + self.labelW
    for i = 1, 4 do
        local y = self.infoY + (i - 1) * self.lineH
        text(el, self.labels[i], PAD, y, "textMuted")
        text(el, self.rows[i], valueX, y, i == 3 and self.powerToken or "text")
    end
    -- 有下拉選單時右邊寫上下限，沒有時寫「生效值   上下限」
    local asideX, asideToken = valueX, "text"
    if self.rangeDD then asideX, asideToken = valueX + DD_W + 10, "textFaint" end
    text(el, self.rangeAside, asideX, self.rangeY + 5, asideToken)
    text(el, self.delayAside, asideX, self.delayY + 5, asideToken)
    text(el, self.speedAside, asideX, self.speedY + 5, asideToken)
    text(el, self.shareAside, asideX, self.shareY + 5, asideToken)
    text(el, self.hint, PAD, self.hintY, "textFaint")
    if not s.manager then
        text(el, self.notManager, PAD + 8, self.listY + 8, "textMuted")
    elseif #self.list:getItems() == 0 then
        drawLines(el, self.page == "near" and self.emptyNear or self.emptyTags, PAD + 8, self.listY + 8, self.lineH,
            "textFaint")
    end
end

-- ── 按鈕 ────────────────────────────────────────────────────────────────

function Win:onLock(checked)
    C.send(self.player, "lock", { key = self.key, on = checked == true })
end

-- 下拉選單：id＝整數或 "default"（改回跟著沙盒預設）；伺服器夾在上下限內再回 state
function Win:onRange(id)
    C.send(self.player, "settings", { key = self.key, range = id })
end

function Win:onDelay(id)
    C.send(self.player, "settings", { key = self.key, delay = id })
end

-- 開關速度：id＝"fast"（加速）或 "default"（正常）
function Win:onSpeed(id)
    C.send(self.player, "settings", { key = self.key, speed = id })
end

-- 分享對象：id＝"none"／"faction"／"safehouse"／"both"（伺服器 Server.lua sharedWith）
function Win:onShare(id)
    C.send(self.player, "settings", { key = self.key, share = id })
end

-- 換分頁：勾選清空、捲回頂端；附近的車會動，換到附近就重讀（伺服器重新量距離與電量）
function Win:onTab(id)
    self.page, self.picked = id, {}
    self.list:setSelectedIndex(nil)
    self.list:setScrollOffset(0)
    self:showPage()
    if id == "near" then C.send(self.player, "query", { key = self.key }) end
end

-- 點列或按 Enter：切換這一台的勾選
function Win:onPick(row)
    local id = rowId(row)
    self.picked[id] = not self.picked[id] or nil
    self.list:setItems(self.list:getItems())   -- 重綁看得到的列，畫出勾選框
    self:refreshButtons()
end

-- 全選：勾起這一頁的每一台（捲到看不到的也算）；已經全勾時清空
function Win:onPickAll()
    local rows, all = self.list:getItems(), true
    for _, row in ipairs(rows) do
        if not self.picked[rowId(row)] then all = false end
    end
    self.picked = {}
    if not all then
        for _, row in ipairs(rows) do self.picked[rowId(row)] = true end
    end
    self.list:setItems(rows)
    self:refreshButtons()
end

-- 登記或取消登記勾起的車：整批一個指令（伺服器 H.register／H.unregister 逐台檢查）；取消登記每次先確認
function Win:onAct()
    local ids = {}
    for _, row in ipairs(self.list:getItems()) do
        local id = rowId(row)
        if self.picked[id] then ids[#ids + 1] = id end
    end
    if #ids == 0 then return end
    local player, key = self.player, self.key
    if self.page == "near" then return C.send(player, "register", { key = key, vehicleIds = ids }) end
    local function go() C.send(player, "unregister", { key = key, tagIds = ids }) end
    if not CAPS.dialog then return go() end
    local n = tostring(#ids)
    UI.Dialog.show({ title = getText("IGUI_KnoxPass_Unregister"), text = getText("IGUI_KnoxPass_ConfirmUnregister", n),
        theme = theme, confirmText = getText("IGUI_KnoxPass_UnregisterN", n), cancelText = getText("IGUI_KnoxPass_Back"),
        danger = true, onResult = function(ok) if ok then go() end end })
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
    -- 固定字串建立時取一次，draw 不查譯文（資訊列與設定列的標籤在 Win.new 量寬度時就取了）
    w.loading = getText("IGUI_KnoxPass_Loading")
    w.retryHint = getText("IGUI_KnoxPass_RetryHint")
    w.notManager = getText("IGUI_KnoxPass_NotManager")
    w.emptyTags = wrap(getText("IGUI_KnoxPass_NoTags"), W - PAD * 2 - 16)
    w.emptyNear = wrap(getText("IGUI_KnoxPass_NoNearby"), W - PAD * 2 - 16)
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
    w.ax, w.ay, w.gz = sq:getX(), sq:getY(), sq:getZ()
    w.gx, w.gy = w.ax + 0.5, w.ay + 0.5
    w.page, w.failed, w.retryAt = "tags", nil, 0
    w.tabs:setSelected("tags", true)
    w.list:setScrollOffset(0)
    w:reset()
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
    if not r.ok and r.cmd == "query" then
        -- 伺服器只在失敗時回 query 的 result：清掉舊資料、寫出原因，Body:prerender 在 3 格內重讀
        w:reset()
        w.failed = wrap(getText("IGUI_KnoxPass_LoadFailed", KnoxPassAPI.whyText(r.why)), W - PAD * 2)
    elseif r.cmd == "register" or r.cmd == "unregister" then
        w.picked = {}                                -- 做完一批就清空勾選（新的 state 隨後就到）
        w.list:setItems(w.list:getItems())
        w:refreshButtons()
    elseif r.ok and r.cmd == "uninstall" then
        w.win:close()
    elseif not r.ok and r.cmd == "lock" and w.state then
        w.lock:setChecked(w.state.lock == true, true) -- 被拒時開關回到伺服器狀態
    elseif not r.ok and r.cmd == "settings" and w.state then
        w:applySettings(w.state)                     -- 被拒時下拉選單回到伺服器的值
    end
end
