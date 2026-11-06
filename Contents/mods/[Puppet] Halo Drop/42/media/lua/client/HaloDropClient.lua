-- Halo Drop 클라: 서버 커맨드 수신, 비행 정보 캐시, 탑승자 숨기기(자기 포함)
--
-- HaloDrop.C (라운드 캐시)
--   fl       경로 (HaloDropFlight.make 형식)
--   t0       경로 경과 0 에 해당하는 로컬 getTimestampMs (서버가 보낸 경과 ms 로 역산)
--   id       라운드 번호
--   aboard   [key] = true  아직 수송기에 탄 사람
--   pilotKey 수송기 차량을 모는 클라 (HaloDropPilot.lua)
--   vid      수송기 차량 id (없으면 nil)
--   ended    경로 끝 / 어드민 종료

if isServer() then return end

require "HaloDropConfig"
require "HaloDropFlight"

HaloDrop.C = { aboard = {} }

local function log(msg) HaloDrop.log(msg) end

local function myKey()
    local p = getPlayer()
    return p and HaloDrop.playerKey(p) or nil
end

local function resetCache()
    HaloDrop.C = { aboard = {} }
end

-- ── 탑승자 숨기기 (자기 자신 포함) ──────────────────────────────────────────
-- 바닐라 투명화(setInvisible)는 못 쓴다:
--   * 능력(ToggleInvisibleHimself)이 없으면 false 로 강제되고, 비관리자 클라가 보내는
--     ExtraInfo(invisible=true) 는 서버에서 권한 위반이다(ExtraInfoPacket.processServer).
--   * 자기 캐릭터는 플래그가 있어도 보인다 -- IsoPlayer.render 가 매 프레임
--     checkCanSeeClient(this) 로 targetAlpha 를 1 로 되돌린다(remoteChr == this 면 무조건 true).
--     그래서 setAlphaAndTarget(0) 도 다음 렌더에 지워진다.
-- 대신 setSceneCulled(true) 를 쓴다. IsoObject.render 가 통째로 건너뛰고
-- IsoGameCharacter.setSceneCulled 가 ModelManager 에서 모델을 뺀다. 엔진이 분할화면 플레이어
-- 제거·부활 플레이어 제거에 쓰는 로컬 전용 스위치라 패킷·권한 검사가 없고, false 로 되돌리면
-- 모델이 다시 붙는다. IsoPlayer 는 업데이트 우선순위가 항상 FULL 이라(getMinimumSimulationLevel)
-- 컬링돼도 OnPlayerUpdate 가 그대로 돈다.
-- 숨기는 대상: 서버가 알려준 탑승자(C.aboard) 전원. 자기 자신은 HaloDrop.J.state == "ABOARD" 일 때만
-- (뛰어내리는 즉시 보여야 하므로 서버 Member 방송을 기다리지 않는다).
local _hidden = {}   -- [key] = IsoPlayer (이 클라가 숨긴 플레이어)

local function setHidden(p, on)
    local ok, err = pcall(function() p:setSceneCulled(on) end)
    if not ok then log("setSceneCulled(" .. tostring(on) .. ") FAILED err=" .. tostring(err)) end
    return ok
end

local function hideTick()
    local C = HaloDrop.C
    local me = getPlayer()
    local mine = me and HaloDrop.playerKey(me) or nil
    local want = HaloDrop.opt("HideCarried") and C.fl ~= nil and not C.ended
    local function shouldHide(k)
        if not want or not C.aboard[k] then return false end
        if k == mine then return HaloDrop.J ~= nil and HaloDrop.J.state == "ABOARD" end
        return true
    end
    -- 숨김 해제: 내린 사람, 라운드 끝, 옵션 끔
    for k, p in pairs(_hidden) do
        if not shouldHide(k) then
            setHidden(p, false)
            _hidden[k] = nil
            log("unhide " .. tostring(k))
        end
    end
    if not want then return end
    for k, _ in pairs(C.aboard) do
        if not _hidden[k] and shouldHide(k) then
            local p = (k == mine) and me or getPlayerByOnlineID(tonumber(k))
            if p and setHidden(p, true) then
                _hidden[k] = p
                log("hide " .. tostring(k) .. (k == mine and " (self)" or ""))
            end
        end
    end
end
Events.OnTick.Add(hideTick)

-- ── 서버 커맨드 ───────────────────────────────────────────────────────────────
function HaloDrop.onServerCommand(module, command, args)
    if module ~= HaloDrop.MODULE then return end
    local C = HaloDrop.C
    if command == "Flight" then
        resetCache()
        C = HaloDrop.C
        C.id = args.id
        C.fl = { ax = args.ax, ay = args.ay, bx = args.bx, by = args.by, speed = args.speed, durMs = args.dur }
        C.t0 = getTimestampMs() - args.elapsed
        C.pilotKey = args.pilot
        C.vid = args.vid
        C.ended = false
        local n = 0
        local amMember = false
        local mine = myKey()
        for _, k in ipairs(args.members) do
            C.aboard[k] = true
            n = n + 1
            if k == mine then amMember = true end
        end
        log(string.format("flight %d A=(%.0f,%.0f) B=(%.0f,%.0f) elapsed=%d dur=%d members=%d me=%s member=%s pilot=%s vid=%s",
            C.id, C.fl.ax, C.fl.ay, C.fl.bx, C.fl.by, args.elapsed, C.fl.durMs, n, tostring(mine),
            tostring(amMember), tostring(C.pilotKey), tostring(C.vid)))
        if amMember and HaloDropJumper then HaloDropJumper.board() end
    elseif args.id ~= C.id then
        return
    elseif command == "Member" then
        C.aboard[args.key] = args.aboard or nil
    elseif command == "Pilot" then
        C.pilotKey = args.pilot
        C.vid = args.vid
        log("pilot -> " .. tostring(C.pilotKey) .. " (me=" .. tostring(myKey()) .. ")")
    elseif command == "PlaneGone" then
        C.vid = nil
    elseif command == "End" then
        C.ended = true
        log("round " .. tostring(C.id) .. " end")
        if HaloDropJumper then HaloDropJumper.onRoundEnd() end
    elseif command == "Closed" then
        log("round " .. tostring(C.id) .. " closed")
        resetCache()
    end
end
Events.OnServerCommand.Add(HaloDrop.onServerCommand)
