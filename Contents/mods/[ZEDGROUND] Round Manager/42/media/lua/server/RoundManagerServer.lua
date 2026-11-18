-- Round Manager 서버: 판 상태 보관·방송
--
-- 뼈대 단계 (11-18). 다음 단계에서 이 파일에 붙일 것
--   캐릭터 초기화 (인벤토리·부상·생존 수치), 사망 처리 (오일리그 리스폰), 판 종료 시 생존자 대기실 이동

if isClient() then return end

require "RoundManagerConfig"

local RM = RoundManager
local state = RM.STATE.WAITING

local function log(msg) RM.log(msg) end

local function toClients(cmd, args)
    if isServer() then
        sendServerCommand(RM.MODULE, cmd, args)
    elseif RM.onServerCommand then
        RM.onServerCommand(RM.MODULE, cmd, args)
    end
end

local function toPlayer(p, cmd, args)
    if isServer() then
        sendServerCommand(p, RM.MODULE, cmd, args)
    elseif RM.onServerCommand then
        RM.onServerCommand(RM.MODULE, cmd, args)
    end
end

local function isAdminPlayer(p)
    if not isServer() then return true end   -- SP
    return p:isAccessLevel("admin")
end

-- 다른 서버 코드(사망 처리 등)가 읽는다
function RM.getState()
    return state
end

local function onClientCommand(module, command, player, args)
    if module ~= RM.MODULE then return end
    local who = tostring(player and player:getUsername())
    if command == "SetState" then
        if not isAdminPlayer(player) then
            log("SetState denied for " .. who)
            return
        end
        local s = args and args.state
        if s ~= RM.STATE.WAITING and s ~= RM.STATE.RUNNING then
            log("SetState ignored: bad state '" .. tostring(s) .. "' from " .. who)
            return
        end
        if s == state then return end
        log("state " .. state .. " -> " .. s .. " by " .. who)
        state = s
        toClients("State", { state = state })
    elseif command == "Sync" then
        toPlayer(player, "State", { state = state })
    end
end
Events.OnClientCommand.Add(onClientCommand)
