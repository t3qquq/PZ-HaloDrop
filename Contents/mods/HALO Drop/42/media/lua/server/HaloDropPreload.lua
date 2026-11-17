-- Halo Drop 서버: 서버 셀 미리 올리기 (청크 스트리밍 선행)
--
-- 왜: 클라가 청크를 요청하면 서버는 그 청크를 자기 쪽에서 먼저 로드해야 보낸다
--   (PlayerDownloadServer.updatePendingChunks: ServerMap.loadOrKeepRelevent 후 chunk.loaded 일 때만 전송).
--   서버 셀(64x64칸)은 플레이어 로드 범위 안에 들어와야 올라가므로, 빠르게 활공하면 앞쪽 셀이 아직 없어
--   클라에 칸이 안 오고 강하 수평 이동이 멈춘다 (런 8: 동쪽 10초, 북쪽 4초 정지).
-- 무엇: 공중에 있는 플레이어 주변 셀을 서버가 미리 올려 둔다.
--   적용 구간은 수송기에서 뛰어내린 순간부터 착지 전까지뿐이다 (탑승 중·착지 후·라운드 밖에는 아무것도 안 한다).
-- 어떻게: ServerMap 은 Lua 에 노출돼 있지 않다. 전용 서버 실행 옵션 -javaagent:HaloDropAgent.jar 로 띄운
--   에이전트가 아래 HaloDropNative 표의 false 값을 자바 함수로 바꿔 넣는다.
--     HaloDropNative.state(x, y)   -> -2 오류, -1 맵 밖, 0 미요청, 1 로드됨, 2 로드 중
--     HaloDropNative.preload(x, y) -> 그 칸이 든 서버 셀을 올리거나 유지(매 틱 불러야 유지된다) 후 같은 코드
--   에이전트가 없으면(값이 false 그대로) 이 파일은 로그 한 줄만 남기고 아무것도 안 한다.

if not isServer() then return end

require "HaloDropConfig"

-- 에이전트가 채우는 자리. 키를 미리 만들어 둬야 한다(에이전트는 있는 키의 값만 바꾼다).
HaloDropNative = HaloDropNative or { state = false, preload = false, version = false }

HaloDropPreload = {}

local CELL = 64
local _pendingSince = {}   -- [key] = 처음 요청한 시각(ms)
local _nextReport = 0
local _stat = { done = 0, sumMs = 0, maxMs = 0 }
local _warned = false
local _active = false      -- 지금 미리 올리는 중인지 (공중 플레이어가 있는 동안만)
local _announced = false

local function log(msg) HaloDrop.log(msg) end

local function addCell(list, seen, cx, cy)
    local key = cx .. "," .. cy
    if seen[key] then return end
    seen[key] = true
    list[#list + 1] = { key = key, cx = cx, cy = cy }
end

local function addAround(list, seen, x, y, r)
    local cx, cy = math.floor(x / CELL), math.floor(y / CELL)
    -- 가운데부터 바깥 순서로 넣어 가까운 셀이 먼저 요청되게 한다
    for ring = 0, r do
        for dx = -ring, ring do
            for dy = -ring, ring do
                if math.max(math.abs(dx), math.abs(dy)) == ring then
                    addCell(list, seen, cx + dx, cy + dy)
                end
            end
        end
    end
end

-- R: 진행 중인 라운드(HaloDropServer), findPlayer(key) -> IsoPlayer
function HaloDropPreload.tick(R, now, findPlayer)
    local P = HaloDrop.PRELOAD
    if not P or not P.ENABLED or not R then return end
    local fnState, fnLoad = HaloDropNative.state, HaloDropNative.preload
    if not fnState or not fnLoad then
        if not _warned then
            _warned = true
            log("preload: native functions missing (server not started with -javaagent:HaloDropAgent.jar) -> preload off. Run server-agent/HaloDrop-ServerSetup.bat in the Halo Drop mod folder to install it")
        end
        return
    end
    if not _announced then
        _announced = true
        log("preload: native agent version " .. tostring(HaloDropNative.version) .. " active")
        if HaloDropNative.version ~= P.AGENT_VERSION then
            log(string.format("preload: WARNING agent version %s but this mod expects %s -> run server-agent/HaloDrop-ServerSetup.bat again (Install / update)",
                tostring(HaloDropNative.version), tostring(P.AGENT_VERSION)))
        end
    end

    -- 원하는 셀 목록: 공중에 있는 플레이어(뛰어내린 뒤 ~ 착지 전) 주변만.
    -- 서버 기준 "공중" = Jumped 를 받은 뒤(aboard=false) Landed 를 받기 전(landed=false).
    local list, seen = {}, {}
    for k, m in pairs(R.members) do
        if not m.aboard and not m.landed then
            local p = findPlayer(k)
            if p then addAround(list, seen, p:getX(), p:getY(), P.PLAYER_CELLS) end
        end
    end
    -- 아무도 공중에 없으면 할 일이 없다 (탑승 중·착지 후에는 미리 올리지 않는다)
    if #list == 0 then
        if _active then
            _active = false
            _pendingSince = {}
            log("preload: idle (nobody in the air)")
        end
        return
    end
    if not _active then
        _active = true
        _nextReport = 0
        log("preload: active (players in the air)")
    end

    -- 올라온 셀은 매 틱 유지, 안 올라온 셀은 동시에 MAX_PENDING 개까지만 요청 (서버 프레임 정지 완화)
    local loaded, pending, deferred, invalid = 0, 0, 0, 0
    for i = 1, #list do
        local c = list[i]
        local x, y = c.cx * CELL + 32, c.cy * CELL + 32
        local st = fnState(x, y)
        if st == 1 then
            fnLoad(x, y)
            loaded = loaded + 1
            local t0 = _pendingSince[c.key]
            if t0 then
                local ms = now - t0
                _stat.done = _stat.done + 1
                _stat.sumMs = _stat.sumMs + ms
                if ms > _stat.maxMs then _stat.maxMs = ms end
                _pendingSince[c.key] = nil
            end
        elseif st == 0 or st == 2 then
            if pending < P.MAX_PENDING then
                fnLoad(x, y)
                pending = pending + 1
                if not _pendingSince[c.key] then _pendingSince[c.key] = now end
            else
                deferred = deferred + 1
            end
        else
            invalid = invalid + 1
        end
    end
    -- 더 이상 원하지 않는 셀의 대기 기록은 지운다
    -- (순회 중에 지우지 않는다: Kahlua 표는 자바 맵이라 순회 중 삭제가 안전한지 보장이 없다)
    local drop = {}
    for key in pairs(_pendingSince) do
        if not seen[key] then drop[#drop + 1] = key end
    end
    for i = 1, #drop do _pendingSince[drop[i]] = nil end

    if now >= _nextReport then
        _nextReport = now + P.REPORT_MS
        local oldest = 0
        for _, t0 in pairs(_pendingSince) do
            if now - t0 > oldest then oldest = now - t0 end
        end
        log(string.format("preload: want=%d loaded=%d pending=%d deferred=%d invalid=%d | finished=%d avg=%dms max=%dms oldestPending=%dms",
            #list, loaded, pending, deferred, invalid, _stat.done,
            _stat.done > 0 and math.floor(_stat.sumMs / _stat.done) or 0, _stat.maxMs, oldest))
        _stat.done, _stat.sumMs, _stat.maxMs = 0, 0, 0
    end
end

-- ── 경로 미리 생성 (C안) ──────────────────────────────────────────────────────
-- 셀을 요청해 다 올라오면(state 1) 요청을 멈춘다. 그러면 ServerMap.postupdate 가 플레이어 근처가 아닌 셀을
-- 내리면서(Unload -> addSaveUnloadedJob) 청크를 저장한다. 다음에 같은 셀은 생성 없이 불러오기만 한다.
-- 로딩 중에 요청을 멈추면 서버가 로딩을 취소하므로(postupdate cancelLoading) 끝날 때까지 매 틱 다시 부른다.

-- 경로 A->B 양옆 halfW 칸 안에 걸치는 셀을 A 쪽부터 순서대로
function HaloDropPreload.routeCells(fl, halfW)
    local ax, ay, bx, by = fl.ax, fl.ay, fl.bx, fl.by
    local dx, dy = bx - ax, by - ay
    local len2 = dx * dx + dy * dy
    if len2 < 1 then len2 = 1 end
    local reach = halfW + CELL * 0.71    -- 셀 중심에서 모서리까지(반대각선)만큼 넉넉히
    local cx0 = math.floor((math.min(ax, bx) - reach) / CELL)
    local cx1 = math.floor((math.max(ax, bx) + reach) / CELL)
    local cy0 = math.floor((math.min(ay, by) - reach) / CELL)
    local cy1 = math.floor((math.max(ay, by) + reach) / CELL)
    local list = {}
    for cx = cx0, cx1 do
        for cy = cy0, cy1 do
            local px, py = cx * CELL + CELL / 2, cy * CELL + CELL / 2
            local t = ((px - ax) * dx + (py - ay) * dy) / len2
            local tc = t
            if tc < 0 then tc = 0 elseif tc > 1 then tc = 1 end
            local qx, qy = ax + dx * tc - px, ay + dy * tc - py
            local d = math.sqrt(qx * qx + qy * qy)
            if d <= reach then
                list[#list + 1] = { key = cx .. "," .. cy, cx = cx, cy = cy, t = t, d = d }
            end
        end
    end
    table.sort(list, function(a, b)
        if a.t ~= b.t then return a.t < b.t end
        return a.d < b.d
    end)
    return list
end

function HaloDropPreload.hasAgent()
    return HaloDropNative.state ~= false and HaloDropNative.state ~= nil
        and HaloDropNative.preload ~= false and HaloDropNative.preload ~= nil
end

-- prep = { cells, next, inflight, done, cached, invalid, sumMs, maxMs, startAt }
function HaloDropPreload.pregenNew(fl, now)
    local P = HaloDrop.ROUTE_PREGEN
    return {
        cells = HaloDropPreload.routeCells(fl, P.HALF_WIDTH),
        next = 1, inflight = {}, nInflight = 0,
        done = 0, cached = 0, invalid = 0, sumMs = 0, maxMs = 0,
        startAt = now,
    }
end

-- 매 틱. 끝났으면 true
function HaloDropPreload.pregenTick(prep, now)
    local P = HaloDrop.ROUTE_PREGEN
    local fnState, fnLoad = HaloDropNative.state, HaloDropNative.preload
    -- 진행 중인 셀: 다 올라왔으면 놓아준다(내려가며 저장), 아니면 유지 요청
    local finished = {}
    for key, c in pairs(prep.inflight) do
        local x, y = c.cx * CELL + 32, c.cy * CELL + 32
        local st = fnState(x, y)
        if st == 1 then
            local ms = now - c.since
            prep.done = prep.done + 1
            prep.sumMs = prep.sumMs + ms
            if ms > prep.maxMs then prep.maxMs = ms end
            finished[#finished + 1] = key
        elseif st == -1 or st == -2 then
            prep.invalid = prep.invalid + 1
            finished[#finished + 1] = key
        else
            fnLoad(x, y)
        end
    end
    for i = 1, #finished do
        prep.inflight[finished[i]] = nil
        prep.nInflight = prep.nInflight - 1
    end
    -- 빈 자리만큼 다음 셀 요청
    while prep.nInflight < P.MAX_PENDING and prep.next <= #prep.cells do
        local c = prep.cells[prep.next]
        prep.next = prep.next + 1
        local x, y = c.cx * CELL + 32, c.cy * CELL + 32
        local st = fnState(x, y)
        if st == 1 then
            prep.cached = prep.cached + 1          -- 이미 올라와 있다(플레이어 근처 등)
        elseif st == -1 or st == -2 then
            prep.invalid = prep.invalid + 1
        else
            fnLoad(x, y)
            prep.inflight[c.key] = { cx = c.cx, cy = c.cy, since = now }
            prep.nInflight = prep.nInflight + 1
        end
    end
    return prep.next > #prep.cells and prep.nInflight == 0
end

-- 진행률. finished = 처리한 셀 수, eta = 남은 예상 ms (지금까지 처리 속도 기준, 모르면 -1)
function HaloDropPreload.pregenProgress(prep, now)
    local total = #prep.cells
    local finished = prep.done + prep.cached + prep.invalid
    local elapsed = now - prep.startAt
    local eta = -1
    if finished > 0 and elapsed > 0 then
        eta = math.floor((total - finished) * elapsed / finished)
    end
    return finished, total, eta
end

function HaloDropPreload.pregenReport(prep, now)
    local finished, total, eta = HaloDropPreload.pregenProgress(prep, now)
    log(string.format("route pregen: %d/%d (generated=%d already-loaded=%d invalid=%d inflight=%d) avg=%dms max=%dms elapsed=%ds eta=%ss",
        finished, total, prep.done, prep.cached, prep.invalid, prep.nInflight,
        prep.done > 0 and math.floor(prep.sumMs / prep.done) or 0, prep.maxMs,
        math.floor((now - prep.startAt) / 1000), eta >= 0 and tostring(math.floor(eta / 1000)) or "?"))
end

function HaloDropPreload.reset()
    _active = false
    _pendingSince = {}
    _nextReport = 0
    _stat.done, _stat.sumMs, _stat.maxMs = 0, 0, 0
end
