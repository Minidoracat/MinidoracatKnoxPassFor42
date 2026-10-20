-- 地圖手錶（MinidoracatMiniMapWatchFor42，選用、不寫 require=）：登記「Knox Pass 感應模組」，並回答「這位玩家戴著哪顆模組」。
-- 模組的憑證是物品 modData 的序號（KP.SERIAL_KEY）：裝進手錶時物品會銷毀，拆下來是新物品、新 ID，
-- modData 跟著搬（地圖手錶 MinidoracatWatch_Modules.lua 安裝時複製、拆下時寫回），所以不用物品 ID。
-- client 與 server（含 SP）都載入。
require "MinidoracatKnoxPass/Core"
local KP = MinidoracatKnoxPass

KP.WATCH_MODULE = "knoxpass"
KP.WATCH_ITEM = "MinidoracatKnoxPass.WatchModule"
KP.SERIAL_KEY = "KnoxPassSerial"

-- 要 2 版：讀序號的 getWatchModuleData 是 2 版才有
local function api()
    local A = MinidoracatWatchAPI
    if type(A) == "table" and type(A.watchApiVersion) == "number" and A.watchApiVersion >= 2 then return A end
    return nil
end

local registered = false
local function register()
    local A = api()
    if registered or not (A and type(A.registerWatchModule) == "function") then return end
    registered = A.registerWatchModule({ id = KP.WATCH_MODULE, name = "IGUI_KnoxPass_WatchModule",
        desc = "IGUI_KnoxPass_WatchModule_Desc", class = "standard", drain = 10, item = KP.WATCH_ITEM }) == true
    if not registered then KP.log("Map Watch module was not registered") end
end
-- Lua 照 Mods= 順序載入（LuaManager.java:1151-1188；只有 require= 會排前面，ZomboidFileSystem.java:819-866）：
-- 地圖手錶先載入就馬上登記；Knox Pass 先載入時等所有 MOD 的 Lua 載完（OnGameBoot：伺服器 GameServer.java:1496，
-- 客戶端重載 Lua 後 Core.java:3962）。loadModAfter 只有客戶端的 MOD 排序畫面讀，伺服器不看
register()
Events.OnGameBoot.Add(register)

-- 裝了 2 版以上的地圖手錶、模組登記成功（管理視窗的步行感應列、小地圖圖層、配方都看這個）
function KP.watchRegistered()
    return registered
end

-- 沙盒「已登記的手錶模組走近就開門」：關掉時步行不感應、配方不能做（開車與右鍵照樣認模組）
function KP.watchSensing()
    return registered and KP.sandbox("WatchSensing") == true
end

-- 模組在錶上的狀態：只有裝在戴著、有電的錶的有效槽位（"active"）才算。"notRequired" 是服主關掉整個
-- 地圖手錶系統，不能當成「不用錶也開」。沒裝、地圖手錶太舊或 API 拋錯一律 false。地圖手錶有 1 秒快取，可每幀呼叫
function KP.watchActive(player)
    local A = api()
    if not (registered and A and player) then return false end
    local ok, state = pcall(A.getWatchModuleState, player, KP.WATCH_MODULE)
    return ok and state == "active"
end

-- 戴著的錶上那顆模組的序號，不管有沒有電（管理視窗的「附近」「正在戴」用）
function KP.wornSerial(player)
    local A = api()
    if not (registered and A and player) then return nil end
    local ok, md = pcall(A.getWatchModuleData, player, KP.WATCH_MODULE)
    local s = ok and type(md) == "table" and md[KP.SERIAL_KEY] or nil
    return KP.isInt(s) and s or nil
end

-- 這位玩家身上有作用的模組序號（開門的憑證）；沒戴、沒電、槽位失效＝nil
function KP.watchSerial(player)
    if not KP.watchActive(player) then return nil end
    return KP.wornSerial(player)
end

-- 戴著有作用、登記在這扇門的模組
function KP.wornPass(player, rec)
    local s = KP.watchSerial(player)
    return s ~= nil and type(rec.mods) == "table" and rec.mods[s] ~= nil
end

-- 物品腳本 OnCreate（items_knoxpass.txt WatchModule）。每次建立物品都會呼叫（Item.java:1916-1919 →
-- InventoryItem.java:4264-4271），也包含讀檔、客戶端收到物品、地圖手錶拆下模組；這些情況原本的 modData 隨後蓋回來，
-- 所以序號不變。這時物品還沒有 ID（InventoryItemFactory.java:116 先建立、:139 才給 ID），所以自己抽一個隨機數
function KP.onModuleCreate(item)
    item:getModData()[KP.SERIAL_KEY] = ZombRandBetween(1, 2147483647)   -- LuaManager.java:7076，long 範圍
end

-- 配方 OnTest（recipes_knoxpass.txt CraftKnoxPassWatchModule）：伺服器完成製作時再查一次，右鍵快速製作也看它
function KP.canCraftModule()
    return KP.canCraft() and KP.watchSensing()
end

-- 同一條配方的 OnAddToMenu：做不了（沒裝 2 版以上的地圖手錶、服主關掉步行感應或製作）就不列出。
-- 為什麼要它、Neat Crafting 怎麼代問：Core.lua 的 MinidoracatKnoxPass_recipeShown 與 KP.wrapNeatCrafting
function MinidoracatKnoxPass_moduleRecipeShown()
    return KP.canCraftModule()
end
