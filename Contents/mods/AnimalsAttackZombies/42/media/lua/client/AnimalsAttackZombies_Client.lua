--[[
    Animals Attack Zombies -- the multiplayer client's half of a fight.

    The server runs the animals (IsoAnimal.updateInternal() skips behavior.update() on a
    client), but two things only a client can do:

      - Play the strike. The server sets idleAction on its copy of the animal, and
        idleAction is not synced (AnimalStateVariables only carries on-floor, dead,
        running and attacking), so every client sets it on its own copy.
      - Land the hit. A zombie is simulated by one client (NetworkZombieManager.moveZombie
        hands it to the nearest player), whose updates overwrite anything the server does
        to it. The server sends the hit to that player, and the knockdown and death then
        reach everyone through the zombie's own sync, as with any other hit.

    Single player does both on the spot and never gets here.
]]

if not isClient() then return end

require "AnimalsAttackZombies"
local AAZ = AnimalsAttackZombies

local function onServerCommand(module, command, args)
    if module ~= AAZ.MODULE then
        return
    end

    if command == AAZ.CMD_STRIKE then
        local animal = getAnimal(args.animal)
        if animal then
            animal:setVariable("idleAction", AAZ.STRIKE_ACTION)
        end
    elseif command == AAZ.CMD_HIT then
        local zombie = AAZ.findZombie(args.zombie)
        -- Ownership may have moved to another client since the server sent this, and only
        -- the owner's changes stick.
        if zombie and not zombie:isRemoteZombie() then
            AAZ.applyHit(zombie, args.x, args.y, args.damage, args.knockdown)
        end
    end
end

Events.OnServerCommand.Add(onServerCommand)
