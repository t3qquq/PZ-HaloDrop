-- Halo Drop 서버: 라운드 상태, 수송기 차량, 낙하산 아이템
--
-- 라운드: IDLE(R=nil) -> 비행(R.ended=false) -> 종료(R.ended=true, 착지 대기) -> 정리(R=nil)
-- 권위 분리
--   서버: 라운드·탑승자 목록, 수송기 스폰·제거·물리 권한 이전, 낙하산 지급·회수
--   클라: 자기 캐릭터의 위치·고도·낙하 속도 (HaloDropJumper.lua), 파일럿 클라의 차량 이동 (HaloDropPilot.lua)
-- 수송기 차량은 퐁듀 좀비 공습 투하와 같은 방식이다: addVehicleDebug -> authorizationChanged(파일럿)
--   -> 파일럿 클라가 매 틱 setWorldTransform. 서버 setWorldTransform 은 Bullet 이동을 하지 않는다.
--   addVehicleDebug 직후엔 getId() 가 -1 일 수 있다(11-06 실측, 라운드 1) -> 틱마다 폴링해 붙으면 Pilot 재방송.
-- 낙하산 착용·해제는 클라가 한다. B42 에서 착용 상태는 클라가 SyncClothing 으로 서버에 올리므로
--   서버가 removeWornItem 해도 다음 동기화에서 되살아난다(11-06 실측: 착지 후 회수했는데 라운드 종료 때
--   또 발견, 다음 라운드에 새로 지급되지 않음). 서버는 인벤토리 아이템 지급·회수만 맡는다.

if isClient() then return end

require "HaloDropConfig"
require "HaloDropFlight"

local CLOSE_AFTER_END_MS = 120000   -- 경로 끝 이후 착지 보고를 기다리는 시간
local CHECK_INTERVAL_MS  = 1000     -- 파일럿 접속 확인 주기
local STATUS_INTERVAL_MS = 5000     -- 상태 로그 주기

local R = nil
local _roundSeq = 0
local _nextCheck = 0
local _nextStatus = 0

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
        pilot = R.pilotKey,
        vid = R.vid,
    }
end

-- ── 낙하산 아이템 ─────────────────────────────────────────────────────────────
-- 인벤토리에서 찾는다(착용 목록이 아니라). 클라가 벗은 뒤에도 인벤토리엔 남아 있다.
local function findChute(p)
    local inv = p:getInventory()
    if not inv then return nil end
    return inv:getFirstTypeRecurse(HaloDrop.CHUTE_ITEM)
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
        log("chute given to " .. tostring(p:getUsername()))
    else
        log("chute already in inventory of " .. tostring(p:getUsername()) .. " -> wear only")
    end
    toPlayer(p, "ChuteWear", { id = R and R.id or 0 })
end

-- 회수: 클라가 먼저 벗었다는 전제(Landed/Cleanup 은 클라가 벗은 뒤 보낸다). 혹시 남은 착용은 같이 푼다
local function chuteTake(p, reason)
    local item = findChute(p)
    if not item then return end
    local wornLoc = p:getWornItems():getLocation(item)
    if wornLoc then pcall(function() p:removeWornItem(item) end) end
    local inv = item:getContainer() or p:getInventory()
    inv:Remove(item)
    sendRemoveItemFromContainer(inv, item)
    local left = findChute(p)
    log("chute removed from " .. tostring(p:getUsername()) .. " (" .. tostring(reason) .. ") wasWorn="
        .. tostring(wornLoc ~= nil) .. " leftover=" .. tostring(left ~= nil))
end

-- ── 수송기 차량 ───────────────────────────────────────────────────────────────
local function planeRemove(reason)
    if not R or not R.vehicle then return end
    local ok, err = pcall(function() R.vehicle:permanentlyRemove() end)
    log("plane removed vid=" .. tostring(R.vid) .. " ok=" .. tostring(ok)
        .. (ok and "" or (" err=" .. tostring(err))) .. " (" .. tostring(reason) .. ")")
    R.vehicle = nil
    R.vid = nil
    toClients("PlaneGone", { id = R.id })
end

local function setPilot(key)
    R.pilotKey = key
    local p = key and findPlayer(key) or nil
    if R.vehicle and p then
        local ok, err = pcall(function() R.vehicle:authorizationChanged(p) end)
        if not ok then log("plane authorization FAILED key=" .. tostring(key) .. " err=" .. tostring(err)) end
    end
    toClients("Pilot", { id = R.id, pilot = key, vid = R.vid })
    log("pilot -> " .. tostring(key))
end

-- 스폰 칸은 서버에 로드돼 있어야 한다. A 는 라운드를 시작한 사람 위치라 로드돼 있다.
local function planeSpawn()
    local sq = getSquare(math.floor(R.fl.ax), math.floor(R.fl.ay), 0)
    if not sq then
        log("plane spawn FAILED: square not loaded at A")
        return
    end
    local ok, v = pcall(function() return addVehicleDebug(HaloDrop.PLANE_SCRIPT, IsoDirections.N, 0, sq) end)
    if not ok or not v then
        log("plane spawn FAILED err=" .. tostring(v))
        return
    end
    R.vehicle = v
    R.vid = v:getId()
    log("plane spawned vid=" .. tostring(R.vid))
    if R.vid < 0 then R.vid = nil end   -- 아직 id 없음 -> onTick 에서 폴링
end

-- addVehicleDebug 직후 id 가 -1 이면 붙을 때까지 기다렸다가 파일럿에게 알린다
local function planePollId()
    if not R or not R.vehicle or R.vid then return end
    local ok, id = pcall(function() return R.vehicle:getId() end)
    if ok and id and id >= 0 then
        R.vid = id
        log("plane id assigned vid=" .. tostring(R.vid))
        local p = R.pilotKey and findPlayer(R.pilotKey) or nil
        if p then pcall(function() R.vehicle:authorizationChanged(p) end) end
        toClients("Pilot", { id = R.id, pilot = R.pilotKey, vid = R.vid })
    end
end

-- 파일럿이 내리면 아직 탑승 중인 사람에게 넘긴다. 없으면 마지막 파일럿이 계속 몬다
-- (차량이 그 클라 범위를 벗어나면 그 클라에선 사라지고, 경로 끝에서 서버가 지운다).
local function pilotHandoff()
    for k, m in pairs(R.members) do
        if m.aboard and k ~= R.pilotKey and findPlayer(k) then
            setPilot(k)
            return
        end
    end
end

-- ── 경로 선정 ─────────────────────────────────────────────────────────────────
-- 차량은 청크에 속해야 존재한다(BaseVehicle.update: 청크 참조가 비면 removeFromWorld). 맵 밖·빈 셀 위로
-- 가면 수송기가 사라진다(11-06 실측: B 의 y 가 음수였고 물 위에서 기체 소실). 셀 존재는
-- IsoMetaGrid.getCellData(셀X, 셀Y)(256칸 셀, 절대 좌표)로 본다.
local PATH_STEP = 32          -- 경로를 이 간격으로 훑어 셀 존재 확인
local PATH_TRIES = 16         -- 무작위 방향 시도 횟수
local PATH_MIN = 200          -- 이보다 짧으면 경고

local function cellExists(x, y)
    local ok, cell = pcall(function()
        return getWorld():getMetaGrid():getCellData(math.floor(x / 256), math.floor(y / 256))
    end)
    return ok and cell ~= nil
end

-- A 에서 angleDeg 방향으로 갈 수 있는 최대 길이(len 상한). 빈 셀을 만나면 그 직전까지
local function usableLength(ax, ay, angleDeg, len)
    local r = math.rad(angleDeg)
    local dx, dy = math.cos(r), math.sin(r)
    local d = PATH_STEP
    while d <= len do
        if not cellExists(ax + dx * d, ay + dy * d) then
            return d - PATH_STEP
        end
        d = d + PATH_STEP
    end
    return len
end

local function pickFlight(ax, ay, len, speed)
    local bestAng, bestLen = 0, -1
    for _ = 1, PATH_TRIES do
        local ang = ZombRand(360)
        local l = usableLength(ax, ay, ang, len)
        if l > bestLen then bestAng, bestLen = ang, l end
        if bestLen >= len then break end
    end
    if bestLen < PATH_MIN then
        log(string.format("WARNING: no map cells around A=(%.0f,%.0f): best path only %d tiles (angle %d)", ax, ay, bestLen, bestAng))
    elseif bestLen < len then
        log(string.format("path shortened to %d tiles (angle %d) to stay on existing map cells", bestLen, bestAng))
    end
    if bestLen < PATH_STEP then bestLen = PATH_STEP end
    return HaloDropFlight.make(ax, ay, bestAng, bestLen, speed), bestAng, bestLen
end

-- ── 라운드 ────────────────────────────────────────────────────────────────────
local function startRound(starter)
    if R then
        log("start ignored: round " .. tostring(R.id) .. " still open")
        return
    end
    local speed = HaloDrop.opt("PlaneSpeed")
    local fl, ang, len = pickFlight(starter:getX(), starter:getY(), HaloDrop.opt("PathLength"), speed)
    _roundSeq = _roundSeq + 1
    R = {
        id = _roundSeq,
        fl = fl,
        startAt = nowMs() + HaloDrop.PREP_MS,
        members = {},
        ended = false,
    }
    local n = 0
    for _, p in ipairs(players()) do
        -- 차에 탄 사람은 붙잡기가 차량 좌석과 충돌하므로 뺀다
        if not p:isDead() and not p:getVehicle() then
            R.members[HaloDrop.playerKey(p)] = { aboard = true, landed = false, name = p:getUsername() }
            n = n + 1
        end
    end
    log(string.format("round %d start by %s: A=(%.0f,%.0f) B=(%.0f,%.0f) angle=%d speed=%.1f len=%d dur=%dms members=%d",
        R.id, tostring(starter:getUsername()), R.fl.ax, R.fl.ay, R.fl.bx, R.fl.by, ang, speed, len, R.fl.durMs, n))
    planeSpawn()
    R.pilotKey = HaloDrop.playerKey(starter)
    if R.vehicle then
        local ok, err = pcall(function() R.vehicle:authorizationChanged(starter) end)
        if not ok then log("plane authorization FAILED err=" .. tostring(err)) end
    end
    toClients("Flight", flightArgs())
end

local function endRound(reason)
    if not R or R.ended then return end
    R.ended = true
    R.closeAt = nowMs() + CLOSE_AFTER_END_MS
    log("round " .. tostring(R.id) .. " end (" .. tostring(reason) .. ")")
    toClients("End", { id = R.id })   -- 아직 탑승 중인 클라는 강제로 뛰어내린다
    planeRemove(reason)
end

local function closeRound(reason)
    if not R then return end
    for k, m in pairs(R.members) do
        local p = findPlayer(k)
        if p then chuteTake(p, "round close") end
    end
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
    if not R then return end
    local now = nowMs()
    planePollId()
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
        log(string.format("status round=%d frac=%.3f ended=%s vid=%s pilot=%s members[%s]",
            R.id, (now - R.startAt) / R.fl.durMs, tostring(R.ended), tostring(R.vid), tostring(R.pilotKey),
            table.concat(parts, " ")))
    end
    if now >= _nextCheck then
        _nextCheck = now + CHECK_INTERVAL_MS
        -- 파일럿이 나갔으면 다른 탑승자에게 넘긴다
        if not R.ended and R.pilotKey and not findPlayer(R.pilotKey) then
            log("pilot " .. tostring(R.pilotKey) .. " gone")
            pilotHandoff()
        end
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
        log(string.format("jump %s (%s) at frac=%.2f pos=(%.0f,%.0f)",
            tostring(m.name), tostring(args.reason), (nowMs() - R.startAt) / R.fl.durMs, player:getX(), player:getY()))
        toClients("Member", { id = R.id, key = key, aboard = false })
        if R.pilotKey == key then pilotHandoff() end
    elseif command == "ChuteOpen" then
        if not R or args.id ~= R.id then return end
        log("chute open " .. tostring(player:getUsername()) .. " (" .. tostring(args.reason) .. ") alt=" .. tostring(args.alt))
        chuteGive(player)
    elseif command == "Landed" then
        log(string.format("landed %s at (%.0f,%.0f,%.1f) chute=%s",
            tostring(player:getUsername()), player:getX(), player:getY(), player:getZ(), tostring(args.chute)))
        chuteTake(player, "landed")
        if R and args.id == R.id and R.members[key] then
            R.members[key].landed = true
            R.members[key].aboard = false
        end
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
        local m = R.members[HaloDrop.playerKey(chr)]
        if m then
            m.aboard = false
            m.landed = true
        end
    end
end
Events.OnCharacterDeath.Add(onCharacterDeath)
