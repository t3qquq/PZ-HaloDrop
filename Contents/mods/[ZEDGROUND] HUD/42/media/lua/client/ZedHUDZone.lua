-- ZEDGROUND HUD : 자기장 타이머 (나침반 바로 아래)
-- 배그처럼 지금 구간과 남은 시간을 보여준다: 대기 중이면 축소 시작까지, 축소 중이면 축소가 끝날 때까지.
-- 값은 Blue Zone 모드의 전역(BlueZone.C, BlueZone.remainMs)에서 읽기만 한다 (ZedHUD.sourceZone*). 라운드가 없으면 아무것도 안 그린다.
-- 문구는 번역 키 (Translate/<언어>/IG_UI.json): IGUI_ZedHUD_ZoneWait / ZoneShrink / ZoneDone / ZonePaused
require "ISUI/ISUIElement"

ZedHUDZone = ISUIElement:derive("ZedHUDZone")

-- 나침반 바로 아래. 나침반이 인벤토리 제목 줄을 피해 내려가면 같이 내려간다
local function topY()
    local c = ZedHUD.COMPASS
    local base = ZedHUD.compass and ZedHUD.compass:getY() or c.top
    return base + c.height + ZedHUD.ZONE.gap
end

function ZedHUDZone:new(playerNum)
    local z = ZedHUD.ZONE
    local x = (getCore():getScreenWidth() - z.width) / 2
    local o = ISUIElement.new(self, x, topY(), z.width, z.height)
    o.playerNum = playerNum or 0
    o.anchorTop = true
    o.lastKey = nil
    return o
end

function ZedHUDZone:initialise()
    ISUIElement.initialise(self)
end

function ZedHUDZone:instantiate()
    ISUIElement.instantiate(self)
    self.javaObject:setConsumeMouseEvents(false)
end

function ZedHUDZone:recenter()
    local z = ZedHUD.ZONE
    self:setX((getCore():getScreenWidth() - z.width) / 2)
    self:setY(topY())
end

local function clock(ms)
    local sec = math.floor((ms + 999) / 1000)
    return string.format("%d:%02d", math.floor(sec / 60), sec - math.floor(sec / 60) * 60)
end

function ZedHUDZone:render()
    local phase, seg, paused = ZedHUD.sourceZoneState()
    local key = tostring(phase) .. ":" .. tostring(seg) .. ":" .. tostring(paused)
    if key ~= self.lastKey then
        self.lastKey = key
        ZedHUD.log("zone timer: phase=" .. tostring(phase) .. " seg=" .. tostring(seg) .. " paused=" .. tostring(paused))
    end
    local wantY = topY()
    if wantY ~= self.lastTop then
        self.lastTop = wantY
        self:setY(wantY)
    end
    if not phase then return end
    local p = getSpecificPlayer(self.playerNum)
    if not p or p:isDead() then return end

    local z = ZedHUD.ZONE
    local col = seg == "shrink" and z.shrink or z.wait
    local text
    if seg == "done" then
        text = getText("IGUI_ZedHUD_ZoneDone")
    else
        local remain = ZedHUD.sourceZoneRemainMs() or 0
        text = getText(seg == "shrink" and "IGUI_ZedHUD_ZoneShrink" or "IGUI_ZedHUD_ZoneWait", tostring(phase), clock(remain))
    end
    if paused then text = text .. " " .. getText("IGUI_ZedHUD_ZonePaused") end

    self:drawRect(0, 0, self.width, self.height, z.bgAlpha, 0, 0, 0)
    local fh = getTextManager():getFontHeight(UIFont.Medium)
    self:drawTextCentre(text, self.width / 2, math.floor((self.height - fh) / 2), col.r, col.g, col.b, 1, UIFont.Medium)
end
