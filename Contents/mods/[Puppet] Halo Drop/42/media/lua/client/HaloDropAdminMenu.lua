-- Halo Drop 어드민 메뉴: 월드 우클릭 -> 라운드 시작 / 종료
-- 클라는 메뉴 표시만 거른다. 실제 권한 검사는 서버(HaloDropServer.lua onClientCommand)가 한다.
-- B42 역할 이름은 소문자이고 isAccessLevel 은 대소문자를 무시한다.

if isServer() then return end

require "HaloDropConfig"

local function canUse(p)
    if not isClient() then return true end   -- SP
    return p:isAccessLevel("admin")
end

local function onSelect(p, command)
    HaloDrop.log("admin menu -> " .. command)
    sendClientCommand(p, HaloDrop.MODULE, command, {})
end

local function onFill(playerNum, context, worldobjects, test)
    local p = getSpecificPlayer(playerNum)
    if not p or not canUse(p) then return end
    if test then return ISWorldObjectContextMenu.setTest() end
    local C = HaloDrop.C
    if C and C.fl then
        context:addOption(getText("ContextMenu_HaloDrop_Stop"), p, onSelect, "Stop")
    else
        context:addOption(getText("ContextMenu_HaloDrop_Start"), p, onSelect, "Start")
    end
end
Events.OnFillWorldObjectContextMenu.Add(onFill)
