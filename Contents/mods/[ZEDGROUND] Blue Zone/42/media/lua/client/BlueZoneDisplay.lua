-- Blue Zone 표시 (클라): 아이소 땅 위 원 둘레 선 / 월드맵·미니맵 원 + 파란 원 바깥 채우기 / 자기장 밖 화면 틴트
--
-- 바닐라 API 만 쓴다 (선행 모드 없음).
-- 시점별
--   아이소(바닐라 쿼터뷰): 플레이어 근처 원호를 isoToScreenX/Y 로 투영해 선으로 그린다
--   Viewpoint 1·3인칭  : isoToScreenX/Y 가 아이소 값을 돌려줘 선이 엉뚱한 곳에 뜨므로 그리지 않는다
--                        (실제 벽은 클라 자바 src/t3bluezone 담당. 카메라 yaw 를 BlueZone.VP 로 넘겨준다)
--   지도·미니맵·틴트는 UI 라 시점과 무관하게 그린다
-- 원 데이터는 BlueZoneClient.lua 의 BlueZone.currentBlue() / BlueZone.C (흰 원 wx, wy, wr) 에서 읽는다.

if isServer() then return end

require "BlueZoneConfig"
require "BlueZoneClient"
require "ISUI/Maps/ISWorldMap"
require "ISUI/Maps/ISMiniMap"

local B = BlueZone

local D = {
    WHITE = { r = 1.00, g = 1.00, b = 1.00, a = 0.95 },
    -- 아이소 땅 위 선
    WORLD_SHOW_RANGE = 120,   -- 경계에서 이 거리(타일) 안에 있을 때만 그린다
    WORLD_ARC_HALF   = 140,   -- 플레이어 쪽 원호 반쪽 길이(타일)
    WORLD_SEG_LEN    = 3,     -- 선분 하나 길이(타일). 짧을수록 원에 가깝다
    WORLD_THICK      = 3,
    -- 지도
    MAP_SEGMENTS = 128,
    MAP_THICK    = 2,
    -- 지도·미니맵에서 파란 원 바깥 전체를 덮는다 (배그 지도처럼 원 밖을 통째로 칠한다). 색은 BlueZone.style().fill
    MAP_FILL_SEGMENTS = 128,
    -- 틴트: 경계 밖 깊이(타일)에 비례해 MIN_A ~ MAX_A. 색은 BlueZone.style().tint
    TINT_MIN_A = 0.12,
    TINT_MAX_A = 0.40,
    TINT_DEPTH = 60,
    VP_CACHE_MS = 250,        -- Viewpoint 시점 판정 캐시 (자바 호출)
}
B.DISPLAY = D

local function log(msg) B.log(msg) end

-- 파란 원·채우기·틴트 색은 연출 방식(샌드박스 BlueZone.Style)에서 온다: BlueZone.STYLES (BlueZoneConfig.lua)
local _styleLogged = nil
local function style()
    local s = B.style()
    if s.name ~= _styleLogged then
        _styleLogged = s.name
        log("display: style " .. tostring(B.opt("Style")) .. " (" .. s.name .. ")")
    end
    return s
end

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

-- Viewpoint 카메라 방향을 자바 벽(src/t3bluezone/BlueZoneWall)에 넘긴다. 자바는 이 값으로 월드 좌표 -> Viewpoint 렌더 좌표의
-- 축 대응(부호·x/y 바뀜)을 검증한다 (11-19 런: 축을 못 맞춰 벽이 한 번도 안 그려졌다).
-- B.VP 는 한 번 만들고 필드만 갱신한다. yaw = Viewpoint.Addons.viewState().eye.yaw (월드 atan2(dy, dx) 기준 도), at = 읽은 시각(ms)
B.VP = B.VP or { at = 0 }
local _camLogged = nil
local function publishCamera()
    local ok, st = pcall(function()
        if Viewpoint and Viewpoint.Addons and Viewpoint.Addons.viewState then return Viewpoint.Addons.viewState() end
        return nil
    end)
    local yaw = nil
    if ok and st and st.on and st.eye then yaw = st.eye.yaw end
    local state = (not ok) and ("FAILED " .. tostring(st)) or (yaw ~= nil and "ok" or "no view state")
    if state ~= _camLogged then
        _camLogged = state
        log("display: camera yaw for the viewpoint wall -> " .. state .. (yaw ~= nil and string.format(" (yaw=%.1f)", yaw) or ""))
    end
    if yaw == nil then return end
    B.VP.yaw = yaw
    B.VP.at = getTimestampMs()
end

-- ── 아이소 땅 위 원호 ─────────────────────────────────────
local function drawWorldArc(playerNum, p, cx, cy, r, c)
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
    local t = style().tint
    getRenderer():renderi(nil, 0, 0, getCore():getScreenWidth(), getCore():getScreenHeight(), t.r, t.g, t.b, a, nil)
end

local function onPreUIDraw()
    local C = B.C
    if not C then return end
    local p = getSpecificPlayer(0)
    if not p or p:isDead() then return end
    local cx, cy, r = B.currentBlue()
    if not viewpointActive() then
        if C.wr >= 0 then drawWorldArc(0, p, C.wx, C.wy, C.wr, D.WHITE) end
        if cx then drawWorldArc(0, p, cx, cy, r, style().line) end
    elseif cx then
        publishCamera()   -- 벽을 그리는 동안만 (파란 원 활성 + Viewpoint 시점)
    end
    if cx then drawTint(p, cx, cy, r) end
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

-- 파란 원 바깥 채우기: 원 둘레에서 바깥 반지름까지 사각형을 고리 모양으로 이어 붙인다.
-- 바깥 반지름은 지도 요소 네 모서리 중 원 중심에서 가장 먼 곳보다 크게 잡아, 지금 보이는 범위에서 원 밖은 전부 덮인다.
-- 보이는 범위 전체가 원 안이면(시작 직후의 큰 원 등) 아무것도 그리지 않는다.
-- drawPolygon 은 바닐라 ISWorldMap 이 텍스처 nil 로 쓰는 것과 같은 호출 (UIElement.DrawPolygon -> SpriteRenderer.renderPoly)
local _fillLogged = {}
local function drawMapOutside(ui, mapAPI, cx, cy, r, c, tag)
    if r <= 0 or not ui.javaObject then return end
    local w, h = ui:getWidth(), ui:getHeight()
    local far = 0
    for i = 0, 3 do
        local ux = (i == 1 or i == 2) and w or 0
        local uy = (i >= 2) and h or 0
        local dx = mapAPI:uiToWorldX(ux, uy) - cx
        local dy = mapAPI:uiToWorldY(ux, uy) - cy
        local d = math.sqrt(dx * dx + dy * dy)
        if d > far then far = d end
    end
    if far <= r then return end
    local n = D.MAP_FILL_SEGMENTS
    local da = 2 * math.pi / n
    local outer = far * 1.05 / math.cos(da / 2)   -- 바깥 고리의 현이 far 안쪽으로 파고들지 않게
    local ix1, iy1 = mapAPI:worldToUIX(cx + r, cy), mapAPI:worldToUIY(cx + r, cy)
    local ox1, oy1 = mapAPI:worldToUIX(cx + outer, cy), mapAPI:worldToUIY(cx + outer, cy)
    for i = 1, n do
        local a = da * i
        local ca, sa = math.cos(a), math.sin(a)
        local ix2, iy2 = mapAPI:worldToUIX(cx + r * ca, cy + r * sa), mapAPI:worldToUIY(cx + r * ca, cy + r * sa)
        local ox2, oy2 = mapAPI:worldToUIX(cx + outer * ca, cy + outer * sa), mapAPI:worldToUIY(cx + outer * ca, cy + outer * sa)
        ui:drawPolygon(nil, ix1, iy1, ix2, iy2, ox2, oy2, ox1, oy1, c.r, c.g, c.b, c.a)
        ix1, iy1, ox1, oy1 = ix2, iy2, ox2, oy2
    end
    if not _fillLogged[tag] then
        _fillLogged[tag] = true
        log(string.format("display: %s outside fill first drawn (ui=%.0fx%.0f blue r%.0f, filled out to r%.0f)", tag, w, h, r, outer))
    end
end

local function drawMapCircles(ui, tag)
    local C = B.C
    if not C or not ui.mapAPI then return end
    local cx, cy, r = B.currentBlue()
    if cx then drawMapOutside(ui, ui.mapAPI, cx, cy, r, style().fill, tag) end
    if C.wr >= 0 then drawMapCircle(ui, ui.mapAPI, C.wx, C.wy, C.wr, D.WHITE) end
    if cx then drawMapCircle(ui, ui.mapAPI, cx, cy, r, style().line) end
end

local _origWorldMapRender = ISWorldMap.render
function ISWorldMap:render()
    _origWorldMapRender(self)
    drawMapCircles(self, "world map")
end

-- 미니맵 안쪽은 render 를 따로 정의하지 않아 ISUIElement.render 를 물려받는다. 테두리 밖으로 안 나가게 스텐실로 자른다
local _origMiniInnerRender = ISMiniMapInner.render
function ISMiniMapInner:render()
    _origMiniInnerRender(self)
    if not B.C then return end
    self:setStencilRect(0, 0, self:getWidth(), self:getHeight())
    drawMapCircles(self, "minimap")
    self:clearStencilRect()
end

log("display: loaded (white+blue world line in iso only, map/minimap circles + blue fill outside the blue circle, outside tint; start blue covers the whole area)")
