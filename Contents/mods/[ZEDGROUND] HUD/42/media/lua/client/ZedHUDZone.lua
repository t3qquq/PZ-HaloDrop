-- ZEDGROUND HUD : 봉쇄 구역(Blue Zone) 타이머
-- 배치는 샌드박스 ZedHUD.TimerLayout 으로 고른다 (ZedHUDConfig.lua ZedHUD.timerLayout)
--   1 = 나침반 아래 (기본): 나침반 바로 아래 가운데 한 줄
--   2 = 배그식: 미니맵 바로 위 막대(남은 시간 + 다음 봉쇄 구역까지 거리) + 구간이 바뀔 때 화면 가운데 알림(ZedHUDNotice)
-- 값은 Blue Zone 모드의 전역(BlueZone.C, BlueZone.remainMs, BlueZone.currentBlue)에서 읽기만 한다. 라운드가 없으면 안 그린다.
-- 문구는 번역 키 (Translate/<언어>/IG_UI.json): IGUI_ZedHUD_Zone*
require "ISUI/ISUIElement"

ZedHUDZone = ISUIElement:derive("ZedHUDZone")
ZedHUDNotice = ISUIElement:derive("ZedHUDNotice")

local function clock(ms)
    local sec = math.floor((ms + 999) / 1000)
    return string.format("%d:%02d", math.floor(sec / 60), sec - math.floor(sec / 60) * 60)
end

-- 1 = 나침반 바로 아래. 나침반이 인벤토리 제목 줄을 피해 내려가면 같이 내려간다
local function compassRect()
    local c, z = ZedHUD.COMPASS, ZedHUD.ZONE
    local base = ZedHUD.compass and ZedHUD.compass:getY() or c.top
    return (getCore():getScreenWidth() - z.width) / 2, base + c.height + z.gap, z.width, z.height
end

-- 2 = 미니맵 바로 위, 미니맵과 같은 폭. 미니맵이 없거나 꺼져 있으면 화면 오른쪽 아래
local function pubgHeight()
    local P = ZedHUD.PUBG
    return getTextManager():getFontHeight(UIFont.Medium) + P.textGap + P.barH + P.markOver
end

local function pubgRect()
    local P = ZedHUD.PUBG
    local h = pubgHeight()
    local mm = getPlayerMiniMap(0)
    if mm and mm:isReallyVisible() then
        return mm:getX(), mm:getY() - h - P.gap, mm:getWidth(), h, true
    end
    local w = P.fallbackWidth
    return getCore():getScreenWidth() - w - P.margin, getCore():getScreenHeight() - h - P.margin, w, h, false
end

function ZedHUDZone:new(playerNum)
    local x, y, w, h = compassRect()
    local o = ISUIElement.new(self, x, y, w, h)
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

-- 위치는 매 render 에서 배치 방식대로 다시 잡는다
function ZedHUDZone:recenter()
    self.lastRect = nil
end

function ZedHUDZone:place(x, y, w, h, tag)
    local key = string.format("%d,%d,%d,%d", x, y, w, h)
    if key == self.lastRect then return end
    self.lastRect = key
    self:setX(x)
    self:setY(y)
    self:setWidth(w)
    self:setHeight(h)
    ZedHUD.log("zone timer: placed " .. tostring(tag) .. " at " .. key)
end

-- 1 = 나침반 아래 한 줄
function ZedHUDZone:renderCompassLayout(phase, seg, paused)
    local z = ZedHUD.ZONE
    local col = seg == "shrink" and ZedHUD.zoneShrinkColor() or z.wait
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

-- 플레이어 위치 정보: 흰 원 경계까지 남은 칸(안이면 0), 파란 원 밖인지, 막대 표시 비율(0~1), 파란 채움 비율(0~1)
local function zoneProgress(p, C, seg)
    if not C or C.wr == nil or C.wr < 0 then return nil end
    local dx, dy = p:getX() - C.wx, p:getY() - C.wy
    local toWhite = math.sqrt(dx * dx + dy * dy) - C.wr
    if toWhite < 0 then toWhite = 0 end
    local outsideBlue = false
    local r = nil
    if BlueZone and BlueZone.currentBlue then
        local cx, cy, cr = BlueZone.currentBlue()
        if cx then
            r = cr
            outsideBlue = BlueZone.isPlayerOutside(p)
        end
    end
    local span = C.fr - C.wr
    if span < 1 then span = 1 end
    local mark = 1 - toWhite / span
    if mark < 0 then mark = 0 elseif mark > 1 then mark = 1 end
    local fill = 0
    if seg == "shrink" and r then
        fill = (C.fr - r) / span
        if fill < 0 then fill = 0 elseif fill > 1 then fill = 1 end
    end
    return toWhite, outsideBlue, mark, fill
end

-- 2 = 배그식: 미니맵 폭 막대 + 막대 왼쪽 위 "N차 m:ss"
function ZedHUDZone:renderPubgLayout(phase, seg, paused, p)
    local P, z = ZedHUD.PUBG, ZedHUD.ZONE
    local w = self.width
    local col = seg == "shrink" and ZedHUD.zoneShrinkColor() or z.wait
    local text
    if seg == "done" then
        text = getText("IGUI_ZedHUD_ZoneDoneShort")
    else
        text = getText("IGUI_ZedHUD_ZoneShort", tostring(phase), clock(ZedHUD.sourceZoneRemainMs() or 0))
    end
    if paused then text = text .. " " .. getText("IGUI_ZedHUD_ZonePausedShort") end
    self:drawText(text, 1, 1, 0, 0, 0, 0.8, UIFont.Medium)   -- 그림자
    self:drawText(text, 0, 0, col.r, col.g, col.b, 1, UIFont.Medium)

    local toWhite, outsideBlue, mark, fill = zoneProgress(p, BlueZone and BlueZone.C, seg)
    if not toWhite then return end
    local by = getTextManager():getFontHeight(UIFont.Medium) + P.textGap + math.floor(P.markOver / 2)
    self:drawRect(0, by, w, P.barH, P.track.a, P.track.r, P.track.g, P.track.b)
    if fill > 0 then
        local fc = ZedHUD.zoneFillColor()
        self:drawRect(0, by, math.floor(w * fill), P.barH, fc.a, fc.r, fc.g, fc.b)
    end
    -- 오른쪽 끝 = 다음 봉쇄 구역 경계
    self:drawRect(w - 2, by - P.markOver / 2, 2, P.barH + P.markOver, 1, 1, 1, 1)
    -- 플레이어 표시
    local mc = P.inside
    if outsideBlue then mc = P.damage elseif toWhite > 0 then mc = P.outside end
    local mx = math.floor((w - 6) * mark)
    self:drawRect(mx, by - P.markOver / 2, 6, P.barH + P.markOver, 1, mc.r, mc.g, mc.b)
end

function ZedHUDZone:render()
    local phase, seg, paused = ZedHUD.sourceZoneState()
    local key = tostring(phase) .. ":" .. tostring(seg) .. ":" .. tostring(paused)
    if key ~= self.lastKey then
        self.lastKey = key
        ZedHUD.log("zone timer: phase=" .. tostring(phase) .. " seg=" .. tostring(seg) .. " paused=" .. tostring(paused))
    end
    local pubg = ZedHUD.timerLayout() == ZedHUD.LAYOUT_PUBG
    if pubg then
        local x, y, w, h, onMap = pubgRect()
        self:place(x, y, w, h, onMap and "pubg above minimap" or "pubg bottom-right (no minimap)")
    else
        local x, y, w, h = compassRect()
        self:place(x, y, w, h, "under compass")
    end
    if not phase then return end
    local p = getSpecificPlayer(self.playerNum)
    if not p or p:isDead() then return end
    if pubg then
        self:renderPubgLayout(phase, seg, paused, p)
    else
        self:renderCompassLayout(phase, seg, paused)
    end
end

-- ── 화면 가운데 알림 (배그식 배치에서만) ─────────────────────
-- 구간(phase·seg)이 바뀌면 NOTICE_MS 동안 띄운다. 접속 직후 처음 받은 상태는 구간이 막 시작된 경우(5초 이내)만 띄운다.
local NOTICE_W, NOTICE_H = 700, 40

function ZedHUDNotice:new(playerNum)
    local x = (getCore():getScreenWidth() - NOTICE_W) / 2
    local y = math.floor(getCore():getScreenHeight() * ZedHUD.PUBG.noticeY)
    local o = ISUIElement.new(self, x, y, NOTICE_W, NOTICE_H)
    o.playerNum = playerNum or 0
    o.lastKey = nil
    o.text = nil
    o.until_ = 0
    return o
end

function ZedHUDNotice:initialise()
    ISUIElement.initialise(self)
end

function ZedHUDNotice:instantiate()
    ISUIElement.instantiate(self)
    self.javaObject:setConsumeMouseEvents(false)
end

function ZedHUDNotice:recenter()
    self:setX((getCore():getScreenWidth() - NOTICE_W) / 2)
    self:setY(math.floor(getCore():getScreenHeight() * ZedHUD.PUBG.noticeY))
end

local function noticeText(phase, seg)
    if seg == "wait" then
        return getText("IGUI_ZedHUD_ZoneNoticeWait", tostring(phase), clock(ZedHUD.sourceZoneRemainMs() or 0))
    elseif seg == "shrink" then
        return getText("IGUI_ZedHUD_ZoneNoticeShrink", tostring(phase))
    elseif seg == "done" then
        return getText("IGUI_ZedHUD_ZoneDone")
    end
    return nil
end

function ZedHUDNotice:render()
    if ZedHUD.timerLayout() ~= ZedHUD.LAYOUT_PUBG then return end
    local phase, seg = ZedHUD.sourceZoneState()
    local key = phase and (tostring(phase) .. ":" .. tostring(seg)) or nil
    local now = getTimestampMs()
    if key ~= self.lastKey then
        local first = self.lastKey == nil
        self.lastKey = key
        if key then
            local C = BlueZone and BlueZone.C
            local fresh = not first
            if first and C and C.dur and C.dur > 0 then
                fresh = (C.dur - (ZedHUD.sourceZoneRemainMs() or 0)) < 5000
            end
            if fresh then
                self.text = noticeText(phase, seg)
                self.until_ = now + ZedHUD.PUBG.NOTICE_MS
                ZedHUD.log("zone notice: phase=" .. tostring(phase) .. " seg=" .. tostring(seg))
            end
        end
    end
    if not self.text or now >= self.until_ then return end
    local p = getSpecificPlayer(self.playerNum)
    if not p or p:isDead() then return end
    local left = self.until_ - now
    local a = 1
    if left < ZedHUD.PUBG.noticeFade then a = left / ZedHUD.PUBG.noticeFade end
    local col = seg == "shrink" and ZedHUD.zoneShrinkColor() or ZedHUD.ZONE.wait
    local fh = getTextManager():getFontHeight(UIFont.Large)
    self:drawRect(0, 0, self.width, self.height, 0.45 * a, 0, 0, 0)
    self:drawTextCentre(self.text, self.width / 2, math.floor((self.height - fh) / 2), col.r, col.g, col.b, a, UIFont.Large)
end
