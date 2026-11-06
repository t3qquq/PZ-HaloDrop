-- Halo Drop 파일럿 클라: 수송기 차량을 경로 위치로 옮긴다
--
-- 퐁듀 수송기(zombierain.lua planePilotTick)와 같은 방식이다.
--   서버가 이 클라에 물리 권한을 넘기고(authorizationChanged), 이 클라가 매 틱 setWorldTransform.
--   클라 setWorldTransform 은 내부에서 Bullet.teleportVehicle 을 부른다(BaseVehicle).
--   B42 는 private tempTransform 리플렉션이 막혀 있어 노출된 zombie.core.physics.Transform 을 쓴다.
-- 높이는 PlaneZ(기본 15층, 퐁듀 수송기와 같음). 탑승자가 머무는 CarryZ 와 분리돼 있다 --
-- 캐릭터 층은 카메라·청크 제약으로 10 근처가 한계지만 차량은 그 제약이 없다. 탑승자는 숨겨지므로
-- 둘의 높이가 달라도 보이지 않는다.

if isServer() then return end

require "HaloDropConfig"
require "HaloDropFlight"

local _tr = nil
local _logged = {}
local _nextLog = nil

local function logOnce(tag, msg)
    if _logged[tag] then return end
    _logged[tag] = true
    HaloDrop.log(msg)
end

local function findPlane(vid)
    local ok, v = pcall(function() return getVehicleById(vid) end)
    if not ok or not v then return nil end
    -- VehicleID 는 재활용되므로 스크립트 이름으로 거른다
    local okS, sn = pcall(function() return v:getScriptName() end)
    if okS and sn == HaloDrop.PLANE_SCRIPT then return v end
    return nil
end

local function pilotTick()
    local C = HaloDrop.C
    if not C.fl or C.ended or not C.vid then return end
    local me = getPlayer()
    if not me or C.pilotKey ~= HaloDrop.playerKey(me) then return end
    local v = findPlane(C.vid)
    if not v then
        logOnce("novehicle" .. tostring(C.id), "pilot: plane vehicle not found yet vid=" .. tostring(C.vid))
        return
    end
    logOnce("found" .. tostring(C.id), "pilot: plane vehicle acquired vid=" .. tostring(C.vid))
    local now = getTimestampMs()
    local x, y = HaloDropFlight.pos(C.fl, now - C.t0)
    if not _nextLog or now >= _nextLog then
        _nextLog = now + 2000
        HaloDrop.log(string.format("pilot tick frac=%.3f target=(%.1f,%.1f) vehicle=(%.1f,%.1f,%.2f)",
            HaloDropFlight.frac(C.fl, now - C.t0), x, y, v:getX(), v:getY(), v:getZ()))
    end
    -- 기수 방향은 매 틱 다시 건다 (setAngles 는 정수 각도가 같으면 아무것도 안 한다).
    -- 한 번만 걸면 권한 이전 전 서버 갱신이 스폰 방향으로 되돌릴 수 있다(퐁듀 2026-10-27).
    local okY, errY = pcall(function() v:setAngles(0, HaloDropFlight.yaw(C.fl), 0) end)
    if not okY then logOnce("yaw" .. tostring(C.id), "pilot: setAngles FAILED err=" .. tostring(errY)) end
    local ok, err = pcall(function()
        if not _tr then _tr = Transform.new() end
        local tr = v:getWorldTransform(_tr)
        local o = tr:getOrigin()
        o:set(o:x() + (x - v:getX()), HaloDrop.opt("PlaneZ") * HaloDrop.PHYS_PER_FLOOR, o:z() + (y - v:getY()))
        v:setWorldTransform(tr)
    end)
    if not ok then logOnce("move" .. tostring(C.id), "pilot: plane move FAILED err=" .. tostring(err)) end
end
Events.OnTick.Add(pilotTick)
