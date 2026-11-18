-- ZEDGROUND HUD : client 진입점
-- 나침반 생성 + 다른 ZEDGROUND 모드 값 조회 (없으면 nil)
require "ZedHUDConfig"
require "ZedHUDCompass"

ZedHUD.compass = nil

-- 생존자 수: Round Manager 가 RoundManager.aliveCount() 를 열면 읽는다 (아직 미구현)
function ZedHUD.sourceAlive()
    if RoundManager and RoundManager.aliveCount then
        return RoundManager.aliveCount()
    end
    return nil
end

-- 자기장 남은 시간(ms): Blue Zone 클라 조회 함수
function ZedHUD.sourceZoneRemainMs()
    if BlueZone and BlueZone.remainMs then
        return BlueZone.remainMs()
    end
    return nil
end

local function createCompass()
    if ZedHUD.compass then return end
    local c = ZedHUDCompass:new(0)
    c:initialise()
    c:addToUIManager()
    c:setAlwaysOnTop(false)
    ZedHUD.compass = c
    ZedHUD.log("compass created w=" .. tostring(ZedHUD.COMPASS.width))
end

local function onGameStart()
    createCompass()
    ZedHUD.log("sources: RoundManager=" .. tostring(RoundManager ~= nil)
        .. " BlueZone=" .. tostring(BlueZone ~= nil))
end

local function onResolutionChange()
    if ZedHUD.compass then ZedHUD.compass:recenter() end
end

Events.OnGameStart.Add(onGameStart)
Events.OnResolutionChange.Add(onResolutionChange)
