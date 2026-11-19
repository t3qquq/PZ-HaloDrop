-- Round Manager 공용 상수·헬퍼 (서버·클라 공용)
--
-- 의존 방향: Round Manager -> 기능 모드 (한쪽만). 기능 모드는 Manager 를 모른다.
--   mod.info 에 require 를 걸지 않는다. 대상 모드가 꺼져 있으면 그 기능 버튼만 비활성화한다.
--   켜짐 판별은 대상 모드의 전역 테이블 + MODULE 존재로 한다 (TARGETS.global).
--
-- 판 상태: WAITING(대기) / RUNNING(진행 중). 사망 처리 분기용 하나만 둔다.
-- 명령 (모듈 RoundManager.MODULE)
--   C -> S  SetState { state = "WAITING" | "RUNNING" }  (admin)
--   C -> S  Sync                                        (권한 불필요)
--   S -> C  State { state = ... }

RoundManager = RoundManager or {}

RoundManager.MODULE = "RoundManager"

RoundManager.STATE = { WAITING = "WAITING", RUNNING = "RUNNING" }

-- 제어판에서 호출하는 기능 모드 진입점. 명령 이름은 각 모드 문서 기준
--   HALO Drop: HaloDropAdminMenu.lua / HaloDropServer.lua onClientCommand
--   Blue Zone: BlueZoneConfig.lua 머리말
RoundManager.TARGETS = {
    HaloDrop = { global = "HaloDrop",  commands = { "Start", "Launch", "Stop" } },
    BlueZone = { global = "BlueZone",  commands = { "Start", "Pause", "Resume", "NextPhase", "Stop" } },
}

-- 오일리그(대기실) 스폰 지점. [ZEDGROUND] Oil Rig Map 의 maps/OilRig/spawnpoints.lua 와 같은 값 (상부 갑판, z4)
-- 칸 가운데에 서도록 +0.5. 맵 모드 id 는 t3OilRig (켜져 있을 때만 이동 메뉴를 쓴다)
RoundManager.OIL_RIG_MOD = "t3OilRig"
RoundManager.OIL_RIG_SPAWN = { x = 19213.5, y = 272.5, z = 4 }

function RoundManager.log(msg)
    print("[RoundManager] " .. tostring(msg))
end

-- 대상 모드가 켜져 있으면 그 모드의 커맨드 모듈명, 아니면 nil
function RoundManager.targetModule(key)
    local t = RoundManager.TARGETS[key]
    if not t then return nil end
    local g = _G[t.global]
    if type(g) ~= "table" or type(g.MODULE) ~= "string" then return nil end
    return g.MODULE
end
