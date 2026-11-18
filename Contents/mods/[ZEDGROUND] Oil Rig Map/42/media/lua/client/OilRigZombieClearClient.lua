-- OilRig: drop local copies of zombies the server removed from the rig.
-- Mirrors the vanilla ZombieDeleteOnClient packet, which Lua cannot send.
if not isClient() then return end

local function onServerCommand(module, command, args)
    if module ~= "OilRig" or command ~= "RemoveZombies" then return end
    if not args or not args.ids then return end

    local want = {}
    local total = 0
    for _, id in ipairs(args.ids) do
        want[math.floor(id)] = true
        total = total + 1
    end

    local cell = getCell()
    if not cell then return end
    local list = cell:getZombieList()
    local hit = {}
    for i = 0, list:size() - 1 do
        local z = list:get(i)
        if z and want[math.floor(z:getOnlineID())] then
            hit[#hit + 1] = z
        end
    end

    for _, z in ipairs(hit) do
        pcall(function() z:getEmitter():unregister() end)
        z:removeFromWorld()
        z:removeFromSquare()
    end
    print(string.format("[OilRig] client removed %d of %d zombie(s) by server request", #hit, total))
end

Events.OnServerCommand.Add(onServerCommand)
