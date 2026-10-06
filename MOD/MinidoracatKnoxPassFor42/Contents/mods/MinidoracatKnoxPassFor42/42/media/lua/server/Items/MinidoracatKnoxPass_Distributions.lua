-- 把感應盒與讀頭塞進原版既有的 procedural loot 表（版型照家族 AutoDrive MDAD_Distributions.lua）。
--
-- OnPostDistributionMerge（IsoWorld.java:1888）早於 SandboxOptions.load()（IsoWorld.java:1896），
-- 此處讀不到存檔的 SpawnLoot：權重永遠註冊，生成後由 OnFillContainer 讀已載入的沙盒值移除。
-- 已生成的容器與既有道具不受影響。表名都已對過 ProceduralDistributions.lua（42.21.0）。
--
-- 顏色：表裡只放米白，生成後在 OnFillContainer 隨機換成 7 色之一。不把權重拆成 7 色各一筆：每一筆都會另加一次
-- 殭屍密度加成（ItemPickerJava.java:2109，(基礎機率 × 100 × 戰利品倍率 ＋ 殭屍密度) × 時間倍率），拆開生成量會變多。

require "MinidoracatKnoxPass/Core"
local KP = MinidoracatKnoxPass

local ENTRIES = {
    {
        fullType = KP.TAG_TYPE,
        -- 車用小電子：加油站修車區、修車廠電工架、車材行工具、電器行雜貨
        targets = {
            { "GasStorageMechanics", 2 },
            { "GasStorageCombo", 1 },
            { "CarSupplyTools", 2 },
            { "MechanicShelfElectric", 2 },
            { "ElectronicStoreMisc", 1 },
        },
    },
    {
        fullType = KP.READER_TYPE,
        -- 門禁設備：電工工具、電子板條箱，五金行與修車廠電工架少量
        targets = {
            { "ElectricianTools", 1 },
            { "CrateElectronics", 1 },
            { "ToolStoreMisc", 0.5 },
            { "MechanicShelfElectric", 0.5 },
        },
    },
}

-- ProceduralDistributions 是 process-global：回主選單換存檔不保證重建，先刪自己的 pair 再加，避免權重疊加
local function removeItem(items, fullType)
    local i = #items - 1
    while i >= 1 do
        if items[i] == fullType then
            table.remove(items, i + 1)
            table.remove(items, i)
        end
        i = i - 2
    end
end

local function injectLoot()
    local list = ProceduralDistributions and ProceduralDistributions.list
    if not list then return end
    for entryIndex = 1, #ENTRIES do
        local entry = ENTRIES[entryIndex]
        for targetIndex = 1, #entry.targets do
            local target = entry.targets[targetIndex]
            local tbl = list[target[1]]
            local items = tbl and tbl.items
            if items then
                removeItem(items, entry.fullType)
                items[#items + 1] = entry.fullType
                items[#items + 1] = target[2]
            end
        end
    end
end

local function isInventoryContainer(item)
    return instanceof(item, "InventoryContainer")
end

-- 剛生成的米白感應盒或讀頭換成隨機一色（米白也是 7 選 1 之一）：電量與狀態照抄（Server.lua H.recolor 同法）
local function recolorLoot(container, item)
    local c = ZombRand(#KP.COLORS)
    if c == 0 then return end
    local isTag = KP.isTag(item)
    local fresh = container:AddItem(KP.colorType(isTag and KP.TAG_TYPE or KP.READER_TYPE, c))
    if not fresh then return end
    if isTag then KP.setCharge(fresh, KP.charge(item)) end
    fresh:setCondition(item:getCondition())
    container:DoRemoveItem(item)
end

-- keep＝搜刮開著：米白的隨機換色；關著：任何顏色都移除。倒著走，換色時加在尾端的新物品不會再被走到
local function filterOneContainer(container, keep)
    local items = container:getItems()
    if not items then return end
    for i = items:size() - 1, 0, -1 do
        local item = items:get(i)
        local c = KP.colorOf(item)   -- 任何顏色的感應盒或讀頭；其他物品是 nil
        -- 仍在生成 call stack 內，直接增刪即可；容器之後才做正常同步
        if c ~= nil and not keep then
            container:DoRemoveItem(item)
        elseif c == 0 and keep then
            recolorLoot(container, item)
        end
    end
end

local function filterSpawnedLoot(_, _, container)
    if isClient() or not container then return end
    -- 背包分支傳的是未曝露的 ItemPickerContainer（ItemPickerJava.java:630,1151,1405），
    -- 對它索引任何欄位都會 throw，只能用 instanceof 判別
    if not instanceof(container, "ItemContainer") then return end
    local keep = KP.sandbox("SpawnLoot") == true
    -- 上面那種壞 event 拿不到真正的背包，改在外層容器的 event 用引擎遞迴 API 一併處理巢狀背包
    -- （ItemContainer.getAllEvalRecurse，ItemContainer.java:1936）
    local nested = container:getAllEvalRecurse(isInventoryContainer)
    filterOneContainer(container, keep)
    for i = 0, nested:size() - 1 do
        local child = nested:get(i):getInventory()
        if child then filterOneContainer(child, keep) end
    end
end

Events.OnPostDistributionMerge.Add(injectLoot)
Events.OnFillContainer.Add(filterSpawnedLoot)
