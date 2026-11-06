-- Halo Drop HUD: 화면 위쪽 가운데에 상태·고도·키 안내를 한 줄로 그린다
-- B42 FBO 렌더러는 OnPostFloorLayerDraw 를 발화하지 않는다. OnPreUIDraw 는 UI 요소보다 먼저 그려져
-- 하늘 뷰(HaloDropSky, 전체화면 UI)에 가려졌으므로(런 4) OnPostUIDraw(바닐라 TutorialSetup 과 같은 훅)에서 그린다.

if isServer() then return end

require "HaloDropConfig"

local function keyName()
    return getKeyName(getCore():getKey("Interact"))
end

local function lineFor(J)
    if J.state == "ABOARD" then
        local C = HaloDrop.C
        if C.fl then
            local wait = C.t0 - getTimestampMs()
            if wait > 0 then
                return getText("IGUI_HaloDrop_Prep", tostring(math.ceil(wait / 1000)))
            end
        end
        return getText("IGUI_HaloDrop_Aboard", keyName())
    elseif J.state == "JUMPING" then
        local C = HaloDrop.C
        if C.jump then return getText("IGUI_HaloDrop_JumpingPlane") end
        local waited = J.jump and (getTimestampMs() - J.jump.at) or 0
        return getText("IGUI_HaloDrop_Jumping", tostring(math.floor(waited / 1000)))
    elseif J.state == "FREEFALL" then
        return getText("IGUI_HaloDrop_Freefall", tostring(math.floor(J.alt)), keyName())
    elseif J.state == "CANOPY" then
        return getText("IGUI_HaloDrop_Canopy", tostring(math.floor(J.alt)))
    end
    return nil
end

local function onPostUIDraw()
    local J = HaloDrop.J
    if not J or not J.state then return end
    local text = lineFor(J)
    if not text then return end
    local x = getCore():getScreenWidth() / 2
    local y = 60
    local tm = getTextManager()
    tm:DrawStringCentre(UIFont.Large, x + 2, y + 2, text, 0, 0, 0, 0.8)
    tm:DrawStringCentre(UIFont.Large, x, y, text, 1, 1, 1, 1)
    -- 강하 중 조작 안내 (한 줄, 작은 글씨)
    if J.state == "FREEFALL" or J.state == "CANOPY" then
        local hint = getText("IGUI_HaloDrop_Hint", getKeyName(getCore():getKey("Run")))
        tm:DrawStringCentre(UIFont.Small, x + 1, y + 31, hint, 0, 0, 0, 0.8)
        tm:DrawStringCentre(UIFont.Small, x, y + 30, hint, 1, 1, 1, 0.9)
    end
end
Events.OnPostUIDraw.Add(onPostUIDraw)
