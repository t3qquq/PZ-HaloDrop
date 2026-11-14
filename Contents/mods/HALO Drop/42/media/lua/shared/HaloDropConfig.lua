-- Halo Drop 공용 상수·헬퍼 (서버·클라 공용)
--
-- 고도 체계
--   가상 고도(m): 탑승·자유낙하의 "진짜" 높이. 화면에는 고도계로만 보인다.
--   실제 z(층): 캐릭터가 실제로 있는 층. 뛰어내릴 때 CarryZ, 이후 가상 고도에 맞춰 DESCENT_Z.LOW_Z(3) 까지
--     내려오고(HaloDropJumper visualZ), 그 아래는 엔진 낙하. 카메라는 캐릭터 z 를 따라가고
--     (PlayerCamera / calculateCameraZ) 청크는 x, y 기준으로만 로드되므로(IsoChunkMap.ProcessChunkPos)
--     실제 z 를 높이 올리면 화면 중심 지면이 로드 범위 밖으로 밀린다. 1층당 x, y 각 3칸.
--     로드 창 폭은 해상도로 정해진다(IsoChunkMap.CalcChunkWidth: 1080p 13, 1440p 이상 19 청크 = +-72칸).

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
-- 뛰어내린 순간 이어받는 수평 속도(타일/초) 상한. 런 5: fl.speed(80) 을 그대로 받아 첫 0.6초에 30칸을 날아가
-- 로드 창 밖으로 나갔다 -> 3초 제자리 스냅백 -> far move -> 10초 current==null(화면 검정·갱신 정지).
-- 눈에 보이는 점프 수송기는 JUMP_PLANE_SPEED 로 지나가므로 그 속도를 이어받는 게 맞다.
HaloDrop.JUMP_VH_MAX         = HaloDrop.JUMP_PLANE_SPEED

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
    -- 플레이어 청크 기준 반경(청크). 1 = 3x3 청크 = ±8칸. 아이소 검정 화면 실험 때는 3(7x7)이었으나
    -- CarryZ 31 에선 7x7x31 = 1519 청크층(런 7 폭증 구간). Viewpoint 는 자체 렌더라 발밑 current 칸(엔진 로직)만
    -- 있으면 되므로 경계 넘김 대비 3x3 만 남긴다 (3x3x31 = 279 청크층, 틱당 PER_TICK 이라 약 35틱)
    CHUNKS   = 1,
    PER_TICK = 8,   -- 틱당 만드는 청크층 수 (64칸씩). 7x7x3층 = 147 -> 약 19틱 (런 5: 4 에서 올림)
}

-- ── 하강 z (HaloDropJumper visualZ). 런 6: 실제 z 가 CarryZ(3) 고정이라 고도 변화가 안 보였고, 마지막 7m
-- (엔진 낙하, z 3->0) 만 떨어지는 느낌이 났다. 그래서 뛰어내리는 z 를 CarryZ(기본 8)로 올리고 가상 고도에 맞춰
-- LOW_Z 까지 끌어내린다. 기본은 가상 고도에 비례(PROPORTIONAL), 끄면 낙하산 개방 고도에서 LOW_Z + (CarryZ-LOW_Z)*CHUTE_FRAC.
-- 11-14: CarryZ 31(엔진 상한) + 비례 매핑으로 변경. Viewpoint 1·3인칭 전용.
-- 공중 칸은 airFill 이 1~z 층에 만든다 (엔진 current 칸 탐색은 z 아래로 내려가며 첫 칸을 잡으므로
-- 칸이 없으면 지면 칸이 current 가 되고, 그 칸이 화면 밖이면 캐릭터가 안 그려진다 - IsoGridSquare.IsOnScreen).
-- CarryZ(HaloDrop.FIXED) 상한. 엔진 층 상한은 31(IsoChunkMap.isGridSquareOutOfRangeZ: -32~31).
-- 런 7: 아이소에서 16·31 은 airFill 폭증(AIR_FILL 반경 3) + 카메라가 층당 3칸 밀려 로드 창 이탈 -> 검정·프레임 정지.
-- 31 은 Viewpoint 1·3인칭 전용 전제 (아이소는 Hooks.skipIsoCellRender 로 건너뛰므로 카메라 밀림이 없다).
-- 아이소로 뛰어내리면 jump 로그에 경고가 남는다(viewCheck).
HaloDrop.CARRY_Z_MAX = 31
HaloDrop.ISO_SAFE_Z  = 12   -- 아이소에서 버티는 상한 (viewCheck 경고 기준)
HaloDrop.DESCENT_Z = {
    ENABLED    = true,
    LOW_Z      = 3,     -- 이 층 아래는 엔진 낙하 (런 3~6 검증 구간)
    -- 가상 고도 -> 실제 z 를 JumpAltitude~LOW_Z 한 직선으로 잇는다. 층당 미터가 구간마다 같아서
    -- 화면 하강 속도 비율이 실제 속도 비율(자유낙하 > 캐노피)과 같아진다.
    -- 이전 CHUTE_FRAC 0.5 는 자유낙하 500m 와 캐노피 93m 에 층을 반씩 나눠 캐노피가 화면상 더 빨랐다(0.15 vs 0.19층/초).
    PROPORTIONAL = true,
    CHUTE_FRAC   = 0.5, -- PROPORTIONAL false 일 때만: 낙하산 개방 고도에서 남겨 둘 층 비율
}

-- ── 강하 그림자 (HaloDropShadow.lua). 발밑 지면 칸에 검은 타원. 캐릭터와의 화면 간격이 남은 높이.
HaloDrop.SHADOW = {
    ENABLED      = true,
    BODY_TILES   = 0.9,    -- 자유낙하 그림자 폭 (월드 칸)
    CANOPY_TILES = 2.6,    -- 낙하산 그림자 폭 (월드 칸)
    ALPHA_FAR    = 0.18,   -- FADE_FLOORS 층 이상 높이에서의 투명도
    ALPHA_NEAR   = 0.55,   -- 지면 바로 위에서의 투명도
    FADE_FLOORS  = 8,
}

-- ── 하강 줌 (HaloDropJumper descentZoom). 런 5: 실제 z 가 끝까지 CarryZ 라 고도가 변하는 시각 단서가 없었다.
-- 뛰어내릴 때 옵션의 가장 먼 줌 레벨까지 빼고, 가상 고도가 ALT_NEAR 까지 내려오는 동안 원래 줌으로 당긴다.
-- 바닐라 Tutorial(Steps.lua SneakStep.setZoom / Tutorial1.lua setZoomLevels)과 같은 경로:
-- setZoomLevels 로 촘촘한 레벨 목록을 깔고 doZoomScroll 로 한 단계씩 옮긴다(MultiTextureFBO2 가 프레임당 0.02 씩 보간).
-- 착지·종료 때 옵션 문자열(getOptionZoomLevels1x/2x, "250;225;..." %)로 원래 목록을 되돌린다. ENABLED false 면 끔.
HaloDrop.DESCENT_ZOOM = {
    ENABLED  = false,  -- 런 6: 2.5->0.75 로 당겨도 "떠 있는" 느낌은 그대로였고, DESCENT_Z 의 z 간격 변화와 서로 상쇄된다
    STEP     = 0.05,   -- 레벨 간격(줌 배율). 작을수록 매끄럽다
    ALT_NEAR = 80,     -- 이 가상 고도(m) 아래서는 원래 줌
}

-- ── 하늘 뷰 (HaloDropSky.lua) 상수. 지도 줌은 샌드박스 SkyZoom. ─────────────────────
HaloDrop.SKY = {
    LEAD       = 90,     -- 지도 중심을 진행 방향으로 당기는 거리(타일). 기체 앞쪽이 더 보이게
    SCENE_FRAC = 0.42,   -- 기체 씬 한 변 = 화면 짧은 변 x 이 값
    SCENE_DY   = 0.0,    -- 기체 씬 세로 위치 보정(화면 높이 비율, + 는 아래)
    SCENE_ZOOM = 3,      -- ISUI3DScene setZoom (1~20). 보이는 폭 = 1366/(e^(0.2*zoom)*88) 유닛: 3 -> 8.5
    SCENE_SCALE = 0.12,  -- 기체 객체 배율(getObjectScale). C-17 53 m x 0.12 = 6.4 유닛. 런 4: 배율 없이는 동체 조각만 보였다
    TILT       = 30,     -- 기체를 내려다보는 각도(도). 인게임 아이소 카메라와 같은 값 (TileGeometryUtils viewRotation (30,315,0))
    YAW0       = 0,      -- 기수 방향 미세 보정(도). 기본 식은 view yaw = 315 + 차량 yaw(HaloDropFlight.yaw) -- 월드에서 setAngles 한
                         -- 차량을 아이소 카메라로 본 것과 같은 모습(UI3DScene.calcMatrices :2655 rotateXYZ 뒤에 객체 변환).
                         -- 런 5 까지는 YAW0 45 + 화면투영각이라 기수가 진행 방향과 안 맞았다. [ ] 키로 ±5 조정, 로그 sky tune:
    COVER_RATE = 2.0,    -- 구름 덮개 알파가 목표로 수렴하는 속도(1/초)
    TILE_LOADS_PER_FRAME = 2,  -- 타일 텍스처를 프레임당 몇 장까지 새로 읽을지 (히치 방지)
    TINT_NIGHT = 0.35,   -- 밤(낮 밝기 0)일 때 타일 밝기 배율
}

function HaloDrop.log(msg)
    print("[HaloDrop] " .. tostring(msg))
end

-- ── 강하 고정값 (11-14: 샌드박스에서 빼고 하드코딩). 실제 높이만 엔진 상한 31층으로 타협하고
-- 나머지는 배그 수치 (claude/PUBG_강하_메커니즘_조사.md 3.1 / 4.2 / 5.1 절, 강의 영상 고도계).
HaloDrop.FIXED = {
    PlaneZ           = 31,    -- 점프 수송기 차량이 나는 실제 층 (엔진 상한)
    CarryZ           = 31,    -- 뛰어내리는 실제 층 (엔진 상한, Viewpoint 1·3인칭 전용)
    JumpAltitude     = 1500,  -- 뛰어내릴 때 가상 고도(m). 영상에서 뛰어내린 직후 고도계 약 1480m
    AutoOpenAltitude = 300,   -- 낙하산 자동 개방 가상 고도(m). 배그 지면 기준 약 300m
    FreefallSpeed    = 65.0,  -- 자유낙하 최대 하강(m/초) = 풀다이브 234km/h
    CanopySpeed      = 15.0,  -- 낙하산 무입력 하강(m/초) = 54km/h
    FreefallSteer    = 16.0,  -- 자유낙하 최대 수평(타일/초). 배그는 34(122km/h)지만 안티치트 한도(차량 밖 1초 평균 20타일/초) 아래로
    CanopySteer      = 13.0,  -- 낙하산 최대 수평(타일/초) = W 47km/h
}

-- 고정값이 있으면 그 값, 아니면 샌드박스 옵션 (등록된 옵션은 로드 후 항상 값이 있다 - fallback 불필요)
function HaloDrop.opt(name)
    local v = HaloDrop.FIXED[name]
    if v ~= nil then return v end
    return SandboxVars.HaloDrop[name]
end

-- 라운드 멤버 키. MP 는 onlineID, SP 는 로컬 플레이어 하나뿐이라 무엇이든 일관되면 된다.
function HaloDrop.playerKey(p)
    return tostring(p:getOnlineID())
end
