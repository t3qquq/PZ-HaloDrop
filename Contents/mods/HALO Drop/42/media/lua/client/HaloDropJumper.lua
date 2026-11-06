-- Halo Drop 점퍼: 자기 캐릭터의 탑승·자유낙하·낙하산·착지
--
-- 상태: nil -> ABOARD -> FREEFALL -> CANOPY -> nil(착지)
--   ABOARD    수송기 경로 위치에 붙잡는다 (실제 z = CarryZ). Flight 수신 즉시 A 로 옮겨진다.
--   FREEFALL  가상 고도를 수직 속도로 줄인다. 상호작용 키로 낙하산
--   CANOPY    낙하산. 수직·수평 속도가 캐노피 목표치로 서서히 수렴한다
-- 실제 z 처리 (HaloDropConfig.lua 고도 체계 참고)
--   붙잡기(hold): 가상 고도가 CarryZ 층보다 높은 동안. 매 틱 x, y, z 를 직접 정하고 낙하 속도를 0 으로 둔다.
--   놓기(release): 가상 고도가 CarryZ 층 아래로 내려오면 엔진 낙하(IsoGameCharacter.updateFalling)에
--     맡기고 낙하 속도만 매 틱 setLastFallSpeed 로 정한다. 바닥 BRAKE_H 층 위부터 LAND_SPEED 로 감속.
--     updateFalling 은 중력을 더하는 등가속도이고 착지 피해는 충돌 순간 속도로만 정한다.
-- 순서: IsoGameCharacter.update(updateFalling 포함)가 먼저 돌고 OnPlayerUpdate 가 뒤에 발화한다(IsoPlayer).
--   그래서 여기서 정한 위치가 그 틱의 렌더 위치가 되고, 낙하 속도는 다음 틱 updateFalling 에 쓰인다.
--
-- 강하 모델 (claude/PUBG_강하_메커니즘_조사.md 9.2 절, 방식 A)
--   heading(도): 몸이 향한 수평 방향. A/D 가 TurnRate(도/초)로 돌린다. 즉시 꺾이지 않는다.
--   pitch(-1~+1): W 를 누르면 +1 로, S 를 누르면 -1 로 PitchRate 속도로 기운다. 떼면 0 으로 돌아온다.
--   목표 속도: pitch 로 (무입력 <-> 활공/다이브/브레이크) 비율표(HaloDrop.FF / CP)를 보간한다.
--     W = 활공(앞으로 기울임, 수평 속도 생김), W + 달리기 키 = 다이브(수직 최대, 수평 0), S = 브레이크.
--   관성: v += (목표 - v) * min(1, Accel*dt). 낙하산을 펴도 속도를 리셋하지 않고 CanopyAccel 로 수렴시킨다
--     (배그 슬링샷: 펴진 직후 몇 초간 자유낙하 속도를 이어받는다).
--   수평 위치는 heading 방향 x 수평 속도로만 움직인다.
-- 안티치트: 차량 밖 캐릭터는 1초 평균 20 타일/초를 넘으면 위반이다(AntiCheatSpeed). 이 검사는 서버 ini
--   AntiCheatSpeed=4(Disabled) 로 끈 서버에서만 수송기 속도 20 초과·A 로의 순간 이동이 안전하다.
-- 낙하산 착용·해제는 여기(클라)서 한다. 서버는 아이템 지급(ChuteWear 지시)·회수만 한다 -- 착용 상태는
--   클라 setWornItem 이 SyncClothing 으로 서버에 올리므로 서버가 벗겨도 되살아난다(11-06 실측).
--   착지 뒤 CHUTE_GUARD_MS 동안 매 틱 착용 목록을 감시해 다시 생기면 즉시 벗긴다.

if isServer() then return end

require "HaloDropConfig"
require "HaloDropFlight"

HaloDropJumper = {}

local J = { state = nil }
HaloDrop.J = J

local CHUTE_GUARD_MS = 10000   -- 착지 뒤 낙하산 재착용 감시 시간

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

local function chuteWear(p)
    local item = findChute(p)
    if not item then return false end
    if p:getWornItems():getLocation(item) then return true end
    local ok, err = pcall(function() p:setWornItem(item:getBodyLocation(), item) end)
    log("chute wear ok=" .. tostring(ok) .. (ok and "" or (" err=" .. tostring(err))) .. " id=" .. tostring(item:getID()))
    -- 착용으로 모델이 다시 만들어진다 (낙하산 메시 로드 동안 캐릭터가 잠깐 안 보이는 건 엔진 쪽)
    return ok
end

-- removeWornItem 은 WornItems.setItem(loc, nil) 이라 multi-item 위치에선 아무것도 안 지운다
-- (11-06 실측, base:zeddmg). 지금은 단일 슬롯 base:tail 이지만, 그래도 남으면 WornItems:remove 로 직접 뺀다.
local function chuteUnwear(p, reason)
    local items = wornChutes(p)
    if #items == 0 then return 0 end
    local worn = p:getWornItems()
    for _, item in ipairs(items) do
        local ok, err = pcall(function() p:removeWornItem(item) end)
        local still = worn:contains(item)
        if still then
            pcall(function() worn:remove(item) end)
            still = worn:contains(item)
        end
        log("chute unwear (" .. tostring(reason) .. ") ok=" .. tostring(ok) .. (ok and "" or (" err=" .. tostring(err)))
            .. " id=" .. tostring(item:getID()) .. " inInventory=" .. tostring(item:getContainer() ~= nil)
            .. " stillWorn=" .. tostring(still))
    end
    p:resetModelNextFrame()
    return #items
end

-- 서버 ChuteWear 는 sendAddItemToContainer 보다 먼저 도착할 수 있다 -> 아이템이 보일 때까지 몇 틱 재시도
local _wearUntil = nil
function HaloDropJumper.onChuteWear()
    local p = getPlayer()
    if not p then return end
    if J.state ~= "CANOPY" then
        log("ChuteWear ignored: state=" .. tostring(J.state))
        return
    end
    if chuteWear(p) then return end
    _wearUntil = getTimestampMs() + 3000
    log("chute item not in inventory yet -> retrying up to 3s")
end

-- 서버 스윕이 지웠다고 알리면 클라 쪽 착용 목록도 다시 확인한다
function HaloDropJumper.onChuteTake(reason)
    local p = getPlayer()
    if not p then return end
    local n = chuteUnwear(p, "server " .. tostring(reason))
    log("ChuteTake from server (" .. tostring(reason) .. ") unworn=" .. tostring(n))
end

-- 착지 뒤 감시: 다시 착용돼 있으면 벗긴다 (누가 되살렸는지 OnClothingUpdated 로그로 추적)
local _guardUntil = nil
local function chuteGuardTick()
    local p = getPlayer()
    if not p then return end
    if _wearUntil then
        if J.state ~= "CANOPY" then
            _wearUntil = nil
        elseif chuteWear(p) then
            _wearUntil = nil
        elseif getTimestampMs() > _wearUntil then
            _wearUntil = nil
            log("chute wear FAILED: item never arrived")
        end
    end
    if _guardUntil then
        if getTimestampMs() > _guardUntil then
            _guardUntil = nil
            log("chute guard ended, worn=" .. tostring(#wornChutes(p)) .. " inventory=" .. tostring(findChute(p) ~= nil))
        else
            local n = chuteUnwear(p, "guard")
            if n > 0 then
                log("chute guard: parachute came back and was removed again (n=" .. tostring(n) .. ")")
                send(p, "Cleanup", {})
            end
        end
    end
end
Events.OnTick.Add(chuteGuardTick)

-- 착용 목록 동기화 패킷(SyncClothing)이 도착할 때마다 발화. 낙하산이 되살아나는 경로 추적용.
local function onClothingUpdated(chr)
    local p = getPlayer()
    if chr ~= p or not _guardUntil then return end
    log("OnClothingUpdated during guard: worn chutes=" .. tostring(#wornChutes(p)) .. " inventory=" .. tostring(findChute(p) ~= nil))
end
Events.OnClothingUpdated.Add(onClothingUpdated)

-- ── 위치 제어 ─────────────────────────────────────────────────────────────────
-- setForceX/Y = x, next, last 동시 설정 (IsoMovingObject). setZ 는 lastZ 도 같이 정하고 31 로 자른다.
-- 멀리 옮길 때(목적지 청크 미로드)는 먼저 removeFromSquare() 로 current/last 칸 참조를 끊어야 한다.
-- 안 끊으면 IsoMovingObject.postupdate 가 "현재 칸 없음 + last 있음" 을 보고 직전 칸 중앙으로 되돌린다
-- (11-06 실측: A 로 못 가고 리그 (19210.5,272.5) 에 붙박임). 바닐라 원격 플레이어 갱신과 같은 순서.
local FAR_JUMP = 32
local function hold(p, x, y, z)
    local dx, dy = x - p:getX(), y - p:getY()
    if dx * dx + dy * dy > FAR_JUMP * FAR_JUMP then
        log(string.format("far move (%.0f,%.0f) -> (%.0f,%.0f): removeFromSquare", p:getX(), p:getY(), x, y))
        pcall(function() p:removeFromSquare() end)
    end
    p:setForceX(x)
    p:setForceY(y)
    p:setZ(z)
    p:setLastFallSpeed(0)
end

local function keyDown(name)
    local ok, v = pcall(function() return isKeyDown(name) end)
    return ok and v or false
end

-- 각도 차이를 -180~180 으로
local function wrapDeg(a)
    while a > 180 do a = a - 360 end
    while a < -180 do a = a + 360 end
    return a
end

local function approach(v, target, rate, dt)
    local k = rate * dt
    if k > 1 then k = 1 end
    return v + (target - v) * k
end

-- 입력 -> 목표 (수직 m/s, 수평 타일/초). table 은 HaloDrop.FF 또는 HaloDrop.CP
local function targets(tbl, vBase, hBase, pitch, diving)
    local base = tbl.neutral
    local toward
    if pitch >= 0 then
        toward = diving and tbl.dive or tbl.glide
    else
        toward = tbl.brake
    end
    local f = math.abs(pitch)
    local v = base.v + (toward.v - base.v) * f
    local h = base.h + (toward.h - base.h) * f
    return v * vBase, h * hBase
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
    J.vz, J.vh = 0, 0
    planeSoundStart(p)
    log(string.format("board: from (%.1f,%.1f,%.1f) -> A=(%.0f,%.0f)", p:getX(), p:getY(), p:getZ(), HaloDrop.C.fl.ax, HaloDrop.C.fl.ay))
end

local function jump(p, reason)
    if J.state ~= "ABOARD" then return end
    J.state = "FREEFALL"
    J.x, J.y = p:getX(), p:getY()
    J.alt = HaloDrop.opt("JumpAltitude")
    J.heading = HaloDropFlight.headingDeg(HaloDrop.C.fl)
    J.pitch = 0
    -- 뛰어내린 순간 수송기 속도를 이어받는다 (수평), 수직은 0 에서 가속
    J.vh = HaloDrop.C.fl.speed
    J.vz = 0
    planeSoundStop(p)
    send(p, "Jumped", { id = HaloDrop.C.id, reason = reason })
    log(string.format("jump (%s) at (%.1f,%.1f) alt=%.0fm heading=%.0f", reason, J.x, J.y, J.alt, J.heading))
end

local function openChute(p, reason)
    if J.state ~= "FREEFALL" then return end
    J.state = "CANOPY"
    pcall(function() p:getEmitter():playSoundImpl("halodrop_chute", nil) end)
    if not J.chuteSent then
        J.chuteSent = true
        send(p, "ChuteOpen", { id = HaloDrop.C.id, reason = reason, alt = math.floor(J.alt) })
    end
    log(string.format("chute open (%s) alt=%.0fm vz=%.1f vh=%.1f", reason, J.alt, J.vz, J.vh))
end

local function land(p)
    local chute = J.state == "CANOPY"
    finish(p)
    chuteUnwear(p, "landed")
    _guardUntil = getTimestampMs() + CHUTE_GUARD_MS
    send(p, "Landed", { id = HaloDrop.C.id, chute = chute })
    log(string.format("landed at (%.1f,%.1f,%.1f) chute=%s vz=%.1f vh=%.1f", p:getX(), p:getY(), p:getZ(), tostring(chute), J.vz or 0, J.vh or 0))
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
        local ai, act, anim = "?", "?", "?"
        pcall(function() ai = tostring(p:getCurrentStateName()) end)
        pcall(function() act = tostring(p:getActionStateName()) end)
        pcall(function() anim = tostring(p:getAnimationStateName()) end)
        log(string.format("tick state=%s alt=%.0fm z=%.2f pos=(%.1f,%.1f) vz=%.1f vh=%.1f hdg=%.0f pitch=%.2f fall=%.2f h=%.2f released=%s falling=%s ai=%s action=%s anim=%s",
            tostring(J.state), J.alt or -1, p:getZ(), p:getX(), p:getY(), J.vz or 0, J.vh or 0, J.heading or 0, J.pitch or 0,
            p:getLastFallSpeed(), h, tostring(J.released), tostring(p:isFalling()), ai, act, anim))
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

    -- ── 강하 모델 ──
    local canopy = J.state == "CANOPY"
    local turnRate = canopy and HaloDrop.opt("CanopyTurnRate") or HaloDrop.opt("FreefallTurnRate")
    local accel = canopy and HaloDrop.opt("CanopyAccel") or HaloDrop.opt("FreefallAccel")
    local vBase = canopy and HaloDrop.opt("CanopySpeed") or HaloDrop.opt("FreefallSpeed")
    local hBase = canopy and HaloDrop.opt("CanopySteer") or HaloDrop.opt("FreefallSteer")
    local tbl = canopy and HaloDrop.CP or HaloDrop.FF

    -- 입력
    local turn = 0
    if keyDown("Left") then turn = turn - 1 end
    if keyDown("Right") then turn = turn + 1 end
    local pitchTarget = 0
    if keyDown("Forward") then pitchTarget = pitchTarget + 1 end
    if keyDown("Backward") then pitchTarget = pitchTarget - 1 end
    local diving = pitchTarget > 0 and keyDown("Run")

    -- heading: 선회 속도 한도 안에서만 돈다
    J.heading = J.heading + turn * turnRate * dt
    J.heading = wrapDeg(J.heading)
    -- pitch: 즉시 +-1 로 튀지 않고 PitchRate 로 기운다
    local pr = HaloDrop.opt("PitchRate") * dt
    if J.pitch < pitchTarget then J.pitch = math.min(pitchTarget, J.pitch + pr)
    elseif J.pitch > pitchTarget then J.pitch = math.max(pitchTarget, J.pitch - pr) end

    -- 목표 속도 -> 관성으로 수렴
    local tv, th = targets(tbl, vBase, hBase, J.pitch, diving)
    J.vz = approach(J.vz, tv, accel, dt)
    J.vh = approach(J.vh, th, accel, dt)

    -- 수평 이동은 heading 방향으로만
    local r = math.rad(J.heading)
    local hx, hy = math.cos(r), math.sin(r)
    if J.vh > 0.01 then
        J.x = J.x + hx * J.vh * dt
        J.y = J.y + hy * J.vh * dt
    end
    p:setForwardDirection(hx, hy)

    if not J.released and J.alt - J.vz * dt > carryAltM() then
        -- 붙잡기: 가상 고도만 줄인다
        J.alt = J.alt - J.vz * dt
        hold(p, J.x, J.y, carryZ)
    else
        if not J.released then
            J.released = true
            log(string.format("release to engine fall at z=%.1f state=%s vz=%.1f", p:getZ(), J.state, J.vz))
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
        local v = J.vz / HaloDrop.M_PER_FLOOR
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
