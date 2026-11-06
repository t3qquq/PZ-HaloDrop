-- Halo Drop 하늘 뷰 (클라): 탑승~점프 대기 동안 월드 대신 지도 위의 수송기를 보여준다
--
-- 왜: 48 타일/초 비행은 클라 청크 스트리밍이 못 따라와 월드가 검게 나온다(11-06 런 3). 비행 구간은
--   서버 Flight(경로·시각)로 위치만 계산하고 화면은 UI 로 그린다 (Wingsmith 하늘 뷰와 같은 구조,
--   claude/Wingsmith_하늘뷰_분석.md).
-- 구조 (런 4 에서 재편: 전체화면 요소가 인벤토리·체력·HUD 를 전부 가렸다)
--   SkyRoot  전체화면 ISUIElement 하나만 UIManager 에 넣고 backMost() 로 맨 뒤에 둔다(바닐라 FishingManager 와 같은 방식).
--            바닐라 UI 는 그 위에 그대로 그려진다. 지도·기체 씬은 이 요소의 자식, 구름 덮개는 root:render 에서 맨 마지막.
--   SkyTiles pzmap2dzi 아이소 렌더 타일(HaloDropMap.levels)을 직접 깐다 (Wingsmith 식). 배율 = 샌드박스 SkyScale(px/칸).
--            타일이 없으면(HaloDropTiles.lua 부재) 아래 SkyMap 으로 대체.
--   SkyMap   UIWorldMap(바닐라 월드맵 벡터 렌더러, 아이소메트릭). 타일 없을 때의 폴백.
--   SkyScene ISUI3DScene 에 수송기 차량 스크립트 모델. 화면 가운데 고정, 기수만 돌림.
--            UI3DScene 은 zoom 1 이어도 보이는 폭이 12.7 유닛(b42.21 :383 zoomMult, :2621 ortho 1366/zoomMult)이라
--            53 m 짜리 C-17 은 getObjectScale("plane"):set(SCENE_SCALE) 로 객체 자체를 줄인다 (바닐라 SpriteModelEditor.lua:596 과 같은 방법).
--   HUD 는 HaloDropHUD 가 OnPostUIDraw 로 그린다 (OnPreUIDraw 는 UI 요소보다 먼저라 이 요소에 가려진다).
-- 조정 키 (하늘 뷰가 열려 있을 때만, 값은 로그 `sky tune:` 으로): [ ] 기수 YAW0 ±5도, ; ' 기체 크기 x0.8/x1.25,
--   , . 내려다보는 각도 TILT ±5도, PgUp PgDn 씬 zoom ±1. 맞춘 값을 HaloDropConfig.lua 의 HaloDrop.SKY 에 옮겨 적는다.
--   기수 방향의 기본 식은 update() 참고 (315 + 차량 yaw). YAW0 는 그 위의 미세 보정.
-- 호출: HaloDropJumper 가 board() 에서 open, 점프 수송기 확보(onPlaneAcquired) 또는 자유낙하 시작 때 close.
--   점프 대기(JUMPING) 중엔 setCover(1).
-- 시점: Viewpoint(1·3인칭) 여부와 무관하게 UI 로 그린다 (런 4 라운드 3 에서 Viewpoint 켠 채로 정상 표시 확인).

if isServer() then return end

require "HaloDropConfig"
require "HaloDropFlight"
require "HaloDropMap"
require "ISUI/ISUIElement"
require "ISUI/Maps/ISMapDefinitions"
require "Vehicles/ISUI/ISUI3DScene"

HaloDropSky = {}
local S = { open = false, cover = 0, coverTarget = 0 }
HaloDropSky.S = S

local function log(msg) HaloDrop.log(msg) end
local K = HaloDrop.SKY

-- 런 중 키로 바꾸는 값. open() 때 K 에서 복사한다
local T = { zoom = K.SCENE_ZOOM, scale = K.SCENE_SCALE, tilt = K.TILT, yaw0 = K.YAW0 }
HaloDropSky.T = T

local function screenSize()
    local core = getCore()
    return core:getScreenWidth(), core:getScreenHeight()
end

-- ── 타일 레이어 (Wingsmith 식 직접 그리기) ──────────────────────────────────────
local SkyTiles = ISUIElement:derive("HaloDropSkyTiles")

function SkyTiles:new()
    local w, h = screenSize()
    local o = ISUIElement:new(0, 0, w, h)
    setmetatable(o, self)
    self.__index = self
    o.tex = {}        -- key -> Texture | false(없음)
    o.loads = 0
    o.drawn, o.missing = 0, 0
    o.nextLog = nil
    return o
end

-- 텍스처는 바닐라 getTexture 가 캐시한다(해제 없음). 프레임당 새로 읽는 수를 제한해 히치를 줄인다.
function SkyTiles:tile(L, c, r)
    local key = L.id .. ":" .. c .. "_" .. r
    local t = self.tex[key]
    if t ~= nil then return t or nil end
    if not HaloDropMap.has(L, c, r) then
        self.tex[key] = false
        return nil
    end
    if self.loads >= K.TILE_LOADS_PER_FRAME then return nil end
    self.loads = self.loads + 1
    local path = L.path .. c .. "_" .. r .. ".jpg"
    local ok, tx = pcall(function() return getTexture(path) end)
    if ok and tx then
        self.tex[key] = tx
        return tx
    end
    self.tex[key] = false
    log("sky tiles: missing " .. path .. (ok and "" or (" err=" .. tostring(tx))))
    return nil
end

function SkyTiles:prerender()
    self.loads = 0
    local scale = HaloDrop.opt("SkyScale")
    local L = HaloDropMap.levelFor(scale)
    if not L or not S.cx then
        self:drawRect(0, 0, self.width, self.height, 1, HaloDropMap.BG.r, HaloDropMap.BG.g, HaloDropMap.BG.b)
        return
    end
    local k = scale / L.px                     -- 타일 px -> 화면 px
    local cxp, cyp = HaloDropMap.toMap(L, S.cx, S.cy)
    local ax, ay = self.width / 2, self.height / 2
    -- 화면 (0,0) 에 해당하는 타일 픽셀 좌표
    local mx0, my0 = cxp - ax / k, cyp - ay / k
    local c0, r0 = math.floor(mx0 / HaloDropMap.TILE), math.floor(my0 / HaloDropMap.TILE)
    local c1 = math.floor((mx0 + self.width / k) / HaloDropMap.TILE)
    local r1 = math.floor((my0 + self.height / k) / HaloDropMap.TILE)
    local tint = S.tint or 1
    self:drawRect(0, 0, self.width, self.height, 1, HaloDropMap.BG.r * tint, HaloDropMap.BG.g * tint, HaloDropMap.BG.b * tint)
    local drawn, missing = 0, 0
    for r = r0, r1 do
        for c = c0, c1 do
            local t = self:tile(L, c, r)
            if t then
                local x = math.floor((c * HaloDropMap.TILE - mx0) * k + 0.5)
                local y = math.floor((r * HaloDropMap.TILE - my0) * k + 0.5)
                local x2 = math.floor(((c + 1) * HaloDropMap.TILE - mx0) * k + 0.5)
                local y2 = math.floor(((r + 1) * HaloDropMap.TILE - my0) * k + 0.5)
                self:drawTextureScaled(t, x, y, x2 - x, y2 - y, 1, tint, tint, tint)
                drawn = drawn + 1
            elseif HaloDropMap.has(L, c, r) then
                missing = missing + 1
            end
        end
    end
    self.drawn, self.missing, self.level = drawn, missing, L
    local now = getTimestampMs()
    if not self.nextLog or now >= self.nextLog then
        self.nextLog = now + 5000
        log(string.format("sky tiles: level=%s scale=%.2f k=%.3f center=(%.0f,%.0f) tiles c%d..%d r%d..%d drawn=%d pending=%d",
            tostring(L.id), scale, k, S.cx, S.cy, c0, c1, r0, r1, drawn, missing))
    end
end

-- ── 지도 레이어 (벡터 폴백) ───────────────────────────────────────────────────────────────
local SkyMap = ISUIElement:derive("HaloDropSkyMap")

function SkyMap:new()
    local w, h = screenSize()
    local o = ISUIElement:new(0, 0, w, h)
    setmetatable(o, self)
    self.__index = self
    return o
end

function SkyMap:instantiate()
    self.javaObject = UIWorldMap.new(self)
    self.mapAPI = self.javaObject:getAPIv3()
    self.mapAPI:setMapItem(MapItem.getSingleton())
    self.mapAPI:setMaxZoom(24)
    self.javaObject:setX(self.x)
    self.javaObject:setY(self.y)
    self.javaObject:setWidth(self.width)
    self.javaObject:setHeight(self.height)
    -- 바닐라 미니맵(ISMiniMap.lua:710~)과 같은 순서로 맵 데이터를 넣는다: 모드 맵(오일리그) → 바닐라
    local dirs = getLotDirectories()
    local nData = 0
    for i = 1, dirs:size() do
        local dir = "media/maps/" .. dirs:get(i - 1)
        local file = dir .. "/worldmap.xml"
        if fileExists(file) then
            self.mapAPI:addData(file)
            nData = nData + 1
        end
        self.mapAPI:endDirectoryData()
        self.mapAPI:addImages(dir)
    end
    self.mapAPI:setBoundsFromWorld()
    MapUtils.initDefaultStyleV3(self)
    self.mapAPI:setBoolean("Isometric", true)
    self.mapAPI:setBoolean("HideUnvisited", false)
    self.mapAPI:setBoolean("Players", false)
    self.mapAPI:setBoolean("RemotePlayers", false)
    self.mapAPI:setBoolean("PlayerNames", false)
    self.mapAPI:setBoolean("Symbols", false)
    self.mapAPI:setBoolean("MiniMapSymbols", false)
    self.mapAPI:setBoolean("WorldBounds", false)
    self.mapAPI:setZoom(HaloDrop.opt("SkyZoom"))
    log(string.format("sky: map ready data=%d zoom=%.1f iso=true", nData, HaloDrop.opt("SkyZoom")))
end

function SkyMap:prerender()
    if S.cx and S.cy then
        self.mapAPI:centerOn(S.cx, S.cy)
    end
end

-- ── 기체 씬 ───────────────────────────────────────────────────────────────────
local SkyScene = ISUIElement:derive("HaloDropSkyScene")

function SkyScene:new()
    local sw, sh = screenSize()
    local w = math.floor(math.min(sw, sh) * K.SCENE_FRAC)
    local o = ISUIElement:new(math.floor((sw - w) / 2), math.floor((sh - w) / 2 + sh * K.SCENE_DY), w, w)
    setmetatable(o, self)
    self.__index = self
    return o
end

function SkyScene:createChildren()
    local sc = ISUI3DScene:new(0, 0, self.width, self.height)
    sc.background = false
    sc:initialise()
    sc:instantiate()
    sc.onMouseDown = function() return true end
    sc.onMouseUp = function() return true end
    sc.onMouseMove = function() return true end
    sc.onRightMouseDown = function() return true end
    sc.onRightMouseUp = function() return true end
    sc.onMouseWheel = function() return true end
    self:addChild(sc)
    local j = sc.javaObject
    local ok, err = pcall(function()
        j:fromLua1("setDrawGrid", false)
        j:fromLua1("setDrawGridAxes", false)
        j:fromLua1("setGizmoVisible", "none")
        j:fromLua1("setMaxZoom", 20)
        j:fromLua1("createVehicle", "plane")
        j:fromLua2("setVehicleScript", "plane", HaloDrop.PLANE_SCRIPT)
        sc:setView("UserDefined")
    end)
    if not ok then log("sky: scene setup FAILED err=" .. tostring(err)) end
    self.scene = sc
    self.tuneSet = nil
    self:applyTune()
end

-- zoom / 객체 크기 / 각도. 값이 바뀌었을 때만 자바로 보낸다
function SkyScene:applyTune()
    if not self.scene then return end
    local j = self.scene.javaObject
    local sig = string.format("%d|%.4f|%d|%d|%d", T.zoom, T.scale, T.tilt, T.yaw0, math.floor((S.yaw or 0) + 0.5))
    if sig == self.tuneSet then return end
    self.tuneSet = sig
    local ok, err = pcall(function()
        j:fromLua1("setZoom", T.zoom)
        j:fromLua1("getObjectScale", "plane"):set(T.scale)
        j:fromLua3("setViewRotation", T.tilt, T.yaw0 + (S.yaw or 0), 0)
    end)
    if not ok then log("sky: scene tune FAILED err=" .. tostring(err)) end
end

function SkyScene:prerender()
    if S.yaw == nil then return end
    self:applyTune()
end

-- ── 루트 (UIManager 에 들어가는 유일한 요소, 맨 뒤) ──────────────────────────────────
local SkyRoot = ISUIElement:derive("HaloDropSkyRoot")

function SkyRoot:new()
    local w, h = screenSize()
    local o = ISUIElement:new(0, 0, w, h)
    setmetatable(o, self)
    self.__index = self
    return o
end

function SkyRoot:prerender()
    -- 열어 둔 사이 바닐라 ISWorldMap 이 닫히면서 setDrawWorld(true) 를 부를 수 있어 매 프레임 다시 끈다
    if S.open then pcall(function() getWorld():setDrawWorld(false) end) end
end

-- 자식(지도·기체)을 다 그린 뒤에 불린다 -> 구름 덮개는 기체까지 덮는다
function SkyRoot:render()
    if S.cover > 0.002 then
        self:drawRect(0, 0, self.width, self.height, 0.92 * S.cover, 0.86, 0.88, 0.92)
    end
end

-- 마우스가 지도를 끌거나 줌하지 못하게 전부 먹는다 (자식 요소도 같은 핸들러)
local function eatMouse(cls)
    cls.onMouseDown = function() return true end
    cls.onMouseUp = function() return true end
    cls.onMouseMove = function() return true end
    cls.onRightMouseDown = function() return true end
    cls.onRightMouseUp = function() return true end
    cls.onMouseWheel = function() return true end
end
eatMouse(SkyRoot)
eatMouse(SkyTiles)
eatMouse(SkyMap)
eatMouse(SkyScene)

-- ── 공개 API ──────────────────────────────────────────────────────────────────
function HaloDropSky.isOpen() return S.open end

local function tuneLine()
    return string.format("sky tune: zoom=%d scale=%.4f tilt=%d yaw0=%d", T.zoom, T.scale, T.tilt, T.yaw0)
end

function HaloDropSky.open()
    if S.open then return end
    if not HaloDrop.opt("SkyView") then
        log("sky: disabled by sandbox SkyView")
        return
    end
    S.open = true
    S.cover, S.coverTarget = 0, 0
    S.cx, S.cy, S.yaw = nil, nil, nil
    T.zoom, T.scale, T.tilt, T.yaw0 = K.SCENE_ZOOM, K.SCENE_SCALE, K.TILT, K.YAW0
    local ok, err = pcall(function()
        getWorld():setDrawWorld(false)
        S.root = SkyRoot:new()
        S.root:initialise()
        S.root:instantiate()
        if HaloDropMap.hasTiles() then
            S.map = SkyTiles:new()
            S.mode = "tiles"
        else
            S.map = SkyMap:new()
            S.mode = "vector"
        end
        S.map:initialise()
        S.map:instantiate()
        S.root:addChild(S.map)
        S.scene = SkyScene:new()
        S.scene:initialise()
        S.scene:instantiate()
        S.root:addChild(S.scene)
        S.root:backMost()
        S.root:addToUIManager()
        S.root:setVisible(true)
    end)
    if not ok then
        log("sky: open FAILED err=" .. tostring(err))
        HaloDropSky.close("open failed")
        return
    end
    log("sky: opened (world drawing off, map=" .. tostring(S.mode) .. ", backmost) " .. tuneLine())
end

function HaloDropSky.close(reason)
    if not S.open and not S.root then return end
    S.open = false
    if S.root then
        pcall(function() S.root:setVisible(false) end)
        pcall(function() S.root:removeFromUIManager() end)
    end
    S.root, S.map, S.scene = nil, nil, nil
    local wm = ISWorldMap_instance
    local mapOpen = false
    pcall(function() mapOpen = wm ~= nil and wm:isVisible() == true end)
    if not mapOpen then pcall(function() getWorld():setDrawWorld(true) end) end
    log("sky: closed (" .. tostring(reason) .. ", world drawing " .. (mapOpen and "left to world map" or "on") .. ") " .. tuneLine())
end

-- 매 틱: 경로 위치·기수. x,y = 경로 위치(타일), headingDeg = 진행 방향(월드 +x = 0, +y = 90)
function HaloDropSky.update(x, y, headingDeg, dt)
    if not S.open then return end
    -- 앞쪽을 더 보이게 중심을 진행 방향으로 조금 당긴다
    local r = math.rad(headingDeg)
    S.cx = x + math.cos(r) * K.LEAD
    S.cy = y + math.sin(r) * K.LEAD
    -- 기체 view yaw = 315 + 차량 yaw. 인게임 아이소 카메라는 viewRotation (30, 315, 0)(b42.21 TileGeometryUtils :20)이고
    -- UI3DScene.calcMatrices(:2655) 는 rotateXYZ(view) 뒤에 객체 변환을 곱하므로 월드에서 yaw φ 로 setAngles 한 차량의
    -- 모습 = 객체 0 + view yaw (315 + φ). 차량 yaw = HaloDropFlight.yaw = atan2(dx, dy) = 90 - headingDeg.
    -- (런 5 까지의 화면투영각 식은 근거가 없었고 기수가 진행 방향과 안 맞았다)
    S.yaw = 315 + (90 - headingDeg)
    S.yaw = S.yaw - math.floor(S.yaw / 360) * 360
    -- 밤이면 타일을 어둡게 (바닐라 낮 밝기 0~1 을 TINT_NIGHT~1 로)
    local okD, day = pcall(function() return getClimateManager():getDayLightStrength() end)
    if okD and type(day) == "number" then
        S.tint = K.TINT_NIGHT + (1 - K.TINT_NIGHT) * math.max(0, math.min(1, day))
    end
    -- 구름 덮개 서서히
    local k = (dt or 0) * K.COVER_RATE
    if k > 1 then k = 1 end
    S.cover = S.cover + (S.coverTarget - S.cover) * k
end

function HaloDropSky.setCover(v)
    S.coverTarget = v
end

function HaloDropSky.setZoom(z)
    if S.map and S.map.mapAPI then pcall(function() S.map.mapAPI:setZoom(z) end) end
end

-- ── 조정 키 (하늘 뷰 열린 동안만) ───────────────────────────────────────────────
local function tuneKey(key)
    if not S.open then return end
    local KB = Keyboard
    local changed = true
    if key == KB.KEY_LBRACKET then T.yaw0 = T.yaw0 - 5
    elseif key == KB.KEY_RBRACKET then T.yaw0 = T.yaw0 + 5
    elseif key == KB.KEY_SEMICOLON then T.scale = T.scale * 0.8
    elseif key == KB.KEY_APOSTROPHE then T.scale = T.scale * 1.25
    elseif key == KB.KEY_COMMA then T.tilt = T.tilt - 5
    elseif key == KB.KEY_PERIOD then T.tilt = T.tilt + 5
    elseif key == KB.KEY_PRIOR then T.zoom = math.min(20, T.zoom + 1)
    elseif key == KB.KEY_NEXT then T.zoom = math.max(1, T.zoom - 1)
    else changed = false end
    if changed then log(tuneLine()) end
end
Events.OnKeyPressed.Add(function(key)
    local ok, err = pcall(tuneKey, key)
    if not ok then log("sky tune key FAILED err=" .. tostring(err)) end
end)

-- 라운드가 끝나거나 죽으면 반드시 월드로 돌아오게
Events.OnPlayerDeath.Add(function(p)
    if p == getPlayer() and S.open then HaloDropSky.close("death") end
end)
