-- Halo Drop 공용 상수·헬퍼 (서버·클라 공용)
--
-- 고도 체계
--   가상 고도(m): 탑승·자유낙하의 "진짜" 높이. 화면에는 고도계로만 보인다.
--   실제 z(층): 캐릭터가 실제로 있는 층. CarryZ 를 넘지 않는다.
--     카메라는 캐릭터 z 를 따라가고(PlayerCamera / calculateCameraZ) 청크는 x, y 기준으로만
--     로드되므로(IsoChunkMap.ProcessChunkPos) 실제 z 를 높이 올리면 화면 중심 지면이
--     로드 범위(기본 +-52칸) 밖으로 밀린다. 1층당 x, y 각 3칸.
--   가상 고도가 CarryZ x M_PER_FLOOR 아래로 내려온 뒤에만 실제 z 가 따라 내려간다.

HaloDrop = HaloDrop or {}

HaloDrop.MODULE       = "HaloDrop"           -- 커맨드 모듈명 (서버·클라 공용, 다른 모드와 겹치지 않게)
HaloDrop.PLANE_SCRIPT = "Base.HaloDropC17"
HaloDrop.CHUTE_ITEM   = "HaloDrop.HaloDropParachute"

HaloDrop.M_PER_FLOOR  = 2.45                 -- 가상 고도(m) <-> 층. 엔진 카메라 환산 2.44949
HaloDrop.PHYS_PER_FLOOR = 2.46               -- 차량 물리 y <-> 층. 퐁듀 수송기(PLANE_FLY_ALT)와 같은 값
HaloDrop.PREP_MS      = 5000                 -- 라운드 시작 방송 후 수송기가 A 를 떠나기까지
HaloDrop.JUMP_PLANE_GRACE_MS = 8000          -- 점프: 발밑 땅이 올라온 뒤 수송기 없이 기다리는 최대 시간
HaloDrop.JUMP_PLANE_BEHIND   = 40            -- 점프 수송기 시작 위치: 점프 지점 뒤쪽(타일). 클라 로드 창(±52칸) 안
HaloDrop.JUMP_PLANE_AHEAD    = 40            -- 점프 수송기 끝 위치: 점프 지점 앞쪽(타일). 지나면 제거 (런 4: 60 은 로드 창 밖이라 skipped 만 늘었다)
HaloDrop.JUMP_PLANE_SPEED    = 12            -- 점프 수송기 통과 속도(타일/초). 비행 속도(48)로는 1초 만에 지나가 안 보였다(런 4) -> 뒤 40칸 3.3초, 앞 40칸 3.3초
HaloDrop.JUMP_PLANE_MAX_MS   = 20000         -- 점프 수송기 최대 수명(서버). 클라 PlaneDone 이 안 와도 지운다

-- 착지 감속. 퐁듀 zombierain.lua 의 LAND_SPEED / FREE_FALL_BRAKE_H 와 같은 값.
-- 착지 피해 기준은 충돌 속도 약 2.24 층/초(FallingConstants). updateFalling 이 착지 틱에
-- 중력분(5.0 x dt)을 한 번 더 더해도 10fps 에서 1.2 + 0.5 = 1.7 로 여유가 있다.
HaloDrop.LAND_SPEED   = 1.2
HaloDrop.BRAKE_H      = 1.0

-- ── 강하 모델 (PUBG 실측 비율, claude/PUBG_강하_메커니즘_조사.md 3.1 / 5.1 절) ──────────
-- 자유낙하: 수직은 FreefallSpeed(=풀다이브 234km/h 에 해당) 대비 비율, 수평은 FreefallSteer 대비 비율.
--   풀다이브 234 / 무입력 180 / 활공·브레이크 126 km/h -> 1.00 / 0.77 / 0.54
--   활공 수평 122 km/h 는 수평 상한(FreefallSteer)을 그대로 쓴다.
HaloDrop.FF = {
    neutral = { v = 0.77, h = 0.00 },   -- 무입력
    glide   = { v = 0.54, h = 1.00 },   -- W: 앞으로 기울여 활공
    dive    = { v = 1.00, h = 0.00 },   -- W + 달리기 키: 정면 아래 다이브
    brake   = { v = 0.54, h = 0.00 },   -- S: 감속
}
-- 캐노피: 수직은 CanopySpeed(=무입력 54km/h) 대비 비율, 수평은 CanopySteer 대비 비율.
--   무입력 54 / W 64 km/h 수직, W 47 km/h 수평 -> 1.00 / 1.19, 수평 1.00
HaloDrop.CP = {
    neutral = { v = 1.00, h = 0.00 },
    glide   = { v = 1.19, h = 1.00 },   -- W: 전진
    dive    = { v = 1.50, h = 0.60 },   -- W + 달리기 키: 빠른 하강 (배그 Shift)
    brake   = { v = 0.85, h = 0.30 },   -- S: 플레어 (수치는 배그 자료 없음, 임의)
}

-- ── 공중 칸 채우기 (HaloDropJumper airFill). 런 4 쿼터뷰 검정 화면 실험. CHUNKS 0 이면 끔 ──────
HaloDrop.AIR_FILL = {
    CHUNKS   = 3,   -- 플레이어 청크 기준 반경(청크). 3 = 7x7 청크 = ±24칸
    PER_TICK = 4,   -- 틱당 만드는 청크층 수 (64칸씩). 7x7x3층 = 147 -> 약 37틱
}

-- ── 하늘 뷰 (HaloDropSky.lua) 상수. 지도 줌은 샌드박스 SkyZoom. ─────────────────────
HaloDrop.SKY = {
    LEAD       = 90,     -- 지도 중심을 진행 방향으로 당기는 거리(타일). 기체 앞쪽이 더 보이게
    SCENE_FRAC = 0.42,   -- 기체 씬 한 변 = 화면 짧은 변 x 이 값
    SCENE_DY   = 0.0,    -- 기체 씬 세로 위치 보정(화면 높이 비율, + 는 아래)
    SCENE_ZOOM = 3,      -- ISUI3DScene setZoom (1~20). 보이는 폭 = 1366/(e^(0.2*zoom)*88) 유닛: 3 -> 8.5
    SCENE_SCALE = 0.12,  -- 기체 객체 배율(getObjectScale). C-17 53 m x 0.12 = 6.4 유닛. 런 4: 배율 없이는 동체 조각만 보였다
    TILT       = 30,     -- 기체를 내려다보는 각도(도). Wingsmith VIEW_TILT 와 같은 출발값
    YAW0       = 45,     -- 기수 방향 보정(도). 런에서 맞춘다 (하늘 뷰 중 [ ] ; ' , . PgUp PgDn 으로 조정, 로그 sky tune:)
    COVER_RATE = 2.0,    -- 구름 덮개 알파가 목표로 수렴하는 속도(1/초)
    TILE_LOADS_PER_FRAME = 2,  -- 타일 텍스처를 프레임당 몇 장까지 새로 읽을지 (히치 방지)
    TINT_NIGHT = 0.35,   -- 밤(낮 밝기 0)일 때 타일 밝기 배율
}

function HaloDrop.log(msg)
    print("[HaloDrop] " .. tostring(msg))
end

-- 등록된 샌드박스 옵션은 로드 후 항상 값이 있다 (fallback 불필요)
function HaloDrop.opt(name)
    return SandboxVars.HaloDrop[name]
end

-- 라운드 멤버 키. MP 는 onlineID, SP 는 로컬 플레이어 하나뿐이라 무엇이든 일관되면 된다.
function HaloDrop.playerKey(p)
    return tostring(p:getOnlineID())
end
