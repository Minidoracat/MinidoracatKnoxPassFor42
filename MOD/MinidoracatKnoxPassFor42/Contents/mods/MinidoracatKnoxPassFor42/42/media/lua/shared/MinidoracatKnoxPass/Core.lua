-- Minidoracat Knox Pass 共用核心：常數、沙盒、感應盒、供電、玩家走訪、幾何、身分。
-- client 與 server（含 SP）都載入；這裡不改世界狀態。
MinidoracatKnoxPass = MinidoracatKnoxPass or {}
local KP = MinidoracatKnoxPass

KP.MODULE = "MinidoracatKnoxPass"                 -- sendClientCommand 模組、沙盒頁、物品 module
KP.TAG_TYPE = "MinidoracatKnoxPass.VehicleTag"
KP.READER_TYPE = "MinidoracatKnoxPass.GateReader"
KP.PART_ID = "KnoxPassTag"
KP.MARKER_OWNER = "KnoxPassReader"                -- 大門錨點 modData：讀頭擁有者名稱（只給右鍵選單用，伺服器不信它）
KP.MARKER_LOCK = "KnoxPassLock"                   -- 大門錨點 modData：Knox Pass 門鎖是否開啟（同上）
KP.MARKER_COLOR = "KnoxPassColor"                 -- 大門錨點 modData：讀頭顏色索引（同上；沒有＝米白）
KP.MARKER_SPEED = "KnoxPassSpeed"                 -- 大門錨點 modData：開關速度 "fast"（沒有＝正常；client 據此選動畫）
KP.MANAGE_RANGE = 3                               -- 操作讀頭要站在大門幾格內（同樓層）
KP.REGISTER_RANGE = 15                            -- 登記時車要在大門幾格內
KP.CHARGE_PER_HOUR = 0.2                          -- 裝在車上、車在跑、電瓶高於 10% 時每遊戲小時充電量
KP.CHARGE_MIN_BATTERY = 0.1
KP.DRAIN_PER_OPEN = 0.01                          -- 每次開門耗電（再乘沙盒耗電倍率）

-- 抬升閘門（scripts/build_barrier_tiles.py 產生 tile 與 spriteModels；索引表見該檔 docstring）：
-- 0-2／3-5＝N／W 向車道 1-3（關，GarageDoor 1-3），8-13＝開（關＋8，IsoDoor.java:793-805），6／7＝N／W 向機箱；
-- 16-24／32-40＝N／W 向臂的靜態姿勢（只在 spriteModels，SP 動畫步進用）。
-- S／E 向＝N／W 向轉 180°（機箱在另一端），編號一律＋80：車道 80-85、開 88-93、機箱 86／87、姿勢 96-152。
-- 轉過來門線落在這一列的南邊／這一行的東邊，門只能在 N／W 邊，所以 S／E 的車道門片建在下一列／下一行（Barrier.lua）。
-- 建造用的替代 tile＝真車道編號＋160（160-165、240-245）：沒有 GarageDoor 屬性，改寫 ISBuildIsoEntity:setInfo、
-- 只看這個屬性接手建造的其他 MOD 攔不到；OnCreate 再換成真的車道門片
KP.BARRIER_TILESET = "MinidoracatKnoxPass_barrier"
KP.BARRIER_KIT = "MinidoracatKnoxPass.BoomBarrierKit"
KP.BARRIER_MIRROR = 80
KP.BARRIER_PLACEHOLDER = 160
KP.BARRIER_HEALTH = 1000                          -- 新蓋閘門：機箱（entity health）與每片車道（setHealth）。IsoDoor 預設 500
KP.BARRIER_ANIM_MS = 4000                         -- 臂的 clip 6 s ÷ speedDelta 1.5（IsoObjectAnimations.java:~281）
KP.BARRIER_ANIM_FAST_MS = 2500                    -- 「加速」：*_fast 模型的 clip 3.75 s ÷ 1.5（build_barrier_tiles.py FAST_TILESET）
KP.BARRIER_POSES = 8                              -- 靜態姿勢 0..8（animationTime k/8）
KP.BARRIER_CLOSE_POSES = 32                       -- 放下用（紅燈）姿勢＝抬起用（綠燈）＋32（build_barrier_tiles.py CLOSE_OFFSET）

-- 車庫捲門的建造替代 tile（build_barrier_tiles.py 的第 3 個 tileset）：編號＝款式×64＋格位，OnCreate 換成原版車庫門片，
-- 耐久依寬度（Barrier.lua KP.RollDoor；IsoDoor 預設 500，地圖車庫門也是 500）
KP.ROLLDOOR_TILESET = "MinidoracatKnoxPass_rolldoor"

-- 物件是閘門的哪一張 tile：回傳索引，不是閘門回 nil
function KP.barrierIndex(obj)
    local spr = obj and obj.getSprite and obj:getSprite()
    local name = spr and spr:getName()
    if not name then return nil end
    local n = string.match(name, "^" .. KP.BARRIER_TILESET .. "_(%d+)$")
    return n and tonumber(n) or nil
end

-- 每扇門可選的開關速度：錨點要有加速版 spriteModel（虛擬 tileset：單臂閘門 build_barrier_tiles.py FAST_TILESET、
-- 模型門 build_model_gates.py fast_tileset）。一層樓車庫捲門與原版的門是 2D 門片或原版模型，沒有加速版
function KP.speedSupported(anchor)
    return KP.barrierIndex(anchor) ~= nil or KP.modelGate(anchor) ~= nil
end

-- 加速版 spriteModel 的名稱：同一個索引，tileset 前綴換成 MinidoracatKnoxPassFast_
function KP.fastTwin(spriteName)
    local rest = spriteName and string.match(spriteName, "^MinidoracatKnoxPass_(.+)$")
    return rest and ("MinidoracatKnoxPassFast_" .. rest) or nil
end

-- 模型門（scripts/build_model_gates.py 產生）：雙桿閘門、兩層樓捲門（三款）、兩層樓大門（五種外觀）。MOD 的 tiledef
-- 每個 tileset 最多 512 格（IsoWorld.java:639-640），所以每個款式一個 tileset。編號＝區塊×64＋格位，區塊＝寬度序×方向數＋方向序。
-- 格位：0／1／2＝車道（關，GarageDoor 1、中間片、最後一片；第 1 片是錨點、掛 3D 模型），8-10＝開（關＋8，
-- IsoDoor.java:793-805），3／4＝兩端 A／B（A 在車道 1 那頭；機箱或門柱，實心 IsoThumpable），16 起＝建造替代 tile
-- （車道 k＝16＋k−1，沒有 GarageDoor），32-40／48-56＝抬起／放下姿勢（只在 spriteModels，SP 動畫步進用）。
-- 擺放：N／S 一列西→東 [A] 車道 1..L [B]；W／E 一行北→南 [B] 車道 L..1 [A]。門只能在 N／W 邊，S／E 的車道門片
-- 建在下一列／下一行（同轉 180° 的單臂閘門）。耐久照大小（2026-10-08 使用者決定）：一車 1000、兩車 1500、三車 2000，兩層樓 +500
KP.GATE_SLOT = { END_A = 3, END_B = 4, OPEN = 8, PLACEHOLDER = 16, POSE_OPEN = 32, POSE_CLOSE = 48 }
local BARRIER2 = { kind = "Barrier", builtin = true, ends = true, widths = { 6, 9 }, faces = { "N", "W" },
    health = { [6] = 1500, [9] = 2000 } }
local ROLL2F = { kind = "Garage", ends = false, widths = { 3, 4, 6, 9 }, faces = { "N", "W" },
    health = { [3] = 1500, [4] = 1500, [6] = 2000, [9] = 2500 } }
local GATE = { kind = "Gate", ends = true, widths = { 6, 9 }, faces = { "N", "W", "S", "E" },
    health = { [6] = 2000, [9] = 2500 } }
KP.MODEL_GATES = {
    MinidoracatKnoxPass_barrier2 = BARRIER2,
    MinidoracatKnoxPass_roll2f_industry = ROLL2F,
    MinidoracatKnoxPass_roll2f_green = ROLL2F,
    MinidoracatKnoxPass_roll2f_white = ROLL2F,
    MinidoracatKnoxPass_gate_a = GATE,
    MinidoracatKnoxPass_gate_b = GATE,
    MinidoracatKnoxPass_gate_c = GATE,
    MinidoracatKnoxPass_gate_d = GATE,
    MinidoracatKnoxPass_gate_e = GATE,
}

-- 物件是哪一扇模型門的哪一格：{ def, tileset, index0（區塊起點）, slot, width, face, fi（方向序，0 起） }；不是模型門回 nil
function KP.modelGate(obj)
    local spr = obj and obj.getSprite and obj:getSprite()
    local name = spr and spr:getName()
    local ts, n = nil, nil
    if name then ts, n = string.match(name, "^(.+)_(%d+)$") end
    local def = ts and KP.MODEL_GATES[ts]
    if not def then return nil end
    local idx = tonumber(n)
    local block = math.floor(idx / 64)
    local nf = #def.faces
    local width = def.widths[math.floor(block / nf) + 1]
    if not width then return nil end
    local fi = block % nf
    return { def = def, tileset = ts, index0 = block * 64, slot = idx % 64, width = width, face = def.faces[fi + 1], fi = fi }
end

-- 方向 → 車道 1 往車道 L 的方向、真門片相對擺放格的偏移（S／E 的門線在擺放那一列的南邊／那一行的東邊）
local ALONG = { N = { 1, 0 }, S = { 1, 0 }, W = { 0, -1 }, E = { 0, -1 } }
KP.GATE_DOOR = { N = { 0, 0 }, W = { 0, 0 }, S = { 0, 1 }, E = { 1, 0 } }

-- 車道 1 真門片的格 → 兩端的格：A 在車道 1 擺放格往外一格，B 再沿車道方向 L＋1 格
function KP.gateEnds(mg, ax, ay)
    local a, d = ALONG[mg.face], KP.GATE_DOOR[mg.face]
    local x, y = ax - d[1] - a[1], ay - d[2] - a[2]
    return x, y, x + a[1] * (mg.width + 1), y + a[2] * (mg.width + 1)
end

-- 一端（mg.slot 是 A 或 B）的格 → 車道 1 真門片的格
function KP.gateAnchor(mg, x, y)
    local a, d = ALONG[mg.face], KP.GATE_DOOR[mg.face]
    if mg.slot == KP.GATE_SLOT.END_B then x, y = x - a[1] * (mg.width + 1), y - a[2] * (mg.width + 1) end
    return x + a[1] + d[1], y + a[2] + d[2]
end

-- 車道 tile 的 DoorWallN／W（關著時車輛的 WallN／WallW 物理形狀 IsoChunk.java:2071-2091、AutoDrive 的 closedDoor）
-- 不寫在 .tiles：從 .tiles 載入會連帶設 sprite.cutN／cutW（IsoWorld.java:928-941），車道變成 cutaway 的外牆，
-- 玩家在閘線附近時車庫門只畫 2D sprite、不畫 3D 臂（IsoGridSquare.java:1318-1319、2301-2309、2392-2394），
-- 開著與動畫中的臂整支看不到（barrier-mp 2026-10-05 實踩）。這裡只補旗標與鍵，不設 cutN／cutW
local function doorWall(name, edge)
    local spr = getSprite(name)
    if not spr then return end
    local props = spr:getProperties()
    props:set(IsoFlagType["DoorWall" .. edge])
    props:set("DoorWall" .. edge, "", false)
end
Events.OnLoadedTileDefinitions.Add(function()
    for _, base in ipairs({ 0, 8, KP.BARRIER_MIRROR, KP.BARRIER_MIRROR + 8 }) do   -- N／W 與轉 180° 的 S／E，關與開
        for i = 0, 5 do doorWall(KP.BARRIER_TILESET .. "_" .. (base + i), i < 3 and "N" or "W") end
    end
    for ts, def in pairs(KP.MODEL_GATES) do
        local nf = #def.faces
        for b = 0, #def.widths * nf - 1 do
            local face = def.faces[b % nf + 1]
            for _, slot in ipairs({ 0, 1, 2, 8, 9, 10 }) do
                doorWall(ts .. "_" .. (b * 64 + slot), (face == "N" or face == "S") and "N" or "W")
            end
        end
    end
end)

-- 種類：單臂與雙桿閘門是 "Barrier"，其他模型門照定義；都不是回 nil（Gates.lua 的 kind，管理視窗的種類名稱）
function KP.gateKind(obj)
    if KP.barrierIndex(obj) then return "Barrier" end
    local mg = KP.modelGate(obj)
    return mg and mg.def.kind
end

function KP.isBarrier(obj)
    return KP.gateKind(obj) == "Barrier"
end

-- 整座一起移除的兩端：單臂閘門的機箱、模型門兩端的機箱或門柱
function KP.isGateEnd(obj)
    local i = KP.barrierIndex(obj)
    if i then return i == 6 or i == 7 or i == KP.BARRIER_MIRROR + 6 or i == KP.BARRIER_MIRROR + 7 end
    local mg = KP.modelGate(obj)
    return mg ~= nil and mg.def.ends and (mg.slot == KP.GATE_SLOT.END_A or mg.slot == KP.GATE_SLOT.END_B)
end

-- 門柱上的讀頭模型（scripts/build_barrier_tiles.py 的第 2 個 tileset）：索引＝顏色×8＋變體（變體 0-3 見 server/ReaderPost.lua R.spot）
KP.READER_POST_TILESET = "MinidoracatKnoxPass_reader"
KP.READER_POST_STRIDE = 8

-- 物件是哪張讀頭模型 tile：回傳 tile 索引（顏色×8＋變體），不是回 nil
function KP.readerPostIndex(obj)
    local spr = obj and obj.getSprite and obj:getSprite()
    local name = spr and spr:getName()
    if not name then return nil end
    local n = string.match(name, "^" .. KP.READER_POST_TILESET .. "_(%d+)$")
    return n and tonumber(n) or nil
end

-- 兩層樓大門的讀頭掛在 A 端門柱的柱面（門柱 0.34-0.60 格厚，門柱讀頭會埋進去；scripts/build_model_gates.py）：
-- 索引＝顏色×32＋外觀×4＋方向序（外觀照 KP.GATE_LOOKS，方向 N W S E）
KP.READER_PILLAR_TILESET = "MinidoracatKnoxPass_readerpillar"
KP.READER_PILLAR_STRIDE = 32
KP.GATE_LOOKS = { "MinidoracatKnoxPass_gate_a", "MinidoracatKnoxPass_gate_b", "MinidoracatKnoxPass_gate_c", "MinidoracatKnoxPass_gate_d", "MinidoracatKnoxPass_gate_e" }

-- 讀頭模型的代碼＝顏色×64＋變體：變體 0-3 門柱讀頭（READER_POST），8 起柱面讀頭（8＋外觀×4＋方向序）；不是讀頭模型回 nil
function KP.readerCode(obj)
    local spr = obj and obj.getSprite and obj:getSprite()
    local name = spr and spr:getName()
    if not name then return nil end
    local n = tonumber(string.match(name, "^" .. KP.READER_POST_TILESET .. "_(%d+)$"))
    if n then return math.floor(n / KP.READER_POST_STRIDE) * 64 + n % KP.READER_POST_STRIDE end
    n = tonumber(string.match(name, "^" .. KP.READER_PILLAR_TILESET .. "_(%d+)$"))
    if n then return math.floor(n / KP.READER_PILLAR_STRIDE) * 64 + 8 + n % KP.READER_PILLAR_STRIDE end
    return nil
end

function KP.readerTileName(code)
    local c, v = math.floor(code / 64), code % 64
    if v < 8 then return KP.READER_POST_TILESET .. "_" .. (c * KP.READER_POST_STRIDE + v) end
    return KP.READER_PILLAR_TILESET .. "_" .. (c * KP.READER_PILLAR_STRIDE + v - 8)
end

function KP.log(msg)
    print("[MinidoracatKnoxPassFor42] " .. tostring(msg))
end

-- CloseDelay 預設 2 秒（2026-10-07 使用者決定，原本 5）：現在從整台車通過門口那一刻起算，見 Sensor.lua
local DEFAULTS = {
    ReadRange = 8, ReadRangeMin = 2, ReadRangeMax = 30, LeadSeconds = 2.0, AutoDriveAhead = 150,
    CloseDelay = 2, CloseDelayMin = 0, CloseDelayMax = 30, RequirePower = true,
    TagDrainPercent = 100, AllowCraft = true, SpawnLoot = true,
}

function KP.sandbox(key)
    local page = SandboxVars and SandboxVars[KP.MODULE]
    local value = page and page[key]
    if value == nil then return DEFAULTS[key] end
    return value
end

-- ── 每扇門的設定（擁有者在管理視窗改，伺服器 Server.lua H.settings）─────────────
-- name＝"ReadRange" 或 "CloseDelay"：沙盒的 <name>Min～<name>Max（服主填反也照樣用）
function KP.settingBounds(name)
    local lo, hi = tonumber(KP.sandbox(name .. "Min")) or 0, tonumber(KP.sandbox(name .. "Max")) or 0
    if lo > hi then lo, hi = hi, lo end
    return lo, hi
end

function KP.clampSetting(name, v)
    local lo, hi = KP.settingBounds(name)
    return math.max(lo, math.min(hi, v))
end

-- 這扇門的生效值：擁有者設的值，沒設就用沙盒預設，一律再夾一次（服主之後縮小範圍，舊值照新範圍用）
function KP.gateRange(rec)
    return KP.clampSetting("ReadRange", tonumber(rec.range) or tonumber(KP.sandbox("ReadRange")) or 8)
end

function KP.gateDelay(rec)
    return KP.clampSetting("CloseDelay", tonumber(rec.closeDelay) or tonumber(KP.sandbox("CloseDelay")) or 2)
end

-- 配方 OnTest（recipes_knoxpass.txt）：引擎對每個候選輸入呼叫，全部 false 時配方無法執行
function KP.canCraft()
    return KP.sandbox("AllowCraft") == true
end

function KP.isInt(v)
    return type(v) == "number" and v == v and v == math.floor(v) and v > -2147483649 and v < 2147483648
end

-- ── 外殼顏色 ────────────────────────────────────────────────────────────
-- 順序就是顏色索引 0-6（帳本 rec.color、門柱 tile 顏色×8＋變體）；米白是原本的物品，type 不帶後綴。
-- 換色用原版油漆一格＋油漆刷（Server.lua H.recolor／recolorReader）；各色配方用同一罐油漆（scripts/gen_colors.py 照這張表產生）；
-- 搜刮生成後隨機換色（server/Items/MinidoracatKnoxPass_Distributions.lua）
KP.COLORS = {
    { id = "Cream", suffix = "", paint = "Base.PaintWhite" },
    { id = "Black", suffix = "_Black", paint = "Base.PaintBlack" },
    { id = "Graphite", suffix = "_Graphite", paint = "Base.PaintGrey" },
    { id = "Olive", suffix = "_Olive", paint = "Base.PaintGreen" },
    { id = "Navy", suffix = "_Navy", paint = "Base.PaintBlue" },
    { id = "Orange", suffix = "_Orange", paint = "Base.PaintOrange" },
    { id = "Red", suffix = "_Red", paint = "Base.PaintRed" },
}
local TAG_COLOR, READER_COLOR = {}, {}   -- 物品 fullType → 顏色索引
for i, c in ipairs(KP.COLORS) do
    TAG_COLOR[KP.TAG_TYPE .. c.suffix] = i - 1
    READER_COLOR[KP.READER_TYPE .. c.suffix] = i - 1
end

-- 感應盒或讀頭的顏色索引；其他物品回 nil
function KP.colorOf(item)
    if not item then return nil end
    local t = item:getFullType()
    return TAG_COLOR[t] or READER_COLOR[t]
end

-- 合法顏色索引（client 送來的值也用這個驗）
function KP.isColor(c)
    return KP.isInt(c) and c >= 0 and c < #KP.COLORS
end

-- 同一種物品換成顏色 c 的 fullType（base＝KP.TAG_TYPE 或 KP.READER_TYPE）
function KP.colorType(base, c)
    return base .. KP.COLORS[c + 1].suffix
end

-- 換成顏色 c 要用的原版油漆（身上含背包、至少一格）與油漆刷（tag base:paintbrush）：原版刷油漆同款查法
-- （ISPaintCursor.lua:227 getFirstTagRecurse(ItemTag.PAINTBRUSH)、getFirstTypeRecurse(paintType)），多跳過 0 格的罐子
-- （getFirstTypeEvalRecurse，ItemContainer.java:1569）。回傳油漆；缺什麼回 nil, 原因代碼（NoBrush／NoPaint）。
-- 伺服器重驗與 client 選單共用
local function hasUse(item) return item:getCurrentUses() >= 1 end
function KP.paintFor(player, c)
    local inv = player:getInventory()
    if not inv:getFirstTagRecurse(ItemTag.PAINTBRUSH) then return nil, "NoBrush" end
    local paint = inv:getFirstTypeEvalRecurse(KP.COLORS[c + 1].paint, hasUse)
    if not paint then return nil, "NoPaint" end
    return paint
end

-- ── 感應盒 ──────────────────────────────────────────────────────────────

function KP.isTag(item)
    return item ~= nil and TAG_COLOR[item:getFullType()] ~= nil
end

function KP.isReader(item)
    return item ~= nil and READER_COLOR[item:getFullType()] ~= nil
end

-- 顯示用序號：由伺服器分配的物品 ID 換算。憑證本身是物品 ID，不是這個字串
function KP.serial(id)
    local n = math.floor(math.abs(id)) % 1000000
    return string.format("KP %04d-%02d", math.floor(n / 100), n % 100)
end

-- DrainableComboItem：getCurrentUsesFloat／setCurrentUsesFloat（DrainableComboItem.java:83-90），
-- 設定值會量化到 UseDelta 一格（0.001，items_knoxpass.txt），所以每次變動至少要一格
function KP.charge(item)
    return item:getCurrentUsesFloat()
end

function KP.setCharge(item, value)
    item:setCurrentUsesFloat(math.max(0, math.min(1, value)))
end

function KP.drainScale()
    return (tonumber(KP.sandbox("TagDrainPercent")) or 100) / 100
end

-- 車上裝著的感應盒（物品類型正確才算），回傳 item, part
function KP.vehicleTag(vehicle)
    local part = vehicle and vehicle:getPartById(KP.PART_ID)
    local item = part and part:getInventoryItem()
    if KP.isTag(item) then return item, part end
    return nil, part
end

-- ── 供電 ────────────────────────────────────────────────────────────────

-- 發電機（haveElectricity，IsoGridSquare.java:9696）或電網（hasGridPower，:11799）都算。
-- 刻意不照原版室外電器要求 getRoom()（ISWorldObjectContextMenu.lua:460-461）：大門在室外，照原版就永遠吃不到電網
function KP.squarePowered(sq)
    return sq ~= nil and (sq:haveElectricity() or sq:hasGridPower())
end

-- ── 玩家 ────────────────────────────────────────────────────────────────

-- server 走在線清單；SP 的 getOnlinePlayers 回空清單（LuaManager.java:4453-4463），改走本機玩家
function KP.eachPlayer(fn)
    if isServer() then
        local list = getOnlinePlayers()
        for i = 0, list:size() - 1 do fn(list:get(i)) end
    else
        for i = 0, getNumActivePlayers() - 1 do
            local p = getSpecificPlayer(i)
            if p then fn(p) end
        end
    end
end

-- 站在 (x,y,z) 那格的 range 格內、同一層
function KP.near(player, x, y, z, range)
    return player ~= nil and math.floor(player:getZ()) == z
        and math.abs(player:getX() - (x + 0.5)) <= range + 0.5
        and math.abs(player:getY() - (y + 0.5)) <= range + 0.5
end

-- 伺服器端身分（家族 conventions「玩家身分」的最小版）：分割畫面第 2–4 位和主玩家共用 SteamID、無從驗證→nil；
-- Steam 伺服器另回 SteamID 數值，只拿來和安裝讀頭時記下的值比對（數值會捨入到 16 的倍數，仍足以擋冒名）。
-- SP 沒有擁有權問題，回本機名字
function KP.principal(player)
    if not player then return nil end
    local name = player:getUsername()
    if type(name) ~= "string" or name == "" then return nil end
    if not isServer() then return name, nil end
    if player:getPlayerNum() ~= 0 then return nil end
    local sid = nil
    if getSteamModeActive and getSteamModeActive() then sid = player:getSteamID() end
    return name, sid
end

-- 伺服器上的管理員：角色有 CanOpenLockedDoors（Capability 已曝露，LuaManager.java:2460；IsoPlayer.getRole 可能為 nil）
function KP.isAdmin(player)
    if not isServer() or not player or not Capability then return false end
    local ok, yes = pcall(function()
        local role = player:getRole()
        return role ~= nil and role:hasCapability(Capability.CanOpenLockedDoors)
    end)
    return ok and yes == true
end

-- ── 幾何 ────────────────────────────────────────────────────────────────

-- 點 (px,py) 到線段 (ax,ay)-(bx,by) 的距離平方
function KP.segDistSq(px, py, ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    local len2 = dx * dx + dy * dy
    local t = 0
    if len2 > 0 then
        t = ((px - ax) * dx + (py - ay) * dy) / len2
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
    end
    local ex, ey = ax + t * dx - px, ay + t * dy - py
    return ex * ex + ey * ey
end
