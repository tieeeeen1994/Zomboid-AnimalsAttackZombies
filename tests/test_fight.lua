-- Fight scenarios, run by run_tests.py in a fresh Lua state each, with the real vanilla
-- animal definitions and the real mod files loaded on top of fake_pz.lua.

local AAZ = AnimalsAttackZombies
Tests = {}

local function check(cond, msg)
    if not cond then error(msg, 2) end
end

local function strikeTimes(animal)
    local times = {}
    for _, v in ipairs(World.varLog) do
        if v.animal == animal and v.key == "idleAction" and v.value == AAZ.STRIKE_ACTION then
            times[#times + 1] = v.time
        end
    end
    return times
end

local function hitTimes(zombie)
    local times = {}
    for _, h in ipairs(World.hitLog) do
        if h.zombie == zombie then times[#times + 1] = h.time end
    end
    return times
end

local function sentCommands(command)
    local found = {}
    for _, c in ipairs(World.sent) do
        if c.command == command then found[#found + 1] = c end
    end
    return found
end

-- Definitions --------------------------------------------------------------------------

function Tests.definitions_stop_roster_fleeing()
    for animalType in pairs(AAZ.roster) do
        check(AnimalDefinitions.animals[animalType].fleeZombies == false, animalType .. " still flees on its own")
    end
    check(AnimalDefinitions.animals["hen"].fleeZombies == nil, "hen changed")
    check(AnimalDefinitions.animals["cowcalf"].fleeZombies == nil, "calf changed")
    check(AnimalDefinitions.animals["ewe"].fleeZombies == nil, "ewe changed")
end

function Tests.every_roster_animal_has_strike_timing()
    for animalType in pairs(AAZ.roster) do
        local animset = AnimalDefinitions.animals[animalType].animset
        check(AAZ.strikeTiming[animset], animalType .. " (" .. tostring(animset) .. ") has no strike timing")
    end
end

-- Single player fights -----------------------------------------------------------------

function Tests.bull_charges_and_kills()
    local bull = NewAnimal("bull", 10, 10, { breed = "holstein" })
    local zombie = NewZombie(14, 10)
    Run(15)
    check(zombie:isDead(), "zombie survived a holstein bull for 15 s, health " .. zombie:getHealth())
    check(bull.s.goAttackCalls > 0, "bull never charged")
    local strikes, hits = strikeTimes(bull), hitTimes(zombie)
    check(#strikes >= 3 and #hits >= 3, "expected at least 3 strikes and hits, got " .. #strikes .. "/" .. #hits)
    -- The first hit lands at the head swipe's AttackConnect point, 0.68 s in.
    local delay = hits[1] - strikes[1]
    check(delay > 0.66 and delay < 0.72, "first hit landed " .. delay .. " s into the strike")
    check(not AAZ.isEngaged(bull), "still engaged with a dead zombie")
    check(not bull.s.blockMovement, "bull left frozen")
    check(bull:getVariableString("idleAction") == "", "strike left playing")
end

function Tests.ignores_zombie_out_of_range()
    local bull = NewAnimal("bull", 10, 10, { breed = "holstein" })
    local zombie = NewZombie(16.5, 10) -- 6.5 tiles, range 6
    Run(5)
    check(bull.s.goAttackCalls == 0, "bull charged a zombie out of range")
    check(bull.s.fled == 0, "bull ran")
    check(zombie:getHealth() == 2.0, "zombie was hit")
end

function Tests.bull_defends_herd_mate()
    local bull = NewAnimal("bull", 10, 10, { breed = "holstein" })
    NewAnimal("cow", 16, 10)
    local zombie = NewZombie(21, 10) -- 11 from the bull, 5 from the cow
    Run(0.6)
    check(AAZ.isEngaged(bull), "bull did not go to the cow's defence")
    Run(20)
    check(zombie:getHealth() < 2.0, "bull never reached the zombie")
end

function Tests.cow_without_calf_runs()
    local cow = NewAnimal("cow", 10, 10)
    local zombie = NewZombie(14, 10)
    Run(3)
    check(cow.s.fled > 0, "cow without a calf did not run")
    check(not AAZ.isEngaged(cow), "cow without a calf fought")
    check(zombie:getHealth() == 2.0, "zombie was hit")
end

function Tests.cow_with_calf_defends_it()
    local cow = NewAnimal("cow", 10, 10)
    local calf = NewAnimal("cowcalf", 12, 10, { baby = true })
    AddBaby(cow, calf)
    local zombie = NewZombie(17, 10) -- 5 from the calf, 7 from the cow
    Run(0.6)
    check(AAZ.isEngaged(cow), "cow did not defend her calf")
    check(cow.s.fled == 0, "cow ran")
    Run(20)
    check(zombie:getHealth() < 2.0, "cow never landed a hit")
end

function Tests.grown_calf_no_longer_defended()
    local cow = NewAnimal("cow", 10, 10)
    local grown = NewAnimal("cow", 12, 10, { baby = false })
    AddBaby(cow, grown)
    NewZombie(14, 10)
    Run(1)
    check(not AAZ.isEngaged(cow), "cow defended a grown daughter")
    check(cow.s.fled > 0, "cow did not run")
end

function Tests.species_turned_off_runs()
    SandboxVars.AnimalsAttackZombies.Bulls = false
    local bull = NewAnimal("bull", 10, 10)
    local zombie = NewZombie(14, 10)
    Run(3)
    check(bull.s.fled > 0, "bull turned off did not run like vanilla")
    check(not AAZ.isEngaged(bull), "bull turned off fought")
    check(zombie:getHealth() == 2.0, "zombie was hit")
end

function Tests.turned_off_animal_ignores_zombie_beyond_vanilla_flee_range()
    SandboxVars.AnimalsAttackZombies.Bulls = false
    local bull = NewAnimal("bull", 10, 10)
    NewZombie(16.5, 10)
    Run(3)
    check(bull.s.fled == 0, "ran from a zombie beyond vanilla's 6 tiles")
end

function Tests.ram_out_of_rut_has_half_range()
    local ram = NewAnimal("ram", 10, 10, { inSeason = false })
    NewZombie(14, 10) -- 4 tiles; range 3 out of season
    Run(2)
    check(not AAZ.isEngaged(ram), "ram out of season charged at 4 tiles")
    check(ram.s.fled == 0, "ram ran")
    ram.s.inSeason = true
    Run(1)
    check(AAZ.isEngaged(ram), "ram in season ignored a zombie at 4 tiles")
end

function Tests.beef_bull_is_slower_to_fight()
    local angus = NewAnimal("bull", 10, 10, { breed = "angus" })
    NewZombie(15, 10) -- 5 tiles; angus range 4.5, holstein 6
    Run(1)
    check(not AAZ.isEngaged(angus), "angus charged at 5 tiles")
    local holstein = NewAnimal("bull", 10, 30, { breed = "holstein" })
    NewZombie(15, 30)
    Run(1)
    check(AAZ.isEngaged(holstein), "holstein ignored a zombie at 5 tiles")
end

function Tests.aggressive_gene_widens_range()
    local calm = NewAnimal("boar", 10, 10, { genes = { aggressiveness = 0.0, strength = 0.5 } })
    NewZombie(15, 10) -- 5 tiles; range 4.5 at aggressiveness 0
    local fierce = NewAnimal("boar", 10, 30, { genes = { aggressiveness = 1.0, strength = 0.5 } })
    NewZombie(17.5, 30) -- 7.5 tiles; range 8.25 at aggressiveness 1
    Run(1)
    check(not AAZ.isEngaged(calm), "calm boar charged at 5 tiles")
    check(AAZ.isEngaged(fierce), "fierce boar ignored a zombie at 7.5 tiles")
end

function Tests.rooster_only_harasses()
    local rooster = NewAnimal("cockerel", 10, 10)
    local zombie = NewZombie(13, 10)
    Run(12)
    check(#hitTimes(zombie) > 0, "rooster never hit")
    check(not zombie:isDead() and zombie:getHealth() > 1.5, "rooster did real damage: " .. zombie:getHealth())
    check(not zombie.s.knockedDown, "rooster knocked a zombie down")
    check(AAZ.isEngaged(rooster), "rooster gave up")
end

function Tests.gives_up_across_a_fence()
    World.fenceX = 12
    -- Pressed up against the fence, well within reach: only the fence stops the hit.
    local bull = NewAnimal("bull", 11.4, 10, { breed = "holstein" })
    local zombie = NewZombie(12.6, 10)
    Run(1)
    check(AAZ.isEngaged(bull), "bull did not engage across the fence")
    Run(7)
    check(not AAZ.isEngaged(bull), "bull still trying after 8 s")
    Run(17) -- 25 s in: inside the 20 s it leaves a given-up zombie alone
    check(not AAZ.isEngaged(bull), "bull went straight back to a zombie it gave up on")
    check(zombie:getHealth() == 2.0, "hit through a fence")
    Run(4)
    check(AAZ.isEngaged(bull), "bull never tried again")
end

function Tests.stops_when_zombie_driven_off()
    local bull = NewAnimal("bull", 10, 10, { breed = "holstein" })
    local zombie = NewZombie(15, 10, { vx = 8 }) -- runs off faster than a bull
    Run(0.6)
    check(AAZ.isEngaged(bull), "bull did not engage")
    Run(3)
    check(not AAZ.isEngaged(bull), "bull chased a zombie out of the leash")
    check(not AAZ.isGivenUp(bull, zombie), "a zombie that left was marked unreachable")
end

function Tests.ignores_fake_dead_and_other_floors()
    local bull = NewAnimal("bull", 10, 10)
    NewZombie(12, 10, { fakeDead = true })
    local upstairs = NewZombie(12, 11)
    upstairs.s.z = 1
    Run(2)
    check(not AAZ.isEngaged(bull), "bull charged a fake-dead zombie or one on another floor")
end

function Tests.damage_multiplier_scales_hits()
    SandboxVars.AnimalsAttackZombies.DamageMultiplier = 0.5
    NewAnimal("bull", 10, 10, { breed = "holstein" })
    local zombie = NewZombie(11.2, 10, { health = 10 })
    Run(1.5)
    check(#hitTimes(zombie) == 1, "expected one hit")
    -- 0.8 (bull) x (0.5 + strength 0.5) x 0.5
    check(math.abs(zombie:getHealth() - 9.6) < 1e-6, "hit took " .. (10 - zombie:getHealth()))
end

-- applyHit -----------------------------------------------------------------------------

function Tests.knockdown_faces_the_animal()
    local zombie = NewZombie(10, 10, { fwdX = 0, fwdY = 1 }) -- looking away, south
    AAZ.applyHit(zombie, 8, 10, 0.5, true)
    check(zombie.s.knockedDown and zombie.s.staggerBack, "not knocked down")
    check(zombie.s.attackPosition == "FRONT", "knockdown from " .. tostring(zombie.s.attackPosition))
    check(zombie.s.fwdX < -0.99, "zombie not turned toward the animal")
    check(zombie.s.hitDir.x > 0.99, "hit direction does not point away from the animal")
    check(zombie.s.events[1] == "wasHit", "no wasHit event")
    check(math.abs(zombie:getHealth() - 1.5) < 1e-6, "damage not applied")
end

function Tests.stagger_reports_side()
    local zombie = NewZombie(10, 10, { fwdX = 1, fwdY = 0 }) -- looking east
    AAZ.applyHit(zombie, 8, 10, 0.1, false) -- animal to the west: behind it
    check(not zombie.s.knockedDown and zombie.s.staggerBack, "expected a stagger")
    check(zombie.s.attackPosition == "BEHIND", "side " .. tostring(zombie.s.attackPosition))
    check(zombie.s.hitFromBehind, "hitFromBehind not set")
end

function Tests.lethal_hit_always_knocks_down()
    local zombie = NewZombie(10, 10, { health = 0.3 })
    AAZ.applyHit(zombie, 9, 10, 0.5, false)
    check(zombie:isDead(), "zombie alive")
    check(zombie.s.knockedDown, "dead zombie left standing")
end

function Tests.trampling_a_downed_zombie()
    local zombie = NewZombie(10, 10)
    zombie.s.onFloor = true
    AAZ.applyHit(zombie, 9, 10, 0.5, true)
    check(math.abs(zombie:getHealth() - 1.5) < 1e-6, "no damage on the ground")
    check(#zombie.s.events == 0 and not zombie.s.staggerBack, "downed zombie made to stagger")
end

function Tests.animal_on_top_of_zombie_does_not_throw()
    local zombie = NewZombie(10, 10)
    AAZ.applyHit(zombie, 10, 10, 0.5, true)
    check(zombie.s.knockedDown, "not knocked down")
end

-- Multiplayer --------------------------------------------------------------------------

function Tests.server_sends_hit_to_zombie_owner()
    local owner = { name = "owner" }
    local bull = NewAnimal("bull", 10, 10, { breed = "holstein" })
    local zombie = NewZombie(11.2, 10, { owner = owner })
    Run(1.5)
    local strikes, hits = sentCommands(AAZ.CMD_STRIKE), sentCommands(AAZ.CMD_HIT)
    check(#strikes == 1 and strikes[1].player == nil, "strike not broadcast")
    check(strikes[1].args.animal == bull:getOnlineID(), "strike for the wrong animal")
    check(#hits == 1 and hits[1].player == owner, "hit not sent to the zombie's owner")
    check(hits[1].args.zombie == zombie:getOnlineID(), "hit for the wrong zombie")
    check(zombie:getHealth() == 2.0, "server changed a zombie a client owns")
end

function Tests.server_hits_unowned_zombie_itself()
    NewAnimal("bull", 10, 10, { breed = "holstein" })
    local zombie = NewZombie(11.2, 10)
    Run(1.5)
    check(#sentCommands(AAZ.CMD_HIT) == 0, "hit sent for a zombie nobody owns")
    check(zombie:getHealth() < 2.0, "unowned zombie not hit")
end

function Tests.client_lands_hit_on_own_zombie_only()
    local own = NewZombie(10, 10)
    local remote = NewZombie(20, 10, { remote = true })
    FireServerCommand(AAZ.MODULE, AAZ.CMD_HIT, { zombie = own:getOnlineID(), x = 9, y = 10, damage = 0.5, knockdown = true })
    FireServerCommand(AAZ.MODULE, AAZ.CMD_HIT, { zombie = remote:getOnlineID(), x = 19, y = 10, damage = 0.5, knockdown = true })
    check(math.abs(own:getHealth() - 1.5) < 1e-6 and own.s.knockedDown, "owned zombie not hit")
    check(remote:getHealth() == 2.0, "remote zombie hit")
end

function Tests.client_plays_strike()
    local bull = NewAnimal("bull", 10, 10)
    FireServerCommand(AAZ.MODULE, AAZ.CMD_STRIKE, { animal = bull:getOnlineID() })
    check(bull:getVariableString("idleAction") == AAZ.STRIKE_ACTION, "strike not played")
    FireServerCommand("SomeOtherMod", AAZ.CMD_STRIKE, { animal = bull:getOnlineID() })
end

function Tests.client_runs_no_fights()
    local bull = NewAnimal("bull", 10, 10)
    NewZombie(12, 10)
    Run(2)
    check(bull.s.goAttackCalls == 0 and bull.s.fled == 0, "a client drove an animal")
end

-- Which mode each test loads the mod in; everything else is single player.
TestModes = {
    server_sends_hit_to_zombie_owner = "server",
    server_hits_unowned_zombie_itself = "server",
    client_lands_hit_on_own_zombie_only = "client",
    client_plays_strike = "client",
    client_runs_no_fights = "client",
}
