-- ZEDGROUND HUD : shared config
-- 표시 전용 모드. 다른 ZEDGROUND 모드를 require 하지 않는다.
-- Round Manager / Blue Zone 은 전역 테이블이 있을 때만 읽는다 (ZedHUD.source*).

ZedHUD = ZedHUD or {}
ZedHUD.MODULE = "ZedHUD"

-- 상단 나침반 (배그 방식: 8방위 글자 + 15도 숫자 + 5도 눈금, 가운데 위 아래로 향한 화살표)
-- 크기는 배그 PC 스크린샷(11-19) 비율: 가로 화면의 약 37%, 얇은 띠. 현재 방위 숫자는 표시하지 않는다
ZedHUD.COMPASS = {
    widthFrac   = 0.37,  -- 화면 가로 대비 바 너비
    minWidth    = 420,   -- px (작은 해상도 하한)
    height      = 30,    -- px (화살표 포함)
    arrowH      = 7,     -- 가운데 화살표 높이 px (바 위쪽에 붙는다)
    top         = 18,    -- 화면 위에서 px (11-19: 8 에서 10px 내림)
    spanDeg     = 180,   -- 바에 보이는 각도 범위
    tickDeg     = 5,     -- 작은 눈금 간격
    labelDeg    = 15,    -- 숫자 간격
    fadeFrac    = 0.15,  -- 양 끝 이 비율만큼 글자가 흐려진다
    bgAlpha     = 0.30,  -- 바 바탕 검정의 불투명도
    barGap      = 2,     -- 접힌 인벤토리·루팅 창 제목 줄 아래로 내릴 때 그 줄과의 간격 px
}

-- 봉쇄 구역(Blue Zone) 타이머 배치 (샌드박스 ZedHUD.TimerLayout, enum)
--   1 = 나침반 아래 (기본): 나침반 바로 아래 가운데 한 줄 "N차 봉쇄 구역 축소까지 m:ss"
--   2 = 배그식: 미니맵 바로 위 막대(남은 시간 + 다음 봉쇄 구역까지 거리) + 구간이 바뀔 때 화면 가운데 알림
ZedHUD.LAYOUT_COMPASS = 1
ZedHUD.LAYOUT_PUBG = 2
-- 등록된 샌드박스 옵션은 로드 후 항상 값이 있다 (fallback 불필요)
function ZedHUD.timerLayout()
    return SandboxVars.ZedHUD.TimerLayout
end

-- 1 = 나침반 아래 타이머. Blue Zone 모드가 켜져 있고 라운드 중일 때만 보인다
ZedHUD.ZONE = {
    width   = 300,   -- px
    height  = 22,    -- px
    gap     = 4,     -- 나침반 아래 간격 px
    bgAlpha = 0.30,
    wait    = { r = 1.00, g = 1.00, b = 1.00 },   -- 대기: 흰색
    shrink  = { r = 0.45, g = 0.70, b = 1.00 },   -- 축소 중: 파란색
}

-- 2 = 배그식. 미니맵 바로 위, 미니맵과 같은 폭 (미니맵이 없거나 꺼져 있으면 화면 오른쪽 아래, fallbackWidth)
--   막대: 미니맵 가로 길이 전체. 오른쪽 끝 = 다음 봉쇄 구역(흰 원) 경계, 플레이어 표시 = 남은 거리 비율,
--         파란 채움 = 이번 축소 진행률(대기 중엔 0). 거리 숫자는 표시하지 않는다 (11-19 t3)
--   막대 왼쪽 위: "N차 m:ss" (대기 흰색 / 축소 파란색), 바탕 상자 없이 그림자만
--   화면 가운데 알림: 구간이 바뀔 때 NOTICE_MS 동안 (새 봉쇄 구역 지정 / 축소 시작 / 최종 축소 완료)
ZedHUD.PUBG = {
    fallbackWidth = 200, -- px. 미니맵이 없을 때 막대 폭
    gap        = 4,    -- 미니맵 위 간격 px
    margin     = 10,   -- 미니맵이 없을 때 화면 오른쪽·아래 여백 px
    textGap    = 2,    -- 글자와 막대 사이 px
    barH       = 4,
    markOver   = 4,    -- 플레이어 표시가 막대 위아래로 튀어나오는 px
    track      = { r = 0.35, g = 0.35, b = 0.35, a = 0.90 },
    fill       = { r = 0.25, g = 0.50, b = 1.00, a = 0.95 },
    inside     = { r = 1.00, g = 1.00, b = 1.00 },   -- 흰 원 안: 흰색 표시
    outside    = { r = 1.00, g = 0.85, b = 0.30 },   -- 흰 원 밖, 파란 원 안: 노란색
    damage     = { r = 1.00, g = 0.35, b = 0.30 },   -- 파란 원 밖(데미지 중): 빨간색
    NOTICE_MS  = 5000,
    noticeY    = 0.22, -- 화면 높이 대비 알림 세로 위치
    noticeFade = 800,  -- 끝나기 전 이 ms 동안 흐려진다
}

-- 나침반 y. 바닐라 인벤토리·루팅 창은 접혀 있어도 제목 줄이 화면 맨 위에 남아 나침반(화살표)을 덮는다 (11-19 t3).
-- 창 위에 덧그리지 않고, 나침반과 가로로 겹치는 제목 줄이 있으면 그 줄 바로 아래로 내린다.
-- 창을 펼친 동안에도 같은 자리(제목 줄 아래)에 있고, 펼친 창이 나침반을 덮는 건 그대로 둔다.
function ZedHUD.compassTop(x, w)
    local c = ZedHUD.COMPASS
    local top = c.top
    local pages = { getPlayerInventory(0), getPlayerLoot(0) }
    for i = 1, 2 do
        local pg = pages[i]
        if pg and pg:isVisible() then
            local px, py = pg:getX(), pg:getY()
            local bottom = py + pg:titleBarHeight()
            if px < x + w and px + pg:getWidth() > x and py < c.top + c.height and bottom + c.barGap > top then
                top = bottom + c.barGap
            end
        end
    end
    return top
end

function ZedHUD.compassWidth()
    local c = ZedHUD.COMPASS
    local w = math.floor(getCore():getScreenWidth() * c.widthFrac)
    if w < c.minWidth then w = c.minWidth end
    return w
end

-- 45도 자리 글자 (0 = 북, 시계방향)
ZedHUD.CARDINAL = {
    [0] = "N", [45] = "NE", [90] = "E", [135] = "SE",
    [180] = "S", [225] = "SW", [270] = "W", [315] = "NW",
}

-- 0~360 정규화
function ZedHUD.norm(deg)
    deg = math.fmod(deg, 360)
    if deg < 0 then deg = deg + 360 end
    return deg
end

-- Viewpoint 1·3인칭이면 카메라가 보는 방위(도, 0 = 북, 시계방향), 아니면 nil.
-- Viewpoint.View.next() 는 "다음" 시점 이름: "first" 면 지금 아이소다 (BlueZoneDisplay 와 같은 판정).
-- Viewpoint.Addons.viewState().eye.yaw 는 월드 atan2(dy, dx) 와 같은 기준(0 = 동, 90 = 남)이다
-- (HaloDrop 11-18 런 tick 로그: crosshair d=(0.09,-0.99) 일 때 eyeYaw=-85). 방위 = yaw + 90.
-- 아래를 똑바로 볼 때도 값이 있어서 crosshair 대신 eye.yaw 를 쓴다.
local _camErrLogged = false
function ZedHUD.cameraHeading()
    if not (Viewpoint and Viewpoint.View and Viewpoint.View.next and Viewpoint.Addons and Viewpoint.Addons.viewState) then
        return nil
    end
    local ok, yaw = pcall(function()
        local nxt = Viewpoint.View.next()
        if nxt == nil or tostring(nxt) == "first" then return nil end
        local st = Viewpoint.Addons.viewState()
        if not st or not st.on or not st.eye then return nil end
        return st.eye.yaw
    end)
    if not ok then
        if not _camErrLogged then
            _camErrLogged = true
            ZedHUD.log("compass: viewpoint camera read FAILED err=" .. tostring(yaw) .. " -> character facing")
        end
        return nil
    end
    if type(yaw) ~= "number" then return nil end
    return ZedHUD.norm(yaw + 90)
end

-- 나침반 방위 (0 = 북, 시계방향). Viewpoint 시점이면 카메라, 아이소면 캐릭터 정면. 월드 좌표는 x = 동, y = 남.
-- 두 번째 값: "camera" / "body" (로그용)
function ZedHUD.headingOf(p)
    local cam = ZedHUD.cameraHeading()
    if cam then return cam, "camera" end
    if not p then return 0, "body" end
    local fx = p:getForwardDirectionX()
    local fy = p:getForwardDirectionY()
    return ZedHUD.norm(math.deg(math.atan2(fx, -fy))), "body"
end

function ZedHUD.log(msg)
    print("[ZedHUD] " .. tostring(msg))
end
