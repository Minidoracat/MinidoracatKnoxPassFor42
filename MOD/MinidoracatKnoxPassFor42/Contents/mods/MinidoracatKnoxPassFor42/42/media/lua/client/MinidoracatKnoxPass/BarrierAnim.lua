-- 閘門臂與模型門（雙桿閘門、兩層樓捲門、兩層樓大門）的模型掛載與動畫補播（SP 與 MP client）。
-- 3D 模型掛在中間那片（KP.hostLane：單臂閘門車道 2、模型門正中間），不掛錨點：半透明層只畫格子在畫面上的物件
-- （FBORenderCell.java:3558、IsoGridSquare.java:7839-7869），掛錨點時錨點那格一出畫面整座都不畫（offscreen-sp）。
-- 單臂閘門的車道 2 有自己的 sprite，模型寫在 tile 上；模型門的中間片全部共用一張 sprite（格位 1／9），只能逐物件指名：
-- 這裡沿車庫門鏈從錨點找到那一片，把它的 spriteModel 覆寫成 spriteModels 的 HOST 兩格（關／開，build_model_gates.py hosted），
-- 舊存檔的門不必重蓋。錨點仍是帳本、讀頭與標記綁的那片。
-- 模型的 Open／Close clip 只在 IsoDoor 收到同步封包時播，而且只播被同步的那一片（IsoDoor.java:1798-1835），所以伺服器從
-- 中間片同步（Gates.lua setGarageOpen）；車庫門在本機 toggle 的分支完全不播（:1582-1596），引擎播放的入口（PlayAnimation、
-- IsoObjectAnimations）又沒有曝露給 Lua。所以 SP、或 MP 有人手點別片時，中間片會直接跳到開／關。這裡偵測「開關變了但引擎沒在播」
-- （PlayAnimation 會先 setAnimating(true)，:1657-1664），把中間片換成 spriteModels 裡的一個姿勢 tile（「通道」），
-- 4 秒內每幀把通道的 animationTime 設成目前進度：SpriteModel 有曝露給 Lua（LuaManager.java:2201），
-- 姿勢腳本以名稱「tileset_索引」登錄（SpriteModels.java:81-96），IsoObject 照名稱取同一個物件來畫（IsoObject.java:6280-6286）。
-- 靜態姿勢的骨架矩陣照（模型, clip, 時間）快取、不淘汰（IsoObjectAnimations.java:155-173），時間量化成 1/STEPS，
-- 每個模型最多 STEPS＋1 筆。通道：單臂閘門抬起用 MinidoracatKnoxPass_barrier_16-24／32-40（綠燈貼圖），放下用 48-56／64-72
-- （紅燈；S／E 向各＋80）；模型門是區塊起點＋32-40／48-56（Core.lua KP.GATE_SLOT）。燈色跟著 spriteModel 的 texture 走
-- （IsoObjectModelDrawer.java:134-139）。每組 9 個通道，同款同方向同時在動的門各用一個，不會互相蓋掉。
-- 只改本機顯示，不經網路；SP 存檔會連覆寫名稱一起存（IsoObject.java:1551-1553），載入時一律重設。
-- 閒置時每幀只問一次 IsOpen；移除、距離與還沒找到的中間片每秒掃一次
-- 每扇門的開關速度（Server.lua mark 在錨點的 KP.MARKER_SPEED）：加速的門靜止時覆寫成加速版 spriteModel（KP.fastTwin，
-- *_fast 模型、clip 3.75 s）。多人收到開關同步時引擎照中間片當下的 getSpriteModel() 播（IsoDoor.PlayAnimation，
-- 逐物件覆寫優先，IsoObject.java:6280-6287），所以播的是加速版；通道姿勢是 clip 的比例時間，兩種速度共用，只換補播時長
require "MinidoracatKnoxPass/Core"
local KP = MinidoracatKnoxPass

local A = {}
KP.BarrierAnim = A

-- 單臂閘門錨點（車道 1，關與開）的 sprite 索引 → 該朝向的姿勢起點；S／E 向（轉 180°）一律＋80
local M = KP.BARRIER_MIRROR
local POSE_BASE = { [0] = 16, [8] = 16, [3] = 32, [11] = 32, [M] = M + 16, [M + 8] = M + 16, [M + 3] = M + 32, [M + 11] = M + 32 }
local SLOT = KP.GATE_SLOT
local FAR = 120                                                  -- 離本機玩家超過這麼多格就不追（區塊已卸載或看不到）
local STEPS = 96                                                 -- 4 秒 96 格＝每秒 24 格
local SWEEP_MS = 1000                                            -- 多久查一次移除與距離

local tracked = {}   -- 掛模型那片 → { anchor, open, start, q, chan, tileset, base, close, rest, width, fast, sm }
local anchors = {}   -- 錨點 → 掛模型那片（那格還沒載入：false）
local channels = {}  -- 通道名稱 → { sm = SpriteModel 腳本物件, user = 正在用的那片 }
local lastSweep = 0

local function isFast(obj)
    return obj:hasModData() and obj:getModData()[KP.MARKER_SPEED] == "fast"
end
local function animMs(s) return s.fast and KP.BARRIER_ANIM_FAST_MS or KP.BARRIER_ANIM_MS end

-- spriteModel 覆寫：沒變就不重設（setSpriteModelName 會清掉引擎的快取）
local function setSm(obj, s, name)
    if name ~= s.sm then
        s.sm = name
        obj:setSpriteModelName(name)
    end
end
-- 不在補播時該用的覆寫。模型門：中間片共用的 sprite 沒有模型，一律指名區塊的 HOST 兩格（關／開）；
-- 單臂閘門：車道 2 的 tile 自己帶桿子，正常速度不覆寫。加速的門用那張的加速版（沒登錄就照正常版）
local function restName(obj, s)
    local name
    if s.rest then
        name = s.tileset .. "_" .. (s.rest + (obj:IsOpen() and SLOT.OPEN or 0))
    else
        local spr = obj:getSprite()
        name = spr and spr:getName()
    end
    if s.fast then
        local twin = KP.fastTwin(name)
        if twin and getScriptManager():getSpriteModel(twin) then return twin end
    end
    return s.rest and name or nil
end

-- 錨點 → 這座門的動畫資料：姿勢的 tileset、抬起姿勢起點、放下姿勢相對抬起的位移、模型門 HOST 格位、寬度；不是錨點回 nil
local function gateOf(obj)
    local base = POSE_BASE[KP.barrierIndex(obj)]
    if base then return { tileset = KP.BARRIER_TILESET, base = base, close = KP.BARRIER_CLOSE_POSES, width = 3 } end
    local mg = KP.modelGate(obj)
    if mg and (mg.slot == 0 or mg.slot == SLOT.OPEN) then
        return { tileset = mg.tileset, base = mg.index0 + SLOT.POSE_OPEN, close = SLOT.POSE_CLOSE - SLOT.POSE_OPEN,
            rest = mg.index0 + SLOT.HOST, width = mg.width }
    end
end

-- MP 客戶端：鏈上其他片的開關對齊掛模型那片。伺服器開關時同步的是掛模型那片（Gates.lua syncPiece）；那格沒載入時整包丟掉
-- （GameClient.java:1626-1629），載入了但片段清單裡有一片沒載入時，接收端改到那片就 return（IsoDoor.java:1811-1816），
-- 之後的片停在舊狀態（含碰撞）。掛模型那片是封包對象，有載入就是最新。只改本機、不送封包、不動鎖：照接收端的做法
-- （:1820-1832）setOpen、changeSprite（都只設欄位，:144-146、:3340-3342）、RecalcAllWithNeighbours、setSquareChanged
-- （內含接收端的 PolygonalMap2.squareChanged，IsoGridSquare.java:4734-4740；順帶的 IsoRegions.squareChanged 在客戶端一開頭就
-- return，IsoRegions.java:309-311）、invalidateRenderChunkLevel。中間片的區塊快照比較舊、或錨點沒載入時對不了，等下一次開關封包
local function align(host)
    if not isClient() then return end
    local open = host:IsOpen()
    for _, step in ipairs({ IsoDoor.getGarageDoorPrev, IsoDoor.getGarageDoorNext }) do
        local p = step(host)
        while p do
            if p:IsOpen() ~= open then
                p:setOpen(open)
                p:changeSprite(p)
                local sq = p:getSquare()
                sq:RecalcAllWithNeighbours(true)
                sq:setSquareChanged()
                p:invalidateRenderChunkLevel(256)
            end
            p = step(p)
        end
    end
end

-- 沿車庫門鏈從錨點走到掛模型那片並開始追（已在追就只更新錨點）；那一格還沒載入（跨 chunk）回 false，每秒再找
local function resolve(anchor)
    local g = gateOf(anchor)
    local host = anchor
    for _ = 2, KP.hostLane(g.width) do host = host and IsoDoor.getGarageDoorNext(host) end
    if not host then return false end
    anchors[anchor] = host
    align(host)
    local s = tracked[host]
    if s then
        s.anchor = anchor
        return true
    end
    -- 模型門的中間片在指名覆寫之前沒有模型，那時收到同步，PlayAnimation 取不到模型只 setAnimating(true)（IsoDoor.java:1657-1664），
    -- 沒有 clip 會把它清掉，之後 toggled 會當成引擎在播。這時清掉是安全的：沒有模型就沒有加進 IsoObjectAnimations，
    -- 引擎沒有東西在播。單臂閘門的車道 2 自己帶模型，可能真的在播，不清
    if g.rest then host:setAnimating(false) end
    g.anchor, g.open, g.fast = anchor, host:IsOpen(), isFast(anchor)
    tracked[host] = g
    g.sm = restName(host, g)
    host:setSpriteModelName(g.sm)   -- 一律重設：SP 存檔帶著上次的覆寫，可能是補播到一半的通道
    return true
end

-- 錨點、中間片或最後一片都可以：先找到錨點（錨點那格還沒載入就等錨點載入時再找）
function A.track(obj)
    if not (KP.barrierIndex(obj) or KP.modelGate(obj)) then return end
    local anchor = obj
    if not gateOf(obj) then
        anchor = IsoDoor.getGarageDoorIndex(obj) ~= -1 and IsoDoor.getGarageDoorFirst(obj) or nil
        if not (anchor and gateOf(anchor)) then return end
    end
    if anchors[anchor] == nil then
        -- 舊版把模型與覆寫掛在錨點，SP 存檔可能帶著（加速版或通道，照新的位移會畫歪）：清掉，畫 tile 自己的
        -- （單臂閘門車道 1 是路面，模型門的錨點沒有模型）
        anchor:setSpriteModelName(nil)
        anchors[anchor] = false
    end
    resolve(anchor)
end

-- 這個方向的一個空通道（同一座換方向時先放掉舊的）；9 個都在用就共用第一個（同款同方向同時動 10 座以上才會）
local function acquire(obj, s, opening)
    if s.chan then channels[s.chan].user = nil end
    local first, fallback = s.base + (opening and 0 or s.close), nil
    for k = 0, KP.BARRIER_POSES do
        local name = s.tileset .. "_" .. (first + k)
        local c = channels[name]
        if not c then
            local sm = getScriptManager():getSpriteModel(name)
            if sm then
                c = { sm = sm }
                channels[name] = c
            end
        end
        if c and c.user == nil then
            c.user, s.chan = obj, name
            return
        end
        fallback = fallback or (c and name)
    end
    s.chan = fallback
end

local function finish(obj, s)
    if s.chan and channels[s.chan].user == obj then channels[s.chan].user = nil end
    s.start, s.q, s.chan = nil, nil, nil
    setSm(obj, s, restName(obj, s))
    obj:setAnimating(false)
    obj:invalidateRenderChunkLevel(256)   -- 同引擎播完時的收尾（IsoObjectAnimations.java:76-78）；帶 doorTrans 的門本來就每幀畫（FBORenderCell.java:1835-1837）
end

-- 任一本機玩家（分割畫面）在範圍內就算近
local function nearPlayer(sq)
    local n = getNumActivePlayers()
    local any = false
    for i = 0, n - 1 do
        local p = getSpecificPlayer(i)
        if p then
            any = true
            if math.abs(p:getX() - sq:getX()) <= FAR and math.abs(p:getY() - sq:getY()) <= FAR then return true end
        end
    end
    return not any
end

local function gone(obj)
    local sq = obj:getSquare()
    return not sq or obj:getObjectIndex() == -1 or not nearPlayer(sq)
end

-- 開關變了：引擎沒在播（或已經是我們在播）就從目前進度接著走；反向中途改變（還在抬就要放下）不跳回端點
local function toggled(obj, s, open, now)
    s.open = open
    if obj:isAnimating() and not s.start then   -- 引擎自己在播原生 clip：換成新狀態的靜止模型（播完的姿勢；加速的門是加速版）
        setSm(obj, s, restName(obj, s))
        return
    end
    local ms = animMs(s)
    local done = s.start and math.min(1, (now - s.start) / ms) or 1
    s.start, s.q = now - (1 - done) * ms, nil
    acquire(obj, s, open)
    if not s.chan then
        s.start = nil
        setSm(obj, s, restName(obj, s))
        return
    end
    setSm(obj, s, s.chan)
    obj:setAnimating(true)   -- 標成「在播」：同引擎 PlayAnimation（IsoDoor.java:1657-1664），反向中途接手時據此判斷；也讓它每幀畫
end

function A.tick()
    local now = getTimestampMs()
    local sweep = now - lastSweep >= SWEEP_MS
    if sweep then lastSweep = now end
    local drop = nil
    for obj, s in pairs(tracked) do
        if sweep and gone(obj) then
            if s.start then finish(obj, s) end
            if anchors[s.anchor] == obj then anchors[s.anchor] = false end   -- 錨點還在：那片重新載入時再找
            drop = drop or {}
            drop[#drop + 1] = obj
        else
            if sweep then
                align(obj)   -- 鏈上晚載入的片（例如在第三個 chunk 的尾端）每秒對齊一次
                -- 擁有者改了速度（錨點標記隨 transmitModData 到）：每秒對一次，不在補播中就換覆寫
                if isFast(s.anchor) ~= s.fast then
                    s.fast = not s.fast
                    if not s.start then setSm(obj, s, restName(obj, s)) end
                end
            end
            local open = obj:IsOpen()
            if open ~= s.open then toggled(obj, s, open, now) end
            if s.start then
                local t = (now - s.start) / animMs(s)
                if t >= 1 then
                    finish(obj, s)
                else
                    local q = math.floor((open and t or 1 - t) * STEPS + 0.5)
                    if q ~= s.q then
                        s.q = q
                        channels[s.chan].sm:setAnimationTime(q / STEPS)
                    end
                end
            end
        end
    end
    if drop then
        for i = 1, #drop do tracked[drop[i]] = nil end
    end
    if sweep then
        for anchor, host in pairs(anchors) do
            if gone(anchor) then
                anchors[anchor] = nil
            elseif not host then
                resolve(anchor)
            end
        end
    end
end

-- 載入區塊時（IsoChunk.java:3829 → Lua/MapObjects.java:184-215）與收到新建物件時（AddItemToMapPacket.java:94）收集：
-- 錨點（單臂閘門車道 1、模型門格位 0／8）與可能掛模型的片（單臂閘門車道 2、模型門中間片 1／9），兩格哪個先載入都找得到
local sprites = {}
for idx in pairs(POSE_BASE) do
    sprites[#sprites + 1] = KP.BARRIER_TILESET .. "_" .. idx
    sprites[#sprites + 1] = KP.BARRIER_TILESET .. "_" .. (idx + 1)
end
for ts, def in pairs(KP.MODEL_GATES) do
    for b = 0, #def.widths * #def.faces - 1 do
        for _, slot in ipairs({ 0, 1, SLOT.OPEN, SLOT.OPEN + 1 }) do sprites[#sprites + 1] = ts .. "_" .. (b * 64 + slot) end
    end
end
MapObjects.OnLoadWithSprite(sprites, A.track, 5)
Events.OnObjectAdded.Add(A.track)
Events.OnTick.Add(A.tick)
