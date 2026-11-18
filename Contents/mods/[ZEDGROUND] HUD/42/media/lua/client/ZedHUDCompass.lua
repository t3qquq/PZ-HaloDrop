-- ZEDGROUND HUD : 상단 나침반 바 (배그 방식)
-- 눈금·숫자·방위 글자가 흐르고, 가운데 위의 아래로 향한 작은 화살표가 지금 보는 방향을 가리킨다.
-- 방향 소스: Viewpoint 1·3인칭이면 카메라, 아이소면 캐릭터 정면 (ZedHUD.headingOf)
require "ISUI/ISUIElement"

ZedHUDCompass = ISUIElement:derive("ZedHUDCompass")

function ZedHUDCompass:new(playerNum)
    local c = ZedHUD.COMPASS
    local w = ZedHUD.compassWidth()
    local x = (getCore():getScreenWidth() - w) / 2
    local o = ISUIElement.new(self, x, c.top, w, c.height)
    o.playerNum = playerNum or 0
    o.anchorTop = true
    o.lastSrc = nil
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
    local w = ZedHUD.compassWidth()
    self:setWidth(w)
    self:setX((getCore():getScreenWidth() - w) / 2)
    self:setY(c.top)
end

-- 가운데 화살표: 아래로 좁아지는 사각형 줄로 그린 삼각형
local function drawArrow(self, cx, h)
    for i = 0, h - 1 do
        local half = h - 1 - i
        self:drawRect(cx - half, i, half * 2 + 1, 1, 1, 1, 1, 1)
    end
end

function ZedHUDCompass:render()
    local p = getSpecificPlayer(self.playerNum)
    if not p or p:isDead() then return end

    local c = ZedHUD.COMPASS
    local w, h = self.width, self.height
    local cx = math.floor(w / 2)
    local pxPerDeg = w / c.spanDeg
    local heading, src = ZedHUD.headingOf(p)
    if src ~= self.lastSrc then
        self.lastSrc = src
        ZedHUD.log("compass: heading source -> " .. tostring(src))
    end
    local half = c.spanDeg / 2
    local barTop = c.arrowH + 1
    local barH = h - barTop

    self:drawRect(0, barTop, w, barH, 0.30, 0, 0, 0)
    drawArrow(self, cx, c.arrowH)

    local fadePx = w * c.fadeFrac
    local start = math.floor((heading - half) / c.tickDeg) * c.tickDeg
    local deg = start
    while deg <= heading + half do
        local x = cx + (deg - heading) * pxPerDeg
        if x >= 0 and x <= w then
            local edge = math.min(x, w - x)
            local a = edge >= fadePx and 1 or edge / fadePx
            local d = ZedHUD.norm(deg)
            local isLabel = math.fmod(d, c.labelDeg) == 0
            local tickH = isLabel and 5 or 3
            self:drawRect(x, h - tickH, 1, tickH, 0.7 * a, 1, 1, 1)
            if isLabel then
                local name = ZedHUD.CARDINAL[d]
                if name then
                    self:drawTextCentre(name, x, barTop, 1, 1, 1, a, UIFont.Medium)
                else
                    self:drawTextCentre(tostring(d), x, barTop + 3, 1, 1, 1, 0.75 * a, UIFont.Small)
                end
            end
        end
        deg = deg + c.tickDeg
    end
end
