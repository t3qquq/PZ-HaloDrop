-- Halo Drop 파일럿 클라: 점프 순간의 수송기 차량을 머리 위로 지나가게 끈다
--
-- 설계 B (11-06): 비행 구간엔 월드 차량이 없다(클라 청크 스트리밍이 48 타일/초를 못 따라와 차량이 사라짐,
--   claude/HaloDrop_설계.md 2절). E 를 누르면 서버가 점프 지점 근처에 차량을 띄우고 이 클라에 물리 권한을
--   넘긴다(JumpPlane). 이 클라는 그 차량을 점프 지점 뒤 JUMP_PLANE_BEHIND 에서 앞 JUMP_PLANE_AHEAD 까지
--   JUMP_PLANE_SPEED 로 끌고 지나간 뒤 PlaneDone 을 보낸다. 차량을 처음 잡은 순간 HaloDropJumper.onPlaneAcquired()
--   (구름을 걷어 다가오는 수송기를 보여준다), 점프 지점을 지나는 순간 HaloDropJumper.onPlanePassed().
-- 이동: setWorldTransform (내부 Bullet.teleportVehicle). 목적지 칸이 이 클라에 안 올라와 있으면 그 틱은
--   옮기지 않는다 -- 옮겨 봐야 BaseVehicle.update 가 이전 청크 안으로 되돌린다(b42.21 :3430~3450).
-- 높이 PlaneZ(층) x PHYS_PER_FLOOR.

if isServer() then return end

require "HaloDropConfig"
require "HaloDropFlight"

HaloDropPilot = {}

local _tr = nil
local _logged = {}
local _run = nil   -- 현재 끌고 있는 수송기 { vid, x0, y0, dx, dy, assignedMs, startMs(차량 확보 시각), passed, moved, skipped, lostAt }

local function log(msg) HaloDrop.log(msg) end

local function logOnce(tag, msg)
    if _logged[tag] then return end
    _logged[tag] = true
    log(msg)
end

local function send(cmd, args)
    local p = getPlayer()
    if p then sendClientCommand(p, HaloDrop.MODULE, cmd, args) end
end

local function findPlane(vid)
    local ok, v = pcall(function() return getVehicleById(vid) end)
    if not ok or not v then return nil end
    -- VehicleID 는 재활용되므로 스크립트 이름으로 거른다
    local okS, sn = pcall(function() return v:getScriptName() end)
    if okS and sn == HaloDrop.PLANE_SCRIPT then return v end
    return nil
end

local function finishRun(why)
    if not _run then return end
    log(string.format("jump plane done (%s) vid=%s moved=%d skipped=%d passed=%s after %dms",
        why, tostring(_run.vid), _run.moved, _run.skipped, tostring(_run.passed), getTimestampMs() - _run.assignedMs))
    send("PlaneDone", { id = HaloDrop.C.id, vid = _run.vid })
    _run = nil
    HaloDrop.C.jump = nil
end

-- 서버 JumpPlane 수신 (HaloDropClient): 점프 지점 (x, y) 와 차량 id
function HaloDropPilot.onJumpPlane(args)
    local C = HaloDrop.C
    if not C.fl then return end
    local dx, dy = HaloDropFlight.dir(C.fl)
    _run = {
        vid = args.vid, x0 = args.x, y0 = args.y, dx = dx, dy = dy,
        assignedMs = getTimestampMs(), startMs = nil, passed = false, moved = 0, skipped = 0, lostAt = nil,
    }
    _logged = {}
    log(string.format("jump plane assigned vid=%s at (%d,%d) dir=(%.2f,%.2f)", tostring(args.vid), args.x, args.y, dx, dy))
end

local function pilotTick()
    if not _run then return end
    local C = HaloDrop.C
    if not C.fl or not C.jump then
        finishRun("flight/jump cleared")
        return
    end
    local now = getTimestampMs()
    if now - _run.assignedMs > HaloDrop.JUMP_PLANE_MAX_MS then
        finishRun("timeout")
        return
    end
    local v = findPlane(_run.vid)
    if not v then
        if _run.startMs then
            if not _run.lostAt then
                _run.lostAt = now
                log("jump plane LOST vid=" .. tostring(_run.vid) .. " (client chunk unloaded?)")
            end
        else
            logOnce("novehicle", "jump plane not found yet vid=" .. tostring(_run.vid))
        end
        return
    end
    if not _run.startMs then
        -- 차량이 이 클라에 보이기 시작한 순간부터 시계를 돈다 (그 전엔 어차피 못 옮긴다)
        _run.startMs = now
        log(string.format("jump plane acquired vid=%s at (%.1f,%.1f) %dms after assign", tostring(_run.vid), v:getX(), v:getY(), now - _run.assignedMs))
        if HaloDropJumper and HaloDropJumper.onPlaneAcquired then HaloDropJumper.onPlaneAcquired() end
    end
    _run.lostAt = nil
    local t = (now - _run.startMs) / 1000
    local speed = HaloDrop.JUMP_PLANE_SPEED
    -- 뒤 BEHIND 에서 출발해 JUMP_PLANE_SPEED 로 전진. 점프 지점 통과 시각 = BEHIND / speed
    local s = -HaloDrop.JUMP_PLANE_BEHIND + speed * t
    local x, y = _run.x0 + _run.dx * s, _run.y0 + _run.dy * s
    if s >= 0 and not _run.passed then
        _run.passed = true
        log(string.format("jump plane passed over (%d,%d) at t=%.2fs", _run.x0, _run.y0, t))
        if HaloDropJumper and HaloDropJumper.onPlanePassed then HaloDropJumper.onPlanePassed() end
    end
    if s > HaloDrop.JUMP_PLANE_AHEAD then
        finishRun("passed ahead")
        return
    end
    local tsq = getCell():getGridSquare(math.floor(x), math.floor(y), 0)
    local okY, errY = pcall(function() v:setAngles(0, HaloDropFlight.yaw(C.fl), 0) end)
    if not okY then logOnce("yaw", "jump plane setAngles FAILED err=" .. tostring(errY)) end
    if not tsq then
        _run.skipped = _run.skipped + 1
        return
    end
    local ok, err = pcall(function()
        if not _tr then _tr = Transform.new() end
        local tr = v:getWorldTransform(_tr)
        local o = tr:getOrigin()
        o:set(o:x() + (x - v:getX()), HaloDrop.opt("PlaneZ") * HaloDrop.PHYS_PER_FLOOR, o:z() + (y - v:getY()))
        v:setWorldTransform(tr)
    end)
    if ok then _run.moved = _run.moved + 1
    else logOnce("move", "jump plane move FAILED err=" .. tostring(err)) end
end
Events.OnTick.Add(pilotTick)

function HaloDropPilot.cancel(why)
    if _run then finishRun(why) end
end
