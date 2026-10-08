-- 閘門臂與模型門（雙桿閘門、兩層樓捲門、兩層樓大門）的動畫補播（SP 與 MP client）。
-- 錨點模型的 Open／Close clip 只在 IsoDoor 收到同步封包時播，而且只播被同步的那一片（IsoDoor.java:1795-1805）；
-- 車庫門在本機 toggle 的分支完全不播（:1582-1596），引擎播放的入口（PlayAnimation、IsoObjectAnimations）又沒有曝露給 Lua。
-- 所以 SP、或 MP 有人手點中間或最後一片時，錨點會直接跳到開／關。這裡偵測「錨點開關變了但引擎沒在播」
-- （PlayAnimation 會先 setAnimating(true)，:1657-1664），把錨點換成 spriteModels 裡的一個姿勢 tile（「通道」），
-- 4 秒內每幀把通道的 animationTime 設成目前進度：SpriteModel 有曝露給 Lua（LuaManager.java:2201），
-- 姿勢腳本以名稱「tileset_索引」登錄（SpriteModels.java:81-96），IsoObject 照名稱取同一個物件來畫（IsoObject.java:6280-6286）。
-- 靜態姿勢的骨架矩陣照（模型, clip, 時間）快取、不淘汰（IsoObjectAnimations.java:155-173），時間量化成 1/STEPS，
-- 每個模型最多 STEPS＋1 筆。通道：單臂閘門抬起用 MinidoracatKnoxPass_barrier_16-24／32-40（綠燈貼圖），放下用 48-56／64-72
-- （紅燈；S／E 向各＋80）；模型門是區塊起點＋32-40／48-56（Core.lua KP.GATE_SLOT）。燈色跟著 spriteModel 的 texture 走
-- （IsoObjectModelDrawer.java:134-139）。每組 9 個通道，同款同方向同時在動的門各用一個，不會互相蓋掉。
-- 只改本機顯示，不經網路、不進存檔。閒置時每幀只問一次 IsOpen；移除與距離每秒掃一次
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

local tracked = {}   -- 錨點物件 → { open, start, q, chan, tileset, base, close }
local channels = {}  -- 通道名稱 → { sm = SpriteModel 腳本物件, user = 正在用的錨點 }
local lastSweep = 0

-- 錨點 → 姿勢的 tileset、抬起姿勢起點、放下姿勢相對抬起的位移；不是錨點回 nil
local function poses(obj)
    local base = POSE_BASE[KP.barrierIndex(obj)]
    if base then return KP.BARRIER_TILESET, base, KP.BARRIER_CLOSE_POSES end
    local mg = KP.modelGate(obj)
    if mg and (mg.slot == 0 or mg.slot == SLOT.OPEN) then
        return mg.tileset, mg.index0 + SLOT.POSE_OPEN, SLOT.POSE_CLOSE - SLOT.POSE_OPEN
    end
end

function A.track(obj)
    if tracked[obj] then return end
    local ts, base, close = poses(obj)
    if ts then tracked[obj] = { open = obj:IsOpen(), tileset = ts, base = base, close = close } end
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
    obj:setSpriteModelName(nil)
    obj:setAnimating(false)
    obj:invalidateRenderChunkLevel(256)   -- 同引擎播完時的收尾（IsoObjectAnimations.java:76-78）；帶 doorTrans 的門本來就每幀畫（FBORenderCell.java:1835-1837）
end

local function nearPlayer(sq)
    local p = getSpecificPlayer(0)
    return p == nil or (math.abs(p:getX() - sq:getX()) <= FAR and math.abs(p:getY() - sq:getY()) <= FAR)
end

-- 開關變了：引擎沒在播（或已經是我們在播）就從目前進度接著走；反向中途改變（還在抬就要放下）不跳回端點
local function toggled(obj, s, open, now)
    s.open = open
    if obj:isAnimating() and not s.start then return end   -- 引擎自己在播原生 clip
    local done = s.start and math.min(1, (now - s.start) / KP.BARRIER_ANIM_MS) or 1
    s.start, s.q = now - (1 - done) * KP.BARRIER_ANIM_MS, nil
    acquire(obj, s, open)
    if not s.chan then
        s.start = nil
        return
    end
    obj:setSpriteModelName(s.chan)
    obj:setAnimating(true)   -- 標成「在播」：同引擎 PlayAnimation（IsoDoor.java:1657-1664），反向中途接手時據此判斷；也讓它每幀畫
end

function A.tick()
    local now = getTimestampMs()
    local sweep = now - lastSweep >= SWEEP_MS
    if sweep then lastSweep = now end
    local gone = nil
    for obj, s in pairs(tracked) do
        local sq = sweep and obj:getSquare()
        if sweep and (not sq or obj:getObjectIndex() == -1 or not nearPlayer(sq)) then
            if s.start then finish(obj, s) end
            gone = gone or {}
            gone[#gone + 1] = obj
        else
            local open = obj:IsOpen()
            if open ~= s.open then toggled(obj, s, open, now) end
            if s.start then
                local t = (now - s.start) / KP.BARRIER_ANIM_MS
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
    if gone then
        for i = 1, #gone do tracked[gone[i]] = nil end
    end
end

-- 載入區塊時（IsoChunk.java:3829 → Lua/MapObjects.java:184-215）與收到新建物件時（AddItemToMapPacket.java:94）收集錨點
local anchors = {}
for idx in pairs(POSE_BASE) do anchors[#anchors + 1] = KP.BARRIER_TILESET .. "_" .. idx end
for ts, def in pairs(KP.MODEL_GATES) do
    for b = 0, #def.widths * #def.faces - 1 do
        anchors[#anchors + 1] = ts .. "_" .. (b * 64)
        anchors[#anchors + 1] = ts .. "_" .. (b * 64 + SLOT.OPEN)
    end
end
MapObjects.OnLoadWithSprite(anchors, A.track, 5)
Events.OnObjectAdded.Add(A.track)
Events.OnTick.Add(A.tick)
