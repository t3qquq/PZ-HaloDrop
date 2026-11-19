-- Blue Zone 공용 상수·헬퍼 (서버·클라 공용)
--
-- 용어 (배그와 같음)
--   파란 원(blue): 지금 데미지 경계. 밖에 있으면 초당 데미지.
--   흰 원(white) : 이번 페이즈에 파란 원이 줄어들 목표. 대기(wait) 중에 미리 보인다.
-- 진행: 시작 -> [페이즈 i: 대기(wait) -> 축소(shrink)] x N -> 끝(done)
--   시작하자마자 페이즈 1 흰 원(줄어들 곳)을 보여준다. 시작 파란 원은 배그처럼 영역(Area) 전체를 덮는 큰 원이라
--   (BlueZoneServer initialBlue) 페이즈 1 대기 동안 영역 안에 있는 사람은 전부 안쪽이다. 페이즈 1 축소가 시작되면
--   그 원이 영역 가장자리부터 흰 원으로 줄어든다. 영역 밖(면제 구역 제외)에 있는 사람은 시작부터 자기장 밖이다.
--   축소 중 파란 원은 중심·반지름 모두 흰 원으로 선형 보간한다.
--   마지막 페이즈의 흰 원 반지름은 0 (배그처럼 끝까지 닫힘). done 에서도 데미지는 계속된다.
--
-- 진입점 (다른 모드·Round Manager 가 부르는 것): 모듈 BlueZone.MODULE 로 sendClientCommand
--   Start      대기 상태에서만. 새 라운드 시작 (진행 중이면 무시 - 먼저 Stop)
--              args { cx, cy } (선택): 페이즈 1 흰 원 중심 힌트. Round Manager 가 HALO Drop 비행 경로 근처를 넘길 용도.
--              원이 영역 안에 들어가게 잘린다. 없으면 영역 안 무작위
--   Pause      일시정지. 타이머와 데미지가 멈춘다 (멱등)
--   Resume     재개 (멱등)
--   NextPhase  다음 구간으로 넘긴다: 대기 중이면 축소를 지금 시작(점진 축소가 바로 보인다),
--              축소 중이면 파란 원을 흰 원에 붙이고 다음 페이즈 대기로. 일시정지 중이면 정지 상태를 유지한 채 넘어간다
--   Stop       라운드 종료, 대기 상태로
--   Sync       (권한 불필요) 현재 상태를 요청한 클라에게 다시 보낸다
--   권한 검사는 서버(BlueZoneServer.lua onClientCommand)가 한다(admin). Sync 만 예외.
-- 서버 -> 클라: State(스냅샷), Stopped
--
-- 페이즈 표는 하드코딩 (11-18 결정). 9페이즈 x 4값을 샌드박스로 빼면 관리가 안 된다.
-- 운영 중 바꿀 일이 있는 전역 배율(대기·축소·데미지)·첫 원 크기·영역만 샌드박스.

BlueZone = BlueZone or {}

BlueZone.MODULE = "BlueZone"   -- 커맨드 모듈명 (다른 모드와 겹치지 않게)

-- PZ 기준 표 (11-18). 기본 판 길이 약 76분 = 하루 1~2판 목표. 1판만 하는 날은 WaitScale 로 대기만 늘린다.
--   wait  : 대기(흰 원 표시, 벽 정지) 초. WaitScale 이 곱해진다. 파밍 시간 기준이라 초반을 길게
--   shrink: 축소 초. ShrinkScale 이 곱해진다. 벽 속도가 대략 초당 2~3칸 이하가 되게 역산 (PZ 이동 속도 실측 전 추정)
--   ratio : 이전 흰 원 반지름 대비. 배그와 같은 비율(2단계 0.65, 이후 0.5). 페이즈 1 은 샌드박스 FirstRadius
--           FirstRadius 1500 기준 반지름 1500/975/488/244/122/61/30/15/0
--   dps   : 자기장 밖 초당 체력(전체 100 기준, DamageScale 이 곱해진다). 배그 옛 PC 표(거리 보정 제외) 0.4~9, 마지막 11
-- 누적(분, 배율 1.0, 11-19 지연 구간 삭제 후): 1: 15/28 | 2: 35/42 | 3: 47/52 | 4: 56/59 | 5: 61.5/63.5 | 6: 65.5/67 | 7: 68.5/69.75 | 8: 70.75/72 | 9: 72.75/74.25
BlueZone.PHASES = {
    { wait = 900, shrink = 780, ratio = nil,  dps = 0.4  },
    { wait = 420, shrink = 420, ratio = 0.65, dps = 0.6  },
    { wait = 300, shrink = 300, ratio = 0.5,  dps = 0.8  },
    { wait = 240, shrink = 180, ratio = 0.5,  dps = 1.0  },
    { wait = 150, shrink = 120, ratio = 0.5,  dps = 3.0  },
    { wait = 120, shrink = 90,  ratio = 0.5,  dps = 5.0  },
    { wait = 90,  shrink = 75,  ratio = 0.5,  dps = 7.0  },
    { wait = 60,  shrink = 75,  ratio = 0.5,  dps = 9.0  },
    { wait = 45,  shrink = 90,  ratio = 0.0,  dps = 11.0 },
}

function BlueZone.log(msg)
    print("[BlueZone] " .. tostring(msg))
end

-- 등록된 샌드박스 옵션은 로드 후 항상 값이 있다 (fallback 불필요)
function BlueZone.opt(name)
    return SandboxVars.BlueZone[name]
end

-- 연출 방식 (샌드박스 BlueZone.Style, enum). 서버 값이 전 클라에 동기화되므로 전원이 같은 모습을 본다.
--   1 field: 배그식 전자기장 (파랑, 번개 줄기)   2 gas: 화생방 오염 구역 (초록 독가스)
-- 색만 여기서 정한다. Viewpoint 벽 모양은 클라 자바(src/t3bluezone/BlueZoneWall)가 같은 샌드박스 값을 읽어 고른다.
--   line   : 지도·미니맵 원 선, 아이소 땅 위 선      fill: 지도·미니맵 원 바깥 채우기
--   tint   : 구역 밖 화면 색                          hud / hudFill: HUD 타이머 글자 / 진행 막대 (ZEDGROUND HUD 가 읽는다)
BlueZone.STYLES = {
    { name = "field",
      line = { r = 0.25, g = 0.50, b = 1.00, a = 0.95 }, fill = { r = 0.10, g = 0.25, b = 0.90, a = 0.35 },
      tint = { r = 0.10, g = 0.25, b = 0.85 },
      hud  = { r = 0.45, g = 0.70, b = 1.00 }, hudFill = { r = 0.25, g = 0.50, b = 1.00, a = 0.95 } },
    { name = "gas",
      line = { r = 0.45, g = 0.95, b = 0.25, a = 0.95 }, fill = { r = 0.22, g = 0.55, b = 0.08, a = 0.38 },
      tint = { r = 0.28, g = 0.55, b = 0.08 },
      hud  = { r = 0.62, g = 0.95, b = 0.40 }, hudFill = { r = 0.40, g = 0.85, b = 0.20, a = 0.95 } },
}

function BlueZone.style()
    return BlueZone.STYLES[BlueZone.opt("Style")]
end

-- 초 -> ms. kind: "wait"(지연·대기, WaitScale) / "shrink"(축소, ShrinkScale)
function BlueZone.durMs(sec, kind)
    local scale = kind == "shrink" and BlueZone.opt("ShrinkScale") or BlueZone.opt("WaitScale")
    return math.floor(sec * 1000 * scale)
end

-- 파란 원이 있는가 (st: 서버 S 또는 클라 스냅샷). 라운드가 돌고 있으면 항상 있다.
-- (11-19 오전까지는 시작 원이 흰 원의 2배라 페이즈 1 대기 동안 숨겼다. 지금은 영역 전체를 덮는 원이라 숨길 이유가 없다)
function BlueZone.blueActive(st)
    return st ~= nil and st.phase ~= nil and st.phase >= 1
end

-- 이 페이즈의 초당 데미지. phase 0 은 0, 범위를 넘으면 마지막 값
function BlueZone.dpsOf(phase)
    if phase < 1 then return 0 end
    local n = #BlueZone.PHASES
    if phase > n then phase = n end
    return BlueZone.PHASES[phase].dps
end

-- 상태(서버 S 또는 클라 스냅샷)와 구간 진행률 frac(0~1)로 지금 파란 원을 구한다.
-- st: seg, fx, fy, fr (구간 시작 파란 원), wx, wy, wr (흰 원, 없으면 wr < 0)
function BlueZone.blueAt(st, frac)
    if st.seg ~= "shrink" or st.wr < 0 then
        return st.fx, st.fy, st.fr
    end
    if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
    return st.fx + (st.wx - st.fx) * frac,
           st.fy + (st.wy - st.fy) * frac,
           st.fr + (st.wr - st.fr) * frac
end

function BlueZone.isOutside(x, y, cx, cy, r)
    local dx, dy = x - cx, y - cy
    return dx * dx + dy * dy > r * r
end

-- 바닐라 B42 지도의 빈 북서쪽 (샌드박스 AvoidEmptyNW). HALO Drop 의 같은 이름 옵션과 같은 영역 (HaloDropServer.lua inEmptyNW).
-- 셀 = 256칸. x < 45 이고 y < 18 인 직사각형 + x 45~58 에서 (45,3)-(58,0) 선 위쪽 삼각형 (t3 지도 캡처 11-08)
local CELL = 256
function BlueZone.inEmptyNW(x, y)
    local cx, cy = x / CELL, y / CELL
    if cx < 45 and cy < 18 then return true end
    if cx >= 45 and cx <= 58 and cy < 3 - 3 * (cx - 45) / 13 then return true end
    return false
end

-- 원 안에서 빈 북서쪽이 차지하는 비율(0~1). 원을 감싸는 9x9 격자 중 원 안에 든 점으로 센다
function BlueZone.emptyFraction(cx, cy, r)
    local n, hit = 0, 0
    for i = -4, 4 do
        for j = -4, 4 do
            local dx, dy = i / 4 * r, j / 4 * r
            if dx * dx + dy * dy <= r * r then
                n = n + 1
                if BlueZone.inEmptyNW(cx + dx, cy + dy) then hit = hit + 1 end
            end
        end
    end
    return n > 0 and hit / n or 0
end

-- 면제 구역(대기실 오일리그). X2 > X1 이고 Y2 > Y1 일 때만 적용
function BlueZone.inExempt(x, y)
    local x1, y1 = BlueZone.opt("ExemptX1"), BlueZone.opt("ExemptY1")
    local x2, y2 = BlueZone.opt("ExemptX2"), BlueZone.opt("ExemptY2")
    if x2 <= x1 or y2 <= y1 then return false end
    return x >= x1 and x <= x2 and y >= y1 and y <= y2
end
