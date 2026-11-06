-- Halo Drop 하늘 뷰 (클라): 탑승~점프 대기 동안 월드 대신 지도 위의 수송기를 보여준다
--
-- 왜: 48 타일/초 비행은 클라 청크 스트리밍이 못 따라와 월드가 검게 나온다(11-06 런 3). 비행 구간은
--   서버 Flight(경로·시각)로 위치만 계산하고 화면은 UI 로 그린다 (Wingsmith 하늘 뷰와 같은 구조,
--   claude/Wingsmith_하늘뷰_분석.md).
-- 구조
--   getWorld():setDrawWorld(false)  월드 렌더를 끈다 (바닐라 ISWorldMap 이 지도를 열 때 쓰는 API).
--   SkyTiles 전체화면 ISUIElement 에 pzmap2dzi 아이소 렌더 타일(HaloDropMap.levels)을 직접 깐다 (Wingsmith 식).
--            화면 배율 = 샌드박스 SkyScale(px/칸). 타일이 없으면(HaloDropTiles.lua 부재) 아래 SkyMap 으로 대체.
--   SkyMap   전체화면 ISUIElement + UIWorldMap(바닐라 월드맵 벡터 렌더러, 아이소메트릭). 타일 없을 때의 폴백.
--   SkyScene 전체화면 ISUIElement + ISUI3DScene 에 수송기 차량 스크립트 모델. 화면 가운데 고정, 기수만 돌림.
--            구름 덮개(점프 대기 중)·HUD 는 HaloDropHUD 가 OnPreUIDraw 로 그린다.
-- 호출: HaloDropJumper 가 board() 에서 open, 자유낙하 시작 때 close. 점프 대기(JUMPING) 중엔 setCover(1).
-- 시점: Viewpoint(1·3인칭) 여부와 무관하게 UI 로 그린다. Viewpoint 가 켜져 있을 때의 동작은 T-VP2 로 확인.

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

-- ── 타일 레이어 (Wingsmith 식 직접 그리기) ──────────────────────────────────────
local SkyTiles = ISUIElement:derive("HaloDropSkyTiles")

function SkyTiles:new()
    local core = getCore()
    local o = ISUIElement:new(0, 0, core:getScreenWidth(), core:getScreenHeight())
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
    if S.open then pcall(function() getWorld():setDrawWorld(false) end) end
    self.loads = 0
    local scale = HaloDrop.opt("SkyScale")
    local L = HaloDropMap.levelFor(scale)
    if not L or not S.cx then
        self:drawRect(0, 0, self.width, self.height, 1, HaloDropMap.BG.r, HaloDropMap.BG.g, HaloDropMap.BG.b)
        return
    end
    local k = scale / L.px                     -- 타일 px -> 화면 px
    local size = HaloDropMap.TILE * k
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

function SkyTiles:render()
    if S.cover > 0.002 then
        self:drawRect(0, 0, self.width, self.height, 0.92 * S.cover, 0.86, 0.88, 0.92)
    end
end

function SkyTiles:onMouseDown() return true end
function SkyTiles:onMouseUp() return true end
function SkyTiles:onMouseMove() return true end
function SkyTiles:onRightMouseDown() return true end
function SkyTiles:onRightMouseUp() return true end
function SkyTiles:onMouseWheel() return true end

-- ── 지도 레이어 (벡터 폴백) ───────────────────────────────────────────────────────────────
local SkyMap = ISUIElement:derive("HaloDropSkyMap")

function SkyMap:new()
    local core = getCore()
    local o = ISUIElement:new(0, 0, core:getScreenWidth(), core:getScreenHeight())
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
    -- 사진 타일: 모드 동봉 media/maps/HaloDropSky/pyramid.zip (없으면 벡터 지도만)
    local okImg, errImg = pcall(function() self.mapAPI:addImages("media/maps/HaloDropSky") end)
    if not okImg then log("sky: addImages(HaloDropSky) FAILED err=" .. tostring(errImg)) end
    self.mapAPI:setBoundsFromWorld()
    MapUtils.initDefaultStyleV3(self)
    local styleAPI = self.mapAPI:getStyleAPI()
    local okL, errL = pcall(function()
        local layer = styleAPI:newPyramidLayer("halodrop-sky")
        layer:setPyramidFileName("pyramid.zip")
        layer:addFill(0.0, 255, 255, 255, 255)
        -- 지명 텍스트 레이어 아래, 벡터 레이어 위에 둔다
        local idx = styleAPI:indexOfLayer("halodrop-sky")
        local textAt = nil
        for i = 0, styleAPI:getLayerCount() - 1 do
            if styleAPI:getLayerByIndex(i):getTypeString() == "Text" then textAt = i break end
        end
        if textAt then styleAPI:moveLayer(idx, textAt) end
    end)
    if not okL then log("sky: pyramid layer FAILED err=" .. tostring(errL)) end
    self.mapAPI:setBoolean("Isometric", true)
    self.mapAPI:setBoolean("HideUnvisited", false)
    self.mapAPI:setBoolean("Players", false)
    self.mapAPI:setBoolean("RemotePlayers", false)
    self.mapAPI:setBoolean("PlayerNames", false)
    self.mapAPI:setBoolean("Symbols", false)
    self.mapAPI:setBoolean("MiniMapSymbols", false)
    self.mapAPI:setBoolean("ImagePyramid", true)
    self.mapAPI:setBoolean("WorldBounds", false)
    self.mapAPI:setZoom(HaloDrop.opt("SkyZoom"))
    log(string.format("sky: map ready data=%d zoom=%.1f iso=true", nData, HaloDrop.opt("SkyZoom")))
end

function SkyMap:prerender()
    -- 지도를 열어 둔 사이 바닐라 ISWorldMap 이 닫히면서 setDrawWorld(true) 를 부를 수 있어 매 프레임 다시 끈다
    if S.open then pcall(function() getWorld():setDrawWorld(false) end) end
    if S.cx and S.cy then
        self.mapAPI:centerOn(S.cx, S.cy)
    end
end

function SkyMap:render()
    -- 구름 덮개 (점프 대기 중 1 로 올라감). 월드맵 위, 기체 씬 아래
    if S.cover > 0.002 then
        self:drawRect(0, 0, self.width, self.height, 0.92 * S.cover, 0.86, 0.88, 0.92)
    end
end

-- 마우스가 지도를 끌거나 줌하지 못하게 전부 먹는다
function SkyMap:onMouseDown() return true end
function SkyMap:onMouseUp() return true end
function SkyMap:onMouseMove() return true end
function SkyMap:onRightMouseDown() return true end
function SkyMap:onRightMouseUp() return true end
function SkyMap:onMouseWheel() return true end

-- ── 기체 씬 ───────────────────────────────────────────────────────────────────
local SkyScene = ISUIElement:derive("HaloDropSkyScene")

function SkyScene:new()
    local core = getCore()
    local w = math.floor(math.min(core:getScreenWidth(), core:getScreenHeight()) * K.SCENE_FRAC)
    local o = ISUIElement:new(math.floor((core:getScreenWidth() - w) / 2), math.floor((core:getScreenHeight() - w) / 2 + core:getScreenHeight() * K.SCENE_DY), w, w)
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
        j:fromLua1("setZoom", K.SCENE_ZOOM)
    end)
    if not ok then log("sky: scene setup FAILED err=" .. tostring(err)) end
    self.scene = sc
    self.yawSet = nil
end

function SkyScene:prerender()
    if not self.scene or S.yaw == nil then return end
    local yaw = math.floor(S.yaw + 0.5)
    if yaw ~= self.yawSet then
        self.yawSet = yaw
        local j = self.scene.javaObject
        pcall(function() j:fromLua3("setViewRotation", K.TILT, K.YAW0 + yaw, 0) end)
    end
end

function SkyScene:onMouseDown() return true end
function SkyScene:onMouseUp() return true end
function SkyScene:onMouseMove() return true end
function SkyScene:onMouseWheel() return true end

-- ── 공개 API ──────────────────────────────────────────────────────────────────
function HaloDropSky.isOpen() return S.open end

function HaloDropSky.open()
    if S.open then return end
    if not HaloDrop.opt("SkyView") then
        log("sky: disabled by sandbox SkyView")
        return
    end
    S.open = true
    S.cover, S.coverTarget = 0, 0
    S.cx, S.cy, S.yaw = nil, nil, nil
    local ok, err = pcall(function()
        getWorld():setDrawWorld(false)
        if HaloDropMap.hasTiles() then
            S.map = SkyTiles:new()
            S.mode = "tiles"
        else
            S.map = SkyMap:new()
            S.mode = "vector"
        end
        S.map:initialise()
        S.map:instantiate()
        S.map:addToUIManager()
        S.map:setVisible(true)
        S.scene = SkyScene:new()
        S.scene:initialise()
        S.scene:instantiate()
        S.scene:addToUIManager()
        S.scene:setVisible(true)
    end)
    if not ok then
        log("sky: open FAILED err=" .. tostring(err))
        HaloDropSky.close("open failed")
        return
    end
    log("sky: opened (world drawing off, map=" .. tostring(S.mode) .. ")")
end

function HaloDropSky.close(reason)
    if not S.open and not S.map and not S.scene then return end
    S.open = false
    for _, ui in ipairs({ S.scene, S.map }) do
        if ui then
            pcall(function() ui:setVisible(false) end)
            pcall(function() ui:removeFromUIManager() end)
        end
    end
    S.map, S.scene = nil, nil
    local wm = ISWorldMap_instance
    local mapOpen = false
    pcall(function() mapOpen = wm ~= nil and wm:isVisible() == true end)
    if not mapOpen then pcall(function() getWorld():setDrawWorld(true) end) end
    log("sky: closed (" .. tostring(reason) .. ", world drawing " .. (mapOpen and "left to world map" or "on") .. ")")
end

-- 매 틱: 경로 위치·기수. x,y = 경로 위치(타일), headingDeg = 진행 방향(월드 +x = 0, +y = 90)
function HaloDropSky.update(x, y, headingDeg, dt)
    if not S.open then return end
    -- 앞쪽을 더 보이게 중심을 진행 방향으로 조금 당긴다
    local r = math.rad(headingDeg)
    S.cx = x + math.cos(r) * K.LEAD
    S.cy = y + math.sin(r) * K.LEAD
    -- 아이소 지도에서 월드 방향 (dx,dy) 의 화면 각도: 화면 x = dx - dy, 화면 y = (dx + dy)/2
    local sx, sy = math.cos(r) - math.sin(r), (math.cos(r) + math.sin(r)) / 2
    S.yaw = math.deg(math.atan2(sy, sx))
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
    if S.map then pcall(function() S.map.mapAPI:setZoom(z) end) end
end

-- 라운드가 끝나거나 죽으면 반드시 월드로 돌아오게
Events.OnPlayerDeath.Add(function(p)
    if p == getPlayer() and S.open then HaloDropSky.close("death") end
end)
