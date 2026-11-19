-- Round Manager 운영 메뉴: 월드 우클릭 -> "ZEDGROUND 운영" 하나로 묶는다
--   판 상태                : 대기 <-> 진행 중 (맨 위: 다른 조작의 전제)
--   공수 강하 (HALO Drop)  : 시작 / 경로 준비 건너뛰고 출발 / 종료
--   봉쇄 구역 (Blue Zone)  : 시작 / 일시정지·재개 / 다음 구간 / 종료
-- 명령은 각 모드 서버로 그대로 보낸다 (RoundManager.call). 권한 검사는 각 모드 서버가 한다.
-- 대상 모드가 꺼져 있으면 그 항목은 비활성으로만 보인다.
-- 이 메뉴가 있으면 각 모드의 자체 우클릭 메뉴는 숨긴다: 모드 전역 테이블에 adminMenuHidden = true 를 세운다.
--   (기능 모드는 Manager 를 모른다. 깃발 이름만 약속이고, Manager 가 없으면 예전 메뉴가 그대로 뜬다)

if isServer() then return end

require "RoundManagerConfig"

local RM = RoundManager

local function log(msg) RM.log(msg) end

local function canUse(p)
    if not isClient() then return true end   -- SP
    return p:isAccessLevel("admin")
end

-- ── 각 모드 메뉴 숨기기 ──────────────────────────────────
local function hideModMenus()
    local parts = {}
    for key, t in pairs(RM.TARGETS) do
        local g = _G[t.global]
        if type(g) == "table" then
            g.adminMenuHidden = true
            parts[#parts + 1] = key
        end
    end
    log("menu: own context menus hidden for [" .. table.concat(parts, ",") .. "] (ZEDGROUND menu takes over)")
end
hideModMenus()                         -- 모든 모드의 shared 가 client 보다 먼저 로드되므로 대개 여기서 끝난다
Events.OnGameStart.Add(hideModMenus)   -- 혹시 늦게 생긴 테이블까지

-- ── 메뉴 만들기 ──────────────────────────────────────────
local function onSelect(p, key, command)
    log("menu -> " .. key .. "." .. command)
    RM.call(key, command)
end

local function onSetState(p, s)
    log("menu -> state " .. tostring(s))
    RM.setState(s)
end

-- 대상 모드가 꺼져 있을 때: 회색 항목 + 툴팁
local function addOff(menu, label)
    local opt = menu:addOption(label, nil, nil)
    opt.notAvailable = true
    local tip = ISToolTip:new()
    tip:initialise()
    tip:setVisible(false)
    tip.description = getText("ContextMenu_RoundManager_ModOff")
    opt.toolTip = tip
end

local function addSub(context, label)
    local root = context:addOption(label)
    local sub = ISContextMenu:getNew(context)
    context:addSubMenu(root, sub)
    return sub
end

local function fillHaloDrop(menu, p)
    local label = getText("ContextMenu_RoundManager_HaloDrop")
    if not RM.isAvailable("HaloDrop") then addOff(menu, label) return end
    local sub = addSub(menu, label)
    local C = HaloDrop.C
    if C and C.prep then
        sub:addOption(getText("ContextMenu_RoundManager_HaloDrop_Launch"), p, onSelect, "HaloDrop", "Launch")
        sub:addOption(getText("ContextMenu_RoundManager_HaloDrop_Stop"), p, onSelect, "HaloDrop", "Stop")
    elseif C and C.fl then
        sub:addOption(getText("ContextMenu_RoundManager_HaloDrop_Stop"), p, onSelect, "HaloDrop", "Stop")
    else
        sub:addOption(getText("ContextMenu_RoundManager_HaloDrop_Start"), p, onSelect, "HaloDrop", "Start")
    end
end

local function fillBlueZone(menu, p)
    local label = getText("ContextMenu_RoundManager_BlueZone")
    if not RM.isAvailable("BlueZone") then addOff(menu, label) return end
    local sub = addSub(menu, label)
    local C = BlueZone.C
    if not C then
        sub:addOption(getText("ContextMenu_RoundManager_BlueZone_Start"), p, onSelect, "BlueZone", "Start")
        return
    end
    if C.paused then
        sub:addOption(getText("ContextMenu_RoundManager_BlueZone_Resume"), p, onSelect, "BlueZone", "Resume")
    else
        sub:addOption(getText("ContextMenu_RoundManager_BlueZone_Pause"), p, onSelect, "BlueZone", "Pause")
    end
    if C.seg ~= "done" then
        sub:addOption(getText("ContextMenu_RoundManager_BlueZone_NextPhase"), p, onSelect, "BlueZone", "NextPhase")
    end
    sub:addOption(getText("ContextMenu_RoundManager_BlueZone_Stop"), p, onSelect, "BlueZone", "Stop")
end

local function fillState(menu, p)
    local cur = RM.state
    local curText = cur == RM.STATE.RUNNING and getText("ContextMenu_RoundManager_State_Running")
        or cur == RM.STATE.WAITING and getText("ContextMenu_RoundManager_State_Waiting")
        or "?"
    local sub = addSub(menu, getText("ContextMenu_RoundManager_State", curText))
    if cur ~= RM.STATE.WAITING then
        sub:addOption(getText("ContextMenu_RoundManager_State_SetWaiting"), p, onSetState, RM.STATE.WAITING)
    end
    if cur ~= RM.STATE.RUNNING then
        sub:addOption(getText("ContextMenu_RoundManager_State_SetRunning"), p, onSetState, RM.STATE.RUNNING)
    end
end

local function onFill(playerNum, context, worldobjects, test)
    local p = getSpecificPlayer(playerNum)
    if not p or not canUse(p) then return end
    if test then return ISWorldObjectContextMenu.setTest() end
    local menu = addSub(context, getText("ContextMenu_RoundManager"))
    fillState(menu, p)
    fillHaloDrop(menu, p)
    fillBlueZone(menu, p)
end
Events.OnFillWorldObjectContextMenu.Add(onFill)
