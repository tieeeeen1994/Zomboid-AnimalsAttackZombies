--[[
    Animals Attack Zombies -- charging a zombie and landing the hits.

    Vanilla can point an animal at a zombie but never lets the hit land.
    BaseAnimalBehavior.goAttack() takes any IsoGameCharacter, and on a dedicated server
    IsoAnimal.hitConsequences() even sends an attackBack animal after a zombie that hits
    it. But AnimalAttackState.animEvent("AttackConnect") only damages an IsoAnimal or an
    IsoPlayer target and does nothing to an IsoZombie. The attack state cannot be entered
    from Lua anyway: it runs while isAnimalAttacking, a read-only callback on
    IsoAnimal.atkTarget, and neither atkTarget nor fightingOpponent has a setter.

    So each fight runs here, one engagement per animal:

      warn     (WarningDisplay option) The animal stops, squares up to the zombie and gives
               its stressed call, the way a bull bellows and paws before it comes. It lasts
               the species' warn time, shorter for an aggressive animal. A zombie that walks
               into reach meanwhile is struck at once; one that backs off is let go.
      charge   goAttack() paths the animal at the zombie and keeps its other behaviors
               (eating, wandering) out of the way. It runs when it has ground to cover.
      strike   In reach and with nothing in between, the animal stops, faces the zombie
               and plays its own attack clip through the idle node this mod adds
               (AnimalsAttackZombies.STRIKE_ACTION). The hit lands at the clip's
               vanilla AttackConnect point, timed in animation seconds
               (GameTime.getTimeDelta(), the same clock AnimationPlayer runs on), so it
               stays in step at any game speed.
      recover  A short pause, then back to charge, which strikes again at once if the
               zombie is still in reach.

    Fighting is stressful: an animal gains stress when it squares up to a zombie
    (StressOnEngage) and more for every second the fight goes on (StressPerSecond), on
    the scale vanilla uses
    (0 to 100; a herd mate killed nearby adds 10 to 30, calm animals lose about 0.5 a
    minute). IsoAnimal.changeStress() applies the animal's stress gene. Stress is the
    server's to change and reaches clients in AnimalPacket, and it has vanilla's knock-on
    effects: a bull, ram, rooster or tom above 80 may turn on a player it does not trust
    (attackIfStressed).

    A fight ends when the zombie dies, gets away from what the animal guards, or cannot
    be reached. A zombie given up on is left alone for a while so the animal does not
    pace a fence forever.

    In multiplayer the hit has to land on the client that simulates the zombie
    (AnimalsAttackZombies.CMD_HIT), and every client is told to play the strike, since
    idleAction is not synced (AnimalsAttackZombies.CMD_STRIKE).
]]

if isClient() then return end

require "AnimalsAttackZombies"
local AAZ = AnimalsAttackZombies

-- Every gameplay number is a sandbox option (AAZ.opt, defaults as in sandbox-options.txt):
--   StuckTime          s without gaining ground before an unreachable zombie is given up on
--   GiveUpTime         s a given-up zombie is left alone
--   MaxFightTime       s of fighting one zombie before giving up on it
--   PauseMin/PauseMax  s between strikes
--   ChargeRunDistance  tiles beyond which the charge is at a run
--   RunUpDistance      tiles of charge that make the first hit harder to stay standing under
--   RunUpKnockdown     % added to the knockdown chance of that hit
--   WarningStandDown   % of the range from what the animal guards at which a warning ends
--   ChaseDistance      tiles past its range an animal follows a zombie before letting it go
--   StressOnEngage     stress on committing to a fight, before the stress gene
--   StressPerSecond    stress per second of fighting; a 10 s fight adds about 20 at the defaults
-- These two stay fixed: they fit the engine, not the game.
local RECHARGE_INTERVAL = 0.5 -- animation s between re-issuing goAttack() to a stopped animal
local REACH_SLACK = 0.5       -- AnimalAttackState misses a player further than attackDist + 0.5

local engagements = {} -- IsoAnimal -> engagement
local givenUp = {}     -- IsoAnimal -> { zombie, untilTime }

-- Animation seconds since load; the one clock every timer here reads.
AAZ.clock = 0

local function distance(a, b)
    local dx, dy = a:getX() - b:getX(), a:getY() - b:getY()
    return math.sqrt(dx * dx + dy * dy)
end

local function sameFloor(a, b)
    return math.floor(a:getZ()) == math.floor(b:getZ())
end

-- True when a wall, fence, closed gate, door or window stands between the two squares.
-- Walks the squares between them; a strike never spans more than a couple.
function AAZ.isBlocked(from, to)
    if not from or not to then
        return true
    end
    local cell = getCell()
    local x, y, z = from:getX(), from:getY(), from:getZ()
    local tx, ty = to:getX(), to:getY()
    local previous = from
    for _ = 1, 4 do
        if x == tx and y == ty then
            return false
        end
        if x < tx then x = x + 1 elseif x > tx then x = x - 1 end
        if y < ty then y = y + 1 elseif y > ty then y = y - 1 end
        local square = cell:getGridSquare(x, y, z)
        if not square or previous:isBlockedTo(square) then
            return true
        end
        previous = square
    end
    return not (x == tx and y == ty)
end

-- How close the animal has to be to strike: its attackDist, capped so the head swipe
-- still looks like it touches, and at least a little more than the gap collision leaves
-- between it and a zombie (cattle 0.5 + zombie 0.3; pigs, sheep and birds less).
local function getReach(animal)
    local def = AAZ.getDefinition(animal)
    local attackDist = (def and def.attackDist) or 1
    return math.max(1.25, math.min(attackDist, 1.75))
end

function AAZ.isEngaged(animal)
    return engagements[animal] ~= nil
end

-- "warn", "charge", "strike" or "recover", or nil when the animal is not fighting.
function AAZ.getFightPhase(animal)
    local e = engagements[animal]
    return e and e.phase
end

function AAZ.isGivenUp(animal, zombie)
    local entry = givenUp[animal]
    return entry ~= nil and entry.zombie == zombie and entry.untilTime > AAZ.clock
end

local function distanceToAnchor(e)
    local dx, dy = e.zombie:getX() - e.anchorX, e.zombie:getY() - e.anchorY
    return math.sqrt(dx * dx + dy * dy)
end

local function addFightStress(animal, amount)
    if amount > 0 then
        animal:changeStress(amount)
    end
end

local function startCharge(animal, e)
    local dist = distance(animal, e.zombie)
    e.phase = "charge"
    e.timer = 0
    e.nextCharge = 0
    e.bestDist = dist
    e.bestDistTime = AAZ.clock
    e.runUp = dist >= AAZ.opt("RunUpDistance", 3)
end

local function startWarning(animal, e)
    animal:stopAllMovementNow()
    animal:getBehavior():setBlockMovement(true)
    animal:setVariable("animalRunning", false)
    animal:faceThisObject(e.zombie)
    if isServer() then
        sendServerCommand(AAZ.MODULE, AAZ.CMD_WARN, { animal = animal:getOnlineID() })
    else
        AAZ.playWarning(animal)
    end
    local warnMin, warnMax = AAZ.tuning(e.profile, "WarnMin"), AAZ.tuning(e.profile, "WarnMax")
    local aggressiveness = AAZ.getGene(animal, "aggressiveness", 0.4)
    e.phase = "warn"
    e.timer = 0
    e.warnTime = ZombRandFloat(math.min(warnMin, warnMax), math.max(warnMin, warnMax))
        * math.max(0.1, 1.3 - 0.6 * aggressiveness)
end

-- anchorX/anchorY: the spot the animal defends (itself, a herd mate or a baby). A zombie
-- that gets further than leash from it has been driven off.
function AAZ.engage(animal, zombie, profile, range, anchorX, anchorY)
    local timing = AAZ.getStrikeTiming(animal)
    if not timing then
        return
    end
    local e = {
        zombie = zombie,
        profile = profile,
        timing = timing,
        reach = getReach(animal),
        range = range,
        anchorX = anchorX,
        anchorY = anchorY,
        leash = range + AAZ.opt("ChaseDistance", 6),
        started = AAZ.clock,
    }
    engagements[animal] = e
    addFightStress(animal, AAZ.opt("StressOnEngage", 5))
    -- No time to posture at a zombie already in reach: it lashes out straight away.
    if AAZ.opt("WarningDisplay", true) and distance(animal, zombie) > e.reach then
        startWarning(animal, e)
    else
        startCharge(animal, e)
    end
end

local function clearStrike(animal)
    if animal:getVariableString("idleAction") == AAZ.STRIKE_ACTION then
        animal:clearVariable("idleAction")
    end
end

-- gone: the animal has left the world (died, carried, loaded into a trailer, hung on a
-- hook), so only the mod's own state is cleared and the animal is left as it is.
local function endEngagement(animal, e, giveUp, gone)
    engagements[animal] = nil
    if gone then
        return
    end
    if e.phase == "strike" or e.phase == "warn" then
        animal:getBehavior():setBlockMovement(false)
    elseif e.phase == "charge" and animal:isAnimalMoving() then
        -- Otherwise it carries on down the charge path at the zombie it just broke off from.
        animal:stopAllMovementNow()
    end
    clearStrike(animal)
    animal:setVariable("animalRunning", false)
    if giveUp then
        givenUp[animal] = { zombie = e.zombie, untilTime = AAZ.clock + AAZ.opt("GiveUpTime", 20) }
    end
end

local function rollHit(animal, e)
    local strength = AAZ.getGene(animal, "strength", 0.5)
    local damage = AAZ.tuning(e.profile, "Damage") * (0.5 + strength) * AAZ.opt("DamageMultiplier", 1)
    local chance = AAZ.tuning(e.profile, "Knockdown") / 100
    if e.runUp and chance > 0 then
        chance = chance + AAZ.opt("RunUpKnockdown", 25) / 100
    end
    e.runUp = false
    return damage, ZombRandFloat(0, 1) < chance
end

local function canHit(animal, zombie, reach)
    return sameFloor(animal, zombie)
        and distance(animal, zombie) <= reach
        and not AAZ.isBlocked(animal:getCurrentSquare(), zombie:getCurrentSquare())
end

local function landHit(animal, e)
    local zombie = e.zombie
    if not canHit(animal, zombie, e.reach + REACH_SLACK) then
        return -- it moved out of reach during the swing
    end
    local damage, knockdown = rollHit(animal, e)
    if isServer() then
        local owner = zombie:getOwnerPlayer()
        if owner then
            sendServerCommand(owner, AAZ.MODULE, AAZ.CMD_HIT, {
                zombie = zombie:getOnlineID(),
                x = animal:getX(),
                y = animal:getY(),
                damage = damage,
                knockdown = knockdown,
            })
            return
        end
    end
    AAZ.applyHit(zombie, animal:getX(), animal:getY(), damage, knockdown)
end

local function startStrike(animal, e)
    animal:stopAllMovementNow()
    animal:getBehavior():setBlockMovement(true)
    animal:setVariable("animalRunning", false)
    animal:faceThisObject(e.zombie)
    animal:setVariable("idleAction", AAZ.STRIKE_ACTION)
    if isServer() then
        sendServerCommand(AAZ.MODULE, AAZ.CMD_STRIKE, { animal = animal:getOnlineID() })
    end
    e.phase = "strike"
    e.timer = 0
    e.landed = false
end

-- Returns "giveup" when the zombie cannot be reached.
local function updateCharge(animal, e)
    local zombie = e.zombie
    local dist = distance(animal, zombie)
    if canHit(animal, zombie, e.reach) then
        startStrike(animal, e)
        return nil
    end

    if dist < e.bestDist - 0.5 then
        e.bestDist = dist
        e.bestDistTime = AAZ.clock
    elseif AAZ.clock - e.bestDistTime > AAZ.opt("StuckTime", 6) then
        return "giveup"
    end

    if AAZ.clock >= e.nextCharge and not animal:isAnimalMoving() then
        -- goAttack() does nothing while an earlier FIGHTANIMAL behavior is still set.
        local behavior = animal:getBehavior()
        behavior:resetBehaviorAction()
        behavior:goAttack(zombie)
        e.nextCharge = AAZ.clock + RECHARGE_INTERVAL
    end
    animal:setVariable("animalRunning", dist > AAZ.opt("ChargeRunDistance", 2))
    return nil
end

-- Returns "end" when the zombie backs off before the warning is over.
local function updateWarning(animal, e, dt)
    e.timer = e.timer + dt
    if distanceToAnchor(e) > e.range * AAZ.opt("WarningStandDown", 125) / 100 then
        return "end"
    end
    animal:faceThisObject(e.zombie)
    if canHit(animal, e.zombie, e.reach) then
        animal:getBehavior():setBlockMovement(false)
        startStrike(animal, e)
    elseif e.timer >= e.warnTime then
        animal:getBehavior():setBlockMovement(false)
        startCharge(animal, e)
    end
    return nil
end

local function updateStrike(animal, e, dt)
    e.timer = e.timer + dt
    if not e.landed and e.timer >= e.timing.connect then
        e.landed = true
        landHit(animal, e)
    end
    if e.timer >= e.timing.length then
        animal:getBehavior():setBlockMovement(false)
        clearStrike(animal)
        e.phase = "recover"
        e.timer = 0
        local pauseMin, pauseMax = AAZ.opt("PauseMin", 0.3), AAZ.opt("PauseMax", 1.0)
        e.recover = ZombRandFloat(math.min(pauseMin, pauseMax), math.max(pauseMin, pauseMax))
    end
end

local function updateRecover(animal, e, dt)
    e.timer = e.timer + dt
    if e.timer >= e.recover then
        startCharge(animal, e)
        e.runUp = false
    end
end

local function isAnimalGone(animal)
    return animal:isDead() or animal:getCurrentSquare() == nil or animal:getVehicle() ~= nil
        or animal:isOnHook() or animal:isHeld()
end

local function isZombieGone(zombie)
    return zombie:isDead() or zombie:getCurrentSquare() == nil
end

-- Returns "end", "giveup" or nil (fight on).
local function checkFight(animal, e)
    local zombie = e.zombie
    if isZombieGone(zombie) then
        return "end"
    end
    if not sameFloor(animal, zombie) then
        return "giveup"
    end
    local dx, dy = zombie:getX() - e.anchorX, zombie:getY() - e.anchorY
    if dx * dx + dy * dy > e.leash * e.leash then
        return "end" -- driven off, or it wandered away
    end
    if AAZ.clock - e.started > AAZ.opt("MaxFightTime", 60) then
        return "giveup"
    end
    return nil
end

local function onTick()
    local dt = getGameTime():getTimeDelta()
    AAZ.clock = AAZ.clock + dt

    -- Fights are ended after the loop, not while pairs() is still walking the table.
    local finished = {}
    for animal, e in pairs(engagements) do
        local outcome
        if isAnimalGone(animal) then
            outcome = "gone"
        else
            outcome = checkFight(animal, e)
        end
        if not outcome then
            addFightStress(animal, AAZ.opt("StressPerSecond", 1.5) * dt)
            if e.phase == "warn" then
                outcome = updateWarning(animal, e, dt)
            elseif e.phase == "charge" then
                outcome = updateCharge(animal, e)
            elseif e.phase == "strike" then
                updateStrike(animal, e, dt)
            else
                updateRecover(animal, e, dt)
            end
        end
        if outcome then
            finished[#finished + 1] = { animal = animal, e = e, outcome = outcome }
        end
    end

    for _, f in ipairs(finished) do
        if engagements[f.animal] == f.e then
            endEngagement(f.animal, f.e, f.outcome == "giveup", f.outcome == "gone")
        end
    end
end

-- Breaks off a fight from outside: the threat scan does this when a crowd gathers or the
-- animal is hurt. Never called while onTick walks the engagements.
function AAZ.disengage(animal)
    local e = engagements[animal]
    if e then
        endEngagement(animal, e, false)
    end
end

-- Drops given-up entries that have run out, and any for animals no longer loaded.
function AAZ.pruneGivenUp()
    local expired = {}
    for animal, entry in pairs(givenUp) do
        if entry.untilTime <= AAZ.clock or animal:getCurrentSquare() == nil then
            expired[#expired + 1] = animal
        end
    end
    for _, animal in ipairs(expired) do
        givenUp[animal] = nil
    end
end

Events.OnTick.Add(onTick)
