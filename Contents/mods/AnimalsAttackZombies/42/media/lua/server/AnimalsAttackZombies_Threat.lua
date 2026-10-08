--[[
    Animals Attack Zombies -- when an animal turns on a zombie.

    Vanilla has every animal back away from zombies. BaseAnimalBehavior.spotted() raises
    stress for a zombie within 10 tiles and runs from one within 6, unless the animal's
    definition sets fleeZombies = false, in which case zombies are ignored altogether.
    attackIfStressed only ever fires at an IsoPlayer. Nothing in vanilla starts a fight
    with a zombie.

    The roster animals have fleeZombies off (Definitions/animal/
    AnimalsAttackZombies_GeneralDefinitions.lua), and a scan here, twice a second, decides
    what each of them does instead. Real livestock are prey animals that fight only when
    they have something to defend and the odds look right, so:

      - Run, as vanilla would have made it (BaseAnimalBehavior.forceFleeFromChr, the same
        flee spotted() uses), when:
          - its species is turned off, or it is a mother without young, and a zombie is
            within FleeRange (6 tiles by default, as vanilla);
          - it is hurt, below the RetreatHealth option;
          - a crowd has gathered: CrowdLimit zombies within CrowdRadius, plus one for every
            other fighter of its kind standing with it (strength in numbers). A fight in
            progress is broken off for either of these.
      - Otherwise fight, if it has something to guard: a male guards himself and the
        animals of his kind around him; a mother guards her babies. The target is the
        zombie nearest it among those within its range of anything it guards.
        Only a zombie it has a clear straight line to counts: one on the far side of its
        pen fence or inside a house is left alone instead of being charged and given up on
        over and over. Neither is a corpse a player is dragging (a live IsoZombie while it
        is grappled).
      - Hesitation option: it does not always commit at once. Each scan it charges with a
        chance that climbs steeply as the zombie gets closer to what it guards (sure to
        charge within the last AlwaysChargePercent of its range), scaled by its species'
        temper, its aggressiveness gene and the Aggression option. Until it commits it
        stands and watches the zombie.

    The range starts at the EngageRange option and follows the animal:
      - RutRange outside the mating season for species with a rut (rams, turkey toms),
      - the breed's range percent (dairy bulls are the quickest to fight),
      - the aggressiveness gene: 0.75x at 0, 1x at the typical 0.4, 1.375x at 1
        (with GeneInfluence at 100%).

    Everything here runs on the server (or in single player), which owns the animals; a
    multiplayer client only sees the result through the animal's own sync.
]]

if isClient() then return end

require "AnimalsAttackZombies"
require "AnimalsAttackZombies_Attack" -- AAZ.clock, AAZ.engage and the given-up list
local AAZ = AnimalsAttackZombies

-- Every gameplay number is a sandbox option (AAZ.opt, defaults as in sandbox-options.txt):
--   EngageRange         tiles, before the rut, breed and gene factors
--   HerdRadius          tiles: herd mates this close to a male are his to defend, and
--                       fellow fighters this close stand with him against a crowd
--   YoungRadius         tiles: a mother defends her babies up to this far from her
--   FleeRange           tiles: roster animals that are not fighting run from a zombie this
--                       close (vanilla's BaseAnimalBehavior.spotted() uses 6)
--   CrowdLimit          zombies that make a lone fighter run; 0 turns crowds off
--   CrowdRadius         tiles: zombies this close count toward a crowd, and a hurt animal
--                       runs from one this close
--   RetreatHealth       % health below which an animal will not fight; 0 turns it off
--   RutRange            % of range outside the mating season, for species with a rut
--   ChargeChanceAtEdge  % chance per scan to commit to a zombie at the edge of the range,
--   ChargeChanceUpClose % and right beside what it guards, rising with closeness squared
--   AlwaysChargePercent % of the range, from what it guards, inside which it always commits
--   Aggression          multiplier on the chance to commit
-- These stay fixed: they fit the engine or mirror vanilla, not the game's balance.
local SCAN_INTERVAL = 0.5    -- animation seconds between scans
local SCAN_MIN_REAL_MS = 100 -- and at least this much real time, so fast forward does not scan every frame
local FLEE_INTERVAL = 4      -- vanilla waits timerFleeAgain (200 ticks, about 4 s) before running again

local nextScan = 0
local lastScanMs = 0
local lastFlee = {} -- IsoAnimal -> AAZ.clock when it last ran

local function isActive(animal)
    return animal ~= nil and not animal:isDead() and animal:getCurrentSquare() ~= nil
        and animal:getVehicle() == nil and not animal:isOnHook() and not animal:isHeld()
end

local function getEngageRange(animal, profile)
    local range = AAZ.opt("EngageRange", 6)
    if profile.rut and not animal:isInMatingSeason() then
        range = range * AAZ.opt("RutRange", 50) / 100
    end
    local breed = animal:getBreed()
    local percent = breed and AAZ.breedRange(profile, string.lower(breed:getName()))
    if percent then
        range = range * percent / 100
    end
    range = range * (0.75 + AAZ.getGene(animal, "aggressiveness", 0.4) * 0.625)
    return math.max(1, range)
end

local function isHurt(animal)
    local threshold = AAZ.opt("RetreatHealth", 40)
    return threshold > 0 and animal:getHealth() * 100 < threshold
end

-- herds: group -> list of every loaded animal of that group (for herd mates).
-- roster: the roster animals, with their profile when their species is turned on.
local function collectAnimals(cell)
    local herds, roster = {}, {}
    local animals = cell:getAnimals()
    for i = 0, animals:size() - 1 do
        local animal = animals:get(i)
        if isActive(animal) then
            local animalType = animal:getAnimalType()
            local def = AnimalDefinitions.animals[animalType]
            local x, y, z = animal:getX(), animal:getY(), math.floor(animal:getZ())
            if def and def.group then
                local herd = herds[def.group]
                if not herd then
                    herd = {}
                    herds[def.group] = herd
                end
                herd[#herd + 1] = { animal = animal, x = x, y = y, z = z }
            end
            if AAZ.roster[animalType] then
                roster[#roster + 1] = {
                    animal = animal, x = x, y = y, z = z,
                    group = def and def.group,
                    profile = AAZ.getProfile(animal),
                }
            end
        end
    end
    return herds, roster
end

local function collectZombies(cell)
    local zombies = {}
    local list = cell:getZombieList()
    for i = 0, list:size() - 1 do
        local zombie = list:get(i)
        if AAZ.isFightableZombie(zombie) then
            zombies[#zombies + 1] = {
                zombie = zombie, x = zombie:getX(), y = zombie:getY(), z = math.floor(zombie:getZ()),
            }
        end
    end
    return zombies
end

-- The spots this animal defends, or nil when it has nothing to defend.
local function getGuardPoints(entry, herds)
    local points = { { x = entry.x, y = entry.y } }
    local youngRadius, herdRadius = AAZ.opt("YoungRadius", 15), AAZ.opt("HerdRadius", 8)
    if entry.profile.guards == "young" then
        local babies = entry.animal:getBabies()
        if babies then
            for i = 0, babies:size() - 1 do
                local baby = babies:get(i)
                if isActive(baby) and baby:isBaby() and math.floor(baby:getZ()) == entry.z then
                    local bx, by = baby:getX(), baby:getY()
                    local dx, dy = bx - entry.x, by - entry.y
                    if dx * dx + dy * dy <= youngRadius * youngRadius then
                        points[#points + 1] = { x = bx, y = by }
                    end
                end
            end
        end
        if #points == 1 then
            return nil
        end
    else
        for _, mate in ipairs(herds[entry.group] or {}) do
            if mate.animal ~= entry.animal and mate.z == entry.z then
                local dx, dy = mate.x - entry.x, mate.y - entry.y
                if dx * dx + dy * dy <= herdRadius * herdRadius then
                    points[#points + 1] = { x = mate.x, y = mate.y }
                end
            end
        end
    end
    return points
end

-- The zombie nearest the animal among those within range of any spot it guards and in a
-- clear straight line from it, the spot nearest that zombie, and how far the zombie is
-- from it.
local function pickTarget(entry, points, range, zombies)
    local minX, maxX, minY, maxY = entry.x, entry.x, entry.y, entry.y
    for _, p in ipairs(points) do
        minX, maxX = math.min(minX, p.x), math.max(maxX, p.x)
        minY, maxY = math.min(minY, p.y), math.max(maxY, p.y)
    end
    minX, maxX, minY, maxY = minX - range, maxX + range, minY - range, maxY + range

    local r2 = range * range
    local candidates = {}
    for _, z in ipairs(zombies) do
        if z.z == entry.z and z.x >= minX and z.x <= maxX and z.y >= minY and z.y <= maxY
                and not AAZ.isGivenUp(entry.animal, z.zombie) then
            local anchor, anchorD2
            for _, p in ipairs(points) do
                local dx, dy = z.x - p.x, z.y - p.y
                local pd2 = dx * dx + dy * dy
                if pd2 <= r2 and (not anchorD2 or pd2 < anchorD2) then
                    anchor, anchorD2 = p, pd2
                end
            end
            if anchor then
                local dx, dy = z.x - entry.x, z.y - entry.y
                candidates[#candidates + 1] = { z = z, anchor = anchor, anchorD2 = anchorD2, d2 = dx * dx + dy * dy }
            end
        end
    end
    -- Nearest first, and the line walk only until one is clear.
    table.sort(candidates, function(a, b) return a.d2 < b.d2 end)
    for _, c in ipairs(candidates) do
        if AAZ.hasClearLine(entry.animal, c.z.zombie) then
            return c.z, c.anchor, math.sqrt(c.anchorD2)
        end
    end
    return nil
end

-- Whether the animal commits to a charge this scan (Hesitation option).
local function commits(animal, profile, anchorDist, range)
    if not AAZ.opt("Hesitation", true) then
        return true
    end
    local closeness = 1 - anchorDist / range
    if closeness >= 1 - AAZ.opt("AlwaysChargePercent", 15) / 100 then
        return true
    end
    local edge = AAZ.opt("ChargeChanceAtEdge", 4) / 100
    local close = AAZ.opt("ChargeChanceUpClose", 60) / 100
    local chance = (edge + (close - edge) * closeness * closeness)
        * AAZ.tuning(profile, "Temper")
        * (0.5 + AAZ.getGene(animal, "aggressiveness", 0.4))
        * AAZ.opt("Aggression", 1)
    return ZombRandFloat(0, 1) < chance
end

local function countZombiesNear(entry, zombies, radius)
    local count, r2 = 0, radius * radius
    for _, z in ipairs(zombies) do
        if z.z == entry.z then
            local dx, dy = z.x - entry.x, z.y - entry.y
            if dx * dx + dy * dy <= r2 then
                count = count + 1
            end
        end
    end
    return count
end

-- Other fighters of the same kind standing with this one.
local function countAllies(entry, fighters)
    local count, herdRadius = 0, AAZ.opt("HerdRadius", 8)
    for _, other in ipairs(fighters) do
        if other ~= entry and other.group == entry.group and other.z == entry.z then
            local dx, dy = other.x - entry.x, other.y - entry.y
            if dx * dx + dy * dy <= herdRadius * herdRadius then
                count = count + 1
            end
        end
    end
    return count
end

local function isOutnumbered(entry, zombies, fighters)
    local limit = AAZ.opt("CrowdLimit", 4)
    if limit <= 0 then
        return false
    end
    return countZombiesNear(entry, zombies, AAZ.opt("CrowdRadius", 8)) >= limit + countAllies(entry, fighters)
end

local function runFromZombies(entry, zombies, radius)
    local animal = entry.animal
    if animal:isAnimalMoving() then
        return
    end
    local last = lastFlee[animal]
    if last and AAZ.clock - last < FLEE_INTERVAL then
        return
    end

    local nearest, nearestD2
    for _, z in ipairs(zombies) do
        if z.z == entry.z then
            local dx, dy = z.x - entry.x, z.y - entry.y
            local d2 = dx * dx + dy * dy
            if d2 <= radius * radius and (not nearestD2 or d2 < nearestD2) then
                nearest, nearestD2 = z, d2
            end
        end
    end
    if nearest then
        animal:getBehavior():forceFleeFromChr(nearest.zombie)
        lastFlee[animal] = AAZ.clock
    end
end

local function pruneLastFlee()
    local stale = {}
    for animal, time in pairs(lastFlee) do
        if AAZ.clock - time >= FLEE_INTERVAL then
            stale[#stale + 1] = animal
        end
    end
    for _, animal in ipairs(stale) do
        lastFlee[animal] = nil
    end
end

-- A hesitating animal stands and watches the zombie it is sizing up.
local function watch(animal, zombie)
    if not animal:isAnimalMoving() then
        animal:faceThisObject(zombie)
    end
end

local function scan()
    local cell = getCell()
    if not cell then
        return
    end
    pruneLastFlee()
    AAZ.pruneGivenUp()

    local herds, roster = collectAnimals(cell)
    if #roster == 0 then
        return
    end
    local zombies = collectZombies(cell)
    if #zombies == 0 then
        return
    end

    -- Sort the roster into fighters and runners first: the crowd check needs to know who
    -- stands with whom.
    local fighters, runners = {}, {}
    for _, entry in ipairs(roster) do
        if entry.profile and not isHurt(entry.animal) then
            entry.points = getGuardPoints(entry, herds)
        end
        if entry.points then
            fighters[#fighters + 1] = entry
        else
            -- Hurt, its young gone or its species turned off: a fight in progress ends too.
            AAZ.disengage(entry.animal)
            if isHurt(entry.animal) then
                entry.fleeRadius = AAZ.opt("CrowdRadius", 8)
            else
                entry.fleeRadius = AAZ.opt("FleeRange", 6)
            end
            runners[#runners + 1] = entry
        end
    end

    for _, entry in ipairs(fighters) do
        if isOutnumbered(entry, zombies, fighters) then
            AAZ.disengage(entry.animal)
            runFromZombies(entry, zombies, AAZ.opt("CrowdRadius", 8))
        elseif not AAZ.isEngaged(entry.animal) then
            local range = getEngageRange(entry.animal, entry.profile)
            local target, anchor, anchorDist = pickTarget(entry, entry.points, range, zombies)
            if target then
                if commits(entry.animal, entry.profile, anchorDist, range) then
                    AAZ.engage(entry.animal, target.zombie, entry.profile, range, anchor.x, anchor.y)
                else
                    watch(entry.animal, target.zombie)
                end
            end
        end
    end

    for _, entry in ipairs(runners) do
        runFromZombies(entry, zombies, entry.fleeRadius)
    end
end

local function onTick()
    if AAZ.clock < nextScan then
        return
    end
    local now = getTimestampMs()
    if now - lastScanMs < SCAN_MIN_REAL_MS then
        return
    end
    nextScan = AAZ.clock + SCAN_INTERVAL
    lastScanMs = now
    scan()
end

Events.OnTick.Add(onTick)
