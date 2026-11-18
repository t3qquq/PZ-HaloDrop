-- Halo Drop 하늘 뷰 타일 지도: 월드 <-> 타일 픽셀 투영 (서버·클라 공용, 상수만)
--
-- 타일은 pzmap2dzi 아이소 렌더(tools/make_sky_tiles.py 가 잘라 넣음). 레벨 L 의 픽셀 좌표:
--   px = L.ox + (wx - wy) * L.px / 2
--   py = L.oy + (wx + wy) * L.px / 4
-- L.px = 그 레벨에서 월드 1칸(타일)의 가로 픽셀 수(기본 렌더 128 의 1/2^n). pzmap2dzi map_info.json 의
-- x0/y0/sqr 와 같은 식이고(html/pzmap/map.js cell2pixel), Wingsmith 의 M.toMap 과도 같은 꼴이다.
-- 타일 파일: L.path .. c .. "_" .. r .. ".jpg" (1024px, pzmap2dzi 이름 그대로). 없는 조각은 L.pieces 에 없다.
--
-- 레벨 목록은 생성 파일 HaloDropTiles.lua 가 채운다 (없으면 HaloDropMap.levels = nil -> 하늘 뷰는 벡터 지도).

require "HaloDropConfig"

HaloDropMap = HaloDropMap or {}
local M = HaloDropMap

M.TILE = 1024
M.BG = { r = 0.33, g = 0.42, b = 0.19 }   -- 타일 없는 곳(바다·빈 땅) 배경. 바닐라 풀색 근처

function M.toMap(L, wx, wy)
    return L.ox + (wx - wy) * L.px / 2, L.oy + (wx + wy) * L.px / 4
end

function M.toWorld(L, mx, my)
    local a = (mx - L.ox) / (L.px / 2)
    local b = (my - L.oy) / (L.px / 4)
    return (a + b) / 2, (b - a) / 2
end

function M.has(L, c, r)
    return L.pieces[c .. "_" .. r] == true
end

-- 화면 배율 scale(화면 px / 월드 칸) 에 맞는 레벨: px >= scale 인 것 중 가장 거친 것 (축소해서 그린다).
-- 전부 scale 보다 거칠면 제일 고운 레벨(확대).
function M.levelFor(scale)
    local levels = M.levels
    if not levels or #levels == 0 then return nil end
    local best = nil
    for _, L in ipairs(levels) do
        if L.px >= scale and (not best or L.px < best.px) then best = L end
    end
    if not best then
        for _, L in ipairs(levels) do
            if not best or L.px > best.px then best = L end
        end
    end
    return best
end

function M.hasTiles()
    return M.levels ~= nil and #M.levels > 0
end

-- 생성 파일이 있으면 M.levels 를 채운다. 없으면 require 가 실패하므로 pcall.
local ok = pcall(function() require "HaloDropTiles" end)
if not ok or not M.levels then
    M.levels = nil
    HaloDrop.log("sky tiles: HaloDropTiles.lua not present -> vector map fallback")
else
    local names = {}
    for _, L in ipairs(M.levels) do
        local n = 0
        for _ in pairs(L.pieces) do n = n + 1 end
        names[#names + 1] = string.format("%s(px=%.4g pieces=%d)", tostring(L.id), L.px, n)
    end
    HaloDrop.log("sky tiles: " .. table.concat(names, " "))
end
