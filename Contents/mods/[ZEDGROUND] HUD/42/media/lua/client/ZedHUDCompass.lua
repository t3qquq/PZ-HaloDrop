-- ZEDGROUND HUD : 상단 나침반 바
require "ISUI/ISUIElement"

ZedHUDCompass = ISUIElement:derive("ZedHUDCompass")

function ZedHUDCompass:new(playerNum)
    local c = ZedHUD.COMPASS
    local x = (getCore():getScreenWidth() - c.width) / 2
    local o = ISUIElement.new(self, x, c.top, c.width, c.height)
    o.playerNum = playerNum or 0
    o.anchorTop = true
    return o
end

function ZedHUDCompass:initialise()
    ISUIElement.initialise(self)
end

function ZedHUDCompass:instantiate()
    ISUIElement.instantiate(self)
    self.javaObject:setConsumeMouseEvents(false)
end

function ZedHUDCompass:recenter()
    local c = ZedHUD.COMPASS
    self:setX((getCore():getScreenWidth() - c.width) / 2)
    self:setY(c.top)
end

function ZedHUDCompass:render()
    local p = getSpecificPlayer(self.playerNum)
    if not p or p:isDead() then return end

    local c = ZedHUD.COMPASS
    local w, h = self.width, self.height
    local cx = w / 2
    local pxPerDeg = w / c.spanDeg
    local heading = ZedHUD.headingOf(p)
    local half = c.spanDeg / 2

    self:drawRect(0, 0, w, h, 0.25, 0, 0, 0)

    -- 보이는 범위의 첫 눈금
    local start = math.floor((heading - half) / c.tickDeg) * c.tickDeg
    local deg = start
    while deg <= heading + half do
        local x = cx + (deg - heading) * pxPerDeg
        local d = ZedHUD.norm(deg)
        local isLabel = math.fmod(d, c.labelDeg) == 0
        local tickH = isLabel and 6 or 3
        self:drawRect(x, h - tickH - 2, 1, tickH, 0.8, 1, 1, 1)

        if isLabel and math.abs(deg - heading) > c.hideNearDeg then
            local name = ZedHUD.CARDINAL[d]
            if name then
                self:drawTextCentre(name, x, 2, 1, 1, 1, 1, UIFont.Medium)
            else
                self:drawTextCentre(tostring(d), x, 5, 1, 1, 1, 0.7, UIFont.Small)
            end
        end
        deg = deg + c.tickDeg
    end

    -- 가운데 현재 방위
    self:drawTextCentre(tostring(math.floor(heading + 0.5) % 360), cx, 2, 1, 0.85, 0.2, 1, UIFont.Medium)
    self:drawRect(cx, h - 2, 1, 2, 1, 1, 0.85, 0.2)
end
