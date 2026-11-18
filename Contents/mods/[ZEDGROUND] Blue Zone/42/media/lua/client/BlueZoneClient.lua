-- Blue Zone 클라: 서버 상태 캐시 + 조회 함수
--
-- 표시(지도 원, 타이머, 경고)는 이 파일에서 하지 않는다. HUD 모드·지도가 아래 함수로 읽어 간다.
--   BlueZone.C              마지막 스냅샷 (nil = 대기). 필드는 서버 snapshot() 참고
--   BlueZone.remainMs()     지금 구간 남은 ms (일시정지면 고정)
--   BlueZone.currentBlue()  지금 파란 원 cx, cy, r (없으면 nil)
--   BlueZone.isPlayerOutside(p)
--   BlueZone.onChange(fn)  상태가 바뀌면(State 수신·Stopped) fn() 호출. Viewpoint 벽 브리지가 쓴다

if isServer() then return end

require "BlueZoneConfig"

local B = BlueZone
B.C = nil
B.listeners = B.listeners or {}

function B.onChange(fn)
    B.listeners[#B.listeners + 1] = fn
end

local function notify()
    for _, fn in ipairs(B.listeners) do
        local ok, err = pcall(fn)
        if not ok then B.log("listener failed: " .. tostring(err)) end
    end
end

local function log(msg) B.log(msg) end

-- 스냅샷 수신 시각 기준으로 클라 자기 시계로 경과를 센다
local function elapsedSinceRecv()
    local C = B.C
    if not C or C.paused then return 0 end
    return getTimestampMs() - C.recvAt
end

function B.remainMs()
    local C = B.C
    if not C then return nil end
    local r = C.remain - elapsedSinceRecv()
    if r < 0 then r = 0 end
    return r
end

function B.currentBlue()
    local C = B.C
    if not C then return nil end
    local frac = 0
    if C.dur > 0 then frac = (C.dur - B.remainMs()) / C.dur end
    return B.blueAt(C, frac)
end

function B.isPlayerOutside(p)
    local cx, cy, r = B.currentBlue()
    if not cx then return false end
    local x, y = p:getX(), p:getY()
    if B.inExempt(x, y) then return false end
    return B.isOutside(x, y, cx, cy, r)
end

function B.onServerCommand(module, command, args)
    if module ~= B.MODULE then return end
    if command == "State" then
        local prev = B.C
        local C = {}
        for k, v in pairs(args) do C[k] = v end
        C.recvAt = getTimestampMs()
        B.C = C
        -- 재방송(10초마다)은 구간이 바뀌었을 때만 로그
        if not prev or prev.id ~= C.id or prev.phase ~= C.phase or prev.seg ~= C.seg or prev.paused ~= C.paused then
            log(string.format("state: round=%d phase=%d/%d seg=%s remain=%dms paused=%s dps=%.1f white=%s",
                C.id, C.phase, C.n, C.seg, C.remain, tostring(C.paused), C.dps,
                C.wr >= 0 and string.format("(%.0f,%.0f r%.0f)", C.wx, C.wy, C.wr) or "none"))
        end
        notify()
    elseif command == "Stopped" then
        log("round " .. tostring(args.id) .. " stopped")
        B.C = nil
        notify()
    end
end
Events.OnServerCommand.Add(B.onServerCommand)

-- 접속(또는 리로드) 직후 진행 중인 라운드 상태를 받는다
local function onGameStart()
    local p = getPlayer()
    if p then sendClientCommand(p, B.MODULE, "Sync", {}) end
end
Events.OnGameStart.Add(onGameStart)
