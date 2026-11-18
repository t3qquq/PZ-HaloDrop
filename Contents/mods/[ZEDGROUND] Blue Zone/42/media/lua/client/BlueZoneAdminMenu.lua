-- Blue Zone 어드민 메뉴: 월드 우클릭 -> 자기장 하위 메뉴
-- 클라는 메뉴 표시만 거른다. 실제 권한 검사는 서버(BlueZoneServer.lua onClientCommand)가 한다.
-- Round Manager 제어판도 같은 명령을 보내면 된다 (이 메뉴는 Manager 없이 테스트할 때용).

if isServer() then return end

require "BlueZoneConfig"

local function canUse(p)
    if not isClient() then return true end   -- SP
    return p:isAccessLevel("admin")
end

local function onSelect(p, command)
    BlueZone.log("admin menu -> " .. command)
    sendClientCommand(p, BlueZone.MODULE, command, {})
end

local function onFill(playerNum, context, worldobjects, test)
    local p = getSpecificPlayer(playerNum)
    if not p or not canUse(p) then return end
    if test then return ISWorldObjectContextMenu.setTest() end
    local root = context:addOption(getText("ContextMenu_BlueZone"))
    local sub = ISContextMenu:getNew(context)
    context:addSubMenu(root, sub)
    local C = BlueZone.C
    if not C then
        sub:addOption(getText("ContextMenu_BlueZone_Start"), p, onSelect, "Start")
        return
    end
    if C.paused then
        sub:addOption(getText("ContextMenu_BlueZone_Resume"), p, onSelect, "Resume")
    else
        sub:addOption(getText("ContextMenu_BlueZone_Pause"), p, onSelect, "Pause")
    end
    if C.seg ~= "done" then
        sub:addOption(getText("ContextMenu_BlueZone_NextPhase"), p, onSelect, "NextPhase")
    end
    sub:addOption(getText("ContextMenu_BlueZone_Stop"), p, onSelect, "Stop")
end
Events.OnFillWorldObjectContextMenu.Add(onFill)
