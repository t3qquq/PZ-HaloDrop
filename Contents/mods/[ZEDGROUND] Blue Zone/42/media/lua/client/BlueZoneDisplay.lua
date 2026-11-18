-- Blue Zone 표시 (클라): 아이소 땅 위 원 둘레 선 / 월드맵·미니맵 원 / 자기장 밖 화면 틴트
--
-- 바닐라 API 만 쓴다 (선행 모드 없음).
-- 시점별
--   아이소(바닐라 쿼터뷰): 플레이어 근처 원호를 isoToScreenX/Y 로 투영해 선으로 그린다
--   Viewpoint 1·3인칭  : isoToScreenX/Y 가 아이소 값을 돌려줘 선이 엉뚱한 곳에 뜨므로 그리지 않는다
--                        (실제 벽은 자바 애드온 담당, 2단계)
--   지도·미니맵·틴트는 UI 라 시점과 무관하게 그린다
-- 원 데이터는 BlueZoneClient.lua 의 BlueZone.currentBlue() / BlueZone.C (흰 원 wx, wy, wr) 에서 읽는다.

if isServer() then return end

require "BlueZoneConfig"
require "BlueZoneClient"
require "ISUI/Maps/ISWorldMap"
require "ISUI/Maps/ISMiniMap"

local B = BlueZone

local D = {
    BLUE  = { r = 0.25, g = 0.50, b = 1.00, a = 0.95 },
    WHITE = { r = 1.00, g = 1.00, b = 1.00, a = 0.95 },
    -- 아이소 땅 위 선
    WORLD_SHOW_RANGE = 120,   -- 경계에서 이 거리(타일) 안에 있을 때만 그린다
    WORLD_ARC_HALF   = 140,   -- 플레이어 쪽 원호 반쪽 길이(타일)
    WORLD_SEG_LEN    = 3,     -- 선분 하나 길이(타일). 짧을수록 원에 가깝다
    WORLD_THICK      = 3,
    -- 지도
    MAP_SEGMENTS = 128,
    MAP_THICK    = 2,
    -- 틴트: 경계 밖 깊이(타일)에 비례해 MIN_A ~ MAX_A
    TINT = { r = 0.10, g = 0.25, b = 0.85 },
    TINT_MIN_A = 0.12,
    TINT_MAX_A = 0.40,
    TINT_DEPTH = 60,
    VP_CACHE_MS = 250,        -- Viewpoint 시점 판정 캐시 (자바 호출)
}
B.DISPLAY = D

local function log(msg) B.log(msg) end

-- ── 시점 판정 ────────────────────────────────────────────
-- Viewpoint.View.next() 는 "다음 시점 이름": "first" 면 지금 아이소다. 전역이 없으면 아이소.
local _vpAt, _vpOn, _vpLogged = 0, false, nil
local function viewpointActive()
    local now = getTimestampMs()
    if now - _vpAt < D.VP_CACHE_MS then return _vpOn end
    _vpAt = now
    local on = false
    if Viewpoint and Viewpoint.View and Viewpoint.View.next then
        local ok, nxt = pcall(Viewpoint.View.next)
        on = ok and nxt ~= nil and tostring(nxt) ~= "first"
    end
    if on ~= _vpLogged then
        _vpLogged = on
        log("display: viewpoint " .. (on and "active -> world line hidden" or "inactive -> iso world line"))
    end
    _vpOn = on
    return on
end
B.viewpointActive = viewpointActive

-- ── 아이소 땅 위 원호 ─────────────────────────────────────
local function drawWorldArc(playerNum, p, cx, cy, r)
    if r < 1 then return end
    local px, py = p:getX(), p:getY()
    local dx, dy = px - cx, py - cy
    local dist = math.sqrt(dx * dx + dy * dy)
    if math.abs(dist - r) > D.WORLD_SHOW_RANGE then return end
    local z = math.floor(p:getZ())
    local phi = math.atan2(dy, dx)
    local span = D.WORLD_ARC_HALF / r
    if span > math.pi then span = math.pi end
    local steps = math.ceil(2 * span * r / D.WORLD_SEG_LEN)
    if steps < 8 then steps = 8 elseif steps > 200 then steps = 200 end
    local c = D.BLUE
    local renderer = getRenderer()
    local a0 = phi - span
    local da = 2 * span / steps
    local sx1 = isoToScreenX(playerNum, cx + r * math.cos(a0), cy + r * math.sin(a0), z)
    local sy1 = isoToScreenY(playerNum, cx + r * math.cos(a0), cy + r * math.sin(a0), z)
    for i = 1, steps do
        local a = a0 + da * i
        local wx, wy = cx + r * math.cos(a), cy + r * math.sin(a)
        local sx2 = isoToScreenX(playerNum, wx, wy, z)
        local sy2 = isoToScreenY(playerNum, wx, wy, z)
        renderer:renderline(nil, math.floor(sx1), math.floor(sy1), math.floor(sx2), math.floor(sy2),
            c.r, c.g, c.b, c.a, D.WORLD_THICK)
        sx1, sy1 = sx2, sy2
    end
end

-- ── 화면 틴트 ────────────────────────────────────────────
local _wasOutside = false
local function drawTint(p, cx, cy, r)
    local x, y = p:getX(), p:getY()
    local outside = not B.inExempt(x, y) and B.isOutside(x, y, cx, cy, r)
    if outside ~= _wasOutside then
        _wasOutside = outside
        log(string.format("display: player %s zone at (%.0f,%.0f) blue=(%.0f,%.0f r%.0f)",
            outside and "left" or "entered", x, y, cx, cy, r))
    end
    if not outside then return end
    local dx, dy = x - cx, y - cy
    local depth = math.sqrt(dx * dx + dy * dy) - r
    local k = depth / D.TINT_DEPTH
    if k > 1 then k = 1 end
    local a = D.TINT_MIN_A + (D.TINT_MAX_A - D.TINT_MIN_A) * k
    local t = D.TINT
    getRenderer():renderi(nil, 0, 0, getCore():getScreenWidth(), getCore():getScreenHeight(), t.r, t.g, t.b, a, nil)
end

local function onPreUIDraw()
    if not B.C then return end
    local p = getSpecificPlayer(0)
    if not p or p:isDead() then return end
    local cx, cy, r = B.currentBlue()
    if not cx then return end
    if not viewpointActive() then
        drawWorldArc(0, p, cx, cy, r)
    end
    drawTint(p, cx, cy, r)
end
Events.OnPreUIDraw.Add(onPreUIDraw)

-- ── 지도·미니맵 원 ────────────────────────────────────────
-- ui: ISUIElement (선 좌표는 그 요소 기준), mapAPI: UIWorldMapV1 (worldToUIX/Y 가 요소 기준 좌표를 돌려준다)
local function drawMapCircle(ui, mapAPI, cx, cy, r, c)
    if r <= 0 or not ui.javaObject then return end
    local n = D.MAP_SEGMENTS
    local da = 2 * math.pi / n
    local x1 = mapAPI:worldToUIX(cx + r, cy)
    local y1 = mapAPI:worldToUIY(cx + r, cy)
    for i = 1, n do
        local a = da * i
        local wx, wy = cx + r * math.cos(a), cy + r * math.sin(a)
        local x2 = mapAPI:worldToUIX(wx, wy)
        local y2 = mapAPI:worldToUIY(wx, wy)
        ui.javaObject:DrawLine(nil, x1, y1, x2, y2, D.MAP_THICK, c.r, c.g, c.b, c.a)
        x1, y1 = x2, y2
    end
end

local function drawMapCircles(ui)
    local C = B.C
    if not C or not ui.mapAPI then return end
    local cx, cy, r = B.currentBlue()
    if not cx then return end
    if C.wr >= 0 then drawMapCircle(ui, ui.mapAPI, C.wx, C.wy, C.wr, D.WHITE) end
    drawMapCircle(ui, ui.mapAPI, cx, cy, r, D.BLUE)
end

local _origWorldMapRender = ISWorldMap.render
function ISWorldMap:render()
    _origWorldMapRender(self)
    drawMapCircles(self)
end

-- 미니맵 안쪽은 render 를 따로 정의하지 않아 ISUIElement.render 를 물려받는다. 테두리 밖으로 안 나가게 스텐실로 자른다
local _origMiniInnerRender = ISMiniMapInner.render
function ISMiniMapInner:render()
    _origMiniInnerRender(self)
    if not B.C then return end
    self:setStencilRect(0, 0, self:getWidth(), self:getHeight())
    drawMapCircles(self)
    self:clearStencilRect()
end

log("display: loaded (world line in iso only, map/minimap circles, outside tint)")
