-- 抬升閘門的抬桿動畫補播（SP 與 MP client）。
-- 臂模型的 Open／Close clip 只在 IsoDoor 收到同步封包時播，而且只播被同步的那一片（IsoDoor.java:1795-1805）；
-- 車庫門在本機 toggle 的分支完全不播（:1582-1596）。所以 SP、或 MP 有人手點車道 2、3 時，錨點會直接跳到開／關。
-- 這裡偵測「錨點開關變了但引擎沒在播」（PlayAnimation 會先 setAnimating(true)，:1657-1664），
-- 在 4 秒內依時間把錨點切到 spriteModels 裡的靜態姿勢（MinidoracatKnoxPass_barrier_16-24／32-40，animationTime k/8；
-- 沒有 sprite 也照樣登錄成 SpriteModel 腳本，SpriteModels.java:81-96）。只改本機顯示，不經網路、不進存檔。
require "MinidoracatKnoxPass/Core"
local KP = MinidoracatKnoxPass

local A = {}
KP.BarrierAnim = A

local POSE_BASE = { [0] = 16, [8] = 16, [3] = 32, [11] = 32 }   -- 錨點（車道 1）的 sprite 索引 → 該朝向的姿勢起點
local FAR = 120                                                  -- 離本機玩家超過這麼多格就不追（區塊已卸載或看不到）

local tracked = {}   -- 錨點物件 → { open, start, pose, base }

function A.track(obj)
    local base = POSE_BASE[KP.barrierIndex(obj)]
    if base and not tracked[obj] then tracked[obj] = { open = obj:IsOpen(), base = base } end
end

local function finish(obj, s)
    s.start, s.pose = nil, nil
    obj:setSpriteModelName(nil)
    obj:setAnimating(false)
    obj:invalidateRenderChunkLevel(256)   -- 靜止時模型烘在 chunk 貼圖裡，換回 sprite 自己的姿勢要重畫（IsoObject.java:6060）
end

local function nearPlayer(sq)
    local p = getSpecificPlayer(0)
    return p == nil or (math.abs(p:getX() - sq:getX()) <= FAR and math.abs(p:getY() - sq:getY()) <= FAR)
end

function A.tick()
    local now = getTimestampMs()
    local gone = nil
    for obj, s in pairs(tracked) do
        local sq = obj:getSquare()
        if not sq or obj:getObjectIndex() == -1 or not nearPlayer(sq) then
            if s.start then finish(obj, s) end
            gone = gone or {}
            gone[#gone + 1] = obj
        else
            local open = obj:IsOpen()
            if open ~= s.open then
                s.open = open
                if s.start or not obj:isAnimating() then
                    -- 反向中途改變（還在抬就要放下）：從目前姿勢接著走，不跳回端點
                    local done = s.start and math.min(1, (now - s.start) / KP.BARRIER_ANIM_MS) or 1
                    s.start = now - (1 - done) * KP.BARRIER_ANIM_MS
                    obj:setAnimating(true)   -- 每幀重畫、不烘進 chunk（FBORenderCell.java:1766-1767）
                end
            end
            if s.start then
                local t = (now - s.start) / KP.BARRIER_ANIM_MS
                if t >= 1 then
                    finish(obj, s)
                else
                    local pose = math.floor((open and t or 1 - t) * KP.BARRIER_POSES + 0.5)
                    if pose ~= s.pose then
                        s.pose = pose
                        obj:setSpriteModelName(KP.BARRIER_TILESET .. "_" .. (s.base + pose))
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
MapObjects.OnLoadWithSprite({
    KP.BARRIER_TILESET .. "_0", KP.BARRIER_TILESET .. "_8", KP.BARRIER_TILESET .. "_3", KP.BARRIER_TILESET .. "_11",
}, A.track, 5)
Events.OnObjectAdded.Add(A.track)
Events.OnTick.Add(A.tick)
