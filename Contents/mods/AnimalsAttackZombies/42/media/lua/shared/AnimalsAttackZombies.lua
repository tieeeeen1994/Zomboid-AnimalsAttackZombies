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
      - server/AnimalsAttackZombies_Threat.lua: decides when an animal turns on a zombie
        (sizing it up, crowds, hurt animals), makes the roster animals that are not
        fighting run instead.
      - server/AnimalsAttackZombies_Attack.lua: the warning display, the charge and the
        hits.
      - client/AnimalsAttackZombies_Client.lua: plays the warning call, the strike and the
        hit on a multiplayer client, where the server cannot.
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
-- Server -> every client: play the strike on this animal now. AnimalPacket does carry
-- idleAction, but only every 0.8-1 s (AnimalSynchronizationManager); the server also pushes
-- an extra packet (IsoAnimal.sendExtraUpdateToClients), which is unreliable.
AAZ.CMD_STRIKE = "Strike"
-- Server -> every client: an animal's hit on a zombie. Only the client that simulates the
-- zombie (NetworkZombieManager.moveZombie) changes its health, since anything else is
-- overwritten by that client's next update; every other client plays the stagger or
-- knockdown on its own copy, as vanilla does with a relayed weapon hit (ZombiePacket
-- carries health but no hit reaction).
AAZ.CMD_HIT = "Hit"
-- Server -> every client: play this animal's warning call. Animal voices are played by each
-- client's own AnimalSoundState, so a sound started on the server is never heard.
AAZ.CMD_WARN = "Warn"

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
--   option    the sandbox option that turns the species on
--   prefix    the start of its tuning options on the Species page: <prefix>Damage and so on
--   guards    "herd":  itself and the animals of its kind around it (intact males)
--             "young": its own babies, and only while it has some (mothers)
--   rut       true: at a reduced range outside its mating season (RutRange option;
--             IsoAnimal.isInMatingSeason is always true when the sandbox turns seasons off)
--   breeds    breed -> default range percent, as the <prefix><Breed> options; dairy bulls
--             are the quickest to fight
--   defaults  the tuning options' defaults:
--     Damage     zombie health one hit takes, before the strength gene and the
--                DamageMultiplier option. A zombie has about 2 (1.8 to 2.1 at normal
--                toughness), so a bull kills in about three hits and a rooster in forty.
--     Knockdown  percent chance that a hit knocks the zombie off its feet
--     Temper     how readily it commits to a charge once a zombie is in range (Hesitation).
--                Mothers defending young commit fastest, turkey toms bluff the most.
--     WarnMin/WarnMax  seconds of warning display before the charge (WarningDisplay): a
--                bull squares up, bellows and paws for longest, a boar or rooster barely pauses.
-- Keep the defaults in step with sandbox-options.txt.
AAZ.roster = {
    bull     = { option = "Bulls", prefix = "Bull", guards = "herd",
                 breeds = { holstein = 100, simmental = 85, angus = 75 },
                 defaults = { Damage = 0.8, Knockdown = 70, Temper = 1.0, WarnMin = 1.5, WarnMax = 3.0 } },
    boar     = { option = "Boars", prefix = "Boar", guards = "herd",
                 defaults = { Damage = 0.6, Knockdown = 50, Temper = 1.0, WarnMin = 0.5, WarnMax = 1.5 } },
    ram      = { option = "Rams", prefix = "Ram", guards = "herd", rut = true,
                 defaults = { Damage = 0.45, Knockdown = 60, Temper = 0.9, WarnMin = 1.0, WarnMax = 2.0 } },
    cockerel = { option = "Roosters", prefix = "Rooster", guards = "herd",
                 defaults = { Damage = 0.05, Knockdown = 0, Temper = 1.1, WarnMin = 0.3, WarnMax = 0.8 } },
    gobblers = { option = "TurkeyToms", prefix = "TurkeyTom", guards = "herd", rut = true,
                 defaults = { Damage = 0.06, Knockdown = 0, Temper = 0.8, WarnMin = 1.0, WarnMax = 2.5 } },
    sow      = { option = "Sows", prefix = "Sow", guards = "young",
                 defaults = { Damage = 0.5, Knockdown = 25, Temper = 1.3, WarnMin = 0.5, WarnMax = 1.2 } },
    cow      = { option = "Cows", prefix = "Cow", guards = "young",
                 defaults = { Damage = 0.6, Knockdown = 40, Temper = 1.3, WarnMin = 1.0, WarnMax = 2.0 } },
}

function AAZ.getOption(name)
    local vars = SandboxVars.AnimalsAttackZombies
    return vars and vars[name]
end

-- A sandbox option, or the given default when it is missing (an old save, or a server
-- running an older copy of the mod). Every number the mod plays by comes through here.
function AAZ.opt(name, default)
    local value = AAZ.getOption(name)
    if value == nil then
        return default
    end
    return value
end

-- One of a species' tuning values from the Species page: key is Damage, Knockdown,
-- Temper, WarnMin or WarnMax.
function AAZ.tuning(profile, key)
    return AAZ.opt(profile.prefix .. key, profile.defaults[key])
end

-- A breed's range percent, or nil for a breed without one.
function AAZ.breedRange(profile, breed)
    local default = profile.breeds and profile.breeds[breed]
    if not default then
        return nil
    end
    return AAZ.opt(profile.prefix .. string.upper(string.sub(breed, 1, 1)) .. string.sub(breed, 2), default)
end

-- The roster entry for this animal, or nil when its species does not fight or is turned off.
function AAZ.getProfile(animal)
    local profile = AAZ.roster[animal:getAnimalType()]
    if profile and AAZ.opt(profile.option, true) then
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

-- A gene's value (0 to 1, usually 0.2 to 0.6), pulled toward the given average by the
-- GeneInfluence option: at 100% the animal's own value, at 0% everyone is average, at
-- 200% the differences doubled. The average stands in for an animal without the gene.
function AAZ.getGene(animal, name, average)
    local allele = animal:getUsedGene(name)
    if not allele then
        return average
    end
    local influence = AAZ.opt("GeneInfluence", 100) / 100
    return math.max(0, average + (allele:getCurrentValue() - average) * influence)
end

-- The animal's stressed call (a bull's bellow, a boar's grunt, a rooster's alarm), which every
-- roster species has. Must run where the sound is heard: single player or a client.
function AAZ.playWarning(animal)
    animal:playBreedSound("stressed")
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

-- The visible part of a hit from an animal standing at (fromX, fromY): the stagger, or
-- the knockdown when knockdown is true. Mirrors what a weapon hit leaves behind
-- (IsoGameCharacter.calculateHitDirection, CombatManager's playerAttackPosition,
-- IsoZombie.knockDown). A zombie on the ground is left as it is: trampled where it lies,
-- it stays down, and dies there once out of health.
function AAZ.applyHitReaction(zombie, fromX, fromY, knockdown)
    if zombie:isOnFloor() then
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

    if knockdown then
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

-- Lands a hit from an animal standing at (fromX, fromY): the damage and its reaction. Must
-- run where the zombie is simulated: in single player, on the client that owns it, or on
-- the server when no client does.
--
-- IsoZombie.Hit() needs a HandWeapon and a player wielder, so it is not used. A zombie out
-- of health is always knocked down: once it is on the ground ZombieOnGroundState finds it
-- dead and calls die(). In multiplayer the owner's next update carries the health to the
-- server, which kills the zombie and tells every client.
function AAZ.applyHit(zombie, fromX, fromY, damage, knockdown)
    if zombie:isDead() then
        return
    end

    local health = math.max(zombie:getHealth() - damage, 0)
    zombie:setHealth(health)
    AAZ.applyHitReaction(zombie, fromX, fromY, knockdown or health <= 0)
end
