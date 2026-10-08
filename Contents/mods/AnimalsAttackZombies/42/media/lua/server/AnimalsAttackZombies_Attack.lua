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
               (eating, wandering) out of the way while the path lasts. It runs when it
               has ground to cover.
      strike   In reach and with nothing in between, the animal stops, faces the zombie
               and plays its own attack clip through the idle node this mod adds
               (AnimalsAttackZombies.STRIKE_ACTION). The hit lands at the clip's
               vanilla AttackConnect point, timed in animation seconds
               (GameTime.getTimeDelta(), the same clock AnimationPlayer runs on), so it
               stays in step at any game speed.
      recover  A short pause, then back to charge, which strikes again at once if the
               zombie is still in reach.

    Vanilla starts a wander or an eat/drink trip whenever an animal is idle, not blocked
    and doing no behavior (BaseAnimalBehavior.wanderIdle/checkBehavior), which would take
    it off the fight. So the animal keeps blockMovement from the warning through every
    strike and pause, and loses it only for the charge; a charge that vanilla replaces
    with another walk (the path no longer leads to the zombie) is stopped and reissued.

    A fight ends when the zombie dies, gets away from what the animal guards, or cannot
    be reached. A zombie given up on is left alone for a while so the animal does not
    pace a fence forever; an animal remembers every zombie it gave up on.

    In multiplayer the hit has to land on the client that simulates the zombie, and every
    other client plays the reaction (AnimalsAttackZombies.CMD_HIT). Every client is told
    to play the strike at once (AnimalsAttackZombies.CMD_STRIKE), and the animal's state
    is pushed straight away (IsoAnimal.sendExtraUpdateToClients) so its facing arrives
    with the strike instead of up to a second later.
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
-- These stay fixed: they fit the engine, not the game.
local RECHARGE_INTERVAL = 0.5 -- animation s between re-issuing goAttack() to a stopped animal
local REACH_SLACK = 0.5       -- AnimalAttackState misses a player further than attackDist + 0.5
local OFF_COURSE = 3          -- tiles between a path's end and the zombie that mean it leads elsewhere
local MAX_LINE_STEPS = 64     -- squares a line-of-sight walk checks before calling it blocked

local engagements = {} -- IsoAnimal -> engagement
local givenUp = {}     -- IsoAnimal -> { [IsoZombie] = untilTime }

-- Animation seconds since load; the one clock every timer here reads.
AAZ.clock = 0

local function distance(a, b)
    local dx, dy = a:getX() - b:getX(), a:getY() - b:getY()
    return math.sqrt(dx * dx + dy * dy)
end

local function sameFloor(a, b)
    return math.floor(a:getZ()) == math.floor(b:getZ())
end

-- True when a wall, fence, closed gate, door or window stands on the straight line from
-- (x0, y0) to (x1, y1) on floor z. Walks every square the line crosses, one edge at a
-- time (a voxel walk), and asks IsoGridSquare.isBlockedTo() at each edge. A line that
-- runs exactly through a corner goes along x first.
function AAZ.isLineBlocked(x0, y0, x1, y1, z)
    local cell = getCell()
    local cx, cy = math.floor(x0), math.floor(y0)
    local tx, ty = math.floor(x1), math.floor(y1)
    local square = cell:getGridSquare(cx, cy, z)
    if not square then
        return true
    end
    local dx, dy = x1 - x0, y1 - y0
    local stepX, stepY = dx > 0 and 1 or -1, dy > 0 and 1 or -1
    local tMaxX, tDeltaX, tMaxY, tDeltaY = 1e9, 1e9, 1e9, 1e9
    if dx ~= 0 then
        tMaxX = ((stepX > 0 and cx + 1 or cx) - x0) / dx
        tDeltaX = 1 / math.abs(dx)
    end
    if dy ~= 0 then
        tMaxY = ((stepY > 0 and cy + 1 or cy) - y0) / dy
        tDeltaY = 1 / math.abs(dy)
    end
    for _ = 1, MAX_LINE_STEPS do
        if cx == tx and cy == ty then
            return false
        end
        if tMaxX <= tMaxY then
            cx = cx + stepX
            tMaxX = tMaxX + tDeltaX
        else
            cy = cy + stepY
            tMaxY = tMaxY + tDeltaY
        end
        local nextSquare = cell:getGridSquare(cx, cy, z)
        if not nextSquare or square:isBlockedTo(nextSquare) then
            return true
        end
        square = nextSquare
    end
    return true
end

-- Whether the animal has a clear straight line to the zombie on its own floor. Used before
-- committing, so an animal does not square up to a zombie on the far side of its pen
-- fence or in a house, and for every strike.
function AAZ.hasClearLine(animal, zombie)
    return sameFloor(animal, zombie)
        and not AAZ.isLineBlocked(animal:getX(), animal:getY(), zombie:getX(), zombie:getY(), math.floor(animal:getZ()))
end

-- Whether a zombie is something to fight at all. A corpse a player is dragging is a live,
-- on-floor IsoZombie (IsoDeadBody.reanimateZombieForGrapple), which vanilla animals ignore
-- too (IsoAnimal.updateLOS).
function AAZ.isFightableZombie(zombie)
    return not zombie:isDead() and not zombie:isFakeDead() and zombie:getCurrentSquare() ~= nil
        and not zombie:isReanimatedForGrappleOnly() and not zombie:isBeingGrappled()
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
    local untilTime = entry and entry[zombie]
    return untilTime ~= nil and untilTime > AAZ.clock
end

local function distanceToAnchor(e)
    local dx, dy = e.zombie:getX() - e.anchorX, e.zombie:getY() - e.anchorY
    return math.sqrt(dx * dx + dy * dy)
end

-- blockMovement keeps vanilla's wandering, eating and drinking out of a fight. e.blocked
-- tracks it, since BaseAnimalBehavior.blockMovement is a field Lua cannot read.
local function block(animal, e)
    animal:getBehavior():setBlockMovement(true) -- also stopAllMovementNow()
    e.blocked = true
end

local function unblock(animal, e)
    if e.blocked then
        animal:getBehavior():setBlockMovement(false)
        e.blocked = false
    end
end

-- Pushes the animal's facing and idleAction to clients now instead of with the next
-- periodic AnimalPacket (every 0.8-1 s).
local function syncToClients(animal)
    if isServer() then
        animal:sendExtraUpdateToClients()
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
    block(animal, e)
    animal:setVariable("animalRunning", false)
    animal:faceThisObject(e.zombie)
    if isServer() then
        sendServerCommand(AAZ.MODULE, AAZ.CMD_WARN, { animal = animal:getOnlineID() })
        syncToClients(animal)
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
        blocked = false,
    }
    engagements[animal] = e
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
-- hook). It is not moved, but its block and strike are still cleared: a carried rooster
-- or a trailered bull comes back as the same IsoAnimal, and would otherwise stand frozen
-- until vanilla's own failsafe (wanderIdle, 8000 multiplier units, about 3 minutes).
local function endEngagement(animal, e, giveUp, gone)
    engagements[animal] = nil
    unblock(animal, e)
    clearStrike(animal)
    animal:setVariable("animalRunning", false)
    if gone then
        return
    end
    if e.phase == "charge" and animal:isAnimalMoving() then
        -- Otherwise it carries on down the charge path at the zombie it just broke off from.
        animal:stopAllMovementNow()
    end
    if giveUp then
        local entry = givenUp[animal]
        if not entry then
            entry = {}
            givenUp[animal] = entry
        end
        entry[e.zombie] = AAZ.clock + AAZ.opt("GiveUpTime", 20)
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
    return distance(animal, zombie) <= reach and AAZ.hasClearLine(animal, zombie)
end

local function landHit(animal, e)
    local zombie = e.zombie
    if not canHit(animal, zombie, e.reach + REACH_SLACK) then
        return -- it moved out of reach during the swing
    end
    local damage, knockdown = rollHit(animal, e)
    if isServer() then
        -- From the owner's last update; tells the other clients to knock it down.
        local lethal = zombie:getHealth() - damage <= 0
        -- A zombie nobody simulates is the server's to hit. Every client gets the hit:
        -- the owner takes the damage, the others play the reaction.
        if not zombie:getOwnerPlayer() then
            AAZ.applyHit(zombie, animal:getX(), animal:getY(), damage, knockdown)
        end
        sendServerCommand(AAZ.MODULE, AAZ.CMD_HIT, {
            zombie = zombie:getOnlineID(),
            x = animal:getX(),
            y = animal:getY(),
            damage = damage,
            knockdown = knockdown,
            lethal = lethal,
        })
        return
    end
    AAZ.applyHit(zombie, animal:getX(), animal:getY(), damage, knockdown)
end

local function startStrike(animal, e)
    animal:stopAllMovementNow()
    block(animal, e)
    animal:setVariable("animalRunning", false)
    animal:faceThisObject(e.zombie)
    -- After block(): stopAllMovementNow() clears idleAction (AnimalData.resetEatingCheck).
    animal:setVariable("idleAction", AAZ.STRIKE_ACTION)
    if isServer() then
        sendServerCommand(AAZ.MODULE, AAZ.CMD_STRIKE, { animal = animal:getOnlineID() })
        syncToClients(animal)
    end
    e.phase = "strike"
    e.timer = 0
    e.landed = false
end

-- Whether a moving animal is still on its charge: goAttack() paths to the zombie itself,
-- and a path that failed carries on along the fence (AnimalFollowWallState) to a spot by
-- it. Anything else is vanilla walking it off to wander, eat or drink.
local function isOffCourse(animal, zombie)
    local pfb = animal:getPathFindBehavior2()
    if pfb:isGoalCharacter() and pfb:getTargetChar() == zombie then
        return false
    end
    local dx = animal:getPathTargetX() + 0.5 - zombie:getX()
    local dy = animal:getPathTargetY() + 0.5 - zombie:getY()
    return dx * dx + dy * dy > OFF_COURSE * OFF_COURSE
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

    local moving = animal:isAnimalMoving()
    if moving and isOffCourse(animal, zombie) then
        animal:stopAllMovementNow()
        moving = false
        e.nextCharge = 0
    end
    if not moving and AAZ.clock >= e.nextCharge then
        -- goAttack() does nothing while blocked or while an earlier FIGHTANIMAL behavior
        -- is still set.
        unblock(animal, e)
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
        startStrike(animal, e)
    elseif e.timer >= e.warnTime then
        startCharge(animal, e) -- still blocked: updateCharge lifts it for goAttack()
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
        -- Still blocked through the pause, so vanilla starts no wander or meal in it.
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

-- Returns "end", "giveup" or nil (fight on).
local function checkFight(animal, e)
    local zombie = e.zombie
    if not AAZ.isFightableZombie(zombie) then
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
-- animal no longer fights (hurt, its young gone, its species turned off). Never called
-- while onTick walks the engagements.
function AAZ.disengage(animal)
    local e = engagements[animal]
    if e then
        endEngagement(animal, e, false)
    end
end

-- Drops given-up zombies whose time has run out, and animals no longer loaded.
function AAZ.pruneGivenUp()
    local emptied = {}
    for animal, entry in pairs(givenUp) do
        if animal:getCurrentSquare() == nil then
            emptied[#emptied + 1] = animal
        else
            local expired = {}
            local left = false
            for zombie, untilTime in pairs(entry) do
                if untilTime <= AAZ.clock then
                    expired[#expired + 1] = zombie
                else
                    left = true
                end
            end
            for _, zombie in ipairs(expired) do
                entry[zombie] = nil
            end
            if not left then
                emptied[#emptied + 1] = animal
            end
        end
    end
    for _, animal in ipairs(emptied) do
        givenUp[animal] = nil
    end
end

Events.OnTick.Add(onTick)
