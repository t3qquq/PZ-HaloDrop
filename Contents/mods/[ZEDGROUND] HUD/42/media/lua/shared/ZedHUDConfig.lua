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
    top         = 8,     -- 화면 위에서 px
    spanDeg     = 180,   -- 바에 보이는 각도 범위
    tickDeg     = 5,     -- 작은 눈금 간격
    labelDeg    = 15,    -- 숫자 간격
    fadeFrac    = 0.15,  -- 양 끝 이 비율만큼 글자가 흐려진다
}

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
