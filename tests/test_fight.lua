-- Fight scenarios, run by run_tests.py in a fresh Lua state each, with the real vanilla
-- animal definitions and the real mod files loaded on top of fake_pz.lua.

local AAZ = AnimalsAttackZombies
Tests = {}

local function check(cond, msg)
    if not cond then error(msg, 2) end
end

-- The core fight without the semi-realistic behaviours: every animal commits at once,
-- charges without warning, never counts zombies and fights at any health.
function Plain()
    local vars = SandboxVars.AnimalsAttackZombies
    vars.Hesitation = false
    vars.WarningDisplay = false
    vars.CrowdLimit = 0
    vars.RetreatHealth = 0
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
    Plain()
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
    Plain()
    local bull = NewAnimal("bull", 10, 10, { breed = "holstein" })
    local zombie = NewZombie(16.5, 10) -- 6.5 tiles, range 6
    Run(5)
    check(bull.s.goAttackCalls == 0, "bull charged a zombie out of range")
    check(bull.s.fled == 0, "bull ran")
    check(zombie:getHealth() == 2.0, "zombie was hit")
end

function Tests.bull_defends_herd_mate()
    Plain()
    local bull = NewAnimal("bull", 10, 10, { breed = "holstein" })
    NewAnimal("cow", 16, 10)
    local zombie = NewZombie(21, 10) -- 11 from the bull, 5 from the cow
    Run(0.6)
    check(AAZ.isEngaged(bull), "bull did not go to the cow's defence")
    Run(20)
    check(zombie:getHealth() < 2.0, "bull never reached the zombie")
end

function Tests.cow_without_calf_runs()
    Plain()
    local cow = NewAnimal("cow", 10, 10)
    local zombie = NewZombie(14, 10)
    Run(3)
    check(cow.s.fled > 0, "cow without a calf did not run")
    check(not AAZ.isEngaged(cow), "cow without a calf fought")
    check(zombie:getHealth() == 2.0, "zombie was hit")
end

function Tests.cow_with_calf_defends_it()
    Plain()
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
    Plain()
    local cow = NewAnimal("cow", 10, 10)
    local grown = NewAnimal("cow", 12, 10, { baby = false })
    AddBaby(cow, grown)
    NewZombie(14, 10)
    Run(1)
    check(not AAZ.isEngaged(cow), "cow defended a grown daughter")
    check(cow.s.fled > 0, "cow did not run")
end

function Tests.species_turned_off_runs()
    Plain()
    SandboxVars.AnimalsAttackZombies.Bulls = false
    local bull = NewAnimal("bull", 10, 10)
    local zombie = NewZombie(14, 10)
    Run(3)
    check(bull.s.fled > 0, "bull turned off did not run like vanilla")
    check(not AAZ.isEngaged(bull), "bull turned off fought")
    check(zombie:getHealth() == 2.0, "zombie was hit")
end

function Tests.turned_off_animal_ignores_zombie_beyond_vanilla_flee_range()
    Plain()
    SandboxVars.AnimalsAttackZombies.Bulls = false
    local bull = NewAnimal("bull", 10, 10)
    NewZombie(16.5, 10)
    Run(3)
    check(bull.s.fled == 0, "ran from a zombie beyond vanilla's 6 tiles")
end

function Tests.ram_out_of_rut_has_half_range()
    Plain()
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
    Plain()
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
    Plain()
    local calm = NewAnimal("boar", 10, 10, { genes = { aggressiveness = 0.0, strength = 0.5 } })
    NewZombie(15, 10) -- 5 tiles; range 4.5 at aggressiveness 0
    local fierce = NewAnimal("boar", 10, 30, { genes = { aggressiveness = 1.0, strength = 0.5 } })
    NewZombie(17.5, 30) -- 7.5 tiles; range 8.25 at aggressiveness 1
    Run(1)
    check(not AAZ.isEngaged(calm), "calm boar charged at 5 tiles")
    check(AAZ.isEngaged(fierce), "fierce boar ignored a zombie at 7.5 tiles")
end

function Tests.rooster_only_harasses()
    Plain()
    local rooster = NewAnimal("cockerel", 10, 10)
    local zombie = NewZombie(13, 10)
    Run(12)
    check(#hitTimes(zombie) > 0, "rooster never hit")
    check(not zombie:isDead() and zombie:getHealth() > 1.5, "rooster did real damage: " .. zombie:getHealth())
    check(not zombie.s.knockedDown, "rooster knocked a zombie down")
    check(AAZ.isEngaged(rooster), "rooster gave up")
end

function Tests.ignores_zombie_behind_a_fence()
    Plain()
    World.fenceX = 12
    -- Pressed up against the fence, well within reach: only the fence is between them.
    local bull = NewAnimal("bull", 11.4, 10, { breed = "holstein" })
    local zombie = NewZombie(12.6, 10)
    Run(30)
    check(not AAZ.isEngaged(bull) and bull.s.goAttackCalls == 0, "bull went for a zombie behind its fence")
    check(zombie:getHealth() == 2.0, "hit through a fence")
end

function Tests.gives_up_when_cut_off()
    Plain()
    local bull = NewAnimal("bull", 10, 10, { breed = "holstein" })
    local zombie = NewZombie(14, 10, { health = 100 })
    Run(0.6)
    check(AAZ.isEngaged(bull), "bull did not engage")
    World.fenceX = 12 -- a gate shuts between them
    bull.s.x = 11.4
    zombie.s.x = 12.6
    Run(8)
    check(not AAZ.isEngaged(bull), "bull still trying after 8 s")
    check(AAZ.isGivenUp(bull, zombie), "zombie not marked given up")
    check(not bull.s.blockMovement, "bull left frozen")
    Run(20) -- the 20 s from giving up (about 7 s in) are over
    check(not AAZ.isGivenUp(bull, zombie), "given up for longer than GiveUpTime")
end

function Tests.remembers_every_zombie_it_gave_up_on()
    Plain()
    SandboxVars.AnimalsAttackZombies.MaxFightTime = 5
    local rooster = NewAnimal("cockerel", 10, 10)
    local first = NewZombie(11, 10, { health = 100 })
    local second = NewZombie(10, 11.2, { health = 100 })
    Run(13) -- two fights of 5 s, one after the other
    check(AAZ.isGivenUp(rooster, first) and AAZ.isGivenUp(rooster, second), "a given-up zombie was forgotten")
    check(not AAZ.isEngaged(rooster), "rooster went back to a zombie it gave up on")
end

function Tests.stops_when_zombie_driven_off()
    Plain()
    local bull = NewAnimal("bull", 10, 10, { breed = "holstein" })
    local zombie = NewZombie(15, 10, { vx = 8 }) -- runs off faster than a bull
    Run(0.6)
    check(AAZ.isEngaged(bull), "bull did not engage")
    Run(3)
    check(not AAZ.isEngaged(bull), "bull chased a zombie out of the leash")
    check(not AAZ.isGivenUp(bull, zombie), "a zombie that left was marked unreachable")
end

function Tests.ignores_dragged_corpse()
    Plain()
    local bull = NewAnimal("bull", 10, 10, { breed = "holstein" })
    local corpse = NewZombie(12, 10, { grappleOnly = true, grappled = true })
    Run(3)
    check(not AAZ.isEngaged(bull), "bull went for a corpse a player is dragging")
    check(corpse:getHealth() == 2.0, "dragged corpse hit")
end

function Tests.ignores_fake_dead_and_other_floors()
    Plain()
    local bull = NewAnimal("bull", 10, 10)
    NewZombie(12, 10, { fakeDead = true })
    local upstairs = NewZombie(12, 11)
    upstairs.s.z = 1
    Run(2)
    check(not AAZ.isEngaged(bull), "bull charged a fake-dead zombie or one on another floor")
end

function Tests.damage_multiplier_scales_hits()
    Plain()
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
    Plain()
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
    Plain()
    local zombie = NewZombie(10, 10, { fwdX = 1, fwdY = 0 }) -- looking east
    AAZ.applyHit(zombie, 8, 10, 0.1, false) -- animal to the west: behind it
    check(not zombie.s.knockedDown and zombie.s.staggerBack, "expected a stagger")
    check(zombie.s.attackPosition == "BEHIND", "side " .. tostring(zombie.s.attackPosition))
    check(zombie.s.hitFromBehind, "hitFromBehind not set")
end

function Tests.lethal_hit_always_knocks_down()
    Plain()
    local zombie = NewZombie(10, 10, { health = 0.3 })
    AAZ.applyHit(zombie, 9, 10, 0.5, false)
    check(zombie:isDead(), "zombie alive")
    check(zombie.s.knockedDown, "dead zombie left standing")
end

function Tests.trampling_a_downed_zombie()
    Plain()
    local zombie = NewZombie(10, 10)
    zombie.s.onFloor = true
    AAZ.applyHit(zombie, 9, 10, 0.5, true)
    check(math.abs(zombie:getHealth() - 1.5) < 1e-6, "no damage on the ground")
    check(#zombie.s.events == 0 and not zombie.s.staggerBack, "downed zombie made to stagger")
end

function Tests.animal_on_top_of_zombie_does_not_throw()
    Plain()
    local zombie = NewZombie(10, 10)
    AAZ.applyHit(zombie, 10, 10, 0.5, true)
    check(zombie.s.knockedDown, "not knocked down")
end

-- Multiplayer --------------------------------------------------------------------------

function Tests.server_broadcasts_hit_on_owned_zombie()
    Plain()
    local owner = { name = "owner" }
    local bull = NewAnimal("bull", 10, 10, { breed = "holstein" })
    local zombie = NewZombie(11.2, 10, { owner = owner })
    Run(1.5)
    local strikes, hits = sentCommands(AAZ.CMD_STRIKE), sentCommands(AAZ.CMD_HIT)
    check(#strikes == 1 and strikes[1].player == nil, "strike not broadcast")
    check(strikes[1].args.animal == bull:getOnlineID(), "strike for the wrong animal")
    check(#hits == 1 and hits[1].player == nil, "hit not broadcast to every client")
    check(hits[1].args.zombie == zombie:getOnlineID(), "hit for the wrong zombie")
    check(hits[1].args.lethal == false, "a 0.8 hit on a full-health zombie sent as lethal")
    check(zombie:getHealth() == 2.0, "server changed a zombie a client owns")
end

function Tests.server_hits_unowned_zombie_itself()
    Plain()
    NewAnimal("bull", 10, 10, { breed = "holstein" })
    local zombie = NewZombie(11.2, 10)
    Run(1.5)
    check(zombie:getHealth() < 2.0, "unowned zombie not hit")
    local hits = sentCommands(AAZ.CMD_HIT)
    check(#hits == 1, "clients not told to play the hit")
    check(hits[1].args.lethal == false, "a 0.8 hit on a full-health zombie sent as lethal")
end

function Tests.server_pushes_animal_state_with_warning_and_strike()
    SandboxVars.AnimalsAttackZombies.Hesitation = false
    local bull = NewAnimal("bull", 10, 10, { breed = "holstein" })
    NewZombie(14, 10, { health = 100 })
    Run(0.3)
    check(bull.s.extraUpdates == 1, "warning not pushed to clients")
    Run(6)
    check(#strikeTimes(bull) >= 1 and bull.s.extraUpdates >= 2, "strike not pushed to clients")
end

function Tests.client_owner_takes_damage_others_react()
    Plain()
    local own = NewZombie(10, 10)
    local remote = NewZombie(20, 10, { remote = true })
    local remoteDying = NewZombie(30, 10, { remote = true })
    FireServerCommand(AAZ.MODULE, AAZ.CMD_HIT, { zombie = own:getOnlineID(), x = 9, y = 10, damage = 0.5, knockdown = true, lethal = false })
    FireServerCommand(AAZ.MODULE, AAZ.CMD_HIT, { zombie = remote:getOnlineID(), x = 19, y = 10, damage = 0.5, knockdown = false, lethal = false })
    FireServerCommand(AAZ.MODULE, AAZ.CMD_HIT, { zombie = remoteDying:getOnlineID(), x = 29, y = 10, damage = 0.5, knockdown = false, lethal = true })
    check(math.abs(own:getHealth() - 1.5) < 1e-6 and own.s.knockedDown, "owned zombie not hit")
    check(remote:getHealth() == 2.0, "a client changed the health of a zombie it does not own")
    check(remote.s.staggerBack and not remote.s.knockedDown, "other client did not play the stagger")
    check(remoteDying:getHealth() == 2.0 and remoteDying.s.knockedDown, "other client did not knock down a dying zombie")
end

function Tests.client_plays_strike()
    Plain()
    local bull = NewAnimal("bull", 10, 10)
    FireServerCommand(AAZ.MODULE, AAZ.CMD_STRIKE, { animal = bull:getOnlineID() })
    check(bull:getVariableString("idleAction") == AAZ.STRIKE_ACTION, "strike not played")
    FireServerCommand("SomeOtherMod", AAZ.CMD_STRIKE, { animal = bull:getOnlineID() })
end

function Tests.client_runs_no_fights()
    Plain()
    local bull = NewAnimal("bull", 10, 10)
    NewZombie(12, 10)
    Run(2)
    check(bull.s.goAttackCalls == 0 and bull.s.fled == 0, "a client drove an animal")
end

-- Semi-realistic behaviour ------------------------------------------------------------

local function soundsOf(animal, id)
    local n = 0
    for _, entry in ipairs(World.soundLog) do
        if entry.animal == animal and entry.id == id then n = n + 1 end
    end
    return n
end

local function countEngaged(animals)
    local n = 0
    for _, a in ipairs(animals) do
        if AAZ.isEngaged(a) then n = n + 1 end
    end
    return n
end

-- Bulls, each alone 40 tiles from the next, with one zombie at the given distance.
local function bullsFacingZombies(distance, count, x0, opts)
    local bulls, zombies = {}, {}
    x0 = x0 or 10
    for i = 1, count or 20 do
        bulls[i] = NewAnimal("bull", x0, i * 40, opts or { breed = "holstein" })
        zombies[i] = NewZombie(x0 + distance, i * 40, { health = 100 })
    end
    return bulls, zombies
end

function Tests.hesitates_at_the_edge_of_range()
    SandboxVars.AnimalsAttackZombies.WarningDisplay = false
    local bulls, zombies = bullsFacingZombies(5.8) -- range 6: barely inside
    Run(0.6)
    check(countEngaged(bulls) <= 4, countEngaged(bulls) .. " of 20 bulls charged the moment a zombie reached the edge")
    for i, bull in ipairs(bulls) do
        if not AAZ.isEngaged(bull) then
            check(bull.s.facing == zombies[i], "a hesitating bull did not watch its zombie")
        end
    end
    Run(40)
    local fought = 0
    for i = 1, 20 do
        if #hitTimes(zombies[i]) > 0 then fought = fought + 1 end
    end
    check(fought >= 14, "only " .. fought .. " of 20 bulls charged a zombie that stood at the edge for 40 s")
end

function Tests.always_charges_a_zombie_on_top_of_it()
    SandboxVars.AnimalsAttackZombies.WarningDisplay = false
    local bulls = bullsFacingZombies(0.8)
    Run(0.2) -- the first scan waits 100 real ms
    check(countEngaged(bulls) == 20, "only " .. countEngaged(bulls) .. " of 20 bulls went for a zombie right on them")
end

function Tests.hesitation_off_charges_at_once()
    SandboxVars.AnimalsAttackZombies.Hesitation = false
    SandboxVars.AnimalsAttackZombies.WarningDisplay = false
    local bulls = bullsFacingZombies(5.8)
    Run(0.2)
    check(countEngaged(bulls) == 20, "with Hesitation off only " .. countEngaged(bulls) .. " of 20 charged")
end

function Tests.warns_before_charging()
    SandboxVars.AnimalsAttackZombies.Hesitation = false
    local bull = NewAnimal("bull", 10, 10, { breed = "holstein" })
    local zombie = NewZombie(14, 10)
    Run(0.3)
    check(AAZ.getFightPhase(bull) == "warn", "bull did not square up first: " .. tostring(AAZ.getFightPhase(bull)))
    check(soundsOf(bull, "stressed") == 1, "no warning call")
    check(bull.s.facing == zombie and bull.s.blockMovement and not bull.s.moving, "bull not standing its ground facing the zombie")
    Run(1.1) -- a bull warns for at least 1.5 s x 1.06
    check(AAZ.getFightPhase(bull) == "warn" and bull.s.goAttackCalls == 0, "warning cut short")
    Run(3)
    check(bull.s.goAttackCalls > 0, "never charged after the warning")
    check(#hitTimes(zombie) > 0, "never hit")
end

function Tests.zombie_walking_into_reach_is_struck_during_warning()
    SandboxVars.AnimalsAttackZombies.Hesitation = false
    local bull = NewAnimal("bull", 10, 10, { breed = "holstein" })
    NewZombie(13, 10, { vx = -2, health = 100 })
    Run(1.2) -- in reach after about 0.6 s, well before the warning could end
    check(#strikeTimes(bull) >= 1, "bull kept posturing at a zombie in reach")
    check(bull.s.goAttackCalls == 0, "bull charged instead of lashing out")
end

function Tests.warning_ends_when_zombie_backs_off()
    SandboxVars.AnimalsAttackZombies.Hesitation = false
    local bull = NewAnimal("bull", 10, 10, { breed = "holstein" })
    local zombie = NewZombie(14, 10, { vx = 6 })
    Run(1.2)
    check(not AAZ.isEngaged(bull), "bull still squaring up to a zombie that left")
    check(bull.s.goAttackCalls == 0, "bull chased a zombie that backed off")
    check(not bull.s.blockMovement, "bull left frozen")
    check(not AAZ.isGivenUp(bull, zombie), "a zombie that backed off was marked unreachable")
end

function Tests.warning_off_charges_straight_away()
    SandboxVars.AnimalsAttackZombies.Hesitation = false
    SandboxVars.AnimalsAttackZombies.WarningDisplay = false
    local bull = NewAnimal("bull", 10, 10, { breed = "holstein" })
    NewZombie(14, 10)
    Run(0.3)
    check(AAZ.getFightPhase(bull) == "charge" and bull.s.goAttackCalls > 0, "bull did not charge at once")
    check(soundsOf(bull, "stressed") == 0, "warning call with WarningDisplay off")
end

function Tests.lone_bull_runs_from_a_crowd()
    SandboxVars.AnimalsAttackZombies.Hesitation = false
    local bull = NewAnimal("bull", 10, 10, { breed = "holstein" })
    for i = 1, 4 do NewZombie(15, 8 + i) end
    Run(0.6)
    check(bull.s.fled > 0, "a lone bull did not run from four zombies")
    check(not AAZ.isEngaged(bull), "a lone bull took on four zombies")
end

function Tests.bulls_together_stand_up_to_a_crowd()
    SandboxVars.AnimalsAttackZombies.Hesitation = false
    local bulls = {
        NewAnimal("bull", 10, 10, { breed = "holstein" }),
        NewAnimal("bull", 10, 12, { breed = "holstein" }),
        NewAnimal("bull", 10, 8, { breed = "holstein" }),
    }
    for i = 1, 4 do NewZombie(15, 8 + i) end
    Run(0.6)
    check(countEngaged(bulls) == 3, "three bulls together did not stand up to four zombies")
    for _, bull in ipairs(bulls) do check(bull.s.fled == 0, "a bull ran") end
end

function Tests.crowd_breaks_off_a_fight()
    SandboxVars.AnimalsAttackZombies.Hesitation = false
    SandboxVars.AnimalsAttackZombies.WarningDisplay = false
    local bull = NewAnimal("bull", 10, 10, { breed = "holstein" })
    NewZombie(14, 10, { health = 100 })
    Run(0.6)
    check(AAZ.isEngaged(bull), "bull did not engage")
    for i = 1, 3 do NewZombie(bull:getX() + 5, bull:getY() + i) end
    Run(0.6)
    check(not AAZ.isEngaged(bull), "bull kept fighting as a crowd gathered")
    check(bull.s.fled > 0 and not bull.s.blockMovement, "bull did not run")
end

function Tests.crowd_limit_off_fights_any_crowd()
    SandboxVars.AnimalsAttackZombies.Hesitation = false
    SandboxVars.AnimalsAttackZombies.CrowdLimit = 0
    local bull = NewAnimal("bull", 10, 10, { breed = "holstein" })
    for i = 1, 8 do NewZombie(14 + (i % 2), 6 + i) end
    Run(0.6)
    check(AAZ.isEngaged(bull) and bull.s.fled == 0, "bull backed off with CrowdLimit 0")
end

function Tests.hurt_animal_runs()
    SandboxVars.AnimalsAttackZombies.Hesitation = false
    local bull = NewAnimal("bull", 10, 10, { breed = "holstein", health = 0.3 })
    NewZombie(17, 10)
    Run(0.6)
    check(not AAZ.isEngaged(bull), "a hurt bull fought")
    check(bull.s.fled > 0, "a hurt bull did not get away from a zombie 7 tiles off")
end

function Tests.hurt_mid_fight_breaks_off()
    SandboxVars.AnimalsAttackZombies.Hesitation = false
    SandboxVars.AnimalsAttackZombies.WarningDisplay = false
    local bull = NewAnimal("bull", 10, 10, { breed = "holstein" })
    NewZombie(14, 10, { health = 100 })
    Run(2)
    check(AAZ.isEngaged(bull), "bull did not engage")
    bull.s.health = 0.2
    Run(0.6)
    check(not AAZ.isEngaged(bull), "badly hurt bull fought on")
    check(bull.s.fled > 0, "badly hurt bull did not run")
end

function Tests.retreat_off_fights_at_any_health()
    SandboxVars.AnimalsAttackZombies.Hesitation = false
    SandboxVars.AnimalsAttackZombies.RetreatHealth = 0
    local bull = NewAnimal("bull", 10, 10, { breed = "holstein", health = 0.1 })
    NewZombie(14, 10)
    Run(0.6)
    check(AAZ.isEngaged(bull), "bull did not fight with RetreatHealth 0")
end

function Tests.fighting_leaves_stress_as_it_was()
    Plain()
    local bull = NewAnimal("bull", 10, 10, { stress = 13, genes = { aggressiveness = 0.4, strength = 0.5, stress = 1.0 } })
    local zombie = NewZombie(11.2, 10, { health = 100 })
    Run(10)
    check(#hitTimes(zombie) > 0, "no fight")
    check(bull:getStress() == 13, "a fight changed stress from 13 to " .. bull:getStress())
end

function Tests.stays_blocked_between_strikes()
    Plain()
    local bull = NewAnimal("bull", 10, 10, { breed = "holstein" })
    NewZombie(11.2, 10, { health = 100 })
    local sawRecover = false
    for _ = 1, 300 do
        Run(1 / 60)
        if AAZ.getFightPhase(bull) == "recover" then
            sawRecover = true
            check(bull.s.blockMovement, "not blocked in the pause between strikes")
            check(not VanillaWander(bull, 30, 30), "vanilla could walk the bull off mid-fight")
        end
    end
    check(sawRecover, "no pause between strikes in 5 s")
end

function Tests.charge_taken_over_by_vanilla_is_reissued()
    Plain()
    local bull = NewAnimal("bull", 10, 10, { breed = "holstein" })
    local zombie = NewZombie(15.5, 10, { health = 100 })
    Run(0.6)
    check(AAZ.getFightPhase(bull) == "charge", "not charging")
    -- The charge path ends short of the zombie, and vanilla starts a wander right then.
    bull.s.moving, bull.s.fightBehavior, bull.s.target = false, false, nil
    check(VanillaWander(bull, 10, 30), "test setup: wander did not start")
    Run(0.1)
    check(bull.s.target == zombie, "bull wandered off mid-charge")
    Run(10)
    check(#hitTimes(zombie) > 0, "bull never got its hit in")
end

function Tests.mother_whose_young_die_stops_fighting()
    Plain()
    local cow = NewAnimal("cow", 10, 10)
    local calf = NewAnimal("cowcalf", 12, 10, { baby = true })
    AddBaby(cow, calf)
    NewZombie(16, 10, { health = 100 })
    Run(0.6)
    check(AAZ.isEngaged(cow), "cow did not defend her calf")
    calf.s.dead = true
    Run(0.6)
    check(not AAZ.isEngaged(cow), "cow fought on with no young left")
    check(not cow.s.blockMovement, "cow left frozen")
end

function Tests.carried_animal_comes_back_unfrozen()
    SandboxVars.AnimalsAttackZombies.Hesitation = false
    local rooster = NewAnimal("cockerel", 10, 10)
    NewZombie(13, 10, { health = 100 })
    Run(0.3)
    check(AAZ.getFightPhase(rooster) == "warn" and rooster.s.blockMovement, "rooster did not square up")
    rooster.s.held = true -- picked up mid-warning
    Run(0.1)
    check(not AAZ.isEngaged(rooster), "still fighting while carried")
    check(not rooster.s.blockMovement, "rooster left frozen")
end

function Tests.server_broadcasts_warning_without_playing_it()
    SandboxVars.AnimalsAttackZombies.Hesitation = false
    local bull = NewAnimal("bull", 10, 10, { breed = "holstein" })
    NewZombie(14, 10)
    Run(0.3)
    local warns = sentCommands(AAZ.CMD_WARN)
    check(#warns == 1 and warns[1].player == nil, "warning not broadcast")
    check(warns[1].args.animal == bull:getOnlineID(), "warning for the wrong animal")
    check(soundsOf(bull, "stressed") == 0, "server played a sound nobody hears")
end

function Tests.client_plays_warning()
    local bull = NewAnimal("bull", 10, 10)
    FireServerCommand(AAZ.MODULE, AAZ.CMD_WARN, { animal = bull:getOnlineID() })
    check(soundsOf(bull, "stressed") == 1, "warning call not played")
end

-- Sandbox options ----------------------------------------------------------------------

function Tests.species_damage_and_knockdown_come_from_options()
    Plain()
    SandboxVars.AnimalsAttackZombies.BullDamage = 2.0
    SandboxVars.AnimalsAttackZombies.BullKnockdown = 0
    SandboxVars.AnimalsAttackZombies.RunUpKnockdown = 0
    NewAnimal("bull", 10, 10, { breed = "holstein" })
    local zombie = NewZombie(11.2, 10, { health = 100 })
    Run(1.5)
    check(#hitTimes(zombie) == 1, "expected one hit")
    -- 2.0 x (0.5 + strength 0.5) x DamageMultiplier 1
    check(math.abs(zombie:getHealth() - 98) < 1e-6, "hit took " .. (100 - zombie:getHealth()))
    Run(10)
    check(not zombie.s.knockedDown, "knocked down with BullKnockdown 0")
end

function Tests.knockdown_chance_100_always_knocks_down()
    Plain()
    SandboxVars.AnimalsAttackZombies.RamKnockdown = 100
    NewAnimal("ram", 10, 10)
    local zombie = NewZombie(11.2, 10, { health = 100 })
    Run(1.5)
    check(zombie.s.knockedDown, "not knocked down at 100%")
end

function Tests.gene_influence_0_makes_every_animal_average()
    Plain()
    SandboxVars.AnimalsAttackZombies.GeneInfluence = 0
    local fierce = NewAnimal("boar", 10, 10, { genes = { aggressiveness = 1.0, strength = 1.0 } })
    NewZombie(17, 10) -- 7 tiles: in reach of a fierce boar's 8.25, not an average one's 6
    Run(1)
    check(not AAZ.isEngaged(fierce), "the gene still widened the range")
end

function Tests.always_charge_percent_100_charges_at_the_edge()
    SandboxVars.AnimalsAttackZombies.WarningDisplay = false
    SandboxVars.AnimalsAttackZombies.AlwaysChargePercent = 100
    local bulls = {}
    for i = 1, 10 do
        bulls[i] = NewAnimal("bull", 10, i * 40, { breed = "holstein" })
        NewZombie(15.8, i * 40)
    end
    Run(0.2)
    for _, bull in ipairs(bulls) do check(AAZ.isEngaged(bull), "a bull hesitated with AlwaysChargePercent 100") end
end

function Tests.charge_chance_0_waits_for_the_certain_zone()
    SandboxVars.AnimalsAttackZombies.WarningDisplay = false
    SandboxVars.AnimalsAttackZombies.ChargeChanceAtEdge = 0
    SandboxVars.AnimalsAttackZombies.ChargeChanceUpClose = 0
    local bull = NewAnimal("bull", 10, 10, { breed = "holstein" })
    NewZombie(13, 10)
    Run(20)
    check(not AAZ.isEngaged(bull), "charged with both charge chances at 0")
end

function Tests.rut_range_100_keeps_full_range_out_of_season()
    Plain()
    SandboxVars.AnimalsAttackZombies.RutRange = 100
    local ram = NewAnimal("ram", 10, 10, { inSeason = false })
    NewZombie(15, 10)
    Run(1)
    check(AAZ.isEngaged(ram), "ram out of season held back with RutRange 100")
end

function Tests.breed_range_comes_from_options()
    Plain()
    SandboxVars.AnimalsAttackZombies.BullAngus = 100
    local angus = NewAnimal("bull", 10, 10, { breed = "angus" })
    NewZombie(15, 10)
    Run(1)
    check(AAZ.isEngaged(angus), "angus held back with BullAngus 100")
end

function Tests.herd_radius_limits_who_is_defended()
    Plain()
    SandboxVars.AnimalsAttackZombies.HerdRadius = 3
    local bull = NewAnimal("bull", 10, 10, { breed = "holstein" })
    NewAnimal("cow", 16, 10)
    NewZombie(21, 10)
    Run(1)
    check(not AAZ.isEngaged(bull), "bull defended a cow 6 tiles off with HerdRadius 3")
end

function Tests.young_radius_limits_which_babies_count()
    Plain()
    SandboxVars.AnimalsAttackZombies.YoungRadius = 1
    local cow = NewAnimal("cow", 10, 10)
    AddBaby(cow, NewAnimal("cowcalf", 12, 10, { baby = true }))
    NewZombie(17, 10)
    Run(1)
    check(not AAZ.isEngaged(cow), "cow counted a calf 2 tiles off with YoungRadius 1")
end

function Tests.flee_range_0_non_fighters_stay_put()
    Plain()
    SandboxVars.AnimalsAttackZombies.FleeRange = 0
    local cow = NewAnimal("cow", 10, 10)
    NewZombie(13, 10)
    Run(3)
    check(cow.s.fled == 0, "cow without a calf ran with FleeRange 0")
end

function Tests.crowd_radius_limits_what_counts()
    SandboxVars.AnimalsAttackZombies.Hesitation = false
    SandboxVars.AnimalsAttackZombies.WarningDisplay = false
    SandboxVars.AnimalsAttackZombies.CrowdRadius = 3
    local bull = NewAnimal("bull", 10, 10, { breed = "holstein" })
    for i = 1, 4 do NewZombie(15, 8 + i) end -- 5 tiles off: outside a crowd radius of 3
    Run(0.6)
    check(AAZ.isEngaged(bull) and bull.s.fled == 0, "zombies outside CrowdRadius counted")
end

function Tests.swapped_warning_and_pause_bounds_still_work()
    SandboxVars.AnimalsAttackZombies.Hesitation = false
    SandboxVars.AnimalsAttackZombies.BullWarnMin = 1.0
    SandboxVars.AnimalsAttackZombies.BullWarnMax = 0.5
    SandboxVars.AnimalsAttackZombies.PauseMin = 0.8
    SandboxVars.AnimalsAttackZombies.PauseMax = 0.2
    local bull = NewAnimal("bull", 10, 10, { breed = "holstein" })
    local zombie = NewZombie(14, 10, { health = 100 })
    Run(1.5) -- warns 0.5 to 1.0 s x 1.06
    check(AAZ.getFightPhase(bull) ~= "warn", "warning ran past its swapped bounds")
    Run(8)
    check(#hitTimes(zombie) >= 2, "strikes stopped with swapped pause bounds")
end

function Tests.chase_distance_sets_when_a_fleeing_zombie_is_let_go()
    Plain()
    SandboxVars.AnimalsAttackZombies.ChaseDistance = 30
    local bull = NewAnimal("bull", 10, 10, { breed = "holstein" })
    NewZombie(15, 10, { vx = 8 })
    Run(3) -- the zombie is about 24 tiles out: past the default 12, inside 36
    check(AAZ.isEngaged(bull), "bull let go inside a 30-tile chase distance")
end

function Tests.max_fight_time_gives_up()
    Plain()
    SandboxVars.AnimalsAttackZombies.MaxFightTime = 5
    local rooster = NewAnimal("cockerel", 10, 10)
    local zombie = NewZombie(11, 10)
    Run(6)
    check(not AAZ.isEngaged(rooster), "rooster fought past MaxFightTime")
    check(AAZ.isGivenUp(rooster, zombie), "zombie not marked given up")
end

-- Which mode each test loads the mod in; everything else is single player.
TestModes = {
    server_broadcasts_hit_on_owned_zombie = "server",
    server_hits_unowned_zombie_itself = "server",
    server_pushes_animal_state_with_warning_and_strike = "server",
    client_owner_takes_damage_others_react = "client",
    client_plays_strike = "client",
    client_runs_no_fights = "client",
    server_broadcasts_warning_without_playing_it = "server",
    carried_animal_comes_back_unfrozen = "sp",
    client_plays_warning = "client",
}
