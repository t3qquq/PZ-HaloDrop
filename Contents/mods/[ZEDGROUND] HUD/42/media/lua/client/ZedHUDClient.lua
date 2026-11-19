-- ZEDGROUND HUD : client 진입점
-- 나침반 생성 + 다른 ZEDGROUND 모드 값 조회 (없으면 nil)
require "ZedHUDConfig"
require "ZedHUDCompass"
require "ZedHUDZone"

ZedHUD.compass = nil
ZedHUD.zone = nil

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

-- 자기장 구간: 페이즈 번호, 구간("wait" | "shrink" | "done"), 일시정지 여부. 라운드가 없거나 Blue Zone 이 없으면 nil
function ZedHUD.sourceZoneState()
    local C = BlueZone and BlueZone.C
    if not C then return nil end
    return C.phase, C.seg, C.paused
end

local function createCompass()
    if ZedHUD.compass then return end
    local c = ZedHUDCompass:new(0)
    c:initialise()
    c:addToUIManager()
    -- 창 위에 덧그리지 않는다. 접힌 인벤토리·루팅 창 제목 줄은 y 를 내려서 피한다 (ZedHUD.compassTop)
    c:setAlwaysOnTop(false)
    ZedHUD.compass = c
    ZedHUD.log("compass created w=" .. tostring(ZedHUD.compassWidth()) .. " h=" .. tostring(ZedHUD.COMPASS.height))
end

local function createZone()
    if ZedHUD.zone then return end
    local z = ZedHUDZone:new(0)
    z:initialise()
    z:addToUIManager()
    z:setAlwaysOnTop(false)
    ZedHUD.zone = z
    local n = ZedHUDNotice:new(0)
    n:initialise()
    n:addToUIManager()
    n:setAlwaysOnTop(false)
    ZedHUD.notice = n
    local layout = ZedHUD.timerLayout()
    ZedHUD.log("zone timer created, layout=" .. tostring(layout) .. " (" .. (layout == ZedHUD.LAYOUT_PUBG and "pubg: above minimap + center notice" or "under the compass") .. ")")
end

local function onGameStart()
    createCompass()
    createZone()
    ZedHUD.log("sources: RoundManager=" .. tostring(RoundManager ~= nil)
        .. " BlueZone=" .. tostring(BlueZone ~= nil))
end

local function onResolutionChange()
    if ZedHUD.compass then ZedHUD.compass:recenter() end
    if ZedHUD.zone then ZedHUD.zone:recenter() end
    if ZedHUD.notice then ZedHUD.notice:recenter() end
end

Events.OnGameStart.Add(onGameStart)
Events.OnResolutionChange.Add(onResolutionChange)
