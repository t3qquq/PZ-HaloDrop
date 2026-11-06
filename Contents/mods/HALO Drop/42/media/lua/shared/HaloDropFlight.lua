-- Halo Drop 비행 경로 계산 (서버·클라 공용)
--
-- 수송기의 "진짜 위치"는 차량이 아니라 이 경로식이다. 서버는 경로(A, B, 속도)와
-- "서버 기준 경과 ms"를 방송하고, 각 클라는 수신 시각에 고정해 같은 식으로 현재 위치를 구한다
-- (기기마다 getTimestampMs 값이 달라 절대 시각은 쓰지 않는다).

require "HaloDropConfig"

HaloDropFlight = {}

-- A(ax, ay) -> B(bx, by), speed 타일/초.
function HaloDropFlight.makeAB(ax, ay, bx, by, speed)
    local dx, dy = bx - ax, by - ay
    local length = math.sqrt(dx * dx + dy * dy)
    if length < 1 then length = 1 end
    return {
        ax = ax, ay = ay, bx = bx, by = by,
        speed = speed,
        length = length,
        durMs = math.floor(length / speed * 1000),
    }
end

-- A(ax, ay) 에서 angleDeg 방향으로 length 타일, speed 타일/초.
function HaloDropFlight.make(ax, ay, angleDeg, length, speed)
    local r = math.rad(angleDeg)
    return HaloDropFlight.makeAB(ax, ay, ax + math.cos(r) * length, ay + math.sin(r) * length, speed)
end

-- 진행률. 0 = A, 1 = B. 출발 전이면 음수.
function HaloDropFlight.frac(fl, elapsedMs)
    return elapsedMs / fl.durMs
end

-- 경과 시간의 수송기 위치. 출발 전은 A, 도착 후는 B 에 고정.
function HaloDropFlight.pos(fl, elapsedMs)
    local f = elapsedMs / fl.durMs
    if f < 0 then f = 0 elseif f > 1 then f = 1 end
    return fl.ax + (fl.bx - fl.ax) * f, fl.ay + (fl.by - fl.ay) * f
end

-- 기수 방향(도). 퐁듀 수송기와 같은 식: atan2(dx, dy).
function HaloDropFlight.yaw(fl)
    return math.deg(math.atan2(fl.bx - fl.ax, fl.by - fl.ay))
end

-- 진행 방향 단위 벡터 (캐릭터가 바라볼 방향)
function HaloDropFlight.dir(fl)
    local dx, dy = fl.bx - fl.ax, fl.by - fl.ay
    local len = math.sqrt(dx * dx + dy * dy)
    if len <= 0 then return 1, 0 end
    return dx / len, dy / len
end

-- 진행 방향 각도(도). 월드 +x = 0, +y = 90 (math.atan2(dy, dx)). 강하 heading 초기값.
function HaloDropFlight.headingDeg(fl)
    return math.deg(math.atan2(fl.by - fl.ay, fl.bx - fl.ax))
end
