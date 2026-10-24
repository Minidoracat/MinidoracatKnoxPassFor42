-- Knox Pass 讀頭管理視窗（MinidoracatUIFor42 API rev 7：Window／Button／Checkbox／Tabs／VirtualList，Dialog 選用；
-- 每扇門設定的下拉選單要 rev 14 的 Dropdown，沒有時只顯示數字；共同管理者名單的搜尋框要 rev 11 的 Autocomplete，
-- 安全屋那一段的捲動要 rev 16 的 ScrollPanel，截字的全文提示要 rev 17 的 Checkbox tooltip，輸入框的紅框要 rev 16 的 setInvalid）。
-- 只有能管理這扇門的人（擁有者、共同管理者、管理員）拿得到 state；伺服器回 NotOwner 時視窗關掉。
-- 畫面只顯示伺服器 state（「大門」那列例外：照這台客戶端看到的門寫，Win:readDoor）；所有變更送指令後等新的 state，
-- 不做樂觀更新。視窗開著時地上畫出這扇門的感應範圍。
-- 框架不足時整檔在這裡結束：KP.Window 不存在，右鍵「管理讀頭」改成停用並提示（Client.lua）。
require "MinidoracatKnoxPass/Client"
require "MinidoracatKnoxPass/Watch"
local KP = MinidoracatKnoxPass
local C = KP.Client
local G = KP.Gates

-- widget 檔不由 V1 載入，也不保證排在本檔之前（MinidoracatKnoxPass < MinidoracatUI），自己 pcall require
if not (MinidoracatUI and MinidoracatUI.v1) then pcall(require, "MinidoracatUI/V1") end
pcall(require, "MinidoracatUI/VirtualList")
pcall(require, "MinidoracatUI/Widgets/Controls")
pcall(require, "MinidoracatUI/Widgets/Window")
pcall(require, "MinidoracatUI/Widgets/Dropdown")
pcall(require, "MinidoracatUI/Widgets/Autocomplete")
pcall(require, "MinidoracatUI/Widgets/ScrollPanel")
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
local DOOR_MS = 250                               -- 「大門」那列多久看一次門現在開著沒

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

-- 提示框的文字：原版 ISToolTip 照 300 px 自動換行、不管行首禁則（會把「打不壞）」拆成「打不／壞）」）。先用框架的
-- UI.Text.wrap 照提示框的字型（ISToolTip.GetFont）折好、用 \n 接起來，ISButton.updateTooltip 看到 \n 就不再換行（ISButton.lua:326-327）
local function tipText(s, w)
    if not (UI.Text and type(UI.Text.wrap) == "function") then return s end
    return table.concat(UI.Text.wrap(s, w, ISToolTip.GetFont()), "\n")
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

-- ── 內容區：prerender 檢查距離、跟上門的開關、讀取失敗時重讀並畫清單底，render 畫資訊列與空清單說明 ─
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
    -- 「大門」那列跟上門現在的開關（Win:readDoor），最多每 DOOR_MS 一次
    local now = getTimestampMs()
    if now >= w.doorAt then
        w.doorAt = now + DOOR_MS
        w:readDoor()
    end
    -- 讀取失敗：站進大門 3 格內（同伺服器 gateFor 的判定）就重讀，最多每 RETRY_MS 一次
    if w.failed and now >= w.retryAt and KP.near(p, w.ax, w.ay, w.gz, KP.MANAGE_RANGE) then
        w.retryAt = now + RETRY_MS
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
    "IGUI_KnoxPass_Durability", "IGUI_KnoxPass_Range", "IGUI_KnoxPass_Delay", "IGUI_KnoxPass_Speed", "IGUI_KnoxPass_Share",
    "IGUI_KnoxPass_Managers" }
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

-- 「不會被破壞」只有管理員能改（伺服器 H.settings 的 adminOf；SP 只有一位玩家，一律算）。一般玩家的視窗不放這個開關，
-- 耐久那一列滑過去說明管理員怎麼開。視窗照打開的人建，身分變了（升降權）下次打開時重建（ensure）
local function canShield(player) return not isClient() or KP.hasAdminRole(player) end

-- 耐久那一列的滑鼠提示：透明面板蓋在那一列，借原版 ISButton.updateTooltip（hover 時建 ISToolTip、離開收掉，
-- ISButton.lua:316-346；UI 框架 Controls.lua updateTooltip 同法）。視窗關掉時 ISToolTip 自己收（ISToolTip.lua:58-59）
local Tip = ISPanel:derive("KnoxPassTip")
function Tip:prerender() end
function Tip:update()
    ISPanel.update(self)
    ISButton.updateTooltip(self)
end

function Win.new(admin)
    local self = setmetatable({ rows = {}, state = nil, page = "tags", picked = {}, tagRows = {}, nearRows = {}, admin = admin },
        Win)
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
    for _, t in ipairs({ getText("IGUI_KnoxPass_NoPower"), getText("IGUI_KnoxPass_PowerNotNeeded"),
        getText("IGUI_KnoxPass_DurabilityShielded"), getText("IGUI_KnoxPass_DurabilityValue", "2500", "2500") }) do
        info = math.max(info, tm:MeasureStringX(FS, t))
    end
    -- 門鎖、算室內、手錶步行感應與不會被破壞（只有管理員的視窗有）四個開關的標籤（含不支援、不准上鎖、伺服器沒開放）：
    -- 開關 36 px＋間距 8 px（UI 框架 Controls.lua:615-616 TOGGLE_WIDTH、LABEL_GAP）。沒裝地圖手錶就不建步行感應那一列
    local hasWalk = KP.watchRegistered()
    local toggle = 0
    local toggleKeys = { "IGUI_KnoxPass_Lock", "IGUI_KnoxPass_LockUnsupported", "IGUI_KnoxPass_LockSafehouseOnly",
        "IGUI_KnoxPass_Indoor", "IGUI_KnoxPass_IndoorFramed", "IGUI_KnoxPass_IndoorUnsupported",
        "IGUI_KnoxPass_Walk", "IGUI_KnoxPass_WalkOff" }
    if admin then
        toggleKeys[#toggleKeys + 1] = "IGUI_KnoxPass_Indestructible"
        toggleKeys[#toggleKeys + 1] = "IGUI_KnoxPass_IndestructibleAll"
    end
    for _, k in ipairs(toggleKeys) do
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
    -- 高度跟字型走：資訊五列＋門鎖與算室內（與步行感應、管理員的不會被破壞）與五列設定（含共同管理）＋說明＋分頁列＋清單＋頁尾
    local toggles = 2 + (hasWalk and 1 or 0) + (admin and 1 or 0)
    local bodyH = PAD + self.lineH * 5 + (ch + GAP) * (toggles + 5) + self.lineH + GAP + ch + GAP + self.listH
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
    y = y + self.lineH * 5 -- 種類、擁有者、供電、門、耐久
    self.lock = UI.Checkbox.new({ x = PAD, y = y, width = W - PAD * 2, label = getText("IGUI_KnoxPass_Lock"),
        theme = theme, target = self, onChange = Win.onLock })
    body:addChild(self.lock)
    y = y + ch + GAP
    -- 算室內（這扇門 rec.indoor）：車庫門鏈才能勾，其他門停用並寫原因；說明放提示（applySettings 照門的種類換字）
    self.indoor = UI.Checkbox.new({ x = PAD, y = y, width = W - PAD * 2, label = getText("IGUI_KnoxPass_Indoor"),
        theme = theme, target = self, onChange = Win.onIndoor })
    body:addChild(self.indoor)
    y = y + ch + GAP
    if hasWalk then
        self.walk = UI.Checkbox.new({ x = PAD, y = y, width = W - PAD * 2, label = getText("IGUI_KnoxPass_Walk"),
            theme = theme, target = self, onChange = Win.onWalk })
        body:addChild(self.walk)
        y = y + ch + GAP
    end
    -- 不會被破壞：只有管理員的視窗有這個開關；一般玩家看耐久那一列（寫「不會被破壞」，滑過去說明管理員怎麼開）
    if admin then
        self.indestructible = UI.Checkbox.new({ x = PAD, y = y, width = W - PAD * 2,
            label = getText("IGUI_KnoxPass_Indestructible"), theme = theme, target = self, onChange = Win.onIndestructible })
        body:addChild(self.indestructible)
        y = y + ch + GAP
    else
        local tip = Tip:new(PAD, self.infoY + self.lineH * 4, W - PAD * 2, self.lineH)
        tip:initialise()
        tip.background = false
        tip.tooltip = tipText(getText("IGUI_KnoxPass_DurabilityTip"), W - PAD * 2)
        body:addChild(tip)
        self.durabilityTip = tip
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

-- 共同管理那一列的按鈕標題：擁有者陣營（開著陣營、擁有者也還在陣營時）、勾選而且還有效的安全屋、個別幾人，用 ManagersJoin
-- 一段一段接起來。陣營跟其他段接在一起時只寫「陣營」，按鈕才放得下（managers-mp 1020a：「陣營「KPManagers」＋1 間安全屋」
-- 被截掉；陣營名在名單視窗看得到）
local function managersSummary(s)
    local people, houses = #(s.co or {}), 0
    for _, h in ipairs(s.houses or {}) do
        if h.on and not h.gone then houses = houses + 1 end
    end
    local parts = {}
    if houses > 0 then parts[1] = getText("IGUI_KnoxPass_ManagersHouses", tostring(houses)) end
    if people > 0 then parts[#parts + 1] = getText("IGUI_KnoxPass_ManagersPeople", tostring(people)) end
    if s.coFaction and s.ownerFaction then
        table.insert(parts, 1, #parts > 0 and getText("IGUI_KnoxPass_ManagersFactionShort")
            or getText("IGUI_KnoxPass_ManagersFaction", s.ownerFaction))
    end
    if #parts == 0 then return getText("IGUI_KnoxPass_ManagersNone") end
    local out = parts[1]
    for i = 2, #parts do out = getText("IGUI_KnoxPass_ManagersJoin", out, parts[i]) end
    return out
end

-- 設定各列跟著 state 走（被拒時也用來回到伺服器的值）：設了值就選生效值（上下限縮小後是夾過的值），沒設選預設。
-- 開關速度只有錨點有加速版模型的門能選（state.speedSupported），其他門停用並寫明；分享對象右邊寫分享出去的是什麼
function Win:applySettings(s)
    -- 不會被破壞（生效值；只有管理員的視窗有開關）：沙盒對所有大門開著時打勾並停用，標籤寫原因
    if self.indestructible then
        self.indestructible:setChecked(s.indestructible == true, true)
        self.indestructible:setEnabled(s.isAdmin == true and s.indestructibleAll ~= true)
        self.indestructible:setLabel(getText(s.indestructibleAll and "IGUI_KnoxPass_IndestructibleAll"
            or "IGUI_KnoxPass_Indestructible"))
    end
    -- 算室內（這扇門 rec.indoor）：只有車庫門鏈能勾（state.indoorSupport＝"yes"）；有門框的門寫「本來就算」，其他門寫不支援。
    -- 說明在提示：模型門與閘門多一句「門片擋住角色時會像牆一樣切掉」（state.indoorCut）。提示要框架 rev 17（Checkbox.setTooltip）
    local support = s.indoorSupport
    self.indoor:setChecked(s.indoor == true, true)
    self.indoor:setEnabled(support == "yes")
    self.indoor:setLabel(getText(support == "framed" and "IGUI_KnoxPass_IndoorFramed"
        or support == "no" and "IGUI_KnoxPass_IndoorUnsupported" or "IGUI_KnoxPass_Indoor"))
    if self.indoor.setTooltip then
        self.indoor:setTooltip(support == "yes" and tipText(getText(s.indoorCut and "IGUI_KnoxPass_IndoorTipCut"
            or "IGUI_KnoxPass_IndoorTip"), W - PAD * 2) or nil)
    end
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

-- 「大門」那列照這台客戶端看到的門寫（伺服器 state 不帶）：Knox Pass、原版右鍵、尋路穿過門、殭屍或別人打開的都照實寫，
-- 視窗開著時 Body:prerender 每 DOOR_MS 再看一次，變了才換字
function Win:readDoor()
    local open = self.adapter ~= nil and G.isOpen(self.adapter, self.anchor)
    if open == self.doorOpen then return end
    self.doorOpen = open
    self.rows[4] = open and self.doorOpenText or self.doorClosedText
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
    self:readDoor()
    -- 耐久：剩下耐久最少的那一片（伺服器 S.durability，墊高的照墊之前的值）；不會被破壞時不寫數字
    rows[5] = s.indestructible and getText("IGUI_KnoxPass_DurabilityShielded")
        or s.hp and getText("IGUI_KnoxPass_DurabilityValue", tostring(s.hp), tostring(s.hpFull)) or "?"
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
    self.indoor:setChecked(false, true)
    self.indoor:setEnabled(false)
    if self.indestructible then
        self.indestructible:setChecked(false, true)
        self.indestructible:setEnabled(false)
    end
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
    text(el, self.labels[6], PAD, self.rangeY + 5, "textMuted")
    text(el, self.labels[7], PAD, self.delayY + 5, "textMuted")
    text(el, self.labels[8], PAD, self.speedY + 5, "textMuted")
    text(el, self.labels[9], PAD, self.shareY + 5, "textMuted")
    text(el, self.labels[10], PAD, self.managersY + 5, "textMuted")
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
    for i = 1, 5 do
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

-- 算室內：這扇門一直記成牆（門開著也算）；伺服器回 BadArgs／NotLoaded 時 Win.onResult 照 state 改回
function Win:onIndoor(checked)
    C.send(self.player, "settings", { key = self.key, indoor = checked == true })
end

-- 不會被破壞：只有管理員能改（伺服器回 AdminOnly 時 Win.onResult 照 state 改回）
function Win:onIndestructible(checked)
    C.send(self.player, "settings", { key = self.key, indestructible = checked == true })
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
-- 內容照管理視窗的 state 畫（Co:apply）；擁有者與管理員能改（state.ownerOrAdmin），共同管理者只能看。三段：陣營（擁有者陣營的
-- 成員）、安全屋（擁有者所在的每一間，一列一個開關；共同管理者只看得到勾選的）、個別帳號。
-- 輸入框是 UI.Autocomplete（框架 API rev 11，CAPS.autocomplete；家族 Safehouse 的分享對象同款）：候選由伺服器
-- H.findPlayers 回，只列伺服器認得的玩家；打了字就能按「加入」，沒選候選時標紅輸入框並提示，伺服器 H.managers 再重查一次。
-- 被截字的帳號、陣營標籤與每一間的全名放在提示（滑鼠停留；Checkbox 的提示鍵盤焦點也讀）。
-- 框架沒有 Autocomplete 時名單照列，新增停用並寫明
local CO_W = 340               -- 最窄寬度；陣營開關的標籤比較長的語言撐寬（Co.new）
local QUERY_TIMEOUT_MS = 3000   -- 候選查詢送出後這麼久沒回覆就當作掉了，可以再送
local TOGGLE_W = 44             -- 勾選框的開關圖樣與間距（標籤截字用）
local HEAD_FIRST, HEAD_TOP = 6, 12   -- 分段標題上方的留白（第一段只留 HEAD_FIRST；同框架 NavList 的群組標題）
local HOUSE_ROWS = 3            -- 安全屋那一段看得到幾列，多的捲動（UI.ScrollPanel）
local TIP_W = 300               -- 提示框的折行寬（同原版 ISToolTip 自動換行的寬度）

local CoBody = ISPanel:derive("KnoxPassCoBody")
-- 文字畫在 prerender：子元件（搜尋框的下拉）在 prerender 之後、render 之前畫，下拉才蓋得住名單文字
-- （UIElement.render：prerender → children → render）
function CoBody:prerender()
    local co = self.co
    if co.ac then
        local now = co.ac:getText()
        if co.picked and now ~= co.picked then co.picked = nil end   -- 選了候選之後又改字就不算選過：只能加入確實存在的玩家
        if now ~= co.typed then                                      -- 改了字：收掉「要從候選選」的紅框
            co.typed = now
            if co.ac.field.setInvalid then co.ac.field:setInvalid(false) end
        end
    end
    co.btnAdd:setEnabled(co.canEdit and co.ac ~= nil and co.typed ~= "" and co.count < co.max)
    co:draw(self)
end

-- 安全屋那一列：框架 Checkbox 畫開關與屋名，這裡在右邊補「屋主 · 人數」或「已失效」（render 在 Checkbox 的 prerender 之後）
local function houseRowRender(box)
    if not box.info then return end
    local c = box._enabled and COL[box.infoToken] or COL.textDisabled or COL.textFaint
    box:drawTextRight(box.info, box.width - 6, box.infoY, c.r, c.g, c.b, c.a, FS)
end

-- 家族 Safehouse 的安全屋：原生 owner 是 @MSH:<編號>，屋主帳號問它的公開 API（MinidoracatSafehouse.v1.ownerName：查本機快取、
-- 不配置；資料還沒到時回 nil，下一次 state 再問）。沒裝家族 Safehouse 就不寫屋主
local function houseOwner(h)
    if h.owner then return h.owner end
    local api = MinidoracatSafehouse and MinidoracatSafehouse.v1
    if not (api and api.CAPABILITIES and api.CAPABILITIES.ownerName and api.ownerName) then return nil end
    local ok, name = pcall(api.ownerName, h.key)
    return ok and type(name) == "string" and name ~= "" and name or nil
end

function Co.new()
    local self = setmetatable({ names = {}, rowText = {}, count = 0, max = KP.MAX_MANAGERS, canEdit = false, houses = {},
        countText = "", footLines = {} }, Co)
    local tm = getTextManager()
    local fh = tm:getFontHeight(FS)
    local ch = fh + 10
    self.lineH, self.ch = fh + 6, ch
    local lineH = self.lineH
    local addTitle, removeTitle = getText("IGUI_KnoxPass_Add"), getText("IGUI_KnoxPass_Remove")
    local addW = tm:MeasureStringX(FS, addTitle) + 20
    self.removeW = tm:MeasureStringX(FS, removeTitle) + 20
    -- 寬度跟著語言撐開（同管理視窗）：陣營開關的標籤只有一行，擁有者不在陣營時那句最長；陣營名太長照樣截字（滑過去看全文）
    local w = math.max(CO_W, PAD * 2 + TOGGLE_W + tm:MeasureStringX(FS, getText("IGUI_KnoxPass_ManagersFactionNone")),
        PAD * 2 + TOGGLE_W + tm:MeasureStringX(FS, getText("IGUI_KnoxPass_ManagersFactionOn", "")))
    self.w = w
    local inner = w - PAD * 2
    self.note = wrap(getText("IGUI_KnoxPass_ManagersNote"), inner)
    self.heads = { getText("IGUI_KnoxPass_ManagersFactionHead"), getText("IGUI_KnoxPass_ManagersHousesHead"),
        getText("IGUI_KnoxPass_ManagersPeopleHead") }
    self.factionHint = wrap(getText("IGUI_KnoxPass_ManagersFactionHint"), inner - TOGGLE_W)
    self.housesHint = wrap(getText("IGUI_KnoxPass_ManagersHousesHint"), inner - TOGGLE_W)
    self.housesNone = wrap(getText("IGUI_KnoxPass_ManagersHousesNone"), inner - 12)
    self.housesOff = wrap(getText("IGUI_KnoxPass_ManagersHousesOff"), inner - 12)
    self.empty = fit(getText("IGUI_KnoxPass_ManagersEmpty"), inner)
    self.onlineTag = getText("IGUI_KnoxPass_Online")
    -- 由上而下：說明；陣營（標題、開關、說明）；安全屋（標題、HOUSE_ROWS 列、說明）；個別帳號（標題與人數、搜尋框＋加入、
    -- 名單最多 KP.MAX_MANAGERS 列）；底下一行（只能看、或框架不足的說明，會換行：留最長那句的行數）。搜尋框的下拉蓋住名單列
    local y = PAD
    self.noteY = y
    y = y + #self.note * lineH + HEAD_FIRST
    self.factionHeadY = y
    y = y + lineH
    self.factionY = y
    y = y + ch
    self.factionHintY = y
    y = y + #self.factionHint * lineH + HEAD_TOP
    self.housesHeadY = y
    y = y + lineH
    self.housesY, self.housesH = y, HOUSE_ROWS * (ch + 2)
    y = y + self.housesH
    self.housesHintY = y
    y = y + #self.housesHint * lineH + HEAD_TOP
    self.peopleHeadY = y
    y = y + lineH
    self.addY = y
    y = y + ch + GAP
    self.listY = y
    y = y + KP.MAX_MANAGERS * (ch + 2) + GAP
    self.footY = y
    local footLines = math.max(#wrap(getText("IGUI_KnoxPass_ManagersReadOnly"), inner),
        #wrap(getText("IGUI_KnoxPass_ManagersNeedFramework"), inner), 1)
    local bodyH = y + footLines * lineH + PAD

    self.win = UI.Window.new({ x = 0, y = 0, width = w, height = bodyH + 40, theme = theme, opaque = true,
        title = getText("IGUI_KnoxPass_ManagersTitle") })
    local top = self.win:contentTop()
    self.win:setHeight(top + bodyH)
    local body = CoBody:new(0, top, w, bodyH)
    body.background = false
    body.co = self
    body:initialise()
    self.win:addChild(body)

    self.faction = UI.Checkbox.new({ x = PAD, y = self.factionY, width = inner, label = "", theme = theme,
        target = self, onChange = Co.onFaction })
    body:addChild(self.faction)
    -- 安全屋：一列一個開關（同陣營那個開關），先建好、照 state 顯示（同「移除」鈕）。放進捲動容器（框架 rev 16）：鍵盤與手把照
    -- 框架 Window 的自動目標走，焦點換到看不到的列會自己捲過去
    -- ponytail: 舊框架沒有捲動容器時只列前 HOUSE_ROWS 間（伺服器排序勾選的在前）；真有人卡在這裡再自己畫捲軸
    local parent, ox, oy, rows = body, PAD, self.housesY, HOUSE_ROWS
    if CAPS.scrollPanel and UI.ScrollPanel then
        self.housesBox = UI.ScrollPanel.new({ x = PAD, y = self.housesY, width = inner, height = self.housesH, theme = theme })
        body:addChild(self.housesBox)
        parent, ox, oy, rows = self.housesBox, 0, 0, KP.MAX_HOUSES
    end
    self.rowW = self.housesBox and self.housesBox:contentWidth() or inner
    self.houseRows = {}
    for i = 1, rows do
        local box = UI.Checkbox.new({ x = ox, y = oy + (i - 1) * (ch + 2), width = self.rowW, height = ch, label = "",
            theme = theme, target = self, onChange = Co.onHouse })
        box.render, box.infoY, box.infoToken = houseRowRender, math.floor((ch - fh) / 2), "textMuted"
        box:setVisible(false)
        parent:addChild(box)
        self.houseRows[i] = box
    end
    -- 個別帳號：每列一顆「移除」；帳號被截掉的列蓋一塊 Tip 顯示全文（同耐久那一列）。Tip 在搜尋框之前加，下拉才蓋得住
    self.rowButtons, self.nameTips = {}, {}
    for i = 1, KP.MAX_MANAGERS do
        local rowY = self.listY + (i - 1) * (ch + 2)
        local tip = Tip:new(PAD, rowY, inner, ch)
        tip:initialise()
        tip.background = false
        tip:setVisible(false)
        body:addChild(tip)
        self.nameTips[i] = tip
        local b = UI.Button.new({ x = w - PAD - self.removeW, y = rowY, width = self.removeW, height = ch, title = removeTitle,
            theme = theme, target = self, onClick = Co.onRemove })
        b:setVisible(false)
        body:addChild(b)
        self.rowButtons[i] = b
    end
    self.btnAdd = UI.Button.new({ x = w - PAD - addW, y = self.addY, width = addW, height = ch, title = addTitle,
        style = "primary", theme = theme, target = self, onClick = Co.onAdd })
    body:addChild(self.btnAdd)
    if CAPS.autocomplete then
        self.ac = UI.Autocomplete.new({ x = PAD, y = self.addY, width = inner - addW - GAP, theme = theme, font = FS,
            placeholder = getText("IGUI_KnoxPass_PlayerHint"), maxLength = KP.NAME_MAX, target = self, opaque = true,
            onQuery = Co.onQuery, onPick = Co.onPick, labelOf = function(row) return row.name end,
            tagOf = function(row) return row.online and self.onlineTag or nil end })
        self.ac:addTo(body)   -- 下拉最後加，才蓋得住名單列
        self.ac:anchorList(self.footY - self.addY - ch)
    end
    return self
end

-- 安全屋那一段（伺服器 Server.lua ownerHouses 排好：勾選的在前）：屋名截到右邊放得下「屋主 · 人數」，
-- 全名、屋主與人數放在提示；已失效（找不到、或擁有者已不在裡面）的列照樣開著，擁有者關掉才移除
function Co:applyHouses(list)
    self.houses = list
    local tm = getTextManager()
    for i, box in ipairs(self.houseRows) do
        local h = list[i]
        box:setVisible(h ~= nil)
        if h then
            local owner, n = houseOwner(h), tostring(h.members or 0)
            local title = h.title ~= nil and h.title ~= "" and h.title or "?"
            local info = h.gone and getText("IGUI_KnoxPass_ManagersHouseGone")
                or owner and getText("IGUI_KnoxPass_ManagersHouseInfo", owner, n)
                or getText("IGUI_KnoxPass_ManagersHouseCount", n)
            box.internal, box.info = h.key, info
            box.infoToken = h.gone and (COL.warning and "warning" or "errorText") or "textMuted"
            box:setLabel(fit(title, self.rowW - TOGGLE_W - tm:MeasureStringX(FS, info) - 18))
            box:setChecked(h.on == true, true)
            box:setEnabled(self.canEdit)
            if box.setTooltip then
                box:setTooltip(tipText(h.gone and getText("IGUI_KnoxPass_ManagersHouseGoneTip", title)
                    or getText("IGUI_KnoxPass_ManagersHouseTip", title, owner or "?", n), TIP_W))
            end
        end
    end
end

-- 照管理視窗的 state 重畫；名單只有擁有者與管理員能改
function Co:apply(s)
    self.canEdit = s.ownerOrAdmin == true
    self.names = s.co or {}
    self.count, self.max = #self.names, s.maxManagers or KP.MAX_MANAGERS
    -- 陣營：截字時才掛完整標籤（框架 rev 17 的提示；滑鼠停留與鍵盤焦點都看得到）
    local factionText = s.ownerFaction and getText("IGUI_KnoxPass_ManagersFactionOn", s.ownerFaction)
        or getText("IGUI_KnoxPass_ManagersFactionNone")
    local label = fit(factionText, self.w - PAD * 2 - TOGGLE_W)
    self.faction:setLabel(label)
    if self.faction.setTooltip then self.faction:setTooltip(label ~= factionText and factionText or nil) end
    self.faction:setChecked(s.coFaction == true, true)
    -- 擁有者不在陣營時不能打開；已經開著（擁有者後來離開陣營）照樣能關
    self.faction:setEnabled(self.canEdit and (s.ownerFaction ~= nil or s.coFaction == true))
    self:applyHouses(s.houses or {})
    -- 只能看的人沒有搜尋列：名單往上移到搜尋列的位置
    local top = self.canEdit and self.listY or self.addY
    local textW = self.w - PAD * 2 - (self.canEdit and (self.removeW + GAP) or 0)
    for i, b in ipairs(self.rowButtons) do
        local name = self.names[i]
        local shown = name and fit(name, textW) or nil
        self.rowText[i] = shown
        b.internal = name
        b:setVisible(name ~= nil and self.canEdit)
        if name then b:setTooltip(getText("IGUI_KnoxPass_RemoveName", name)) end   -- 手把焦點也顯示（ISButton.lua:317）
        local tip = self.nameTips[i]
        tip.tooltip = shown ~= name and name or nil   -- 只有被截掉的列有提示
        tip:setY(top + (i - 1) * (self.ch + 2))
        tip:setWidth(textW)
        tip:setVisible(tip.tooltip ~= nil)
    end
    if self.ac then
        self.ac:setVisible(self.canEdit)
        self.ac:setEnabled(self.count < self.max)
    end
    self.btnAdd:setVisible(self.canEdit)
    self.countText = getText("IGUI_KnoxPass_ManagersCount", tostring(self.count), tostring(self.max))
    self.footText = not self.canEdit and getText("IGUI_KnoxPass_ManagersReadOnly")
        or not self.ac and getText("IGUI_KnoxPass_ManagersNeedFramework") or nil
    self.footLines = self.footText and wrap(self.footText, self.w - PAD * 2) or {}
end

function Co:draw(el)
    local lineH, inner = self.lineH, self.w - PAD * 2
    drawLines(el, self.note, PAD, self.noteY, lineH, "textMuted")
    text(el, self.heads[1], PAD, self.factionHeadY, "textMuted")
    drawLines(el, self.factionHint, PAD + TOGGLE_W, self.factionHintY, lineH, "textFaint")
    text(el, self.heads[2], PAD, self.housesHeadY, "textMuted")
    theme:fill(el, PAD, self.housesY, inner, self.housesH, "well")
    if #self.houses == 0 then
        drawLines(el, self.canEdit and self.housesNone or self.housesOff, PAD + 6, self.housesY + 5, lineH, "textFaint")
    end
    drawLines(el, self.housesHint, PAD + TOGGLE_W, self.housesHintY, lineH, "textFaint")
    text(el, self.heads[3], PAD, self.peopleHeadY, "textMuted")
    local c = COL.textMuted
    el:drawTextRight(self.countText, self.w - PAD, self.peopleHeadY, c.r, c.g, c.b, c.a, FS)
    local top = self.canEdit and self.listY or self.addY
    if self.count == 0 then text(el, self.empty, PAD, top + 5, "textFaint") end
    for i = 1, self.count do
        text(el, self.rowText[i], PAD, top + (i - 1) * (self.ch + 2) + 5, "text")
    end
    drawLines(el, self.footLines, PAD, self.footY, lineH, "textMuted")
end

function Co.show(w)
    local co = Co.instance
    if not co then
        co = Co.new()
        co.win:addToUIManager()
        Co.instance = co
    end
    co.owner, co.picked, co.pending, co.typed = w, nil, nil, nil
    if co.ac then
        co.ac:setText("")
        if co.ac.field.setInvalid then co.ac.field:setInvalid(false) end
    end
    if co.housesBox then co.housesBox:setYScroll(0) end
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

-- 安全屋的開關：送給伺服器、等新的 state（擁有者已不在那間時伺服器回 NoHouse，Win.onResult 照 state 改回）
function Co:onHouse(checked, box)
    local w = self.owner
    if w and box.internal then C.send(w.player, "managers", { key = w.key, house = box.internal, on = checked == true }) end
end

function Co:onRemove(button)
    local w = self.owner
    if w and button.internal then C.send(w.player, "managers", { key = w.key, remove = { button.internal } }) end
end

-- 只能加伺服器認得的玩家（使用者 2026-10-12），所以要從候選選；沒選就按時標紅輸入框並說怎麼做（送出時才檢查：
-- 停用的按鈕鍵盤與手把停不到，也看不到原因。使用者 2026-10-20）
function Co:onAdd()
    local w, name = self.owner, self.picked
    if not w then return end
    if not name then
        local msg = getText("IGUI_KnoxPass_PickCandidate")
        if self.ac and self.ac.field.setInvalid then self.ac.field:setInvalid(true, msg) end   -- 紅框＋驚嘆號，不只靠顏色
        C.say(w.player, msg, true)
        return
    end
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

local function ensure(admin)
    local w = Win.instance
    if w and w.admin == admin then return w end
    if w then   -- 身分變了：舊視窗收掉，照新身分重建（版面在 Win.new 定好）
        w.win:close()
        w.win:removeFromUIManager()
    end
    w = Win.new(admin)
    -- 固定字串建立時取一次，draw 不查譯文（資訊列與設定列的標籤在 Win.new 量寬度時就取了）
    w.loading = getText("IGUI_KnoxPass_Loading")
    w.retryHint = getText("IGUI_KnoxPass_RetryHint")
    w.doorOpenText, w.doorClosedText = getText("IGUI_KnoxPass_DoorOpen"), getText("IGUI_KnoxPass_DoorClosed")
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
    local w = ensure(canShield(player))
    local sq = anchor:getSquare()
    w.player, w.anchor, w.key = player, anchor, key
    w.ax, w.ay, w.gz = sq:getX(), sq:getY(), sq:getZ()
    w.gx, w.gy = w.ax + 0.5, w.ay + 0.5
    w.adapter = G.resolve(anchor)   -- 只取第一個回傳值（adapter）
    w.doorOpen, w.doorAt = nil, 0   -- 換一扇門：下一次 prerender 就重寫「大門」那列
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
