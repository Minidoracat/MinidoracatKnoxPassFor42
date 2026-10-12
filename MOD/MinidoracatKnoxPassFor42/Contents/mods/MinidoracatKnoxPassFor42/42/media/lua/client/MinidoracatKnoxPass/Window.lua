-- Knox Pass 讀頭管理視窗（MinidoracatUIFor42 API rev 7：Window／Button／Checkbox／Tabs／VirtualList，Dialog 選用；
-- 每扇門設定的下拉選單要 rev 14 的 Dropdown，沒有時只顯示數字；共同管理者名單的搜尋框要 rev 11 的 Autocomplete）。
-- 只有能管理這扇門的人（擁有者、共同管理者、管理員）拿得到 state；伺服器回 NotOwner 時視窗關掉。
-- 畫面只顯示伺服器 state；所有變更送指令後等新的 state，不做樂觀更新。視窗開著時地上畫出這扇門的感應範圍。
-- 框架不足時整檔在這裡結束：KP.Window 不存在，右鍵「管理讀頭」改成停用並提示（Client.lua）。
require "MinidoracatKnoxPass/Client"
require "MinidoracatKnoxPass/Watch"
local KP = MinidoracatKnoxPass
local C = KP.Client

-- widget 檔不由 V1 載入，也不保證排在本檔之前（MinidoracatKnoxPass < MinidoracatUI），自己 pcall require
if not (MinidoracatUI and MinidoracatUI.v1) then pcall(require, "MinidoracatUI/V1") end
pcall(require, "MinidoracatUI/VirtualList")
pcall(require, "MinidoracatUI/Widgets/Controls")
pcall(require, "MinidoracatUI/Widgets/Window")
pcall(require, "MinidoracatUI/Widgets/Dropdown")
pcall(require, "MinidoracatUI/Widgets/Autocomplete")
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

-- 已登記：最近通過的在前，沒通過過的（lastHours＝nil）在最後；附近：由近到遠。車與手錶模組同一份清單
local function tagBefore(a, b) return (a.lastHours or 1e9) < (b.lastHours or 1e9) end
local function nearBefore(a, b) return a.dist < b.dist end

-- 勾選記 ID（已登記＝感應盒物品 ID，附近＝車輛 ID），不記列號：清單重排或更新後勾的還是同一台。
-- 手錶模組列另有 pick 鍵（"m"＋序號，Win:apply 算好），序號才不會撞到車輛或感應盒的 ID
local function rowId(row) return row.pick or row.id or row.vid end

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
local Co = {}   -- 共同管理者名單視窗（下方「共同管理者名單視窗」段）
Co.__index = Co
Win.Co = Co     -- E2E 與報告情境取用名單視窗（Win.Co.instance）

local LABELS = { "IGUI_KnoxPass_Kind", "IGUI_KnoxPass_Owner", "IGUI_KnoxPass_Power", "IGUI_KnoxPass_Door",
    "IGUI_KnoxPass_Range", "IGUI_KnoxPass_Delay", "IGUI_KnoxPass_Speed", "IGUI_KnoxPass_Share", "IGUI_KnoxPass_Managers" }
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
        getText("IGUI_KnoxPass_SpeedUnsupported"), getText("IGUI_KnoxPass_ShareHint"), getText("IGUI_KnoxPass_ManagersHint") }) do
        aside = math.max(aside, tm:MeasureStringX(FS, t))
    end
    for _, k in ipairs({ "IGUI_KnoxPass_NoPower", "IGUI_KnoxPass_PowerNotNeeded" }) do
        info = math.max(info, tm:MeasureStringX(FS, getText(k)))
    end
    -- 門鎖與手錶步行感應兩個開關的標籤（含不支援、不准上鎖、伺服器沒開放）：開關 36 px＋間距 8 px
    -- （UI 框架 Controls.lua:615-616 TOGGLE_WIDTH、LABEL_GAP）。沒裝地圖手錶就不建步行感應那一列
    local hasWalk = KP.watchRegistered()
    local toggle = 0
    for _, k in ipairs({ "IGUI_KnoxPass_Lock", "IGUI_KnoxPass_LockUnsupported", "IGUI_KnoxPass_LockSafehouseOnly",
        "IGUI_KnoxPass_Walk", "IGUI_KnoxPass_WalkOff" }) do
        toggle = math.max(toggle, tm:MeasureStringX(FS, getText(k)))
    end
    -- 分頁列：兩個分頁（數字取最寬的情況）、「全選」與動作鈕。按鈕寬取兩種標題較寬的，換標題不跳動
    local tabsW = tm:MeasureStringX(FS, getText("IGUI_KnoxPass_TabRegistered", "64", "64"))
        + tm:MeasureStringX(FS, getText("IGUI_KnoxPass_TabNearby", "99")) + 54   -- Tabs 每頁左右各 12、間隔 2、兩端各 2
    local allW = math.max(tm:MeasureStringX(FS, getText("IGUI_KnoxPass_SelectAll")),
        tm:MeasureStringX(FS, getText("IGUI_KnoxPass_SelectNone"))) + 20          -- Button 左右各 10
    local actW = math.max(tm:MeasureStringX(FS, getText("IGUI_KnoxPass_RegisterN", "99")),
        tm:MeasureStringX(FS, getText("IGUI_KnoxPass_UnregisterN", "64"))) + 20
    W = math.max(460, PAD * 2 + self.labelW + math.max(DD_W + 10 + aside, info), PAD * 2 + tabsW + GAP * 2 + allW + actW,
        PAD * 2 + 36 + 8 + toggle)
    -- 高度跟字型走：資訊四列＋門鎖（與步行感應）與五列設定（含共同管理）＋說明＋分頁列＋清單＋頁尾
    local bodyH = PAD + self.lineH * 4 + (ch + GAP) * (hasWalk and 7 or 6) + self.lineH + GAP + ch + GAP + self.listH
        + PAD + ch + PAD
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    self.win = UI.Window.new({ x = math.floor((sw - W) / 2), y = math.floor((sh - bodyH) / 2) - 20, width = W,
        height = bodyH + 40, title = getText("IGUI_KnoxPass_Title"), theme = theme,
        onClose = function()
            hideRange(self)
            Co.hide()   -- 名單視窗跟著關
        end })
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
    if hasWalk then
        self.walk = UI.Checkbox.new({ x = PAD, y = y, width = W - PAD * 2, label = getText("IGUI_KnoxPass_Walk"),
            theme = theme, target = self, onChange = Win.onWalk })
        body:addChild(self.walk)
        y = y + ch + GAP
    end

    -- 每扇門的感應距離、關門延遲、開關速度與分享對象：距離與延遲只列沙盒上下限內的值；框架沒有 Dropdown 時 draw 只寫目前的值。
    -- 視窗本體半透明，清單會蓋住下面幾列：opaque（框架 rev 18）讓清單不透明，才不會透出底下的按鈕與說明（舊框架忽略）
    self.rangeY, self.delayY, self.speedY, self.shareY = y, y + ch + GAP, y + (ch + GAP) * 2, y + (ch + GAP) * 3
    if CAPS.dropdown then
        self.rangeDD = UI.Dropdown.new({ x = PAD + self.labelW, y = self.rangeY, width = DD_W, height = ch, font = FS,
            theme = theme, target = self, onChange = Win.onRange, opaque = true })
        self.delayDD = UI.Dropdown.new({ x = PAD + self.labelW, y = self.delayY, width = DD_W, height = ch, font = FS,
            theme = theme, target = self, onChange = Win.onDelay, opaque = true })
        self.speedDD = UI.Dropdown.new({ x = PAD + self.labelW, y = self.speedY, width = DD_W, height = ch, font = FS,
            theme = theme, target = self, onChange = Win.onSpeed, opaque = true })
        self.speedDD:setOptions({ { id = "default", label = getText("IGUI_KnoxPass_SpeedNormal") },
            { id = "fast", label = getText("IGUI_KnoxPass_SpeedFast") } })
        self.shareDD = UI.Dropdown.new({ x = PAD + self.labelW, y = self.shareY, width = DD_W, height = ch, font = FS,
            theme = theme, target = self, onChange = Win.onShare, opaque = true })
        local opts = {}
        for i, o in ipairs(SHARES) do opts[i] = { id = o.id, label = getText(o.key) } end
        self.shareDD:setOptions(opts)
        body:addChild(self.rangeDD)
        body:addChild(self.delayDD)
        body:addChild(self.speedDD)
        body:addChild(self.shareDD)
    end
    -- 共同管理：按鈕寫目前的名單摘要，按下去開名單視窗（Co.show）
    self.managersY = self.shareY + ch + GAP
    self.btnManagers = UI.Button.new({ x = PAD + self.labelW, y = self.managersY, width = DD_W, height = ch, title = "",
        theme = theme, target = self, onClick = Win.onManagers })
    body:addChild(self.btnManagers)
    y = self.managersY + ch + GAP
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

-- 列的字串與勾選在綁定時算好（勾選改了就 setItems 重綁）；文字從勾選框右邊（x＝28）開始。
-- 手錶模組：已登記的寫誰正戴著（只給名字），沒人戴時寫上次是誰、何時通過；附近的寫戴著的人與手錶能不能用
function Win:bindRow(c, row, index)
    local w = c.width - 36
    c.index, c.picked = index, self.picked[rowId(row)] == true
    if row.kind == "mod" then
        c.title = fit(row.wearer and getText("IGUI_KnoxPass_ModWearing", row.wearer) or getText("IGUI_KnoxPass_ModNobody"), w)
        c.sub = fit(tostring(row.serial) .. "   " .. (row.lastHours and getText("IGUI_KnoxPass_LastPassedBy",
            tostring(row.lastBy or "?"), agoText(row.lastHours)) or getText("IGUI_KnoxPass_LastPassed", agoText(nil))), w)
    elseif row.kind == "nearMod" then
        c.title = fit(getText("IGUI_KnoxPass_ModNear", tostring(row.name)), w)
        c.sub = fit(tostring(row.serial) .. "   " .. getText("IGUI_KnoxPass_Distance", tostring(row.dist)) .. "   "
            .. getText(row.active and "IGUI_KnoxPass_ModReady" or "IGUI_KnoxPass_ModIdle"), w)
    elseif self.page == "near" then
        c.title = fit(vehicleName(row.script), w)
        c.sub = fit(tostring(row.serial) .. "   " .. getText("IGUI_KnoxPass_Distance", tostring(row.dist)) .. "   "
            .. chargeText(row.charge), w)
    else
        c.title = fit(vehicleName(row.script), w)
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

-- 共同管理那一列的按鈕標題：擁有者陣營（開著陣營、擁有者也還在陣營時）與個別幾人
local function managersSummary(s)
    local n = #(s.co or {})
    if s.coFaction and s.ownerFaction then
        if n > 0 then return getText("IGUI_KnoxPass_ManagersBoth", s.ownerFaction, tostring(n)) end
        return getText("IGUI_KnoxPass_ManagersFaction", s.ownerFaction)
    end
    if n > 0 then return getText("IGUI_KnoxPass_ManagersPeople", tostring(n)) end
    return getText("IGUI_KnoxPass_ManagersNone")
end

-- 設定各列跟著 state 走（被拒時也用來回到伺服器的值）：設了值就選生效值（上下限縮小後是夾過的值），沒設選預設。
-- 開關速度只有錨點有加速版模型的門能選（state.speedSupported），其他門停用並寫明；分享對象右邊寫分享出去的是什麼
function Win:applySettings(s)
    self.btnManagers:setTitle(managersSummary(s))
    self.btnManagers:setEnabled(true)
    self.managersAside = getText("IGUI_KnoxPass_ManagersHint")
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
    self.rangeDD:setEnabled(true)
    self.delayDD:setOptions(settingOptions(s.delayMin, s.delayMax, s.delayDefault, "IGUI_KnoxPass_Seconds"))
    self.delayDD:setSelected(s.delaySet ~= nil and s.delay or "default", true)
    self.delayDD:setEnabled(true)
    self.speedDD:setSelected(fast and "fast" or "default", true)
    self.speedDD:setEnabled(s.speedSupported == true)
    self.shareDD:setSelected(s.share or "none", true)
    self.shareDD:setEnabled(true)
    -- 手錶步行感應（這扇門 rec.walk）：伺服器沒開放（沙盒 WatchSensing）時停用，標籤寫原因
    if self.walk then
        self.walk:setChecked(s.walk ~= false, true)
        self.walk:setEnabled(s.walkSupported == true)
        self.walk:setLabel(getText(s.walkSupported and "IGUI_KnoxPass_Walk" or "IGUI_KnoxPass_WalkOff"))
    end
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
    -- 已登記＝車＋手錶模組；附近＝還沒登記的車＋15 格內戴著模組的人（列表是 state 裡的表，就地標上種類與勾選鍵）
    local tags = {}
    for _, row in ipairs(s.tags or {}) do tags[#tags + 1] = row end
    for _, row in ipairs(s.mods or {}) do
        row.kind, row.pick = "mod", "m" .. tostring(row.id)
        tags[#tags + 1] = row
    end
    self.tagRows = sortRows(tags, tagBefore)
    local near = {}
    for _, row in ipairs(s.nearby or {}) do
        if not row.registered then near[#near + 1] = row end
    end
    for _, row in ipairs(s.nearMods or {}) do
        row.kind, row.pick = "nearMod", "m" .. tostring(row.id)
        near[#near + 1] = row
    end
    self.nearRows = sortRows(near, nearBefore)
    self.tabs:setItemLabel("tags", getText("IGUI_KnoxPass_TabRegistered", tostring(#self.tagRows), tostring(s.maxTags)))
    self.tabs:setItemLabel("near", getText("IGUI_KnoxPass_TabNearby", tostring(#self.nearRows)))
    -- 門鎖：不支援的門停用並寫明；沙盒「安全屋外的讀頭」不准上鎖時（state.lockAllowed＝false），沒上鎖的停用並寫原因，
    -- 已上鎖的照樣能關掉
    local blocked = s.lock ~= true and s.lockAllowed == false
    self.lock:setChecked(s.lock == true, true)
    self.lock:setEnabled(s.lockSupported ~= false and not blocked)
    self.lock:setLabel(getText(s.lockSupported == false and "IGUI_KnoxPass_LockUnsupported"
        or blocked and "IGUI_KnoxPass_LockSafehouseOnly" or "IGUI_KnoxPass_Lock"))
    if Co.shownFor(self.key) then Co.instance:apply(s) end
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
    self.btnManagers:setEnabled(false)
    if self.walk then self.walk:setEnabled(false) end
    if self.rangeDD then
        self.rangeDD:setEnabled(false)
        self.delayDD:setEnabled(false)
        self.speedDD:setEnabled(false)
        self.shareDD:setEnabled(false)
    end
    hideRange(self)   -- 換一扇門或讀取失敗：等新 state 再畫範圍
    Co.hide()
    self:refreshButtons()
end

-- 分頁列在拿到 state 後才顯示；「全選」在整頁都勾了時變「全不選」；動作鈕跟著分頁（登記／取消登記）並寫出勾了幾台
function Win:refreshButtons()
    local s = self.state
    local has = s ~= nil
    local rows, n = self.list:getItems(), 0
    for _, row in ipairs(rows) do
        if self.picked[rowId(row)] then n = n + 1 end
    end
    local near = self.page == "near"
    self.tabs:setVisible(has)
    self.btnAll:setVisible(has)
    self.btnAct:setVisible(has)
    self.btnAll:setTitle(getText(n > 0 and n == #rows and "IGUI_KnoxPass_SelectNone" or "IGUI_KnoxPass_SelectAll"))
    self.btnAll:setEnabled(has and #rows > 0)
    if n == 0 then
        self.btnAct:setTitle(getText(near and "IGUI_KnoxPass_Register" or "IGUI_KnoxPass_Unregister"))
    else
        self.btnAct:setTitle(getText(near and "IGUI_KnoxPass_RegisterN" or "IGUI_KnoxPass_UnregisterN", tostring(n)))
    end
    self.btnAct:setStyle(near and "primary" or "danger")
    self.btnAct:setEnabled(has and n > 0)
    -- 閘門的讀頭是內建的（伺服器 H.uninstall 回 BuiltIn）：拆整座閘門走拆除機箱。共同管理者不能拆（OwnerOnly），停用並說明
    local coOnly = has and s.ownerOrAdmin ~= true
    self.btnRemoveReader:setEnabled(has and not coOnly and s.kind ~= "Barrier")
    self.btnRemoveReader:setTooltip(coOnly and self.ownerOnly or nil)
end

function Win:draw(el)
    local s = self.state
    -- 設定四列與下拉選單同高（高 fh+10，文字下移 5 置中）；標籤在讀取中與讀取失敗時也畫，停用的選單看得出是什麼
    text(el, self.labels[5], PAD, self.rangeY + 5, "textMuted")
    text(el, self.labels[6], PAD, self.delayY + 5, "textMuted")
    text(el, self.labels[7], PAD, self.speedY + 5, "textMuted")
    text(el, self.labels[8], PAD, self.shareY + 5, "textMuted")
    text(el, self.labels[9], PAD, self.managersY + 5, "textMuted")
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
    text(el, self.managersAside, valueX + DD_W + 10, self.managersY + 5, "textFaint")   -- 名單按鈕一律有，右邊寫說明
    text(el, self.hint, PAD, self.hintY, "textFaint")
    if #self.list:getItems() == 0 then
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

-- 手錶步行感應：這扇門要不要讓已登記的模組走近就開（開車與右鍵不受影響）
function Win:onWalk(checked)
    C.send(self.player, "settings", { key = self.key, walk = checked == true })
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

-- 登記或取消登記勾起的車與手錶模組：整批一個指令（伺服器 H.register／H.unregister 逐項檢查）；取消登記每次先確認
function Win:onAct()
    local ids, mods = {}, {}
    for _, row in ipairs(self.list:getItems()) do
        if self.picked[rowId(row)] then
            if row.kind then mods[#mods + 1] = row.id else ids[#ids + 1] = rowId(row) end
        end
    end
    local n = #ids + #mods
    if n == 0 then return end
    local player, key = self.player, self.key
    local vehicles, modules = ids[1] and ids or nil, mods[1] and mods or nil   -- 空的不送（伺服器收到空清單回 BadArgs）
    if self.page == "near" then
        return C.send(player, "register", { key = key, vehicleIds = vehicles, modIds = modules })
    end
    local function go() C.send(player, "unregister", { key = key, tagIds = vehicles, modIds = modules }) end
    if not CAPS.dialog then return go() end
    UI.Dialog.show({ title = getText("IGUI_KnoxPass_Unregister"), text = getText("IGUI_KnoxPass_ConfirmUnregister", tostring(n)),
        theme = theme, confirmText = getText("IGUI_KnoxPass_UnregisterN", tostring(n)), cancelText = getText("IGUI_KnoxPass_Back"),
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

-- 「共同管理」那一列的按鈕：開名單視窗
function Win:onManagers()
    if self.state then Co.show(self) end
end

-- ── 共同管理者名單視窗 ──────────────────────────────────────────────────
-- 內容照管理視窗的 state 畫（Co:apply）；擁有者與管理員能改（state.ownerOrAdmin），共同管理者只能看。
-- 輸入框是 UI.Autocomplete（框架 API rev 11，CAPS.autocomplete；家族 Safehouse 的分享對象同款）：候選由伺服器
-- H.findPlayers 回，只列伺服器認得的玩家；選了候選才能按「加入」，伺服器 H.managers 再重查一次。
-- 框架沒有 Autocomplete 時名單照列，新增停用並寫明
local CO_W = 340               -- 最窄寬度；陣營開關的標籤比較長的語言撐寬（Co.new）
local QUERY_TIMEOUT_MS = 3000   -- 候選查詢送出後這麼久沒回覆就當作掉了，可以再送
local TOGGLE_W = 44             -- 勾選框的開關圖樣與間距（標籤截字用）

local CoBody = ISPanel:derive("KnoxPassCoBody")
-- 文字畫在 prerender：子元件（搜尋框的下拉）在 prerender 之後、render 之前畫，下拉才蓋得住名單文字
-- （UIElement.render：prerender → children → render）
function CoBody:prerender()
    local co = self.co
    -- 選了候選之後又改字就不算選過：只能加入確實存在的玩家
    if co.picked and co.ac and co.ac:getText() ~= co.picked then co.picked = nil end
    co.btnAdd:setEnabled(co.canEdit and co.picked ~= nil and co.count < co.max)
    co:draw(self)
end

function Co.new()
    local self = setmetatable({ names = {}, rowText = {}, count = 0, max = KP.MAX_MANAGERS, canEdit = false }, Co)
    local tm = getTextManager()
    local fh = tm:getFontHeight(FS)
    local ch = fh + 10
    self.lineH, self.ch = fh + 6, ch
    local addTitle, removeTitle = getText("IGUI_KnoxPass_Add"), getText("IGUI_KnoxPass_Remove")
    local addW = tm:MeasureStringX(FS, addTitle) + 20
    self.removeW = tm:MeasureStringX(FS, removeTitle) + 20
    -- 寬度跟著語言撐開（同管理視窗）：陣營開關的標籤只有一行，擁有者不在陣營時那句最長；陣營名太長照樣截字
    local w = math.max(CO_W, PAD * 2 + TOGGLE_W + tm:MeasureStringX(FS, getText("IGUI_KnoxPass_ManagersFactionNone")),
        PAD * 2 + TOGGLE_W + tm:MeasureStringX(FS, getText("IGUI_KnoxPass_ManagersFactionOn", "")))
    self.w = w
    self.note = wrap(getText("IGUI_KnoxPass_ManagersNote"), w - PAD * 2)
    self.factionHint = wrap(getText("IGUI_KnoxPass_ManagersFactionHint"), w - PAD * 2 - TOGGLE_W)
    self.empty = fit(getText("IGUI_KnoxPass_ManagersEmpty"), w - PAD * 2)
    self.onlineTag = getText("IGUI_KnoxPass_Online")
    -- 由上而下：說明、陣營開關與說明、搜尋框＋加入、名單（最多 KP.MAX_MANAGERS 列）、底下一行（人數或只能看的說明，
    -- 會換行：留最長那句的行數）。搜尋框在名單上面，下拉蓋住名單列
    local y = PAD
    self.noteY = y
    y = y + #self.note * self.lineH + GAP
    self.factionY = y
    y = y + ch
    self.factionHintY = y
    y = y + #self.factionHint * self.lineH + GAP
    self.addY = y
    y = y + ch + GAP
    self.listY = y
    y = y + KP.MAX_MANAGERS * (ch + 2) + GAP
    self.countY = y
    local countLines = math.max(#wrap(getText("IGUI_KnoxPass_ManagersReadOnly"), w - PAD * 2),
        #wrap(getText("IGUI_KnoxPass_ManagersNeedFramework"), w - PAD * 2), 1)
    local bodyH = y + countLines * self.lineH + PAD

    self.win = UI.Window.new({ x = 0, y = 0, width = w, height = bodyH + 40, theme = theme, opaque = true,
        title = getText("IGUI_KnoxPass_ManagersTitle") })
    local top = self.win:contentTop()
    self.win:setHeight(top + bodyH)
    local body = CoBody:new(0, top, w, bodyH)
    body.background = false
    body.co = self
    body:initialise()
    self.win:addChild(body)

    self.faction = UI.Checkbox.new({ x = PAD, y = self.factionY, width = w - PAD * 2, label = "", theme = theme,
        target = self, onChange = Co.onFaction })
    body:addChild(self.faction)
    self.rowButtons = {}
    for i = 1, KP.MAX_MANAGERS do
        local b = UI.Button.new({ x = w - PAD - self.removeW, y = self.listY + (i - 1) * (ch + 2), width = self.removeW,
            height = ch, title = removeTitle, theme = theme, target = self, onClick = Co.onRemove })
        b:setVisible(false)
        body:addChild(b)
        self.rowButtons[i] = b
    end
    self.btnAdd = UI.Button.new({ x = w - PAD - addW, y = self.addY, width = addW, height = ch, title = addTitle,
        style = "primary", theme = theme, target = self, onClick = Co.onAdd })
    body:addChild(self.btnAdd)
    if CAPS.autocomplete then
        self.ac = UI.Autocomplete.new({ x = PAD, y = self.addY, width = w - PAD * 2 - addW - GAP, theme = theme, font = FS,
            placeholder = getText("IGUI_KnoxPass_PlayerHint"), maxLength = KP.NAME_MAX, target = self, opaque = true,
            onQuery = Co.onQuery, onPick = Co.onPick, labelOf = function(row) return row.name end,
            tagOf = function(row) return row.online and self.onlineTag or nil end })
        self.ac:addTo(body)   -- 下拉最後加，才蓋得住名單列
        self.ac:anchorList(self.countY - self.addY - ch)
    end
    return self
end

-- 照管理視窗的 state 重畫；名單只有擁有者與管理員能改
function Co:apply(s)
    self.canEdit = s.ownerOrAdmin == true
    self.names = s.co or {}
    self.count, self.max = #self.names, s.maxManagers or KP.MAX_MANAGERS
    self.faction:setLabel(fit(s.ownerFaction and getText("IGUI_KnoxPass_ManagersFactionOn", s.ownerFaction)
        or getText("IGUI_KnoxPass_ManagersFactionNone"), self.w - PAD * 2 - TOGGLE_W))
    self.faction:setChecked(s.coFaction == true, true)
    -- 擁有者不在陣營時不能打開；已經開著（擁有者後來離開陣營）照樣能關
    self.faction:setEnabled(self.canEdit and (s.ownerFaction ~= nil or s.coFaction == true))
    local textW = self.w - PAD * 2 - (self.canEdit and (self.removeW + GAP) or 0)
    for i, b in ipairs(self.rowButtons) do
        local name = self.names[i]
        self.rowText[i] = name and fit(name, textW) or nil
        b.internal = name
        b:setVisible(name ~= nil and self.canEdit)
    end
    local full = self.count >= self.max
    if self.ac then
        self.ac:setVisible(self.canEdit)
        self.ac:setEnabled(not full)
    end
    self.btnAdd:setVisible(self.canEdit)
    if not self.canEdit then
        self.countText = getText("IGUI_KnoxPass_ManagersReadOnly")
    elseif not self.ac then
        self.countText = getText("IGUI_KnoxPass_ManagersNeedFramework")
    else
        self.countText = getText("IGUI_KnoxPass_ManagersCount", tostring(self.count), tostring(self.max))
    end
    self.countLines = wrap(self.countText, self.w - PAD * 2)
end

-- 只能看的人沒有搜尋列：名單往上移到搜尋列的位置
function Co:draw(el)
    drawLines(el, self.note, PAD, self.noteY, self.lineH, "textMuted")
    drawLines(el, self.factionHint, PAD + TOGGLE_W, self.factionHintY, self.lineH, "textFaint")
    local top = self.canEdit and self.listY or self.addY
    if self.count == 0 then text(el, self.empty, PAD, top + 5, "textFaint") end
    for i = 1, self.count do
        text(el, self.rowText[i], PAD, top + (i - 1) * (self.ch + 2) + 5, "text")
    end
    drawLines(el, self.countLines, PAD, self.countY, self.lineH, "textMuted")
end

function Co.show(w)
    local co = Co.instance
    if not co then
        co = Co.new()
        co.win:addToUIManager()
        Co.instance = co
    end
    co.owner, co.picked, co.pending = w, nil, nil
    if co.ac then co.ac:setText("") end
    -- 擺在管理視窗右邊，放不下就擺左邊
    local x = w.win:getX() + w.win:getWidth() + 8
    if x + co.w > getCore():getScreenWidth() then x = math.max(0, w.win:getX() - co.w - 8) end
    co.win:setX(x)
    co.win:setY(w.win:getY())
    co:apply(w.state)
    co.win:setVisible(true)
    co.win:bringToTop()
end

function Co.hide()
    local co = Co.instance
    if not (co and co.win:getIsVisible()) then return end
    if co.ac then
        co.ac:close()
        co.ac:blur()
    end
    co.win:setVisible(false)
end

function Co.shownFor(key)
    local co = Co.instance
    return co ~= nil and co.win:getIsVisible() and co.owner ~= nil and co.owner.key == key
end

function Co:onFaction(checked)
    local w = self.owner
    if w then C.send(w.player, "managers", { key = w.key, faction = checked == true }) end
end

function Co:onRemove(button)
    local w = self.owner
    if w and button.internal then C.send(w.player, "managers", { key = w.key, remove = { button.internal } }) end
end

function Co:onAdd()
    local w, name = self.owner, self.picked
    if not (w and name) then return end
    self.picked = nil
    if self.ac then self.ac:setText("") end
    C.send(w.player, "managers", { key = w.key, add = name })
end

-- 一次只送一筆，回覆在 Win.onPlayers 交給 setResults；回 false＝框架下一幀再問
function Co:onQuery(textNow)
    local w, now = self.owner, getTimestampMs()
    if not w or (self.pending and now - self.pendingAt < QUERY_TIMEOUT_MS) then return false end
    self.pending, self.pendingAt = textNow, now
    C.send(w.player, "findPlayers", { key = w.key, query = textNow })
    return true
end

function Co:onPick(row)
    self.picked = row.name
end

-- ── 入口（Client.lua 呼叫）──────────────────────────────────────────────

local function ensure()
    if Win.instance then return Win.instance end
    local w = Win.new()
    -- 固定字串建立時取一次，draw 不查譯文（資訊列與設定列的標籤在 Win.new 量寬度時就取了）
    w.loading = getText("IGUI_KnoxPass_Loading")
    w.retryHint = getText("IGUI_KnoxPass_RetryHint")
    w.ownerOnly = getText("IGUI_KnoxPass_Why_OwnerOnly")
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
    if not r.ok and r.cmd == "query" and r.why == "NotOwner" then
        -- 伺服器確認沒有管理權（只回原因、不給設定）：關掉視窗並提示，不重讀
        w.win:close()
        C.say(w.player, KnoxPassAPI.whyText(r.why), true)
    elseif not r.ok and r.cmd == "query" then
        -- 讀取失敗：清掉舊資料、寫出原因，Body:prerender 在 3 格內重讀（TooFar 這類走近就會好的原因）
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
    elseif not r.ok and r.cmd == "managers" and w.state and Co.shownFor(w.key) then
        Co.instance:apply(w.state)                   -- 被拒時名單視窗回到伺服器的狀態（原因由 Client.lua 提示）
    elseif not r.ok and r.cmd == "findPlayers" and Co.shownFor(w.key) then
        local co = Co.instance                       -- 候選被拒（例如走遠了）：安靜收起，候選只是方便
        co.pending = nil
        if co.ac then co.ac:queryFailed(false) end
    end
end

-- 共同管理者候選（Server.lua H.findPlayers）：交給名單視窗的輸入框；不是最後送出的查詢時框架自己丟掉
function Win.onPlayers(args)
    if not Co.shownFor(args.key) then return end
    local co = Co.instance
    if args.query == co.pending then co.pending = nil end
    if co.ac and type(args.query) == "string" then co.ac:setResults(args.query, args.rows) end
end
