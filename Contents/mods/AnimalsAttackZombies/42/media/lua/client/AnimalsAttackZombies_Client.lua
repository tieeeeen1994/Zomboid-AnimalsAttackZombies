--[[
    Animals Attack Zombies -- the multiplayer client's half of a fight.

    The server runs the animals (IsoAnimal.updateInternal() skips behavior.update() on a
    client) and decides everything about a fight, but three things only a client can do:

      - Play the warning call. Animal voices come from each client's own AnimalSoundState;
        one started on the server is never heard.
      - Start the strike at once. AnimalPacket carries idleAction, but only every 0.8-1 s
        (or as an unreliable extra update), so the server also tells every client.
      - Land the hit. A zombie is simulated by one client (NetworkZombieManager.moveZombie
        hands it to the nearest player), whose updates overwrite anything the server does
        to it: that client takes the damage, and its next update carries the health to the
        server, which kills the zombie for everyone. Every other client plays the stagger
        or knockdown on its own copy, as vanilla does with a relayed weapon hit, since a
        zombie's own sync (ZombiePacket) carries no hit reaction.

    Single player does all three on the spot and never gets here. Everything else a
    client sees (the animal facing the zombie, running, its stress) comes through the
    animal's own sync (AnimalPacket).
]]

if not isClient() then return end

require "AnimalsAttackZombies"
local AAZ = AnimalsAttackZombies

local function onServerCommand(module, command, args)
    if module ~= AAZ.MODULE then
        return
    end

    if command == AAZ.CMD_WARN then
        local animal = getAnimal(args.animal)
        if animal then
            AAZ.playWarning(animal)
        end
    elseif command == AAZ.CMD_STRIKE then
        local animal = getAnimal(args.animal)
        if animal then
            animal:setVariable("idleAction", AAZ.STRIKE_ACTION)
        end
    elseif command == AAZ.CMD_HIT then
        local zombie = AAZ.findZombie(args.zombie)
        if not zombie or zombie:isDead() then
            return
        end
        -- Whoever owns the zombie when the hit arrives takes the damage; ownership may have
        -- moved since the server sent it.
        if zombie:isRemoteZombie() then
            AAZ.applyHitReaction(zombie, args.x, args.y, args.knockdown or args.lethal)
        else
            AAZ.applyHit(zombie, args.x, args.y, args.damage, args.knockdown)
        end
    end
end

Events.OnServerCommand.Add(onServerCommand)
