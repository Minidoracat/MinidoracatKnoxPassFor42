-- 小地圖與世界地圖（MinidoracatMiniMapFor42，選用）：標出你戴著、有作用的手錶模組登記過的大門。
-- 門的清單是伺服器只推給本人的 KP.passes.gates（Sensor.lua pushPasses），這裡不掃世界。
-- 圖層的開關、大小與名稱由小地圖保存（settings 5 版的 layers），Knox Pass 不存任何值。
require "MinidoracatKnoxPass/Core"
require "MinidoracatKnoxPass/Watch"
local KP = MinidoracatKnoxPass

local M = {}
KP.MapLayer = M

local OWNER = "MinidoracatKnoxPassFor42"
local CREAM = { r = 0.95, g = 0.90, b = 0.78 }       -- 米白：金黃已經是車輛管理的「自己的車」
local BADGE = { r = 0.06, g = 0.06, b = 0.07, a = 0.92 }

-- 貼圖等到第一次畫才取（OnGameStart 前可能還沒載入）；取不到記 false，不每幀重試
local gateTex, dotTex = nil, nil
local function textures()
    if gateTex == nil then gateTex = getTexture("media/ui/MinidoracatKnoxPass/map_gate.png") or false end
    if dotTex == nil then dotTex = getTexture("media/ui/MinidoracatUI/mui_dot.png") or false end
    return gateTex or nil, dotTex or nil
end

local function marker(label)
    local tex, dot = textures()
    return { texture = tex, r = CREAM.r, g = CREAM.g, b = CREAM.b, state = "live", label = label, layer = "gates",
        badge = dot and { texture = dot, r = BADGE.r, g = BADGE.g, b = BADGE.b, a = BADGE.a },
        ring = { r = CREAM.r, g = CREAM.g, b = CREAM.b, a = 1 } }
end

-- provider 每幀被呼叫：一律回快取表，只在推送換了（KP.passes.rev）時重建
local cache = { rev = -1, out = { revision = 0, markers = {} } }

function M.provider(playerNum, surface)
    if playerNum ~= 0 then return nil end   -- 推送清單只有一份，分割畫面第 2-4 位不畫（同車輛管理）
    local p, passes = getSpecificPlayer(0), KP.passes
    if not (p and passes and passes.gates and KP.watchActive(p)) then return nil end   -- 沒戴、沒電或槽位失效
    if passes.rev ~= cache.rev then
        local markers = {}
        for i, g in ipairs(passes.gates) do
            local m = marker(getText("IGUI_KnoxPass_Kind_" .. tostring(g.kind)))
            m.id, m.x, m.y = g.key, g.x, g.y
            markers[i] = m
        end
        cache.rev = passes.rev
        cache.out = { revision = cache.out.revision + 1, markers = markers }
    end
    return cache.out
end

local function atLeast(v, n) return type(v) == "number" and v >= n end

-- MiniMap 不在 require 內，載入序不保證：等所有 client Lua 載完（OnGameStart）才偵測。沒裝地圖手錶就沒有模組、
-- 沒有可畫的門，不登記；小地圖太舊（要 settings 5 版＋marker 3 版）就不畫、log 一次
function M.register()
    local API = MinidoracatMiniMapAPI
    if M.registered or not KP.watchRegistered() then return end
    if not (API and atLeast(API.settingsApiVersion, 5) and atLeast(API.markerApiVersion, 3)
        and type(API.registerMarkerProvider) == "function" and type(API.registerSettingsSection) == "function") then
        return KP.log("MiniMap layer API not available; gates are not drawn on the minimap")
    end
    API.registerMarkerProvider(OWNER, M.provider)
    M.registered = API.registerSettingsSection(OWNER, { label = "IGUI_KnoxPass_MapSection", icon = "lock",
        group = "addon", order = 20, layers = { { id = "gates", label = "IGUI_KnoxPass_MapLayer",
            show = { mini = true, world = true }, size = 16, names = { mini = false, world = true },
            namesMiniLabel = "IGUI_KnoxPass_MapNamesMini", namesWorldLabel = "IGUI_KnoxPass_MapNamesWorld",
            sample = marker(getText("IGUI_KnoxPass_Kind_Double")) } } }) == true
end

Events.OnGameStart.Add(M.register)
