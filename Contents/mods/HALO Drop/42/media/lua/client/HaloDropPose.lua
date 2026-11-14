-- Halo Drop: 강하 자세 (플레이어 애니메이션 변수)
--
-- 강하 중인 플레이어에게 애니메이션 변수 HaloDropPose 를 세운다. 값에 따라
-- AnimSets/player/<상태>/HaloDropPose_*.xml 노드가 낙하 클립을 고른다.
--   "freefall" = Bob_FallIdle04 (몸통 수평, 배 아래 - 무입력·감속)
--   "glide"    = Bob_FallIdle03 (머리 쪽이 45도 들림 - W 활공)
--   "dive"     = HaloDropDive (머리부터 65도 - W + 달리기 다이브)
--   "canopy"   = HaloDropParaDescent (두 손을 머리 위로 - 낙하산)
--   nil        = 변수 해제 (바닐라 애니메이션으로 복귀)
--
-- 사용자 정의 애니메이션 변수는 네트워크로 안 간다(PlayerVariables 는 정해진 변수만 보낸다).
-- 그래서 자기 자세가 바뀔 때 서버로 "Pose" 를 보내고, 서버가 전 클라에 돌려주면
-- 각 클라가 그 플레이어 객체(getPlayerByOnlineID)에 같은 변수를 세운다.

HaloDropPose = HaloDropPose or {}

local VAR = "HaloDropPose"
local _mine = nil      -- 내 현재 자세
local _remote = {}     -- [onlineID] = pose (다른 플레이어)
local _nextSweep = 0

local function log(msg) HaloDrop.log(msg) end

local function apply(p, pose)
    if pose then
        p:setVariable(VAR, pose)
    else
        p:clearVariable(VAR)
    end
end

-- 내 캐릭터 자세를 바꾼다. 같은 값이면 아무것도 안 한다.
function HaloDropPose.set(p, pose)
    if pose == _mine then return end
    local prev = _mine
    _mine = pose
    local ok, err = pcall(apply, p, pose)
    log(string.format("pose: %s -> %s ok=%s%s", tostring(prev), tostring(pose), tostring(ok), ok and "" or (" err=" .. tostring(err))))
    sendClientCommand(p, HaloDrop.MODULE, "Pose", { pose = pose or "" })
end

function HaloDropPose.get()
    return _mine
end

-- 다른 플레이어 자세 (서버 중계)
local function onServerCommand(module, command, args)
    if module ~= HaloDrop.MODULE or command ~= "Pose" or not args then return end
    local me = getPlayer()
    if not me or args.oid == nil or args.oid == me:getOnlineID() then return end
    local pose = args.pose
    if pose == "" then pose = nil end
    _remote[args.oid] = pose
    local rp = getPlayerByOnlineID(args.oid)
    local ok = false
    if rp then ok = pcall(apply, rp, pose) end
    log(string.format("pose remote: oid=%s pose=%s found=%s ok=%s", tostring(args.oid), tostring(pose), tostring(rp ~= nil), tostring(ok)))
end
Events.OnServerCommand.Add(onServerCommand)

-- 플레이어 객체가 나중에 만들어지거나 다시 만들어지는 경우에 대비해 1초마다 다시 세운다
local function onTick()
    local now = getTimestampMs()
    if now < _nextSweep then return end
    _nextSweep = now + 1000
    for oid, pose in pairs(_remote) do
        local rp = getPlayerByOnlineID(oid)
        if rp then pcall(apply, rp, pose) end
    end
end
Events.OnTick.Add(onTick)
