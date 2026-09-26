--[[
    Animals Attack Zombies -- shared

    Written against Build 42 (Steam build 24909800). Java names in the comments come
    from a Vineflower decompile of projectzomboid.jar. docs/implementation.md holds the
    engine findings, and docs/research.md the real-life behavior behind the roster below.

    How the mod is laid out:

      - shared/AnimalsAttackZombies.lua (this file): the roster of animals that fight,
        the sandbox option reads, and AAZ.applyHit(), which lands an animal's hit on a
        zombie wherever that zombie is simulated.
      - shared/Definitions/animal/AnimalsAttackZombies_GeneralDefinitions.lua: stops the
        roster animals running from zombies on their own, so they can stand their ground.
      - server/AnimalsAttackZombies_Threat.lua: decides when an animal turns on a zombie,
        and makes the roster animals that are not fighting run instead.
      - server/AnimalsAttackZombies_Attack.lua: charges the zombie and times the hits.
      - client/AnimalsAttackZombies_Client.lua: plays the strike and lands the hit on a
        multiplayer client, where the server cannot.
      - AnimSets/<animset>/idle/AnimalsAttackZombies_Strike.xml: the strike animation.
      - Server files start with `if isClient() then return end`: animal AI only runs on
        the server and in single player (IsoAnimal.updateInternal() skips
        behavior.update() on a client).
      - Every species has its own sandbox option on the AnimalsAttackZombies page, on by
        default, read as SandboxVars.AnimalsAttackZombies.<Option>, with its name and a
        tooltip in Translate/EN/Sandbox.json.
      - Every species has a line in README.md, workshop.txt and mod.info; keep the three
        in step.
]]

AnimalsAttackZombies = AnimalsAttackZombies or {}
local AAZ = AnimalsAttackZombies

AAZ.MODULE = "AnimalsAttackZombies"
-- Server -> every client: play the strike on this animal. idleAction is not synced
-- (AnimalStateVariables only sends on-floor, dead, running and attacking).
AAZ.CMD_STRIKE = "Strike"
-- Server -> the player whose client simulates the zombie: land the hit on it. A zombie
-- belongs to one client in multiplayer (NetworkZombieManager.moveZombie), and anything
-- the server does to it is overwritten by that client's next update.
AAZ.CMD_HIT = "Hit"

-- The idleAction value that plays the strike node this mod adds to each animset's idle
-- state. The attack state itself cannot be used: it runs while isAnimalAttacking, a
-- read-only callback variable bound to IsoAnimal.atkTarget, which Lua cannot set.
-- Must not start with "idle", or BaseAnimalBehavior.clearIdleAction() wipes it.
AAZ.STRIKE_ACTION = "aazStrike"

-- Per animset: seconds into the clip at which the hit lands (the vanilla attack node's
-- AttackConnect point), and the clip's length (from its .x file in media/anims_X).
AAZ.strikeTiming = {
    cow      = { connect = 0.68, length = 1.93 }, -- Cow_Attack_HeadSwipe, connects at 35%
    pig      = { connect = 1.55, length = 1.63 }, -- FarmPig_Attack_Bite, 95%
    ram      = { connect = 0.53, length = 1.50 }, -- SheepRam_Attack_Headbutt, 35%
    cockerel = { connect = 1.74, length = 1.83 }, -- Chk_Cock_Attack_Claw, 95%
    turkey   = { connect = 1.64, length = 1.73 }, -- Turk_Attack_Claw, 95%
}

-- Animal type -> how it fights. Only these types ever attack a zombie.
--   option     the sandbox option that turns the species on
--   guards     "herd":  itself and the animals of its kind around it (intact males)
--              "young": its own babies, and only while it has some (mothers)
--   rut        true: at half range outside its mating season (IsoAnimal.isInMatingSeason,
--              which is always true when the sandbox turns mating seasons off)
--   damage     zombie health one hit takes, before the strength gene and the
--              DamageMultiplier option. A zombie has about 2 (1.8 to 2.1 at normal
--              toughness), so a bull kills in about three hits and a rooster in forty.
--   knockdown  chance that a hit knocks the zombie off its feet
--   breeds     range factor per breed; dairy bulls are the quickest to fight
AAZ.roster = {
    bull     = { option = "Bulls",      guards = "herd",  damage = 0.8,  knockdown = 0.7,
                 breeds = { holstein = 1.0, simmental = 0.85, angus = 0.75 } },
    boar     = { option = "Boars",      guards = "herd",  damage = 0.6,  knockdown = 0.5 },
    ram      = { option = "Rams",       guards = "herd",  damage = 0.45, knockdown = 0.6, rut = true },
    cockerel = { option = "Roosters",   guards = "herd",  damage = 0.05, knockdown = 0 },
    gobblers = { option = "TurkeyToms", guards = "herd",  damage = 0.06, knockdown = 0, rut = true },
    sow      = { option = "Sows",       guards = "young", damage = 0.5,  knockdown = 0.25 },
    cow      = { option = "Cows",       guards = "young", damage = 0.6,  knockdown = 0.4 },
}

function AAZ.getOption(name)
    local vars = SandboxVars.AnimalsAttackZombies
    return vars and vars[name]
end

-- The roster entry for this animal, or nil when its species does not fight or is turned off.
function AAZ.getProfile(animal)
    local profile = AAZ.roster[animal:getAnimalType()]
    if profile and AAZ.getOption(profile.option) then
        return profile
    end
    return nil
end

function AAZ.getDefinition(animal)
    return AnimalDefinitions.animals[animal:getAnimalType()]
end

function AAZ.getStrikeTiming(animal)
    local def = AAZ.getDefinition(animal)
    return def and AAZ.strikeTiming[def.animset]
end

-- A gene's value, 0 to 1 (usually 0.2 to 0.6), or the given default when the animal has none.
function AAZ.getGene(animal, name, default)
    local allele = animal:getUsedGene(name)
    if allele then
        return allele:getCurrentValue()
    end
    return default
end

function AAZ.findZombie(onlineId)
    local zombies = getCell():getZombieList()
    for i = 0, zombies:size() - 1 do
        local zombie = zombies:get(i)
        if zombie:getOnlineID() == onlineId then
            return zombie
        end
    end
    return nil
end

-- Which side of the zombie a point lies on, as IsoGameCharacter.testDotSide() works it out.
-- (dx, dy) runs from the zombie to the point and is not zero.
local function getSide(zombie, dx, dy)
    local length = math.sqrt(dx * dx + dy * dy)
    dx, dy = dx / length, dy / length
    local fx, fy = zombie:getForwardDirectionX(), zombie:getForwardDirectionY()
    local dot = dx * fx + dy * fy
    if dot > 0.7 then
        return "FRONT"
    end
    if dot < -0.5 then
        return "BEHIND"
    end
    if dx * fy - dy * fx > 0 then
        return "RIGHT"
    end
    return "LEFT"
end

-- Lands a hit from an animal standing at (fromX, fromY). Must run where the zombie is
-- simulated: in single player, on the client that owns it, or on the server when no
-- client does.
--
-- Mirrors what a weapon hit leaves behind (IsoGameCharacter.calculateHitDirection,
-- CombatManager's playerAttackPosition, IsoZombie.knockDown) without IsoZombie.Hit(),
-- which needs a HandWeapon and a player wielder. A zombie out of health is always
-- knocked down: once it is on the ground ZombieOnGroundState finds it dead and calls
-- die(), which also reports the death to the server in multiplayer.
function AAZ.applyHit(zombie, fromX, fromY, damage, knockdown)
    if zombie:isDead() then
        return
    end

    local health = math.max(zombie:getHealth() - damage, 0)
    zombie:setHealth(health)
    if zombie:isOnFloor() then
        -- Trampled where it lies: it stays down, and dies there once out of health.
        return
    end

    local dx, dy = zombie:getX() - fromX, zombie:getY() - fromY
    if math.abs(dx) + math.abs(dy) < 0.01 then
        dx = 1
    end
    local hitDir = zombie:getHitDir()
    hitDir:set(dx, dy)
    hitDir:normalize()
    zombie:setHitReaction("")

    if knockdown or health <= 0 then
        -- Turned to face the animal, so it goes over backwards and away from it. Only
        -- FRONT reliably knocks down: the transitions for a hit from behind test for
        -- "BACK", which vanilla never sets.
        zombie:setForwardDirection(-dx, -dy)
        zombie:setPlayerAttackPosition("FRONT")
        zombie:setHitFromBehind(false)
        zombie:setKnockedDown(true)
        zombie:setStaggerBack(true)
        zombie:setHitForce(1.0)
    else
        local side = getSide(zombie, -dx, -dy)
        zombie:setPlayerAttackPosition(side)
        zombie:setHitFromBehind(side == "BEHIND")
        zombie:setStaggerBack(true)
        zombie:setHitForce(0.6)
    end
    zombie:reportEvent("wasHit")
end
