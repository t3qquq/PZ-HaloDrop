-- Halo Drop 강하 그림자: 자유낙하·낙하산 중 캐릭터 발밑 지면 칸 위치에 그림자를 그린다.
-- 캐릭터(z 층)와 그림자(지면)의 화면 간격 = 남은 높이. 하강 z(DESCENT_Z)와 함께 "얼마나 남았나"를 보여주는 단서.
-- 그리기: OnPreUIDraw(월드 뒤·UI 앞) 에서 isoToScreenX/Y(playerNum, x, y, 지면 z) 로 화면 좌표를 얻어
--   getRenderer():render(tex, x, y, w, h, r, g, b, a) (바닐라 GridSquareSelector.lua 와 같은 호출) 로 검게 곱해 그린다.
-- 지면 z: 캐릭터 아래로 내려가며 바닥이 있는 첫 칸(TreatAsSolidFloor / hasFloor). 없으면 0.
-- 크기: 월드 1칸의 화면 폭(isoToScreenX 두 점 차이) 기준이라 줌과 무관. 낙하산이면 CANOPY_TILES, 아니면 BODY_TILES.
-- 투명도: 지면에서 FADE_FLOORS 층 이상이면 ALPHA_FAR, 가까울수록 ALPHA_NEAR.

if isServer() then return end

require "HaloDropConfig"

local TEX_PATH = "media/textures/HaloDrop/shadow.png"
local tex = nil
local texFailed = false

local function groundZ(cell, xi, yi, zTop)
    for z = zTop, 0, -1 do
        local sq = cell:getGridSquare(xi, yi, z)
        if sq and (sq:TreatAsSolidFloor() or sq:hasFloor()) then return z end
    end
    return 0
end

local function onPreUIDraw()
    local J = HaloDrop.J
    if not J or (J.state ~= "FREEFALL" and J.state ~= "CANOPY") then return end
    local S = HaloDrop.SHADOW
    if not S or not S.ENABLED or texFailed then return end
    local p = getPlayer()
    if not p or p:isDead() then return end
    if not tex then
        local ok, t = pcall(function() return getTexture(TEX_PATH) end)
        if not ok or not t then
            texFailed = true
            print("[HaloDrop] shadow: texture not found " .. TEX_PATH)
            return
        end
        tex = t
    end
    local pn = p:getPlayerNum()
    local x, y, z = p:getX(), p:getY(), p:getZ()
    local gz = groundZ(getCell(), math.floor(x), math.floor(y), math.floor(z) - 1)
    local h = z - gz                                  -- 남은 높이(층)
    if h < 0.05 then return end
    local sx, sy = isoToScreenX(pn, x, y, gz), isoToScreenY(pn, x, y, gz)
    local tileW = (isoToScreenX(pn, x + 1, y, gz) - sx) * 2   -- 월드 1칸의 화면 폭 (줌 반영)
    if tileW <= 1 then return end
    local tiles = (J.state == "CANOPY") and S.CANOPY_TILES or S.BODY_TILES
    local w = tileW * tiles
    local hh = w * 0.5
    local t = math.max(0, 1 - h / S.FADE_FLOORS)
    local a = S.ALPHA_FAR + (S.ALPHA_NEAR - S.ALPHA_FAR) * t
    getRenderer():render(tex, sx - w / 2, sy - hh / 2, w, hh, 0, 0, 0, a)
end
Events.OnPreUIDraw.Add(onPreUIDraw)
