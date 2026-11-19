-- Blue Zone 서버: 라운드 상태, 원 선정, 자기장 밖 데미지
--
-- 상태 S (nil = 대기)
--   id, phase (1..N), seg ("wait" | "shrink" | "done")
--   segStart, segDur (ms), pausedAt (ms, 일시정지 중일 때만)
--   from = { x, y, r }  구간 시작 시점의 파란 원 (wait/delay/done 에서는 그대로 현재 파란 원)
--   white = { x, y, r } 이번 페이즈 목표. done 에서는 nil
-- 시작 파란 원 = 페이즈 1 흰 원과 같은 중심, 영역(Area)에서 가장 먼 모서리까지 닿는 반지름 (배그식: 처음엔 영역 전체가 안쪽).
--   페이즈 1 축소가 시작되면 그 원이 영역 가장자리부터 흰 원으로 줄어든다. 벽은 사람보다 훨씬 빠르고(시작 로그 wall speed)
--   대신 페이즈 1 데미지가 가장 약하다. 11-18~19 오전엔 흰 원의 2배였는데, 시작 때 파란 원이 안 보이고
--   축소 시작 순간 그 원 밖에 있던 사람이 예고 없이 데미지를 받아서 되돌렸다 (11-19 t3 결정)
-- 시간은 서버 getTimestampMs 기준. 클라에는 "구간 남은 ms" 로 보내고 클라가 자기 시계로 센다.
-- 데미지: 서버가 BodyDamage:ReduceGeneralHealth 후 sendDamage(player) 로 BodyDamage 전체를 클라에 보낸다
--   (바닐라 ISSmashWindow:complete 와 같은 방식, PlayerDamagePacket).

if isClient() then return end

require "BlueZoneConfig"

local B = BlueZone
local DAMAGE_INTERVAL_MS = 1000
local SYNC_INTERVAL_MS   = 10000   -- 상태 재방송·상태 로그 주기

local S = nil
local _seq = 0

local function log(msg) B.log(msg) end
local function nowMs() return getTimestampMs() end

local function players()
    local out = {}
    if isServer() then
        local list = getOnlinePlayers()
        for i = 0, list:size() - 1 do out[#out + 1] = list:get(i) end
    else
        local p = getPlayer()
        if p then out[1] = p end
    end
    return out
end

-- SP 에서는 sendServerCommand 가 동작하지 않으므로 클라 핸들러를 직접 부른다
local function toClients(cmd, args)
    if isServer() then
        sendServerCommand(B.MODULE, cmd, args)
    elseif B.onServerCommand then
        B.onServerCommand(B.MODULE, cmd, args)
    end
end

local function toPlayer(p, cmd, args)
    if isServer() then
        sendServerCommand(p, B.MODULE, cmd, args)
    elseif B.onServerCommand then
        B.onServerCommand(B.MODULE, cmd, args)
    end
end

-- ── 원 선정 ───────────────────────────────────────────────

local function area()
    return B.opt("AreaX1"), B.opt("AreaY1"), B.opt("AreaX2"), B.opt("AreaY2")
end

local function clamp(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi end
    return v
end

-- 빈 북서쪽 피하기 (샌드박스 AvoidEmptyNW). 흰 원(다음 안전 구역)이 바닐라 지도의 빈 땅에 잡히지 않게 다시 뽑는다.
-- 기준: 원 중심이 빈 지역 밖이고, 원 넓이의 EMPTY_MAX 미만이 빈 지역. PICK_TRIES 번 다 걸리면 빈 비율이 가장 낮은 후보를 쓴다.
local EMPTY_MAX, PICK_TRIES = 0.5, 40

local function emptyBad(c)
    return B.inEmptyNW(c.x, c.y) or B.emptyFraction(c.x, c.y, c.r) >= EMPTY_MAX
end

-- gen() 이 돌려주는 후보 원 중 빈 지역을 피한 것. what = 로그용 이름
local function pickAvoiding(what, gen)
    local c = gen()
    if not B.opt("AvoidEmptyNW") or not emptyBad(c) then return c end
    local best, bestFrac = c, B.emptyFraction(c.x, c.y, c.r)
    for i = 2, PICK_TRIES do
        c = gen()
        if not emptyBad(c) then
            log(string.format("%s: avoided empty north-west after %d tries -> (%.0f,%.0f r%.0f)", what, i, c.x, c.y, c.r))
            return c
        end
        local f = B.emptyFraction(c.x, c.y, c.r)
        if f < bestFrac then best, bestFrac = c, f end
    end
    log(string.format("%s: WARNING every try hit the empty north-west, using the least empty (%.0f,%.0f r%.0f, %.0f%% empty)",
        what, best.x, best.y, best.r, bestFrac * 100))
    return best
end

-- 페이즈 1 흰 원: 영역 안에 통째로 들어가는 원. hintX/hintY 가 있으면 그 점에 가장 가까운 자리, 없으면 무작위
-- 크기는 맵(영역) 기준: 지름 = 영역 짧은 변 x FirstSize (기본 0.71 = 기존 r1500 의 약 3배. 참고: 배그 에란겔 8km 맵에 첫 원 지름 4564.7m = 0.57)
local function pickFirst(hintX, hintY)
    local x1, y1, x2, y2 = area()
    local short = math.min(x2 - x1, y2 - y1)
    local r = short * B.opt("FirstSize") / 2
    log(string.format("first circle size: area short side %d x FirstSize %.2f -> r%.0f", short, B.opt("FirstSize"), r))
    if hintX and hintY then
        local cx, cy = clamp(hintX, x1 + r, x2 - r), clamp(hintY, y1 + r, y2 - r)
        log(string.format("first circle from center hint (%.0f,%.0f) -> (%.0f,%.0f)", hintX, hintY, cx, cy))
        local c = { x = cx, y = cy, r = r }
        if B.opt("AvoidEmptyNW") and emptyBad(c) then
            log(string.format("first circle from hint is %.0f%% empty north-west (hint kept)", B.emptyFraction(cx, cy, r) * 100))
        end
        return c
    end
    return pickAvoiding("first circle", function()
        return { x = ZombRandFloat(x1 + r, x2 - r), y = ZombRandFloat(y1 + r, y2 - r), r = r }
    end)
end

-- 시작 파란 원: 페이즈 1 흰 원과 같은 중심, 영역 네 모서리 중 가장 먼 곳까지 닿는 반지름 (영역 전체를 덮는다)
local function initialBlue(first)
    local x1, y1, x2, y2 = area()
    local dx = math.max(first.x - x1, x2 - first.x)
    local dy = math.max(first.y - y1, y2 - first.y)
    return { x = first.x, y = first.y, r = math.sqrt(dx * dx + dy * dy) }
end

-- 다음 흰 원: 이전 흰 원 안에 통째로 들어가는 무작위 원 (원판 위 균일 분포). 빈 북서쪽은 pickAvoiding 으로 피한다
local function pickNext(prev, ratio)
    local r = prev.r * ratio
    local maxOff = prev.r - r
    return pickAvoiding("next circle", function()
        local ang = ZombRandFloat(0, 2 * math.pi)
        local d = maxOff * math.sqrt(ZombRandFloat(0, 1))
        return { x = prev.x + math.cos(ang) * d, y = prev.y + math.sin(ang) * d, r = r }
    end)
end

-- ── 상태 ─────────────────────────────────────────────────

local function elapsedMs(now)
    local t = (S.pausedAt or now) - S.segStart
    if t < 0 then t = 0 end
    return t
end

local function remainMs(now)
    if S.seg == "done" then return 0 end
    local r = S.segDur - elapsedMs(now)
    if r < 0 then r = 0 end
    return r
end

local function snapshot(now)
    local w = S.white
    return {
        id = S.id, phase = S.phase, n = #B.PHASES, seg = S.seg,
        dur = S.segDur, remain = remainMs(now), paused = S.pausedAt ~= nil,
        fx = S.from.x, fy = S.from.y, fr = S.from.r,
        wx = w and w.x or 0, wy = w and w.y or 0, wr = w and w.r or -1,
        dps = B.dpsOf(S.phase),
    }
end

local function currentBlue(now)
    local st = { seg = S.seg, fx = S.from.x, fy = S.from.y, fr = S.from.r,
        wx = S.white and S.white.x or 0, wy = S.white and S.white.y or 0, wr = S.white and S.white.r or -1 }
    local frac = 0
    if S.segDur > 0 then frac = elapsedMs(now) / S.segDur end
    return B.blueAt(st, frac)
end

local function broadcast(now, why)
    toClients("State", snapshot(now))
    log(string.format("state sent (%s): round=%d phase=%d/%d seg=%s remain=%dms paused=%s blue=(%.0f,%.0f r%.0f) white=%s",
        why, S.id, S.phase, #B.PHASES, S.seg, remainMs(now), tostring(S.pausedAt ~= nil),
        S.from.x, S.from.y, S.from.r,
        S.white and string.format("(%.0f,%.0f r%.0f)", S.white.x, S.white.y, S.white.r) or "none"))
end

local function setSeg(now, seg, durSec)
    S.seg = seg
    S.segStart = now
    S.segDur = durSec and B.durMs(durSec, seg) or 0
    if S.pausedAt then S.pausedAt = now end
end

-- 구간 하나 진행 (시간이 다 됐거나 NextPhase)
local function advance(now, why)
    if S.seg == "wait" then
        setSeg(now, "shrink", B.PHASES[S.phase].shrink)
    elseif S.seg == "shrink" then
        S.from = S.white   -- 파란 원이 흰 원에 닿음
        S.white = nil
        local nextPhase = S.phase + 1
        if nextPhase > #B.PHASES then
            setSeg(now, "done", nil)
        else
            S.phase = nextPhase
            S.white = pickNext(S.from, B.PHASES[nextPhase].ratio)
            setSeg(now, "wait", B.PHASES[nextPhase].wait)
        end
    else
        return
    end
    broadcast(now, why)
end

local function startRound(by, hintX, hintY)
    _seq = _seq + 1
    local now = nowMs()
    local first = pickFirst(hintX, hintY)
    S = { id = _seq, phase = 1, from = initialBlue(first), white = first,
        nextDamage = now + DAMAGE_INTERVAL_MS, nextSync = now + SYNC_INTERVAL_MS, hurt = {}, lastPos = {} }
    setSeg(now, "wait", B.PHASES[1].wait)
    local x1, y1, x2, y2 = area()
    log(string.format("round %d started by %s: area=(%d,%d)-(%d,%d) waitScale=%.2f shrinkScale=%.2f damageScale=%.2f avoidEmptyNW=%s first=(%.0f,%.0f r%.0f) start blue r%.0f",
        S.id, tostring(by), x1, y1, x2, y2, B.opt("WaitScale"), B.opt("ShrinkScale"), B.opt("DamageScale"), tostring(B.opt("AvoidEmptyNW")),
        first.x, first.y, first.r, S.from.r))
    -- 페이즈 1 벽 속도(반지름 기준 타일/초). 영역 전체에서 줄어들어 사람보다 빠르다 -> 축소 시간 조정 판단용
    local shrinkSec = B.durMs(B.PHASES[1].shrink, "shrink") / 1000
    if shrinkSec > 0 then
        log(string.format("phase 1 wall speed: (r%.0f -> r%.0f) / %.0fs = %.1f tiles/s", S.from.r, first.r, shrinkSec, (S.from.r - first.r) / shrinkSec))
    end
    broadcast(now, "start")
end

local function stopRound(reason)
    if not S then return end
    log("round " .. tostring(S.id) .. " stopped (" .. tostring(reason) .. ")")
    toClients("Stopped", { id = S.id })
    S = nil
end

-- ── 데미지 ───────────────────────────────────────────────

-- 독가스 연출(Style 2) 전용: 방독면과 기침
-- 방독면(필터가 남은 방독면·방진 마스크·급조 방독면)은 배그 전파 방해 배낭처럼 데미지를 대신 받는다:
--   필터가 남아 있는 동안 체력 데미지·기침 없음, 받을 데미지만큼 필터가 준다 (꽉 찬 필터 = 체력 MaskFilterHealth 만큼).
--   필터 잔량은 바닐라 Clothing 의 usedDelta(0~1, 시체 악취 방어와 같은 값)를 그대로 쓴다.
-- 방독면이 없으면 COUGH_MIN~MAX ms 마다 기침 또는 신음. 재생은 클라가 한다(Cough 명령, BlueZoneClient.lua).
local GAS_STYLE = 2
local COUGH_MIN_MS, COUGH_MAX_MS = 4000, 8000
local MOAN_CHANCE = 35          -- % : 기침 대신 고통 신음
local MASK_SYNC_TICKS = 5       -- 필터 잔량을 클라에 보내는 주기(데미지 틱 수)

local function findMask(p)
    local worn = p:getWornItems()
    for i = 0, worn:size() - 1 do
        local it = worn:getItemByIndex(i)
        if it and instanceof(it, "Clothing") and it:hasFilter() and it:getUsedDelta() > 0 then return it end
    end
    return nil
end

local function maskAbsorb(p, mask, amount, key)
    local before = mask:getUsedDelta()
    local left = before - amount / B.opt("MaskFilterHealth")
    if left < 0 then left = 0 end
    mask:setUsedDelta(left)
    S.mask = S.mask or {}
    local m = S.mask[key]
    if not m then
        m = { ticks = 0 }
        S.mask[key] = m
        log(string.format("mask %s absorbing gas: %s filter %.3f", tostring(p:getUsername()), tostring(mask:getFullType()), before))
    end
    m.ticks = m.ticks + 1
    if left <= 0 then
        S.mask[key] = nil
        log(string.format("mask %s filter depleted (%s)", tostring(p:getUsername()), tostring(mask:getFullType())))
    end
    if isServer() and (left <= 0 or m.ticks % MASK_SYNC_TICKS == 0) then mask:syncItemFields() end
end

local function coughTick(p, now, key)
    S.cough = S.cough or {}
    local c = S.cough[key]
    if not c then
        c = { next = now + ZombRand(1000, 3000), count = 0 }   -- 가스에 들어가고 1~3초 뒤 첫 기침
        S.cough[key] = c
    end
    if now < c.next then return end
    c.next = now + ZombRand(COUGH_MIN_MS, COUGH_MAX_MS)
    c.count = c.count + 1
    local moan = ZombRand(100) < MOAN_CHANCE
    if c.count == 1 then log(string.format("cough %s first (%s)", tostring(p:getUsername()), moan and "moan" or "cough")) end
    toClients("Cough", { id = p:getOnlineID(), moan = moan })
end

local function damageTick(now)
    if not B.blueActive(S) then return end
    local dps = B.dpsOf(S.phase) * B.opt("DamageScale")
    if dps <= 0 then return end
    local cx, cy, r = currentBlue(now)
    local amount = dps * DAMAGE_INTERVAL_MS / 1000
    for _, p in ipairs(players()) do
        if not p:isDead() and not p:isGodMod() then
            local x, y = p:getX(), p:getY()
            local pkey = tostring(p:getOnlineID())
            local outside = not B.inExempt(x, y) and B.isOutside(x, y, cx, cy, r)
            local gas = B.opt("Style") == GAS_STYLE
            local mask = outside and gas and findMask(p) or nil
            if not outside then
                if S.cough then S.cough[pkey] = nil end
                if S.mask then S.mask[pkey] = nil end
            elseif mask then
                maskAbsorb(p, mask, amount, pkey)
                if S.cough then S.cough[pkey] = nil end
            else
                if gas then coughTick(p, now, pkey) end
                local bd = p:getBodyDamage()
                local before = bd:getOverallBodyHealth()
                bd:ReduceGeneralHealth(amount)
                if isServer() then sendDamage(p) end
                -- 페이즈마다 사람별 첫 피격만 남긴다 (매초 로그 방지). 이후 수치는 상태 로그에서 본다
                local key = tostring(p:getOnlineID()) .. ":" .. tostring(S.phase)
                if not S.hurt[key] then
                    S.hurt[key] = true
                    log(string.format("damage %s phase=%d amount=%.2f health %.1f -> %.1f at (%.0f,%.0f) blue=(%.0f,%.0f r%.0f)",
                        tostring(p:getUsername()), S.phase, amount, before, bd:getOverallBodyHealth(), x, y, cx, cy, r))
                end
            end
        end
    end
end

-- 사람별 이동 속도(타일/초, 직전 상태 로그 이후 직선거리). PZ 달리기 속도를 재서 축소 시간을 맞추는 용도
local function speedLog(now)
    local parts = {}
    for _, p in ipairs(players()) do
        if not p:isDead() then
            local key = tostring(p:getOnlineID())
            local x, y = p:getX(), p:getY()
            local last = S.lastPos[key]
            if last and now > last.t then
                local d = math.sqrt((x - last.x) * (x - last.x) + (y - last.y) * (y - last.y))
                parts[#parts + 1] = string.format("%s=%.2f%s", tostring(p:getUsername()), d * 1000 / (now - last.t),
                    p:getVehicle() and "(vehicle)" or "")
            end
            S.lastPos[key] = { x = x, y = y, t = now }
        end
    end
    if #parts > 0 then log("speed tiles/s (last interval): " .. table.concat(parts, " ")) end
end

local function statusLog(now)
    speedLog(now)
    local cx, cy, r = currentBlue(now)
    local outside = {}
    for _, p in ipairs(players()) do
        if not p:isDead() then
            local x, y = p:getX(), p:getY()
            if B.isOutside(x, y, cx, cy, r) and not B.inExempt(x, y) then
                outside[#outside + 1] = string.format("%s(hp%.0f%s)", tostring(p:getUsername()),
                    p:getBodyDamage():getOverallBodyHealth(), p:isGodMod() and ",god" or "")
            end
        end
    end
    log(string.format("status round=%d phase=%d seg=%s remain=%dms paused=%s blue=(%.0f,%.0f r%.0f) outside[%s]",
        S.id, S.phase, S.seg, remainMs(now), tostring(S.pausedAt ~= nil), cx, cy, r, table.concat(outside, " ")))
end

local function onTick()
    if not S then return end
    local now = nowMs()
    if S.pausedAt then return end
    if S.seg ~= "done" and now - S.segStart >= S.segDur then
        advance(now, "timer")
    end
    if now >= S.nextDamage then
        S.nextDamage = now + DAMAGE_INTERVAL_MS
        damageTick(now)
    end
    if now >= S.nextSync then
        S.nextSync = now + SYNC_INTERVAL_MS
        statusLog(now)
        toClients("State", snapshot(now))   -- 클라 시계 오차 보정용 재방송 (로그는 statusLog 로 대신)
    end
end
Events.OnTick.Add(onTick)

-- ── 명령 ─────────────────────────────────────────────────

local function isAdminPlayer(p)
    if not isServer() then return true end   -- SP
    return p:isAccessLevel("admin")
end

local ADMIN_ONLY = { Start = true, Pause = true, Resume = true, NextPhase = true, Stop = true }

local function onClientCommand(module, command, player, args)
    if module ~= B.MODULE then return end
    local who = tostring(player and player:getUsername())
    if ADMIN_ONLY[command] and not isAdminPlayer(player) then
        log(command .. " denied for " .. who)
        return
    end
    local now = nowMs()
    if command == "Start" then
        if S then
            log("Start ignored: round " .. tostring(S.id) .. " already running (send Stop first)")
            return
        end
        local hx, hy = tonumber(args and args.cx), tonumber(args and args.cy)
        startRound(who, hx, hy)
    elseif command == "Pause" then
        if not S or S.pausedAt then return end
        S.pausedAt = now
        log("paused by " .. who)
        broadcast(now, "pause")
    elseif command == "Resume" then
        if not S or not S.pausedAt then return end
        S.segStart = S.segStart + (now - S.pausedAt)
        S.pausedAt = nil
        S.nextDamage = now + DAMAGE_INTERVAL_MS
        log("resumed by " .. who)
        broadcast(now, "resume")
    elseif command == "NextPhase" then
        if not S or S.seg == "done" then return end
        -- 대기 -> 축소 시작, 축소 -> 흰 원에 붙이고 다음 대기 (구간 하나씩. 11-19: 예전엔 축소를 통째로 건너뛰어 점진 축소를 볼 수 없었다)
        log("next phase by " .. who .. " (from phase=" .. S.phase .. " seg=" .. S.seg .. ")")
        advance(now, "next phase")
    elseif command == "Stop" then
        stopRound("admin " .. who)
    elseif command == "Sync" then
        if S then toPlayer(player, "State", snapshot(now)) end
    end
end
Events.OnClientCommand.Add(onClientCommand)
