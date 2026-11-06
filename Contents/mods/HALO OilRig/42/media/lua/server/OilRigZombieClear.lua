-- OilRig: keep the rig free of zombies.
-- B42 has no "no zombie spawn" zone, so the server removes every zombie
-- inside the rig footprint (all levels) and tells clients to drop their copies.
-- Server and SP only. MP clients also load media/lua/server, hence the guard.
if isClient() then return end

-- Rig footprint, world coords, inclusive. Must match the 75_1 lot.
local RIG = { x1 = 19200, y1 = 256, x2 = 19226, y2 = 287 }
local SWEEP_TICKS = 60 -- periodic sweep, about once per second

local tick = 0
local sweepSoon = false

local function log(msg)
    print("[OilRig] " .. msg)
end

local function inRig(z)
    local x, y = math.floor(z:getX()), math.floor(z:getY())
    return x >= RIG.x1 and x <= RIG.x2 and y >= RIG.y1 and y <= RIG.y2
end

local function sweep(source)
    local cell = getCell()
    if not cell then return end
    local list = cell:getZombieList()
    local found = {}
    for i = 0, list:size() - 1 do
        local z = list:get(i)
        if z and inRig(z) then
            found[#found + 1] = z
        end
    end
    if #found == 0 then return end

    local ids = {}
    for _, z in ipairs(found) do
        local id = z:getOnlineID()
        log(string.format("removing zombie id=%d at (%d,%d,%d) reanimated=%s source=%s",
            id, math.floor(z:getX()), math.floor(z:getY()), math.floor(z:getZ()),
            tostring(z:isReanimatedPlayer()), source))
        -- Same steps as the vanilla removezombies command, minus the
        -- delete packet (NetworkZombiePacker is not exposed to Lua).
        z:removeFromWorld()
        z:removeFromSquare()
        if id ~= -1 then
            ids[#ids + 1] = id
        end
    end

    if isServer() and #ids > 0 then
        sendServerCommand("OilRig", "RemoveZombies", { ids = ids })
    end
    log(string.format("removed %d zombie(s), notified clients of %d id(s)", #found, #ids))
end

-- Fires before the zombie is added to the world, so only flag a sweep here.
local function onZombieCreate(z)
    if z and inRig(z) then
        sweepSoon = true
    end
end

local function onTick()
    tick = tick + 1
    if sweepSoon or tick >= SWEEP_TICKS then
        local source = sweepSoon and "create" or "periodic"
        tick = 0
        sweepSoon = false
        sweep(source)
    end
end

Events.OnZombieCreate.Add(onZombieCreate)
Events.OnTick.Add(onTick)
log(string.format("zombie clear active for rig (%d,%d)-(%d,%d)", RIG.x1, RIG.y1, RIG.x2, RIG.y2))
