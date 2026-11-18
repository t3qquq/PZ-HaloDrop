-- ZEDGROUND HUD : shared config
-- 표시 전용 모드. 다른 ZEDGROUND 모드를 require 하지 않는다.
-- Round Manager / Blue Zone 은 전역 테이블이 있을 때만 읽는다 (ZedHUD.source*).

ZedHUD = ZedHUD or {}
ZedHUD.MODULE = "ZedHUD"

-- 상단 나침반 (배그 방식: 8방위 글자 + 15도 숫자 + 5도 눈금, 가운데 현재 방위)
ZedHUD.COMPASS = {
    width       = 480,   -- px
    height      = 40,    -- px
    top         = 12,    -- 화면 위에서 px
    spanDeg     = 150,   -- 바에 보이는 각도 범위
    tickDeg     = 5,     -- 작은 눈금 간격
    labelDeg    = 15,    -- 숫자 간격
    hideNearDeg = 8,     -- 가운데 현재 방위 숫자와 겹치는 라벨 숨김 범위
}

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

-- 캐릭터 정면 방위 (0 = 북, 시계방향). 월드 좌표는 x = 동, y = 남.
function ZedHUD.headingOf(p)
    if not p then return 0 end
    local fx = p:getForwardDirectionX()
    local fy = p:getForwardDirectionY()
    return ZedHUD.norm(math.deg(math.atan2(fx, -fy)))
end

function ZedHUD.log(msg)
    print("[ZedHUD] " .. tostring(msg))
end
