-- Round Manager 클라: 판 상태 캐시 + 기능 모드 호출 헬퍼
--
-- 제어판 UI(다음 단계)는 아래 함수만 쓴다
--   RoundManager.state                    마지막으로 받은 판 상태 (접속 직후 Sync 전에는 nil)
--   RoundManager.isAvailable(key)         대상 모드가 켜져 있나 (버튼 활성화 판단)
--   RoundManager.call(key, command)       대상 모드 진입점 호출
--   RoundManager.setState(state)          판 상태 변경 요청

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
    local p = getPlayer()
    if p then sendClientCommand(p, RM.MODULE, "Sync", {}) end
    local parts = {}
    for key, _ in pairs(RM.TARGETS) do
        parts[#parts + 1] = key .. "=" .. (RM.isAvailable(key) and "on" or "off")
    end
    log("targets: " .. table.concat(parts, " "))
end
Events.OnGameStart.Add(onGameStart)
