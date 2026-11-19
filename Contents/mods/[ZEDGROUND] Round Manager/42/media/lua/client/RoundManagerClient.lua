-- Round Manager 클라: 판 상태 캐시 + 기능 모드 호출 헬퍼
--
-- 제어판 UI(다음 단계)는 아래 함수만 쓴다
--   RoundManager.state                    마지막으로 받은 판 상태 (접속 직후 Sync 전에는 nil)
--   RoundManager.isAvailable(key)         대상 모드가 켜져 있나 (버튼 활성화 판단)
--   RoundManager.call(key, command)       대상 모드 진입점 호출
--   RoundManager.setState(state)          판 상태 변경 요청
--   RoundManager.requestSync(why)         판 상태를 서버에 다시 묻는다
--
-- 판 상태 받기 (11-19 long 런: 접속 직후 OnGameStart 에서 한 번 보낸 Sync 에 답이 없어 메뉴가 내내 "판 상태: ?" 였다.
-- 서버에 받은 기록도 없음 -> 접속 직후 명령은 서버에 안 닿을 수 있다고 본다). 답을 받을 때까지 SYNC_RETRY_MS 마다
-- 다시 묻고(SYNC_MAX 번까지), 그 뒤에도 모르면 운영 메뉴를 열 때마다 한 번 더 묻는다.

if isServer() then return end

require "RoundManagerConfig"

local RM = RoundManager
RM.state = nil

local function log(msg) RM.log(msg) end

function RM.isAvailable(key)
    return RM.targetModule(key) ~= nil
end

function RM.call(key, command)
    local module = RM.targetModule(key)
    if not module then
        log("call " .. tostring(key) .. "." .. tostring(command) .. " skipped: target mod not active")
        return false
    end
    local p = getPlayer()
    if not p then return false end
    log("call " .. key .. "." .. command .. " (module " .. module .. ")")
    sendClientCommand(p, module, command, {})
    return true
end

function RM.setState(s)
    local p = getPlayer()
    if not p then return end
    sendClientCommand(p, RM.MODULE, "SetState", { state = s })
end

local SYNC_RETRY_MS = 2000
local SYNC_MAX = 30
local syncTries, nextSync = 0, 0

function RM.requestSync(why)
    local p = getPlayer()
    if not p then return end
    syncTries = syncTries + 1
    log("sync request #" .. syncTries .. " (" .. tostring(why) .. ")")
    sendClientCommand(p, RM.MODULE, "Sync", {})
end

local function syncTick()
    if RM.state ~= nil then
        Events.OnTick.Remove(syncTick)
        return
    end
    local now = getTimestampMs()
    if now < nextSync then return end
    if syncTries >= SYNC_MAX then
        log("sync: no answer after " .. syncTries .. " requests, stopped (the menu asks again when opened)")
        Events.OnTick.Remove(syncTick)
        return
    end
    nextSync = now + SYNC_RETRY_MS
    RM.requestSync("retry")
end

function RM.onServerCommand(module, command, args)
    if module ~= RM.MODULE then return end
    if command == "State" then
        if RM.state ~= args.state then
            log("state: " .. tostring(RM.state) .. " -> " .. tostring(args.state))
        end
        RM.state = args.state
    end
end
Events.OnServerCommand.Add(RM.onServerCommand)

local function onGameStart()
    Events.OnTick.Add(syncTick)
    local parts = {}
    for key, _ in pairs(RM.TARGETS) do
        parts[#parts + 1] = key .. "=" .. (RM.isAvailable(key) and "on" or "off")
    end
    log("targets: " .. table.concat(parts, " "))
end
Events.OnGameStart.Add(onGameStart)
