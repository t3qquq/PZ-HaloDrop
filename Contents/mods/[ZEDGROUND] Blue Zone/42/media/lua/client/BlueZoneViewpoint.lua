-- Blue Zone <-> Viewpoint 벽 애드온 브리지 (클라)
--
-- 벽 자체는 Viewpoint 애드온(42/media/viewpoint/addons/t3bluezone, BlueZoneWall.jar)이 그린다.
-- 이 파일은 자기장 상태와 플레이어 위치를 그 애드온의 Lua export 로 넘기기만 한다.
--   Zone.set(fx, fy, fr, wx, wy, wr, durMs, remainMs, shrinking, paused) : 상태가 바뀔 때 + 애드온을 처음 찾았을 때
--   Zone.clear()                                                       : 라운드 종료
--   Zone.player(x, y, z)                                               : PLAYER_MS 마다 (자바가 축 방향을 맞추는 데 쓴다)
-- Viewpoint 가 없거나 애드온이 거부·미로드면 조용히 아무것도 안 한다 (찾을 때까지 FIND_MS 마다 다시 본다).
-- export 경로는 문서가 없어서 Viewpoint.Addons[ID].Zone 과 Viewpoint.Addons[ID] 를 차례로 보고, 찾은 경로를 로그로 남긴다.

if isServer() then return end

require "BlueZoneConfig"
require "BlueZoneClient"

local B = BlueZone
local ID = "t3bluezone"
local FIND_MS = 2000
local PLAYER_MS = 250

local bridge = nil
local nextFind, nextPlayer = 0, 0
local missLogged = false

local function log(msg) B.log(msg) end

local function findBridge()
    if not Viewpoint then return nil, "Viewpoint not installed" end
    local okr, root = pcall(function() return Viewpoint.Addons end)
    if not okr or not root then return nil, "Viewpoint.Addons missing" end
    local ok, t = pcall(function() return root[ID] end)
    if not ok or t == nil then return nil, "Viewpoint.Addons[\"" .. ID .. "\"] missing" end
    local okz, z = pcall(function() return t.Zone end)
    if okz and z ~= nil and z.set then return z, "Viewpoint.Addons[\"" .. ID .. "\"].Zone" end
    if t.set then return t, "Viewpoint.Addons[\"" .. ID .. "\"]" end
    return nil, "Viewpoint.Addons[\"" .. ID .. "\"] has no Zone.set"
end

local function push()
    if not bridge then return end
    local C = B.C
    local ok, err
    if not C or not B.blueActive(C) then
        ok, err = pcall(bridge.clear)   -- 페이즈 1 대기에는 파란 원(벽)이 아직 없다
    else
        local remain = B.remainMs() or 0
        ok, err = pcall(bridge.set, C.fx, C.fy, C.fr, C.wx, C.wy, C.wr, C.dur, remain, C.seg == "shrink", C.paused == true)
    end
    if not ok then
        log("viewpoint bridge call failed, dropping bridge: " .. tostring(err))
        bridge = nil
    end
end

local function onTick()
    local now = getTimestampMs()
    if not bridge then
        if now < nextFind then return end
        nextFind = now + FIND_MS
        local b, where = findBridge()
        if not b then
            if not missLogged then
                missLogged = true
                log("viewpoint wall addon not found yet (" .. tostring(where) .. "), retrying every " .. FIND_MS .. "ms")
            end
            return
        end
        bridge = b
        local okv, ver = pcall(b.version)
        log("viewpoint wall addon found at " .. where .. " version=" .. tostring(okv and ver or "?"))
        push()
    end
    if now >= nextPlayer then
        nextPlayer = now + PLAYER_MS
        local p = getSpecificPlayer(0)
        if p then
            local ok, err = pcall(bridge.player, p:getX(), p:getY(), p:getZ())
            if not ok then
                log("viewpoint bridge player call failed, dropping bridge: " .. tostring(err))
                bridge = nil
            end
        end
    end
end
Events.OnTick.Add(onTick)

B.onChange(push)
