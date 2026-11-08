-- 閘門路面的 KNOX PASS 字：玩家自己的 MOD 選項（選項 → 模組 → Minidoracat Knox Pass），預設照舊印字。
-- 字樣讓人一眼看出這是會擋車的 Knox Pass 大門，不是原版可以穿過的柵欄；關掉只改自己的畫面，白色停止線照舊。
-- 關掉時把有字的模型換成沒字的版本 <名稱>Plain（只少了字，停止線、骨架、clip 都一樣；
-- scripts/blender/barrier/build_barrier.py lines(text=False)、barrier2/build_barrier2.py paint(text=False)）：
-- 單臂閘門車道 1 的路面（BarrierLines），雙桿閘門的路面畫在臂的動畫模型裡（掛中間片的 HOST 兩格），連加速版與姿勢通道一起換。
-- 每格有兩份 SpriteModel，要一起換（setModelScriptName：SpriteModel.java:86）：tile 那份是 IsoSprite.spriteModel，
-- 門靜止時畫它（IsoObject.java:6288-6294）；腳本那份照名稱「tileset_索引」登錄，載入時從 tile 那份複製
-- （SpriteModels.java:85-88），加速版、BarrierAnim 的姿勢通道與模型門中間片的覆寫用 setSpriteModelName 指名它（IsoObject.java:6281-6287）。
-- 不看是哪一片：每個 tileset 的 512 格整批照模型名稱換，模型改掛哪一格都換得到。
-- 引擎每次畫都照名稱取模型（IsoObjectModelDrawer.java:101），這兩種門每幀畫（車道 doorTrans、雙桿 tileGeometry
-- Translucent），所以已經蓋好的門下一幀就換。兩份都是每個客戶端各一份，不經網路、不進存檔。
require "MinidoracatKnoxPass/Core"
local KP = MinidoracatKnoxPass

local OPTIONS_ID, OPTION = "MinidoracatKnoxPass", "RoadText"
local TILES = 512   -- 每個 tileset 最多 512 格（IsoWorld.java:639-640）

-- 有字的模型 → 沒字的版本（models_knoxpass_barrier.txt、models_knoxpass_gates.txt）
local PLAIN = {
    ["Base.MinidoracatKnoxPass_BarrierLines"] = "Base.MinidoracatKnoxPass_BarrierLinesPlain",
    ["Base.MinidoracatKnoxPass_Barrier2Boom6"] = "Base.MinidoracatKnoxPass_Barrier2Boom6Plain",
    ["Base.MinidoracatKnoxPass_Barrier2Boom9"] = "Base.MinidoracatKnoxPass_Barrier2Boom9Plain",
    ["Base.MinidoracatKnoxPass_Barrier2Boom6Fast"] = "Base.MinidoracatKnoxPass_Barrier2Boom6PlainFast",
    ["Base.MinidoracatKnoxPass_Barrier2Boom9Fast"] = "Base.MinidoracatKnoxPass_Barrier2Boom9PlainFast",
}
local TEXT = {}
for text, plain in pairs(PLAIN) do TEXT[plain] = text end

local R = {}
KP.RoadText = R

local options, loaded = nil, false

-- 有路面字的 tileset：單臂閘門、雙桿閘門與它的加速版（虛擬 tileset，KP.fastTwin）
local function tilesets()
    local out = { KP.BARRIER_TILESET }
    for ts, def in pairs(KP.MODEL_GATES) do
        if def.kind == "Barrier" then
            out[#out + 1] = ts
            out[#out + 1] = KP.fastTwin(ts)
        end
    end
    return out
end

-- 沒有選項或讀不到一律當開著。ini 原版只在選項畫面建立時讀回，第一次用到時自己補讀一次
function R.on()
    if not options then return true end
    if not loaded then
        loaded = true
        pcall(PZAPI.ModOptions.load, PZAPI.ModOptions)
    end
    local opt = options:getOption(OPTION)
    return not (opt and opt:getValue() == false)
end

-- 這個 tileset 的 tile 那份：只有 SpriteModelManager 拿得到（LuaManager.java:2395；原版 SpriteModelEditor.lua:696
-- 同樣用法），照登錄它的模組 ID 取（SpriteModelManager.java:82-84；沒有那格回 nil：SpriteModels.java:37-45）
local function tileCopies(ts)
    local mgr = SpriteModelManager and SpriteModelManager.getInstance()
    local ids = mgr and mgr:getModIDs()
    for k = 0, (ids and ids:size() or 0) - 1 do
        local id = ids:get(k)
        if mgr:findTileset(id, ts) then
            return function(i) return mgr:getTileProperties(id, ts, i % 8, math.floor(i / 8)) end
        end
    end
end

-- 不記換過哪些：SpriteModel 是 Java 物件，Lua 重載時不會跟著重來，每次照目前的名稱整批對一次
function R.refresh()
    local to = R.on() and TEXT or PLAIN
    local function swap(sm)
        local name = sm and to[sm:getModelScriptName()]
        if name then sm:setModelScriptName(name) end
    end
    local sms = getScriptManager()
    for _, ts in ipairs(tilesets()) do
        local tile = tileCopies(ts)
        for i = 0, TILES - 1 do
            swap(sms:getSpriteModel(ts .. "_" .. i))
            if tile then swap(tile(i)) end
        end
    end
end

if type(PZAPI) == "table" and type(PZAPI.ModOptions) == "table" and type(PZAPI.ModOptions.create) == "function" then
    local ok, created = pcall(function()
        -- 頁名沿用沙盒頁的名稱鍵（各語言都已是「Minidoracat Knox Pass」，getText 照前綴查表：Translator.java:442）
        local o = PZAPI.ModOptions:create(OPTIONS_ID, "Sandbox_MinidoracatKnoxPass")
        o:addTickBox(OPTION, "IGUI_KnoxPass_RoadText", true, "IGUI_KnoxPass_RoadText_tooltip")
        -- 選項畫面按套用：原版先把畫面值寫回 option.value 再呼叫 apply（MainOptions.lua:2829-2835、3760-3763）
        function o:apply() R.refresh() end
        return o
    end)
    if ok then options = created end
end

-- 設定備份與補回（UI 框架 rev 23）：主選單沒有 MOD 建選項時按套用，原版會清空整個 ModOptions.ini
-- （家族 pitfalls）。要早於 OnMainMenuEnter 裡 MainOptions:create 的 load
Events.OnGameBoot.Add(function()
    if not options then return end
    local UI = MinidoracatUI and MinidoracatUI.v1
    if not (UI and UI.API_MAJOR == 1 and type(UI.API_REVISION) == "number" and UI.API_REVISION >= 23
        and UI.CAPABILITIES and UI.CAPABILITIES.modOptionsBackup and UI.ModOptionsBackup) then
        return
    end
    local restored = UI.ModOptionsBackup.protect(options)
    if type(restored) == "number" and restored > 0 then
        KP.log("restored " .. restored .. " options from the backup (ModOptions.ini was wiped)")
    end
end)

Events.OnGameStart.Add(R.refresh)
