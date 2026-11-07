-- Halo Drop 점퍼: 자기 캐릭터의 탑승·자유낙하·낙하산·착지
--
-- 상태: nil -> ABOARD -> JUMPING -> FREEFALL -> CANOPY -> nil(착지)
--   ABOARD    제자리(리그)에 숨긴 채 움직임만 막는다. 경로 위치는 숫자로만 돌고 하늘 뷰(HaloDropSky)가 그린다.
--             (이전: A 로 옮겨 경로를 따라 끌고 다님 -> 48 타일/초를 클라 청크 스트리밍이 못 따라와 폐기, 11-06 런 3)
--   JUMPING   E 를 누른 순간 경로 위치로 옮겨 CarryZ 에 붙잡고, 구름 덮개 아래서 발밑 청크·수송기를 기다린다.
--             발밑 칸이 올라오고 수송기가 머리 위를 지나면(또는 JumpWaitMax 초과) FREEFALL.
--   FREEFALL  가상 고도를 수직 속도로 줄인다. 상호작용 키로 낙하산
--   CANOPY    낙하산. 수직·수평 속도가 캐노피 목표치로 서서히 수렴한다
-- 실제 z 처리 (HaloDropConfig.lua 고도 체계 참고)
--   붙잡기(hold): 가상 고도가 LOW_Z(3) 층보다 높은 동안. 매 틱 x, y 를 직접 정하고 z 는 visualZ(가상 고도)
--     -- 뛰어내릴 때 CarryZ(기본 8), 낙하산 개방 고도에서 그 중간, LOW_Z 까지 선형 -- 로 끌어내리며 낙하 속도를 0 으로 둔다.
--   놓기(release): 가상 고도가 LOW_Z 층 아래로 내려오면 엔진 낙하(IsoGameCharacter.updateFalling)에
--     맡기고 낙하 속도만 매 틱 setLastFallSpeed 로 정한다. 바닥 BRAKE_H 층 위부터 LAND_SPEED 로 감속.
--     updateFalling 은 중력을 더하는 등가속도이고 착지 피해는 충돌 순간 속도로만 정한다.
-- 순서: IsoGameCharacter.update(updateFalling 포함)가 먼저 돌고 OnPlayerUpdate 가 뒤에 발화한다(IsoPlayer).
--   그래서 여기서 정한 위치가 그 틱의 렌더 위치가 되고, 낙하 속도는 다음 틱 updateFalling 에 쓰인다.
--
-- 강하 모델 (claude/PUBG_강하_메커니즘_조사.md 9.2 절, 방식 A)
--   heading(도): 몸이 향한 수평 방향. A/D 가 TurnRate(도/초)로 돌린다. 즉시 꺾이지 않는다.
--   pitch(-1~+1): W 를 누르면 +1 로, S 를 누르면 -1 로 PitchRate 속도로 기운다. 떼면 0 으로 돌아온다.
--   목표 속도: pitch 로 (무입력 <-> 활공/다이브/브레이크) 비율표(HaloDrop.FF / CP)를 보간한다.
--     W = 활공(앞으로 기울임, 수평 속도 생김), W + 달리기 키 = 다이브(수직 최대, 수평 0), S = 브레이크.
--   관성: v += (목표 - v) * min(1, Accel*dt). 낙하산을 펴도 속도를 리셋하지 않고 CanopyAccel 로 수렴시킨다
--     (배그 슬링샷: 펴진 직후 몇 초간 자유낙하 속도를 이어받는다).
--   수평 위치는 heading 방향 x 수평 속도로만 움직인다.
-- 안티치트: 차량 밖 캐릭터는 1초 평균 20 타일/초를 넘으면 위반이다(AntiCheatSpeed). 이 검사는 서버 ini
--   AntiCheatSpeed=4(Disabled) 로 끈 서버에서만 수송기 속도 20 초과·A 로의 순간 이동이 안전하다.
-- 낙하산 착용·해제는 여기(클라)서 한다. 서버는 아이템 지급(ChuteWear 지시)·회수만 한다 -- 착용 상태는
--   클라 setWornItem 이 SyncClothing 으로 서버에 올리므로 서버가 벗겨도 되살아난다(11-06 실측).
--   착지 뒤 CHUTE_GUARD_MS 동안 매 틱 착용 목록을 감시해 다시 생기면 즉시 벗긴다.

if isServer() then return end

require "HaloDropConfig"
require "HaloDropFlight"
require "HaloDropSky"

HaloDropJumper = {}

local J = { state = nil }
HaloDrop.J = J

local CHUTE_GUARD_MS = 10000   -- 착지 뒤 낙하산 재착용 감시 시간

local function log(msg) HaloDrop.log(msg) end

local function send(p, cmd, args)
    sendClientCommand(p, HaloDrop.MODULE, cmd, args)
end

-- 뛰어내리는 실제 층. 샌드박스 CarryZ 를 CARRY_Z_MAX 로 자른다.
-- 런 7: 31·16 으로 돌리자 airFill 이 50만 칸을 만들고(7878 청크층) 프레임이 수십 초씩 멈췄으며 낙하 내내 화면이 검었다.
-- 카메라는 1층당 3칸 북서로 밀려 16층이면 48칸, 31층이면 93칸 -- 로드 창(±72칸)을 벗어난다.
local function carryZ()
    local v = HaloDrop.opt("CarryZ")
    local cap = HaloDrop.CARRY_Z_MAX or 12
    if v > cap then
        if not HaloDrop._carryZWarned then
            HaloDrop._carryZWarned = true
            log(string.format("CarryZ %d capped to %d (CARRY_Z_MAX)", v, cap))
        end
        return cap
    end
    return v
end

-- 엔진 낙하로 넘기는 가상 고도. 하강 z(DESCENT_Z) 를 쓰면 LOW_Z 층, 아니면 CarryZ 층
local function lowZ()
    local D = HaloDrop.DESCENT_Z
    if D and D.ENABLED then return math.min(D.LOW_Z, carryZ()) end
    return carryZ()
end
local function carryAltM()
    return lowZ() * HaloDrop.M_PER_FLOOR
end

-- 가상 고도 -> 붙잡아 둘 실제 z (HaloDrop.DESCENT_Z). 구간별 선형:
--   JumpAltitude 에서 CarryZ, AutoOpenAltitude 에서 LOW_Z + (CarryZ-LOW_Z)*CHUTE_FRAC, lowAltM 에서 LOW_Z.
--   런 6: z 가 끝까지 CarryZ(3) 라 "둥둥 떠 있는" 느낌 -> 마지막 7m(엔진 낙하)에서만 내려가는 게 보였다.
--   엔진은 current 칸을 z 아래로 내려가며 찾으므로(IsoMovingObject.findCurrentGridSquare) 공중 칸은
--   airFill 이 만든다. 1층 = 화면 약 96px.
local function visualZ(alt)
    local carry = carryZ()
    local D = HaloDrop.DESCENT_Z
    if not D or not D.ENABLED then return carry end
    local low = lowZ()
    local top = HaloDrop.opt("JumpAltitude")
    local mid = HaloDrop.opt("AutoOpenAltitude")
    local lowAlt = low * HaloDrop.M_PER_FLOOR
    if mid <= lowAlt or mid >= top then mid = (top + lowAlt) / 2 end
    local zMid = low + (carry - low) * D.CHUTE_FRAC
    if alt >= top then return carry end
    if alt >= mid then return zMid + (carry - zMid) * (alt - mid) / (top - mid) end
    if alt >= lowAlt then return low + (zMid - low) * (alt - lowAlt) / (mid - lowAlt) end
    return low
end

-- ── 소리 (자기 캐릭터 emitter, 로컬 재생) ───────────────────────────────────
local function planeSoundStart(p)
    if J.planeSnd then return end
    local ok, h = pcall(function() return p:getEmitter():playSoundImpl("halodrop_plane", nil) end)
    if ok and h and h ~= 0 then J.planeSnd = h end
end

local function planeSoundStop(p)
    if not J.planeSnd then return end
    pcall(function() p:getEmitter():stopSound(J.planeSnd) end)
    J.planeSnd = nil
end

-- ── 낙하산 착용·해제 (클라) ───────────────────────────────────────────────────
local function findChute(p)
    local inv = p:getInventory()
    return inv and inv:getFirstTypeRecurse(HaloDrop.CHUTE_ITEM) or nil
end

-- 착용 목록에 있는 낙하산 전부 (인벤토리에서 이미 지워졌는데 착용 목록에만 남은 경우도 잡는다)
local function wornChutes(p)
    local out = {}
    local worn = p:getWornItems()
    if not worn then return out end
    for i = 0, worn:size() - 1 do
        local it = worn:get(i):getItem()
        if it and it:getFullType() == HaloDrop.CHUTE_ITEM then out[#out + 1] = it end
    end
    return out
end

local function chuteWear(p)
    local item = findChute(p)
    if not item then return false end
    if p:getWornItems():getLocation(item) then return true end
    local ok, err = pcall(function() p:setWornItem(item:getBodyLocation(), item) end)
    log("chute wear ok=" .. tostring(ok) .. (ok and "" or (" err=" .. tostring(err))) .. " id=" .. tostring(item:getID()))
    -- 착용으로 모델이 다시 만들어진다 (낙하산 메시 로드 동안 캐릭터가 잠깐 안 보이는 건 엔진 쪽)
    return ok
end

-- removeWornItem 은 WornItems.setItem(loc, nil) 이라 multi-item 위치에선 아무것도 안 지운다
-- (11-06 실측, base:zeddmg). 지금은 단일 슬롯 base:tail 이지만, 그래도 남으면 WornItems:remove 로 직접 뺀다.
local function chuteUnwear(p, reason)
    local items = wornChutes(p)
    if #items == 0 then return 0 end
    local worn = p:getWornItems()
    for _, item in ipairs(items) do
        local ok, err = pcall(function() p:removeWornItem(item) end)
        local still = worn:contains(item)
        if still then
            pcall(function() worn:remove(item) end)
            still = worn:contains(item)
        end
        log("chute unwear (" .. tostring(reason) .. ") ok=" .. tostring(ok) .. (ok and "" or (" err=" .. tostring(err)))
            .. " id=" .. tostring(item:getID()) .. " inInventory=" .. tostring(item:getContainer() ~= nil)
            .. " stillWorn=" .. tostring(still))
    end
    p:resetModelNextFrame()
    return #items
end

-- 서버 ChuteWear 는 sendAddItemToContainer 보다 먼저 도착할 수 있다 -> 아이템이 보일 때까지 몇 틱 재시도
local _wearUntil = nil
function HaloDropJumper.onChuteWear()
    local p = getPlayer()
    if not p then return end
    if J.state ~= "CANOPY" then
        log("ChuteWear ignored: state=" .. tostring(J.state))
        return
    end
    if chuteWear(p) then return end
    _wearUntil = getTimestampMs() + 3000
    log("chute item not in inventory yet -> retrying up to 3s")
end

-- 서버 스윕이 지웠다고 알리면 클라 쪽 착용 목록도 다시 확인한다
function HaloDropJumper.onChuteTake(reason)
    local p = getPlayer()
    if not p then return end
    local n = chuteUnwear(p, "server " .. tostring(reason))
    log("ChuteTake from server (" .. tostring(reason) .. ") unworn=" .. tostring(n))
end

-- 착지 뒤 감시: 다시 착용돼 있으면 벗긴다 (누가 되살렸는지 OnClothingUpdated 로그로 추적)
local _guardUntil = nil
local function chuteGuardTick()
    local p = getPlayer()
    if not p then return end
    if _wearUntil then
        if J.state ~= "CANOPY" then
            _wearUntil = nil
        elseif chuteWear(p) then
            _wearUntil = nil
        elseif getTimestampMs() > _wearUntil then
            _wearUntil = nil
            log("chute wear FAILED: item never arrived")
        end
    end
    if _guardUntil then
        if getTimestampMs() > _guardUntil then
            _guardUntil = nil
            log("chute guard ended, worn=" .. tostring(#wornChutes(p)) .. " inventory=" .. tostring(findChute(p) ~= nil))
        else
            local n = chuteUnwear(p, "guard")
            if n > 0 then
                log("chute guard: parachute came back and was removed again (n=" .. tostring(n) .. ")")
                send(p, "Cleanup", {})
            end
        end
    end
end
Events.OnTick.Add(chuteGuardTick)

-- 착용 목록 동기화 패킷(SyncClothing)이 도착할 때마다 발화. 낙하산이 되살아나는 경로 추적용.
local function onClothingUpdated(chr)
    local p = getPlayer()
    if chr ~= p or not _guardUntil then return end
    log("OnClothingUpdated during guard: worn chutes=" .. tostring(#wornChutes(p)) .. " inventory=" .. tostring(findChute(p) ~= nil))
end
Events.OnClothingUpdated.Add(onClothingUpdated)

-- ── 위치 제어 ─────────────────────────────────────────────────────────────────
-- setForceX/Y = x, next, last 동시 설정 (IsoMovingObject). setZ 는 lastZ 도 같이 정하고 31 로 자른다.
-- 멀리 옮길 때(목적지 청크 미로드)는 먼저 removeFromSquare() 로 current/last 칸 참조를 끊어야 한다.
-- 안 끊으면 IsoMovingObject.postupdate 가 "현재 칸 없음 + last 있음" 을 보고 직전 칸 중앙으로 되돌린다
-- (11-06 실측: A 로 못 가고 리그 (19210.5,272.5) 에 붙박임). 바닐라 원격 플레이어 갱신과 같은 순서.
local FAR_JUMP = 32
local function hold(p, x, y, z)
    local dx, dy = x - p:getX(), y - p:getY()
    if dx * dx + dy * dy > FAR_JUMP * FAR_JUMP then
        log(string.format("far move (%.0f,%.0f) -> (%.0f,%.0f): removeFromSquare", p:getX(), p:getY(), x, y))
        pcall(function() p:removeFromSquare() end)
    end
    p:setForceX(x)
    p:setForceY(y)
    p:setZ(z)
    p:setLastFallSpeed(0)
end

local function keyDown(name)
    local ok, v = pcall(function() return isKeyDown(name) end)
    return ok and v or false
end

-- 각도 차이를 -180~180 으로
local function wrapDeg(a)
    while a > 180 do a = a - 360 end
    while a < -180 do a = a + 360 end
    return a
end

local function approach(v, target, rate, dt)
    local k = rate * dt
    if k > 1 then k = 1 end
    return v + (target - v) * k
end

-- 입력 -> 목표 (수직 m/s, 수평 타일/초). table 은 HaloDrop.FF 또는 HaloDrop.CP
local function targets(tbl, vBase, hBase, pitch, diving)
    local base = tbl.neutral
    local toward
    if pitch >= 0 then
        toward = diving and tbl.dive or tbl.glide
    else
        toward = tbl.brake
    end
    local f = math.abs(pitch)
    local v = base.v + (toward.v - base.v) * f
    local h = base.h + (toward.h - base.h) * f
    return v * vBase, h * hBase
end


-- ── 공중 칸 채우기 (런 4 검정 화면 대응, 추정 기반 실험) ─────────────────────────
-- B42 청크는 minLevel~maxLevel 사이 층만 갖는다(IsoChunk.setSquare :3100 이 새 z 가 오면 범위를 늘림,
-- 들판 청크는 0층뿐). 조명/시야 네이티브는 청크마다 그 범위만 갱신(LightingJNI.updateChunk :604)하므로
-- z=3 에 뜬 플레이어 눈과 지면 사이 1~3층 데이터가 아예 없어 검게 나오는 것으로 추정.
-- 건물에서 떨어질 땐 건물 청크가 지붕까지 층을 갖고 있어 멀쩡하다. 그래서 주변 청크의 1~z 층에
-- 빈 칸을 클라에서 만들어(getOrCreateGridSquare, IsoCell :3296 LuaMethod) 층 범위를 넓혀 본다.
-- 비용: 청크·층 하나당 64칸, 틱당 AIR_FILL.PER_TICK 청크층. 서버와 무관한 클라 전용 빈 칸.
local _air = { done = {}, chunks = 0, squares = 0, nextLog = nil }

local function airFillReset()
    _air.done, _air.chunks, _air.squares, _air.nextLog = {}, 0, 0, nil
end

local function airFill(p)
    local A = HaloDrop.AIR_FILL
    if not A or A.CHUNKS <= 0 then return end
    local pz = math.floor(p:getZ())
    if pz < 1 then return end
    local cell = getCell()
    local cx, cy = math.floor(p:getX() / 8), math.floor(p:getY() / 8)
    local budget = A.PER_TICK
    for r = 0, A.CHUNKS do
        for wx = cx - r, cx + r do
            for wy = cy - r, cy + r do
                if math.max(math.abs(wx - cx), math.abs(wy - cy)) == r then
                    -- 이 청크가 클라에 올라와 있을 때만 (0층 칸 존재)
                    if cell:getGridSquare(wx * 8, wy * 8, 0) ~= nil then
                        for z = 1, pz do
                            local key = wx .. "," .. wy .. "," .. z
                            if not _air.done[key] then
                                if budget <= 0 then return end
                                budget = budget - 1
                                _air.done[key] = true
                                local n = 0
                                local ok, err = pcall(function()
                                    for x = 0, 7 do
                                        for y = 0, 7 do
                                            if cell:getOrCreateGridSquare(wx * 8 + x, wy * 8 + y, z) then n = n + 1 end
                                        end
                                    end
                                end)
                                if not ok then
                                    log("air fill FAILED at chunk (" .. wx .. "," .. wy .. ") z=" .. z .. " err=" .. tostring(err))
                                    return
                                end
                                _air.chunks = _air.chunks + 1
                                _air.squares = _air.squares + n
                            end
                        end
                    end
                end
            end
        end
    end
    local now = getTimestampMs()
    if not _air.nextLog or now >= _air.nextLog then
        _air.nextLog = now + 2000
        -- 반경 1 청크(3x3) x 1~pz 층 중 채운 비율: 검정 화면과의 상관 확인용 (런 5)
        local coreDone, coreAll = 0, 0
        for wx = cx - 1, cx + 1 do
            for wy = cy - 1, cy + 1 do
                for z = 1, pz do
                    coreAll = coreAll + 1
                    if _air.done[wx .. "," .. wy .. "," .. z] then coreDone = coreDone + 1 end
                end
            end
        end
        log(string.format("air fill: chunk-levels=%d squares=%d around chunk (%d,%d) z<=%d core=%d/%d",
            _air.chunks, _air.squares, cx, cy, pz, coreDone, coreAll))
    end
end

-- ── 하강 줌 (HaloDrop.DESCENT_ZOOM) ───────────────────────────────────────────
-- 실제 z 는 CarryZ 에 고정이라 고도가 변하는 시각 단서가 없다(런 5). 뛰어내릴 때 옵션의 가장 먼 줌 레벨까지
-- 빼고 가상 고도가 ALT_NEAR 로 내려오는 동안 원래 줌으로 당긴다.
-- 엔진: 줌 목표는 레벨 목록의 값과 == 비교로만 옮겨 다니므로(MultiTextureFBO2.getNextZoom) 목록을 촘촘히 깔고
--   (setZoomLevels, 바닐라 Tutorial1.lua:297) doZoomScroll 로 한 단계씩 민다. 보간은 엔진이 프레임당 0.02.
--   getZoom/getMaxZoom 은 tileScale/2 가 곱해진 표시값, getNextZoom(i, 0)·목록은 내부값 -> 내부값으로 통일.
--   자동 줌(autoZoom)이 켜져 있으면 엔진이 매 프레임 목표를 덮어쓰므로 잠시 끈다.
local Z = { active = false }

local function parsePercents(s)
    local list = {}
    local pos = 1
    while true do
        local a, b = string.find(s, ";", pos, true)
        local tok = a and string.sub(s, pos, a - 1) or string.sub(s, pos)
        local n = tonumber(tok)
        if n then list[#list + 1] = n / 100 end
        if not a then break end
        pos = b + 1
    end
    return list
end

-- 옵션에 저장된 줌 레벨 목록(내부값, 큰 값 = 멀리). 비어 있으면 엔진 기본 목록
local function optionZoomLevels()
    local s = nil
    pcall(function()
        if Core.getTileScale() == 2 then s = getCore():getOptionZoomLevels2x() else s = getCore():getOptionZoomLevels1x() end
    end)
    local list = (s and s ~= "") and parsePercents(s) or {}
    if #list == 0 then list = { 2.5, 2.25, 2.0, 1.75, 1.5, 1.25, 1.0, 0.75, 0.5, 0.25 } end
    return list
end

local function descentZoomStart(p)
    local D = HaloDrop.DESCENT_ZOOM
    if not D or not D.ENABLED or Z.active then return end
    local core = getCore()
    local pi = p:getPlayerNum()
    local ok, err = pcall(function()
        local ts = Core.getTileScale() / 2
        local near = core:getNextZoom(pi, 0)            -- 현재 목표 줌(내부값)
        local far = core:getMaxZoom() / ts             -- 옵션 목록의 가장 먼 레벨(내부값)
        if far <= near + D.STEP / 2 then
            log(string.format("descent zoom: skipped (near=%.2f far=%.2f)", near, far))
            return
        end
        local levels = {}
        local v = far
        while v > near + D.STEP / 2 do
            levels[#levels + 1] = v
            v = v - D.STEP
        end
        levels[#levels + 1] = near
        Z.auto = core:getAutoZoom(pi)
        if Z.auto then core:setAutoZoom(pi, false) end
        setZoomLevels(unpack(levels))
        -- 목표는 지금 near(목록 마지막) -> 한 단계씩 far 로
        for _ = 1, #levels - 1 do core:doZoomScroll(pi, 1) end
        Z.active, Z.levels, Z.idx, Z.alt0, Z.near, Z.far, Z.pi = true, levels, 1, J.alt, near, far, pi
        log(string.format("descent zoom: start far=%.2f near=%.2f levels=%d autozoom=%s", far, near, #levels, tostring(Z.auto)))
    end)
    if not ok then log("descent zoom: start FAILED err=" .. tostring(err)) end
end

local function descentZoomTick()
    if not Z.active then return end
    local D = HaloDrop.DESCENT_ZOOM
    local n = #Z.levels
    local f = (J.alt - D.ALT_NEAR) / math.max(1, Z.alt0 - D.ALT_NEAR)   -- 1 = 출발 고도, 0 = ALT_NEAR
    if f < 0 then f = 0 elseif f > 1 then f = 1 end
    local want = n - math.floor(f * (n - 1) + 0.5)                      -- 1 = far, n = near
    if want <= Z.idx then return end
    local core = getCore()
    local pi = Z.pi
    local ok, err = pcall(function()
        while Z.idx < want do
            core:doZoomScroll(pi, -1)
            Z.idx = Z.idx + 1
        end
    end)
    if not ok then
        log("descent zoom: tick FAILED err=" .. tostring(err))
        Z.active = false
    end
end

local function descentZoomStop(reason)
    if not Z.active then return end
    Z.active = false
    local core = getCore()
    local pi = Z.pi
    local ok, err = pcall(function()
        while Z.idx < #Z.levels do
            core:doZoomScroll(pi, -1)
            Z.idx = Z.idx + 1
        end
        setZoomLevels(unpack(optionZoomLevels()))
        if Z.auto then core:setAutoZoom(pi, true) end
    end)
    log(string.format("descent zoom: stop (%s) target=%.2f ok=%s%s", tostring(reason), Z.near or -1, tostring(ok), ok and "" or (" err=" .. tostring(err))))
end

-- ── 상태 전이 ─────────────────────────────────────────────────────────────────
local function finish(p)
    J.state = nil
    planeSoundStop(p)
    p:setBlockMovement(false)
    HaloDropSky.close("finish")
    descentZoomStop("finish")
end

function HaloDropJumper.board()
    local p = getPlayer()
    if not p or p:isDead() then return end
    J.state = "ABOARD"
    J.alt = HaloDrop.opt("JumpAltitude")
    J.lastTs = getTimestampMs()
    J.released = false
    J.chuteSent = false
    J.vz, J.vh = 0, 0
    J.jump = nil
    planeSoundStart(p)
    HaloDropSky.open()
    log(string.format("board: staying at (%.1f,%.1f,%.1f), route A=(%.0f,%.0f)", p:getX(), p:getY(), p:getZ(), HaloDrop.C.fl.ax, HaloDrop.C.fl.ay))
end

-- E: 경로 현재 위치로 옮기고 구름 아래서 땅·수송기를 기다린다 (JUMPING)
local function startJump(p, reason)
    if J.state ~= "ABOARD" then return end
    local C = HaloDrop.C
    local now = getTimestampMs()
    local x, y = HaloDropFlight.pos(C.fl, now - C.t0)
    J.state = "JUMPING"
    J.x, J.y = x, y
    J.jump = { at = now, groundAt = nil, planeSeen = false, reason = reason }
    airFillReset()
    HaloDropSky.setCover(1)
    send(p, "Jumped", { id = C.id, reason = reason, x = math.floor(x), y = math.floor(y) })
    hold(p, x, y, carryZ())
    log(string.format("jump start (%s): moved to route (%.0f,%.0f) frac=%.3f, waiting for ground (max %ds)",
        reason, x, y, HaloDropFlight.frac(C.fl, now - C.t0), HaloDrop.opt("JumpWaitMax")))
end

-- JUMPING -> FREEFALL. why 는 로그용 (plane passed / ground only / timeout / forced)
local function jump(p, why)
    if J.state ~= "JUMPING" then return end
    local jp = J.jump or {}
    local now = getTimestampMs()
    J.state = "FREEFALL"
    J.alt = HaloDrop.opt("JumpAltitude")
    J.heading = HaloDropFlight.headingDeg(HaloDrop.C.fl)
    J.pitch = 0
    -- 뛰어내린 순간 수송기 속도를 이어받는다 (수평), 수직은 0 에서 가속.
    -- 상한 JUMP_VH_MAX: 런 5 에서 80 을 그대로 받아 로드 창을 벗어나 3초 스냅백 + 10초 current==null 이 났다
    J.vh = math.min(HaloDrop.C.fl.speed, HaloDrop.JUMP_VH_MAX)
    J.vz = 0
    J.waitLogged = nil
    planeSoundStop(p)
    HaloDropSky.close("freefall")
    descentZoomStart(p)
    log(string.format("jump (%s) at (%.1f,%.1f) alt=%.0fm heading=%.0f waited=%dms ground=%s plane=%s",
        why, J.x, J.y, J.alt, J.heading, now - (jp.at or now),
        jp.groundAt and tostring(jp.groundAt - jp.at) .. "ms" or "no", tostring(jp.planeSeen)))
    J.jump = nil
end

-- 파일럿(HaloDropPilot)이 점프 수송기를 이 클라에서 잡았다: 구름을 걷고 하늘 뷰를 닫아 다가오는 수송기를 보여준다.
-- 캐릭터는 아직 JUMPING(제자리 hold). 런 4 에선 통과 순간에야 닫혀 수송기가 보이기도 전에 지나갔다.
function HaloDropJumper.onPlaneAcquired()
    if J.state ~= "JUMPING" or not J.jump then return end
    if HaloDropSky.isOpen() then
        HaloDropSky.setCover(0)
        HaloDropSky.close("plane acquired")
        log("jump: plane acquired -> sky closed, waiting for pass")
    end
end

-- 수송기가 머리 위를 지났다고 파일럿(HaloDropPilot)이 알려온다
function HaloDropJumper.onPlanePassed()
    if J.state == "JUMPING" and J.jump then J.jump.planeSeen = true end
end

local function openChute(p, reason)
    if J.state ~= "FREEFALL" then return end
    J.state = "CANOPY"
    pcall(function() p:getEmitter():playSoundImpl("halodrop_chute", nil) end)
    if not J.chuteSent then
        J.chuteSent = true
        send(p, "ChuteOpen", { id = HaloDrop.C.id, reason = reason, alt = math.floor(J.alt) })
    end
    log(string.format("chute open (%s) alt=%.0fm vz=%.1f vh=%.1f", reason, J.alt, J.vz, J.vh))
end

local function land(p)
    local chute = J.state == "CANOPY"
    finish(p)
    chuteUnwear(p, "landed")
    _guardUntil = getTimestampMs() + CHUTE_GUARD_MS
    send(p, "Landed", { id = HaloDrop.C.id, chute = chute })
    log(string.format("landed at (%.1f,%.1f,%.1f) chute=%s vz=%.1f vh=%.1f", p:getX(), p:getY(), p:getZ(), tostring(chute), J.vz or 0, J.vh or 0))
end

function HaloDropJumper.onRoundEnd()
    local p = getPlayer()
    if not p then return end
    if J.state == "ABOARD" then startJump(p, "forced") end
end

-- ── 매 틱 ─────────────────────────────────────────────────────────────────────
local function onPlayerUpdate(p)
    if not J.state or p ~= getPlayer() then return end
    if p:isDead() then
        finish(p)
        return
    end
    local now = getTimestampMs()
    local dt = (now - (J.lastTs or now)) / 1000
    if dt < 0 then dt = 0 elseif dt > 0.25 then dt = 0.25 end
    J.lastTs = now
    p:setBlockMovement(true)
    local carry = carryZ()

    -- 1초 주기 상태 로그 (실시간 검증용)
    if not J.nextLog or now >= J.nextLog then
        J.nextLog = now + 1000
        local h = -1
        pcall(function() h = p:getHeightAboveFloor() end)
        local ai, act, anim = "?", "?", "?"
        pcall(function() ai = tostring(p:getCurrentStateName()) end)
        pcall(function() act = tostring(p:getActionStateName()) end)
        pcall(function() anim = tostring(p:getAnimationStateName()) end)
        log(string.format("tick state=%s alt=%.0fm z=%.2f pos=(%.1f,%.1f) vz=%.1f vh=%.1f hdg=%.0f pitch=%.2f fall=%.2f h=%.2f released=%s falling=%s ai=%s action=%s anim=%s",
            tostring(J.state), J.alt or -1, p:getZ(), p:getX(), p:getY(), J.vz or 0, J.vh or 0, J.heading or 0, J.pitch or 0,
            p:getLastFallSpeed(), h, tostring(J.released), tostring(p:isFalling()), ai, act, anim))
    end

    if J.state == "ABOARD" then
        local C = HaloDrop.C
        if not C.fl then
            -- 라운드 정보가 사라졌다(Closed 수신 등): 탑승 취소
            log("aboard: flight lost -> cancel")
            finish(p)
            return
        end
        -- 제자리에 숨은 채 대기. 경로 위치는 하늘 뷰에만 쓴다
        local x, y = HaloDropFlight.pos(C.fl, now - C.t0)
        HaloDropSky.update(x, y, HaloDropFlight.headingDeg(C.fl), dt)
        p:setLastFallSpeed(0)
        return
    end

    if J.state == "JUMPING" then
        local C = HaloDrop.C
        local jp = J.jump
        hold(p, J.x, J.y, carry)
        local fx, fy = 1, 0
        if C.fl then fx, fy = HaloDropFlight.dir(C.fl) end
        p:setForwardDirection(fx, fy)
        if C.fl then HaloDropSky.update(J.x, J.y, HaloDropFlight.headingDeg(C.fl), dt) end
        local waited = now - jp.at
        if not jp.groundAt and p:getSquare() ~= nil then
            jp.groundAt = now
            log(string.format("jump: ground loaded after %dms at (%.0f,%.0f)", waited, J.x, J.y))
        end
        if jp.groundAt then airFill(p) end
        local maxMs = HaloDrop.opt("JumpWaitMax") * 1000
        if jp.planeSeen then
            jump(p, "plane passed")
        elseif waited > maxMs then
            jump(p, "timeout")
        elseif jp.groundAt and not C.jump and now - jp.groundAt > HaloDrop.JUMP_PLANE_GRACE_MS then
            -- 땅은 올라왔는데 서버가 수송기를 못 띄웠다(스폰 실패 등): 그냥 떨어진다
            jump(p, "ground only")
        end
        return
    end

    -- ── 강하 모델 ──
    airFill(p)
    local canopy = J.state == "CANOPY"
    local turnRate = canopy and HaloDrop.opt("CanopyTurnRate") or HaloDrop.opt("FreefallTurnRate")
    local accel = canopy and HaloDrop.opt("CanopyAccel") or HaloDrop.opt("FreefallAccel")
    local vBase = canopy and HaloDrop.opt("CanopySpeed") or HaloDrop.opt("FreefallSpeed")
    local hBase = canopy and HaloDrop.opt("CanopySteer") or HaloDrop.opt("FreefallSteer")
    local tbl = canopy and HaloDrop.CP or HaloDrop.FF

    -- 입력
    local turn = 0
    if keyDown("Left") then turn = turn - 1 end
    if keyDown("Right") then turn = turn + 1 end
    local pitchTarget = 0
    if keyDown("Forward") then pitchTarget = pitchTarget + 1 end
    if keyDown("Backward") then pitchTarget = pitchTarget - 1 end
    local diving = pitchTarget > 0 and keyDown("Run")

    -- heading: 선회 속도 한도 안에서만 돈다
    J.heading = J.heading + turn * turnRate * dt
    J.heading = wrapDeg(J.heading)
    -- pitch: 즉시 +-1 로 튀지 않고 PitchRate 로 기운다
    local pr = HaloDrop.opt("PitchRate") * dt
    if J.pitch < pitchTarget then J.pitch = math.min(pitchTarget, J.pitch + pr)
    elseif J.pitch > pitchTarget then J.pitch = math.max(pitchTarget, J.pitch - pr) end

    -- 목표 속도 -> 관성으로 수렴
    local tv, th = targets(tbl, vBase, hBase, J.pitch, diving)
    J.vz = approach(J.vz, tv, accel, dt)
    J.vh = approach(J.vh, th, accel, dt)

    -- 수평 이동은 heading 방향으로만. 다음 칸이 이 클라에 아직 안 올라와 있으면 가상 위치를 전진시키지 않는다
    -- (런 5: 미로드 칸으로 나가면 postupdate 가 직전 칸 중앙으로 되돌리고, 가상 위치만 앞서가 far move 가 났다)
    local r = math.rad(J.heading)
    local hx, hy = math.cos(r), math.sin(r)
    if J.vh > 0.01 then
        local nx, ny = J.x + hx * J.vh * dt, J.y + hy * J.vh * dt
        if getCell():getGridSquare(math.floor(nx), math.floor(ny), 0) ~= nil then
            J.x, J.y = nx, ny
            J.waitLogged = nil
        elseif not J.waitLogged then
            J.waitLogged = true
            log(string.format("fall: next square (%d,%d) not loaded -> holding horizontal", math.floor(nx), math.floor(ny)))
        end
    end
    p:setForwardDirection(hx, hy)
    descentZoomTick()

    if not J.released and J.alt - J.vz * dt > carryAltM() then
        -- 붙잡기: 가상 고도를 줄이고 실제 z 는 visualZ 로 따라 내린다 (DESCENT_Z 꺼져 있으면 CarryZ 고정)
        J.alt = J.alt - J.vz * dt
        hold(p, J.x, J.y, visualZ(J.alt))
    else
        if not J.released then
            J.released = true
            log(string.format("release to engine fall at z=%.1f state=%s vz=%.1f", p:getZ(), J.state, J.vz))
        end
        -- 놓기: 엔진이 z 를 내린다. 수평 위치와 낙하 속도만 정한다.
        p:setForceX(J.x)
        p:setForceY(J.y)
        J.alt = p:getZ() * HaloDrop.M_PER_FLOOR
        local h = p:getHeightAboveFloor()
        if h <= 0.001 then
            land(p)
            return
        end
        local v = J.vz / HaloDrop.M_PER_FLOOR
        if h < HaloDrop.BRAKE_H and canopy then v = HaloDrop.LAND_SPEED end
        p:setLastFallSpeed(v)
    end

    local auto = HaloDrop.opt("AutoOpenAltitude")
    if J.state == "FREEFALL" and auto > 0 and J.alt <= auto then
        openChute(p, "auto")
    end
end
Events.OnPlayerUpdate.Add(onPlayerUpdate)

-- 상호작용 키: 탑승 중이면 뛰어내리기(수송기 출발 후), 자유낙하 중이면 낙하산
local function onKeyPressed(key)
    if not J.state or key ~= getCore():getKey("Interact") then return end
    local p = getPlayer()
    if not p then return end
    if J.state == "ABOARD" then
        local C = HaloDrop.C
        if C.fl and getTimestampMs() - C.t0 >= 0 then startJump(p, "key") end
    elseif J.state == "FREEFALL" then
        openChute(p, "key")
    end
end
Events.OnKeyPressed.Add(onKeyPressed)

local function onPlayerDeath(p)
    if p == getPlayer() and J.state then
        log("died during state " .. tostring(J.state))
        finish(p)
        chuteUnwear(p, "death")
    end
end
Events.OnPlayerDeath.Add(onPlayerDeath)

-- 공중에서 접속이 끊겼다 다시 들어오면 낙하산이 남아 있을 수 있다 -> 서버에 회수 요청
local _cleanupDone = false
local function cleanupTick()
    if _cleanupDone then return end
    local p = getPlayer()
    if not p then return end
    _cleanupDone = true
    Events.OnTick.Remove(cleanupTick)
    if findChute(p) or #wornChutes(p) > 0 then
        log("leftover parachute found -> cleanup")
        chuteUnwear(p, "cleanup")
        send(p, "Cleanup", {})
    end
end
Events.OnTick.Add(cleanupTick)
