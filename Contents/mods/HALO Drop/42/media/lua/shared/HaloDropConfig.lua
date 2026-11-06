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

-- 착지 감속. 퐁듀 zombierain.lua 의 LAND_SPEED / FREE_FALL_BRAKE_H 와 같은 값.
-- 착지 피해 기준은 충돌 속도 약 2.24 층/초(FallingConstants). updateFalling 이 착지 틱에
-- 중력분(5.0 x dt)을 한 번 더 더해도 10fps 에서 1.2 + 0.5 = 1.7 로 여유가 있다.
HaloDrop.LAND_SPEED   = 1.2
HaloDrop.BRAKE_H      = 1.0

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
