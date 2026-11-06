-- Halo Drop 점퍼: 자기 캐릭터의 탑승·자유낙하·낙하산·착지
--
-- 상태: nil -> ABOARD -> FREEFALL -> CANOPY -> nil(착지)
--   ABOARD    수송기 경로 위치에 붙잡는다 (실제 z = CarryZ)
--   FREEFALL  가상 고도를 FreefallSpeed 로 줄인다. 상호작용 키로 낙하산
--   CANOPY    가상 고도를 CanopySpeed 로 줄인다
-- 실제 z 처리 (HaloDropConfig.lua 고도 체계 참고)
--   붙잡기(hold): 가상 고도가 CarryZ 층보다 높은 동안. 매 틱 x, y, z 를 직접 정하고 낙하 속도를 0 으로 둔다.
--   놓기(release): 가상 고도가 CarryZ 층 아래로 내려오면 엔진 낙하(IsoGameCharacter.updateFalling)에
--     맡기고 낙하 속도만 매 틱 setLastFallSpeed 로 정한다. 바닥 BRAKE_H 층 위부터 LAND_SPEED 로 감속.
--     updateFalling 은 중력을 더하는 등가속도이고 착지 피해는 충돌 순간 속도로만 정한다.
-- 순서: IsoGameCharacter.update(updateFalling 포함)가 먼저 돌고 OnPlayerUpdate 가 뒤에 발화한다(IsoPlayer).
--   그래서 여기서 정한 위치가 그 틱의 렌더 위치가 되고, 낙하 속도는 다음 틱 updateFalling 에 쓰인다.
-- 안티치트: 차량 밖 캐릭터는 1초 평균 20 타일/초를 넘으면 위반이다(AntiCheatSpeed).
--   수송기 속도·조향 속도 샌드박스 상한을 19 로 둔 이유.
-- 낙하산 착용·해제는 여기(클라)서 한다. 서버는 아이템 지급(ChuteWear 지시)·회수만 한다 -- 착용 상태는
--   클라 setWornItem 이 SyncClothing 으로 서버에 올리므로 서버가 벗겨도 되살아난다(11-06 실측).

if isServer() then return end

require "HaloDropConfig"
require "HaloDropFlight"

HaloDropJumper = {}

local J = { state = nil }
HaloDrop.J = J

local function log(msg) HaloDrop.log(msg) end

local function send(p, cmd, args)
    sendClientCommand(p, HaloDrop.MODULE, cmd, args)
end

local function carryAltM()
    return HaloDrop.opt("CarryZ") * HaloDrop.M_PER_FLOOR
end

-- ── 소리 (자기 캐릭터 emitter, 로컬 재생) ───────────────────────────────────
local function planeSoundStart(p)
    if J.planeSnd then return end
    local ok, h = pcall(function() return p:getEmitter():playSoundImpl("halodrop_plane", nil) end)
    if ok and h and h ~= 0 then J.planeSnd = h end
end

local function planeSoundStop(p)
    if not J.planeSnd then return end
    pcall(function() p:getEmitter():stopSound(J.planeSnd) end)
    J.planeSnd = nil
end

-- ── 낙하산 착용·해제 (클라) ───────────────────────────────────────────────────
local function findChute(p)
    local inv = p:getInventory()
    return inv and inv:getFirstTypeRecurse(HaloDrop.CHUTE_ITEM) or nil
end

local function chuteWear(p)
    local item = findChute(p)
    if not item then return false end
    if p:getWornItems():getLocation(item) then return true end
    local ok, err = pcall(function() p:setWornItem(item:getBodyLocation(), item) end)
    log("chute wear ok=" .. tostring(ok) .. (ok and "" or (" err=" .. tostring(err))))
    return ok
end

-- 착용 목록에 있는 낙하산 전부 (인벤토리에서 이미 지워졌는데 착용 목록에만 남은 경우도 잡는다)
local function wornChutes(p)
    local out = {}
    local worn = p:getWornItems()
    if not worn then return out end
    for i = 0, worn:size() - 1 do
        local it = worn:get(i):getItem()
        if it and it:getFullType() == HaloDrop.CHUTE_ITEM then out[#out + 1] = it end
    end
    return out
end

local function chuteUnwear(p, reason)
    local items = wornChutes(p)
    if #items == 0 then return end
    for _, item in ipairs(items) do
        local ok, err = pcall(function() p:removeWornItem(item) end)
        log("chute unwear (" .. tostring(reason) .. ") ok=" .. tostring(ok) .. (ok and "" or (" err=" .. tostring(err)))
            .. " inInventory=" .. tostring(item:getContainer() ~= nil))
    end
end

-- 서버 ChuteWear 는 sendAddItemToContainer 보다 먼저 도착할 수 있다 -> 아이템이 보일 때까지 몇 틱 재시도
local _wearUntil = nil
function HaloDropJumper.onChuteWear()
    local p = getPlayer()
    if not p then return end
    if chuteWear(p) then return end
    _wearUntil = getTimestampMs() + 3000
    log("chute item not in inventory yet -> retrying up to 3s")
end

local function wearRetryTick()
    if not _wearUntil then return end
    local p = getPlayer()
    if not p then return end
    if chuteWear(p) then
        _wearUntil = nil
    elseif getTimestampMs() > _wearUntil then
        _wearUntil = nil
        log("chute wear FAILED: item never arrived")
    end
end
Events.OnTick.Add(wearRetryTick)

-- ── 위치 제어 ─────────────────────────────────────────────────────────────────
-- setForceX/Y = x, next, last 동시 설정 (IsoMovingObject). setZ 는 lastZ 도 같이 정하고 31 로 자른다.
local function hold(p, x, y, z)
    p:setForceX(x)
    p:setForceY(y)
    p:setZ(z)
    p:setLastFallSpeed(0)
end

-- 이동 키 -> 월드 방향. 아이소 화면 위 = 월드 (-1,-1), 오른쪽 = (+1,-1).
local SQ = 0.70710678
local function steerDir()
    local sx, sy = 0, 0
    if isKeyDown("Forward") then sy = sy - 1 end
    if isKeyDown("Backward") then sy = sy + 1 end
    if isKeyDown("Left") then sx = sx - 1 end
    if isKeyDown("Right") then sx = sx + 1 end
    if sx == 0 and sy == 0 then return 0, 0 end
    local wx = (sx + sy) * SQ
    local wy = (sy - sx) * SQ
    local len = math.sqrt(wx * wx + wy * wy)
    return wx / len, wy / len
end

-- ── 상태 전이 ─────────────────────────────────────────────────────────────────
local function finish(p)
    J.state = nil
    planeSoundStop(p)
    p:setBlockMovement(false)
end

function HaloDropJumper.board()
    local p = getPlayer()
    if not p or p:isDead() then return end
    J.state = "ABOARD"
    J.alt = HaloDrop.opt("JumpAltitude")
    J.lastTs = getTimestampMs()
    J.released = false
    J.chuteSent = false
    planeSoundStart(p)
    log(string.format("board: from (%.1f,%.1f,%.1f)", p:getX(), p:getY(), p:getZ()))
end

local function jump(p, reason)
    if J.state ~= "ABOARD" then return end
    J.state = "FREEFALL"
    J.x, J.y = p:getX(), p:getY()
    J.alt = HaloDrop.opt("JumpAltitude")
    planeSoundStop(p)
    send(p, "Jumped", { id = HaloDrop.C.id, reason = reason })
    log(string.format("jump (%s) at (%.1f,%.1f) alt=%.0fm", reason, J.x, J.y, J.alt))
end

local function openChute(p, reason)
    if J.state ~= "FREEFALL" then return end
    J.state = "CANOPY"
    pcall(function() p:getEmitter():playSoundImpl("halodrop_chute", nil) end)
    if not J.chuteSent then
        J.chuteSent = true
        send(p, "ChuteOpen", { id = HaloDrop.C.id, reason = reason, alt = math.floor(J.alt) })
    end
    log(string.format("chute open (%s) alt=%.0fm", reason, J.alt))
end

local function land(p)
    local chute = J.state == "CANOPY"
    finish(p)
    chuteUnwear(p, "landed")
    send(p, "Landed", { id = HaloDrop.C.id, chute = chute })
    log(string.format("landed at (%.1f,%.1f,%.1f) chute=%s", p:getX(), p:getY(), p:getZ(), tostring(chute)))
end

function HaloDropJumper.onRoundEnd()
    local p = getPlayer()
    if p and J.state == "ABOARD" then jump(p, "forced") end
end

-- ── 매 틱 ─────────────────────────────────────────────────────────────────────
local function onPlayerUpdate(p)
    if not J.state or p ~= getPlayer() then return end
    if p:isDead() then
        finish(p)
        return
    end
    local now = getTimestampMs()
    local dt = (now - (J.lastTs or now)) / 1000
    if dt < 0 then dt = 0 elseif dt > 0.25 then dt = 0.25 end
    J.lastTs = now
    p:setBlockMovement(true)
    local carryZ = HaloDrop.opt("CarryZ")

    -- 1초 주기 상태 로그 (실시간 검증용)
    if not J.nextLog or now >= J.nextLog then
        J.nextLog = now + 1000
        local h = -1
        pcall(function() h = p:getHeightAboveFloor() end)
        -- 애니 상태 3단계: AI 상태 / 액션 컨텍스트 상태 / AdvancedAnimator 루트 상태
        local ai, act, anim = "?", "?", "?"
        pcall(function() ai = tostring(p:getCurrentStateName()) end)
        pcall(function() act = tostring(p:getActionStateName()) end)
        pcall(function() anim = tostring(p:getAnimationStateName()) end)
        log(string.format("tick state=%s alt=%.0fm z=%.2f pos=(%.1f,%.1f) fall=%.2f h=%.2f released=%s falling=%s ai=%s action=%s anim=%s",
            tostring(J.state), J.alt or -1, p:getZ(), p:getX(), p:getY(), p:getLastFallSpeed(), h,
            tostring(J.released), tostring(p:isFalling()), ai, act, anim))
    end

    if J.state == "ABOARD" then
        local C = HaloDrop.C
        if not C.fl then
            -- 라운드 정보가 사라졌다(Closed 수신 등): 그 자리에서 강하
            jump(p, "lost flight")
            return
        end
        local x, y = HaloDropFlight.pos(C.fl, now - C.t0)
        hold(p, x, y, carryZ)
        local fx, fy = HaloDropFlight.dir(C.fl)
        p:setForwardDirection(fx, fy)
        return
    end

    -- 수평 조향
    local canopy = J.state == "CANOPY"
    local steer = canopy and HaloDrop.opt("CanopySteer") or HaloDrop.opt("FreefallSteer")
    local dx, dy = steerDir()
    if dx ~= 0 or dy ~= 0 then
        J.x = J.x + dx * steer * dt
        J.y = J.y + dy * steer * dt
        p:setForwardDirection(dx, dy)
    end
    local speed = canopy and HaloDrop.opt("CanopySpeed") or HaloDrop.opt("FreefallSpeed")

    if not J.released and J.alt - speed * dt > carryAltM() then
        -- 붙잡기: 가상 고도만 줄인다
        J.alt = J.alt - speed * dt
        hold(p, J.x, J.y, carryZ)
    else
        if not J.released then
            J.released = true
            log(string.format("release to engine fall at z=%.1f state=%s", p:getZ(), J.state))
        end
        -- 놓기: 엔진이 z 를 내린다. 수평 위치와 낙하 속도만 정한다.
        p:setForceX(J.x)
        p:setForceY(J.y)
        J.alt = p:getZ() * HaloDrop.M_PER_FLOOR
        local h = p:getHeightAboveFloor()
        if h <= 0.001 then
            land(p)
            return
        end
        local v = speed / HaloDrop.M_PER_FLOOR
        if h < HaloDrop.BRAKE_H and canopy then v = HaloDrop.LAND_SPEED end
        p:setLastFallSpeed(v)
    end

    local auto = HaloDrop.opt("AutoOpenAltitude")
    if J.state == "FREEFALL" and auto > 0 and J.alt <= auto then
        openChute(p, "auto")
    end
end
Events.OnPlayerUpdate.Add(onPlayerUpdate)

-- 상호작용 키: 탑승 중이면 뛰어내리기(수송기 출발 후), 자유낙하 중이면 낙하산
local function onKeyPressed(key)
    if not J.state or key ~= getCore():getKey("Interact") then return end
    local p = getPlayer()
    if not p then return end
    if J.state == "ABOARD" then
        local C = HaloDrop.C
        if C.fl and getTimestampMs() - C.t0 >= 0 then jump(p, "key") end
    elseif J.state == "FREEFALL" then
        openChute(p, "key")
    end
end
Events.OnKeyPressed.Add(onKeyPressed)

local function onPlayerDeath(p)
    if p == getPlayer() and J.state then
        log("died during state " .. tostring(J.state))
        finish(p)
        chuteUnwear(p, "death")
    end
end
Events.OnPlayerDeath.Add(onPlayerDeath)

-- 공중에서 접속이 끊겼다 다시 들어오면 낙하산이 남아 있을 수 있다 -> 서버에 회수 요청
local _cleanupDone = false
local function cleanupTick()
    if _cleanupDone then return end
    local p = getPlayer()
    if not p then return end
    _cleanupDone = true
    Events.OnTick.Remove(cleanupTick)
    if findChute(p) or #wornChutes(p) > 0 then
        log("leftover parachute found -> cleanup")
        chuteUnwear(p, "cleanup")
        send(p, "Cleanup", {})
    end
end
Events.OnTick.Add(cleanupTick)
