-- Halo Drop 서버: 라운드 상태, 수송기 차량, 낙하산 아이템
--
-- 라운드: IDLE(R=nil) -> 비행(R.ended=false) -> 종료(R.ended=true, 착지 대기) -> 정리(R=nil)
-- 권위 분리
--   서버: 라운드·탑승자 목록, 수송기 스폰·제거·물리 권한 이전, 낙하산 지급·회수
--   클라: 자기 캐릭터의 위치·고도·낙하 속도 (HaloDropJumper.lua), 파일럿 클라의 차량 이동 (HaloDropPilot.lua)
-- 경로: 비행 박스(샌드박스 WorldX1~Y2, 타일) 를 가로지르는 무작위 직선. A/B 는 박스 둘레 위의 점이다
--   (배그처럼 맵 한쪽 끝에서 반대쪽으로). 탑승자는 제자리(리그)에 숨은 채 대기하고, 비행 위치는 숫자로만
--   돈다 (설계 B, 11-06: 클라 청크 스트리밍이 비행 속도를 못 따라와 경로를 따라 끌고 다니는 방식 폐기).
-- 수송기 차량은 점프 순간에만 존재한다: 클라 Jumped(x,y) -> 그 칸의 청크가 서버에 올라오면
--   addVehicleDebug -> authorizationChanged(그 플레이어) -> JumpPlane -> 그 클라가 몇 초 끌고 지나간 뒤
--   PlaneDone -> permanentlyRemove. 서버 setWorldTransform 은 Bullet 이동을 하지 않는다.
--   [소스 42.20.2] addVehicleDebug 는 IsoChunk.doSpawnedVehiclesInInvalidPosition 이 false 면 차량을
--   월드에 넣지 않고 객체만 돌려준다(실내 칸 = 차량존 없고 isOutside 아님, 또는 다른 차량과 겹침).
--   그 경우 addToWorld -> createPhysics 가 안 돌아 getId() 가 영원히 -1 이다 (11-06 실측: 리그 z0 칸).
--   그래서 청크가 로드된 뒤 실외 칸을 골라 스폰하고, id 가 -1 이면 다른 칸으로 재시도한다.
-- 낙하산 착용·해제는 클라가 한다. B42 에서 착용 상태는 클라가 SyncClothing 으로 서버에 올리므로
--   서버가 removeWornItem 해도 다음 동기화에서 되살아난다(11-06 실측). 서버는 인벤토리 아이템
--   지급·회수만 맡되, 착지 뒤 몇 초간 다시 생겼는지 스윕해서 지운다.

if isClient() then return end

require "HaloDropConfig"
require "HaloDropFlight"

local CLOSE_AFTER_END_MS = 120000   -- 경로 끝 이후 착지 보고를 기다리는 시간
local STATUS_INTERVAL_MS = 5000     -- 상태 로그 주기
local SPAWN_SEARCH_R     = 8        -- 점프 지점 주변에서 실외 칸을 찾는 반경(칸)
local CHUTE_SWEEP_MS     = { 1500, 4000, 8000 }   -- 착지 뒤 낙하산 재확인 시점

local R = nil
local _roundSeq = 0
local _nextStatus = 0
local _chuteSweeps = {}   -- [key] = { p = IsoPlayer, at = { ms... } }

local function log(msg) HaloDrop.log(msg) end
local function nowMs() return getTimestampMs() end

-- 서버면 접속자 전원, SP 면 로컬 플레이어 하나
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

local function findPlayer(key)
    for _, p in ipairs(players()) do
        if HaloDrop.playerKey(p) == key then return p end
    end
    return nil
end

-- SP 에서는 sendServerCommand 가 동작하지 않으므로 클라 핸들러를 직접 부른다
local function toClients(cmd, args)
    if isServer() then
        sendServerCommand(HaloDrop.MODULE, cmd, args)
    elseif HaloDrop.onServerCommand then
        HaloDrop.onServerCommand(HaloDrop.MODULE, cmd, args)
    end
end

-- 특정 플레이어에게만. SP 는 접속자가 하나라 방송과 같다
local function toPlayer(p, cmd, args)
    if isServer() then
        sendServerCommand(p, HaloDrop.MODULE, cmd, args)
    elseif HaloDrop.onServerCommand then
        HaloDrop.onServerCommand(HaloDrop.MODULE, cmd, args)
    end
end

local function aboardKeys()
    local keys = {}
    for k, m in pairs(R.members) do
        if m.aboard then keys[#keys + 1] = k end
    end
    return keys
end

local function flightArgs()
    return {
        id = R.id,
        ax = R.fl.ax, ay = R.fl.ay, bx = R.fl.bx, by = R.fl.by,
        speed = R.fl.speed, dur = R.fl.durMs,
        elapsed = nowMs() - R.startAt,
        members = aboardKeys(),
    }
end

-- ── 낙하산 아이템 ─────────────────────────────────────────────────────────────
-- 인벤토리에서 찾는다(착용 목록이 아니라). 클라가 벗은 뒤에도 인벤토리엔 남아 있다.
local function findChute(p)
    local inv = p:getInventory()
    if not inv then return nil end
    return inv:getFirstTypeRecurse(HaloDrop.CHUTE_ITEM)
end

-- 착용 목록에 남은 낙하산 (인벤토리에 없어도 착용 목록에만 있을 수 있다: SyncClothing 이 만든 사본)
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

-- 지급: 인벤토리 추가 -> 클라에 아이템 전송 -> 클라에 착용 지시(ChuteWear)
local function chuteGive(p)
    local item = findChute(p)
    if not item then
        item = instanceItem(HaloDrop.CHUTE_ITEM)
        if not item then
            log("chute give FAILED: no item script " .. HaloDrop.CHUTE_ITEM)
            return
        end
        local inv = p:getInventory()
        inv:AddItem(item)
        sendAddItemToContainer(inv, item)
        log("chute given to " .. tostring(p:getUsername()) .. " id=" .. tostring(item:getID()))
    else
        log("chute already in inventory of " .. tostring(p:getUsername()) .. " -> wear only")
    end
    toPlayer(p, "ChuteWear", { id = R and R.id or 0 })
end

-- 회수: 착용 목록·인벤토리 양쪽에서 전부 지운다. 지운 게 있으면 true.
local function chuteTake(p, reason)
    local removed = 0
    local worn = p:getWornItems()
    for _, item in ipairs(wornChutes(p)) do
        -- removeWornItem 은 multi-item 위치에선 no-op 이라(11-06 실측) 남으면 WornItems:remove 로 직접 뺀다
        pcall(function() p:removeWornItem(item) end)
        if worn:contains(item) then pcall(function() worn:remove(item) end) end
        removed = removed + 1
    end
    local item = findChute(p)
    while item do
        local inv = item:getContainer() or p:getInventory()
        inv:Remove(item)
        sendRemoveItemFromContainer(inv, item)
        removed = removed + 1
        item = findChute(p)
    end
    if removed > 0 then
        log("chute removed from " .. tostring(p:getUsername()) .. " (" .. tostring(reason) .. ") n=" .. tostring(removed))
    end
    return removed > 0
end

-- 착지 뒤 몇 초간 다시 생기는지 재확인 (SyncClothing 중계가 되살릴 수 있다)
local function chuteScheduleSweeps(p)
    local at = {}
    local now = nowMs()
    for i, d in ipairs(CHUTE_SWEEP_MS) do at[i] = now + d end
    _chuteSweeps[HaloDrop.playerKey(p)] = { p = p, at = at }
end

local function chuteSweepTick()
    local now = nowMs()
    for key, s in pairs(_chuteSweeps) do
        local remaining = {}
        for _, t in ipairs(s.at) do
            if now >= t then
                local p = findPlayer(key)
                if p then
                    local worn = #wornChutes(p)
                    local inInv = findChute(p) ~= nil
                    if worn > 0 or inInv then
                        log(string.format("chute sweep: %s still has chute (worn=%d inventory=%s) -> removing again",
                            tostring(p:getUsername()), worn, tostring(inInv)))
                        chuteTake(p, "sweep")
                        toPlayer(p, "ChuteTake", { reason = "sweep" })
                    end
                end
            else
                remaining[#remaining + 1] = t
            end
        end
        if #remaining == 0 then _chuteSweeps[key] = nil else s.at = remaining end
    end
end

-- ── 점프 수송기 ───────────────────────────────────────────────────────────────
-- R.jumps[key] = { x, y, p, pending, deadline, tried, reason, vehicle, vid, spawnedAt }
local function jumpPlaneRemove(key, reason)
    local j = R and R.jumps[key]
    if not j then return end
    if j.vehicle then
        local ok, err = pcall(function() j.vehicle:permanentlyRemove() end)
        log("jump plane removed vid=" .. tostring(j.vid) .. " ok=" .. tostring(ok)
            .. (ok and "" or (" err=" .. tostring(err))) .. " (" .. tostring(reason) .. ")")
        if j.p then toPlayer(j.p, "PlaneGone", { id = R.id, vid = j.vid }) end
    elseif j.pending then
        log("jump plane for " .. tostring(key) .. " cancelled while pending (" .. tostring(reason) .. ")")
    end
    R.jumps[key] = nil
end

local function jumpPlanesRemoveAll(reason)
    if not R then return end
    for key, _ in pairs(R.jumps) do jumpPlaneRemove(key, reason) end
end

-- (cx, cy) 주변에서 차량을 놓을 수 있는 실외 칸을 찾는다. 청크가 안 올라와 있으면 nil.
-- tried[x..","..y] 는 이미 실패한 칸.
local function findSpawnSquare(cx, cy, tried)
    local center = getSquare(cx, cy, 0)
    if not center then return nil, "square not loaded" end
    for r = 0, SPAWN_SEARCH_R do
        for dy = -r, r do
            for dx = -r, r do
                if math.abs(dx) == r or math.abs(dy) == r then
                    local x, y = cx + dx, cy + dy
                    if not tried[x .. "," .. y] then
                        local sq = getSquare(x, y, 0)
                        if sq and sq:isOutside() and not sq:isVehicleIntersecting() then
                            return sq
                        end
                    end
                end
            end
        end
    end
    return nil, "no outside square within r=" .. SPAWN_SEARCH_R
end

-- 매 틱: 점프 지점 청크가 로드되면 실외 칸에 스폰해 그 플레이어에게 권한을 넘긴다.
-- id 가 -1 이면(월드에 안 들어감) 그 칸을 제외하고 재시도. 수명이 지나면 지운다.
local function jumpPlanesTick()
    if not R then return end
    local now = nowMs()
    for key, j in pairs(R.jumps) do
        if j.pending then
            if now > j.deadline then
                j.pending = false
                log("jump plane spawn FAILED for " .. tostring(key) .. ": timeout (" .. tostring(j.reason) .. ")")
                R.jumps[key] = nil
            else
                local sq, why = findSpawnSquare(j.x, j.y, j.tried)
                if not sq then
                    j.reason = why
                else
                    local ok, v = pcall(function() return addVehicleDebug(HaloDrop.PLANE_SCRIPT, IsoDirections.N, 0, sq) end)
                    if not ok or not v then
                        j.pending = false
                        log("jump plane spawn FAILED for " .. tostring(key) .. " err=" .. tostring(v))
                        R.jumps[key] = nil
                    else
                        local id = -1
                        pcall(function() id = v:getId() end)
                        if not id or id < 0 then
                            j.tried[sq:getX() .. "," .. sq:getY()] = true
                            j.reason = "rejected at (" .. tostring(sq:getX()) .. "," .. tostring(sq:getY()) .. ")"
                            log("jump plane spawn rejected at (" .. tostring(sq:getX()) .. "," .. tostring(sq:getY()) .. ") id=-1, retrying another square")
                            pcall(function() v:permanentlyRemove() end)
                        else
                            j.vehicle, j.vid, j.pending, j.spawnedAt = v, id, false, now
                            log(string.format("jump plane spawned vid=%d at (%d,%d) for %s after %dms", id, sq:getX(), sq:getY(), tostring(key), now - j.askedAt))
                            if j.p then
                                local okA, err = pcall(function() v:authorizationChanged(j.p) end)
                                if not okA then log("jump plane authorization FAILED err=" .. tostring(err)) end
                                toPlayer(j.p, "JumpPlane", { id = R.id, vid = id, x = j.x, y = j.y })
                            end
                        end
                    end
                end
            end
        elseif j.vehicle and now - j.spawnedAt > HaloDrop.JUMP_PLANE_MAX_MS + 5000 then
            jumpPlaneRemove(key, "lifetime")
        end
    end
end

-- ── 탑승 구역 ─────────────────────────────────────────────────────────────────
-- 샌드박스 ZoneX1~ZoneX2, ZoneY1~ZoneY2 (월드 타일 좌표, 양끝 포함). X2 > X1 이고 Y2 > Y1 일 때만 켜진다.
-- 기본값 0 은 꺼짐 = 접속자 전원 탑승. 높이(z)는 보지 않는다 (오일리그는 여러 층).
local function boardingZone()
    local x1, y1 = HaloDrop.opt("ZoneX1"), HaloDrop.opt("ZoneY1")
    local x2, y2 = HaloDrop.opt("ZoneX2"), HaloDrop.opt("ZoneY2")
    if x2 > x1 and y2 > y1 then
        return { x1 = x1, y1 = y1, x2 = x2, y2 = y2 }
    end
    if x1 ~= 0 or y1 ~= 0 or x2 ~= 0 or y2 ~= 0 then
        log(string.format("boarding zone invalid (%d,%d)-(%d,%d): need X2>X1 and Y2>Y1, filter OFF", x1, y1, x2, y2))
    end
    return nil
end

local function inZone(zone, p)
    local x, y = math.floor(p:getX()), math.floor(p:getY())
    return x >= zone.x1 and x <= zone.x2 and y >= zone.y1 and y <= zone.y2
end

-- ── 경로 선정 ─────────────────────────────────────────────────────────────────
-- 비행 박스(WorldX1~Y2) 를 가로지르는 무작위 직선. 박스 가운데 60% 안의 점 P 를 지나는 무작위 각도의
-- 직선을 박스 테두리로 잘라 A(진입)·B(진출)로 쓴다. 길이가 박스 짧은 변의 절반보다 짧으면 다시 뽑는다.
local PATH_TRIES = 48   -- AvoidEmptyNW 거부분까지 감안해 16 -> 48

local function flightBox()
    local x1, y1 = HaloDrop.opt("WorldX1"), HaloDrop.opt("WorldY1")
    local x2, y2 = HaloDrop.opt("WorldX2"), HaloDrop.opt("WorldY2")
    if x2 - x1 < 300 or y2 - y1 < 300 then
        log(string.format("flight box invalid (%d,%d)-(%d,%d): need at least 300x300, using 5000x5000 around (0,0)+", x1, y1, x2, y2))
        return { x1 = 0, y1 = 0, x2 = 5000, y2 = 5000 }
    end
    return { x1 = x1, y1 = y1, x2 = x2, y2 = y2 }
end

-- 점 P 를 지나 방향 (dx, dy) 인 직선과 박스의 교점 두 개 (t 가 작은 쪽이 A)
local function clipLine(box, px, py, dx, dy)
    local tmin, tmax = -1e9, 1e9
    if math.abs(dx) > 1e-6 then
        local t1, t2 = (box.x1 - px) / dx, (box.x2 - px) / dx
        if t1 > t2 then t1, t2 = t2, t1 end
        if t1 > tmin then tmin = t1 end
        if t2 < tmax then tmax = t2 end
    end
    if math.abs(dy) > 1e-6 then
        local t1, t2 = (box.y1 - py) / dy, (box.y2 - py) / dy
        if t1 > t2 then t1, t2 = t2, t1 end
        if t1 > tmin then tmin = t1 end
        if t2 < tmax then tmax = t2 end
    end
    return px + dx * tmin, py + dy * tmin, px + dx * tmax, py + dy * tmax
end

-- 바닐라 B42 지도의 빈 북서쪽 (샌드박스 AvoidEmptyNW). 셀 = 256칸. 노란 영역:
--   x < 45 이고 y < 18 인 직사각형 + x 45~58 에서 (45,3)-(58,0) 선 위쪽 삼각형 (t3 지도 캡처 11-08)
local CELL = 256
local function inEmptyNW(x, y)
    local cx, cy = x / CELL, y / CELL
    if cx < 45 and cy < 18 then return true end
    if cx >= 45 and cx <= 58 and cy < 3 - 3 * (cx - 45) / 13 then return true end
    return false
end

-- A→B 를 128칸 간격으로 훑어 빈 지역을 지나는지
local function crossesEmptyNW(ax, ay, bx, by)
    local len = math.sqrt((bx - ax) ^ 2 + (by - ay) ^ 2)
    local n = math.max(1, math.ceil(len / 128))
    for i = 0, n do
        local t = i / n
        if inEmptyNW(ax + (bx - ax) * t, ay + (by - ay) * t) then return true end
    end
    return false
end

local function pickFlight(speed)
    local box = flightBox()
    local w, h = box.x2 - box.x1, box.y2 - box.y1
    local minLen = math.min(w, h) * 0.5
    local avoid = HaloDrop.opt("AvoidEmptyNW")
    local best, rejected = nil, 0
    for _ = 1, PATH_TRIES do
        local px = box.x1 + w * (0.2 + ZombRand(600) / 1000)
        local py = box.y1 + h * (0.2 + ZombRand(600) / 1000)
        local r = math.rad(ZombRand(360))
        local ax, ay, bx, by = clipLine(box, px, py, math.cos(r), math.sin(r))
        local fl = HaloDropFlight.makeAB(ax, ay, bx, by, speed)
        if avoid and crossesEmptyNW(ax, ay, bx, by) then
            rejected = rejected + 1
            -- 빈 지역을 지나는 경로는 길이와 무관하게 후보에서 뺀다. 전부 걸리면 마지막 것이라도 쓴다
            if not best then best = fl; best.emptyNW = true end
        else
            if not best or best.emptyNW or fl.length > best.length then best = fl; best.emptyNW = nil end
            if fl.length >= minLen then break end
        end
    end
    if rejected > 0 then
        log(string.format("flight path: %d candidate(s) rejected for crossing empty NW%s", rejected,
            best.emptyNW and " -- ALL rejected, using one anyway" or ""))
    end
    return best, box
end

-- ── 라운드 ────────────────────────────────────────────────────────────────────
local function startRound(starter)
    if R then
        log("start ignored: round " .. tostring(R.id) .. " still open")
        return
    end
    local speed = HaloDrop.opt("PlaneSpeed")
    local zone = boardingZone()
    local fl, box = pickFlight(speed)
    _roundSeq = _roundSeq + 1
    R = {
        id = _roundSeq,
        fl = fl,
        startAt = nowMs() + HaloDrop.PREP_MS,
        members = {},
        jumps = {},
        ended = false,
    }
    if HaloDropPreload then HaloDropPreload.reset() end
    local n = 0
    local outside = {}
    for _, p in ipairs(players()) do
        -- 차에 탄 사람은 붙잡기가 차량 좌석과 충돌하므로 뺀다
        if not p:isDead() and not p:getVehicle() then
            if zone and not inZone(zone, p) then
                outside[#outside + 1] = string.format("%s(%.0f,%.0f)", tostring(p:getUsername()), p:getX(), p:getY())
            else
                R.members[HaloDrop.playerKey(p)] = { aboard = true, landed = false, name = p:getUsername() }
                n = n + 1
            end
        end
    end
    if zone then
        log(string.format("round %d boarding zone (%d,%d)-(%d,%d) starterInZone=%s outside=%d [%s]",
            R.id, zone.x1, zone.y1, zone.x2, zone.y2, tostring(inZone(zone, starter)), #outside, table.concat(outside, " ")))
        if n == 0 then log("round " .. tostring(R.id) .. " WARNING: nobody inside boarding zone") end
    end
    log(string.format("round %d start by %s: box (%d,%d)-(%d,%d) A=(%.0f,%.0f) B=(%.0f,%.0f) len=%.0f speed=%.1f dur=%dms members=%d",
        R.id, tostring(starter:getUsername()), box.x1, box.y1, box.x2, box.y2,
        R.fl.ax, R.fl.ay, R.fl.bx, R.fl.by, R.fl.length, speed, R.fl.durMs, n))
    -- 수송기 차량은 각자 점프하는 순간 그 자리에 띄운다 (jumpPlanesTick)
    toClients("Flight", flightArgs())
end

local function endRound(reason)
    if not R or R.ended then return end
    R.ended = true
    R.closeAt = nowMs() + CLOSE_AFTER_END_MS
    log("round " .. tostring(R.id) .. " end (" .. tostring(reason) .. ")")
    toClients("End", { id = R.id })   -- 아직 탑승 중인 클라는 강제로 뛰어내린다 (각자 JUMPING -> 점프 수송기 요청)
end

local function closeRound(reason)
    if not R then return end
    for k, m in pairs(R.members) do
        local p = findPlayer(k)
        if p then chuteTake(p, "round close") end
    end
    jumpPlanesRemoveAll("round close")
    log("round " .. tostring(R.id) .. " closed (" .. tostring(reason) .. ")")
    toClients("Closed", { id = R.id })
    R = nil
end

local function allLanded()
    for _, m in pairs(R.members) do
        if not m.landed then return false end
    end
    return true
end

local function onTick()
    chuteSweepTick()
    if not R then return end
    local now = nowMs()
    jumpPlanesTick()
    -- 서버 셀 미리 올리기 (HaloDropPreload.lua, 자바 에이전트가 있을 때만 동작)
    if HaloDropPreload then HaloDropPreload.tick(R, now, findPlayer) end
    if not R.ended and now - R.startAt > R.fl.durMs then
        endRound("path end")
    end
    if R.ended and (allLanded() or now > R.closeAt) then
        closeRound(allLanded() and "all landed" or "timeout")
        return
    end
    if now >= _nextStatus then
        _nextStatus = now + STATUS_INTERVAL_MS
        local parts = {}
        for k, m in pairs(R.members) do
            parts[#parts + 1] = tostring(m.name) .. "=" .. (m.landed and "landed" or (m.aboard and "aboard" or "air"))
        end
        local jp = {}
        for k, j in pairs(R.jumps) do
            jp[#jp + 1] = tostring(k) .. "=" .. (j.pending and ("pending:" .. tostring(j.reason)) or ("vid" .. tostring(j.vid)))
        end
        log(string.format("status round=%d frac=%.3f ended=%s members[%s] jumps[%s]",
            R.id, (now - R.startAt) / R.fl.durMs, tostring(R.ended), table.concat(parts, " "), table.concat(jp, " ")))
    end
end
Events.OnTick.Add(onTick)

local function isAdminPlayer(p)
    if not isServer() then return true end
    return p:isAccessLevel("admin")
end

local function onClientCommand(module, command, player, args)
    if module ~= HaloDrop.MODULE then return end
    local key = HaloDrop.playerKey(player)
    if command == "Start" then
        if not isAdminPlayer(player) then
            log("Start denied for " .. tostring(player:getUsername()))
            return
        end
        startRound(player)
    elseif command == "Stop" then
        if not isAdminPlayer(player) then
            log("Stop denied for " .. tostring(player:getUsername()))
            return
        end
        if R and R.ended then
            closeRound("admin stop")
        else
            endRound("admin stop")
        end
    elseif command == "Jumped" then
        if not R or args.id ~= R.id then return end
        local m = R.members[key]
        if not m or not m.aboard then return end
        m.aboard = false
        local jx, jy = math.floor(args.x or player:getX()), math.floor(args.y or player:getY())
        log(string.format("jump %s (%s) at frac=%.2f route=(%d,%d) player=(%.0f,%.0f)",
            tostring(m.name), tostring(args.reason), (nowMs() - R.startAt) / R.fl.durMs, jx, jy, player:getX(), player:getY()))
        toClients("Member", { id = R.id, key = key, aboard = false })
        -- 점프 수송기: 그 칸 청크가 서버에 올라오면 띄운다 (jumpPlanesTick)
        jumpPlaneRemove(key, "re-jump")
        R.jumps[key] = { x = jx, y = jy, p = player, pending = true, askedAt = nowMs(),
            deadline = nowMs() + HaloDrop.opt("JumpWaitMax") * 1000, tried = {}, reason = "waiting for chunk" }
    elseif command == "PlaneDone" then
        if not R or args.id ~= R.id then return end
        jumpPlaneRemove(key, "client done")
    elseif command == "ChuteOpen" then
        if not R or args.id ~= R.id then return end
        log("chute open " .. tostring(player:getUsername()) .. " (" .. tostring(args.reason) .. ") alt=" .. tostring(args.alt))
        chuteGive(player)
    elseif command == "Landed" then
        log(string.format("landed %s at (%.0f,%.0f,%.1f) chute=%s",
            tostring(player:getUsername()), player:getX(), player:getY(), player:getZ(), tostring(args.chute)))
        if R and args.id == R.id then jumpPlaneRemove(key, "landed") end
        chuteTake(player, "landed")
        chuteScheduleSweeps(player)
        if R and args.id == R.id and R.members[key] then
            R.members[key].landed = true
            R.members[key].aboard = false
        end
    elseif command == "Blocked" then
        -- 강하 중 클라가 다음 칸이 없어 수평 이동을 멈췄다. 같은 칸이 서버에 있는지 본다.
        -- 서버 getCell():getGridSquare 는 ServerMap 을 읽는다(IsoCell.getGridSquare: GameServer.server 분기).
        local x, y = tonumber(args and args.x), tonumber(args and args.y)
        if not x or not y then return end
        local sq = getCell():getGridSquare(x, y, 0) ~= nil
        local cell = "n/a"
        if HaloDropNative and HaloDropNative.state then
            local st = HaloDropNative.state(x, y)
            cell = (st == 1 and "loaded") or (st == 2 and "loading") or (st == 0 and "not-requested") or (st == -1 and "outside-map") or ("error" .. tostring(st))
        end
        log(string.format("blocked diag %s next=(%d,%d) player=(%s,%s) for %sms: serverSquare=%s serverCell=%s -> %s",
            tostring(player:getUsername()), x, y, tostring(args.px), tostring(args.py), tostring(args.ms),
            tostring(sq), cell, sq and "SERVER HAS IT (transfer / client side)" or "SERVER NOT LOADED (server side)"))
    elseif command == "Pose" then
        -- 강하 자세 중계: 애니메이션 변수는 네트워크로 안 가므로 전 클라가 그 플레이어에게 직접 세운다
        local pose = args and args.pose or ""
        log("pose " .. tostring(player:getUsername()) .. " -> '" .. tostring(pose) .. "'")
        toClients("Pose", { oid = player:getOnlineID(), pose = pose })
    elseif command == "Cleanup" then
        chuteTake(player, "client cleanup")
    end
end
Events.OnClientCommand.Add(onClientCommand)

-- 공중에서 죽으면 낙하산이 시체에 남지 않게 사망 처리(becomeCorpse) 전에 회수한다
local function onCharacterDeath(chr)
    if not instanceof(chr, "IsoPlayer") then return end
    chuteTake(chr, "death")
    if R then
        local k = HaloDrop.playerKey(chr)
        local m = R.members[k]
        if m then
            m.aboard = false
            m.landed = true
        end
        jumpPlaneRemove(k, "death")
    end
end
Events.OnCharacterDeath.Add(onCharacterDeath)
