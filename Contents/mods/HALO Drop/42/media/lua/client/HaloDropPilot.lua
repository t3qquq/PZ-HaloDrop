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
-- 차량 보유 상태 (라운드마다 초기화). lost/skipped 는 주기 로그에 함께 찍는다.
local _st = { id = nil, have = false, lost = 0, skipped = 0, moved = 0 }

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
    if _st.id ~= C.id then
        _st.id, _st.have, _st.lost, _st.skipped, _st.moved = C.id, false, 0, 0, 0
    end
    local v = findPlane(C.vid)
    local now = getTimestampMs()
    local frac = HaloDropFlight.frac(C.fl, now - C.t0)
    if not v then
        if _st.have then
            -- 11-06 런 3 실측: 첫 틱 뒤 매번 사라짐. 클라 차량은 자기 청크가 언로드되면
            -- IsoChunk.removeFromWorld -> VehicleManager 에서 빠진다 (b42.21 BaseVehicle:8182).
            _st.have = false
            _st.lost = _st.lost + 1
            HaloDrop.log(string.format("pilot: plane vehicle LOST vid=%s frac=%.3f (lost=%d, client chunk unloaded?)",
                tostring(C.vid), frac, _st.lost))
        else
            logOnce("novehicle" .. tostring(C.id), "pilot: plane vehicle not found yet vid=" .. tostring(C.vid))
        end
        return
    end
    if not _st.have then
        _st.have = true
        HaloDrop.log(string.format("pilot: plane vehicle %s vid=%s frac=%.3f at (%.1f,%.1f)",
            _st.lost > 0 and "RE-ACQUIRED" or "acquired", tostring(C.vid), frac, v:getX(), v:getY()))
    end
    local x, y = HaloDropFlight.pos(C.fl, now - C.t0)
    -- 목적지 칸이 이 클라에 안 올라와 있으면 옮기지 않는다. 옮겨 봐야 BaseVehicle.update 가
    -- (sq==null && chunk.refs 비어있지 않음) 분기에서 이전 청크 안으로 되돌려 놓는다 (b42.21 :3430~3450).
    local tsq = getCell():getGridSquare(math.floor(x), math.floor(y), 0)
    if not tsq then
        _st.skipped = _st.skipped + 1
    else
        _st.moved = _st.moved + 1
    end
    if not _nextLog or now >= _nextLog then
        _nextLog = now + 2000
        HaloDrop.log(string.format("pilot tick frac=%.3f target=(%.1f,%.1f) vehicle=(%.1f,%.1f,%.2f) targetLoaded=%s moved=%d skipped=%d lost=%d",
            frac, x, y, v:getX(), v:getY(), v:getZ(), tostring(tsq ~= nil), _st.moved, _st.skipped, _st.lost))
    end
    -- 기수 방향은 매 틱 다시 건다 (setAngles 는 정수 각도가 같으면 아무것도 안 한다).
    -- 한 번만 걸면 권한 이전 전 서버 갱신이 스폰 방향으로 되돌릴 수 있다(퐁듀 2026-10-27).
    local okY, errY = pcall(function() v:setAngles(0, HaloDropFlight.yaw(C.fl), 0) end)
    if not okY then logOnce("yaw" .. tostring(C.id), "pilot: setAngles FAILED err=" .. tostring(errY)) end
    if not tsq then return end
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
