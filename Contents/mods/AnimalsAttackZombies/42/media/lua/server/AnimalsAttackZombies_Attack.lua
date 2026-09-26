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

-- All in animation seconds.
local RECHARGE_INTERVAL = 0.5 -- how often a charging animal that has stopped is sent at the zombie again
local STUCK_TIME = 6          -- no ground gained in this long: the zombie is out of reach
local GIVE_UP_TIME = 20       -- a zombie given up on is left alone this long
local MAX_FIGHT_TIME = 60
local RECOVER_MIN, RECOVER_MAX = 0.3, 1.0
local RUN_DISTANCE = 2        -- charges at a run beyond this
local RUN_UP = 3              -- a first hit after a run-up this long is harder to stay standing under
local RUN_UP_KNOCKDOWN = 0.25
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

function AAZ.isGivenUp(animal, zombie)
    local entry = givenUp[animal]
    return entry ~= nil and entry.zombie == zombie and entry.untilTime > AAZ.clock
end

-- anchorX/anchorY: the spot the animal defends (itself, a herd mate or a baby). A zombie
-- that gets further than leash from it has been driven off.
function AAZ.engage(animal, zombie, profile, range, anchorX, anchorY)
    local timing = AAZ.getStrikeTiming(animal)
    if not timing then
        return
    end
    local dist = distance(animal, zombie)
    engagements[animal] = {
        zombie = zombie,
        profile = profile,
        timing = timing,
        reach = getReach(animal),
        anchorX = anchorX,
        anchorY = anchorY,
        leash = range * 1.5 + 3,
        started = AAZ.clock,
        phase = "charge",
        timer = 0,
        nextCharge = 0,
        bestDist = dist,
        bestDistTime = AAZ.clock,
        runUp = dist >= RUN_UP,
    }
end

local function clearStrike(animal)
    if animal:getVariableString("idleAction") == AAZ.STRIKE_ACTION then
        animal:clearVariable("idleAction")
    end
end

local function endEngagement(animal, e, giveUp)
    engagements[animal] = nil
    if e.phase == "strike" then
        animal:getBehavior():setBlockMovement(false)
    end
    clearStrike(animal)
    animal:setVariable("animalRunning", false)
    if giveUp then
        givenUp[animal] = { zombie = e.zombie, untilTime = AAZ.clock + GIVE_UP_TIME }
    end
end

local function rollHit(animal, e)
    local strength = AAZ.getGene(animal, "strength", 0.5)
    local damage = e.profile.damage * (0.5 + strength) * (AAZ.getOption("DamageMultiplier") or 1)
    local chance = e.profile.knockdown
    if e.runUp and chance > 0 then
        chance = chance + RUN_UP_KNOCKDOWN
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
    elseif AAZ.clock - e.bestDistTime > STUCK_TIME then
        return "giveup"
    end

    if AAZ.clock >= e.nextCharge and not animal:isAnimalMoving() then
        -- goAttack() does nothing while an earlier FIGHTANIMAL behavior is still set.
        local behavior = animal:getBehavior()
        behavior:resetBehaviorAction()
        behavior:goAttack(zombie)
        e.nextCharge = AAZ.clock + RECHARGE_INTERVAL
    end
    animal:setVariable("animalRunning", dist > RUN_DISTANCE)
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
        e.recover = ZombRandFloat(RECOVER_MIN, RECOVER_MAX)
    end
end

local function updateRecover(animal, e, dt)
    e.timer = e.timer + dt
    if e.timer >= e.recover then
        e.phase = "charge"
        e.bestDist = distance(animal, e.zombie)
        e.bestDistTime = AAZ.clock
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
    if AAZ.clock - e.started > MAX_FIGHT_TIME then
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
            outcome = "end"
        else
            outcome = checkFight(animal, e)
        end
        if not outcome then
            if e.phase == "charge" then
                outcome = updateCharge(animal, e)
            elseif e.phase == "strike" then
                updateStrike(animal, e, dt)
            else
                updateRecover(animal, e, dt)
            end
        end
        if outcome then
            finished[#finished + 1] = { animal = animal, e = e, giveUp = outcome == "giveup" }
        end
    end

    for _, f in ipairs(finished) do
        if engagements[f.animal] == f.e then
            endEngagement(f.animal, f.e, f.giveUp)
        end
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
