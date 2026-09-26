--[[
    Animals Attack Zombies -- when an animal turns on a zombie.

    Vanilla has every animal back away from zombies. BaseAnimalBehavior.spotted() raises
    stress for a zombie within 10 tiles and runs from one within 6, unless the animal's
    definition sets fleeZombies = false, in which case zombies are ignored altogether.
    attackIfStressed only ever fires at an IsoPlayer. Nothing in vanilla starts a fight
    with a zombie.

    The roster animals have fleeZombies off (Definitions/animal/
    AnimalsAttackZombies_GeneralDefinitions.lua), and a scan here, twice a second, decides
    what each of them does instead:

      - Fight: an animal whose species is turned on and that has something to guard picks
        the nearest zombie within its range of what it guards and hands it to
        AnimalsAttackZombies_Attack. A male guards himself and the animals of his kind
        around him; a mother guards her babies, and only while she has some.
      - Run: every other roster animal (species turned off, or a mother without young)
        runs from a zombie within 6 tiles, the way vanilla would have made it
        (BaseAnimalBehavior.forceFleeFromChr, the same flee spotted() uses).

    The range starts at the EngageRange option and follows the animal:
      - half outside the mating season for species with a rut (rams, turkey toms),
      - the breed's factor (dairy bulls are the quickest to fight),
      - the aggressiveness gene: 0.75x at 0, 1x at the typical 0.4, 1.375x at 1.
]]

if isClient() then return end

require "AnimalsAttackZombies"
require "AnimalsAttackZombies_Attack" -- AAZ.clock, AAZ.engage and the given-up list
local AAZ = AnimalsAttackZombies

local SCAN_INTERVAL = 0.5    -- animation seconds between scans
local SCAN_MIN_REAL_MS = 100 -- and at least this much real time, so fast forward does not scan every frame
local HERD_RADIUS = 8        -- herd mates this close to a male are his to defend
local YOUNG_RADIUS = 15      -- a mother defends her babies up to this far from her
local FLEE_RANGE = 6         -- vanilla runs from a zombie within 6 tiles (BaseAnimalBehavior.spotted)
local FLEE_INTERVAL = 4      -- vanilla waits timerFleeAgain (200 ticks, about 4 s) before running again
local RUT_FACTOR = 0.5

local nextScan = 0
local lastScanMs = 0
local lastFlee = {} -- IsoAnimal -> AAZ.clock when it last ran

local function isActive(animal)
    return animal ~= nil and not animal:isDead() and animal:getCurrentSquare() ~= nil
        and animal:getVehicle() == nil and not animal:isOnHook() and not animal:isHeld()
end

local function getEngageRange(animal, profile)
    local range = AAZ.getOption("EngageRange") or 6
    if profile.rut and not animal:isInMatingSeason() then
        range = range * RUT_FACTOR
    end
    if profile.breeds then
        local breed = animal:getBreed()
        local factor = breed and profile.breeds[string.lower(breed:getName())]
        if factor then
            range = range * factor
        end
    end
    range = range * (0.75 + AAZ.getGene(animal, "aggressiveness", 0.4) * 0.625)
    return math.max(1, range)
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
        if not zombie:isDead() and not zombie:isFakeDead() and zombie:getCurrentSquare() then
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
    if entry.profile.guards == "young" then
        local babies = entry.animal:getBabies()
        if babies then
            for i = 0, babies:size() - 1 do
                local baby = babies:get(i)
                if isActive(baby) and baby:isBaby() and math.floor(baby:getZ()) == entry.z then
                    local bx, by = baby:getX(), baby:getY()
                    local dx, dy = bx - entry.x, by - entry.y
                    if dx * dx + dy * dy <= YOUNG_RADIUS * YOUNG_RADIUS then
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
                if dx * dx + dy * dy <= HERD_RADIUS * HERD_RADIUS then
                    points[#points + 1] = { x = mate.x, y = mate.y }
                end
            end
        end
    end
    return points
end

-- The zombie nearest the animal among those within range of any spot it guards, and
-- that spot.
local function pickTarget(entry, points, range, zombies)
    local minX, maxX, minY, maxY = entry.x, entry.x, entry.y, entry.y
    for _, p in ipairs(points) do
        minX, maxX = math.min(minX, p.x), math.max(maxX, p.x)
        minY, maxY = math.min(minY, p.y), math.max(maxY, p.y)
    end
    minX, maxX, minY, maxY = minX - range, maxX + range, minY - range, maxY + range

    local r2 = range * range
    local best, bestAnchor, bestD2
    for _, z in ipairs(zombies) do
        if z.z == entry.z and z.x >= minX and z.x <= maxX and z.y >= minY and z.y <= maxY
                and not AAZ.isGivenUp(entry.animal, z.zombie) then
            local anchor
            for _, p in ipairs(points) do
                local dx, dy = z.x - p.x, z.y - p.y
                if dx * dx + dy * dy <= r2 then
                    anchor = p
                    break
                end
            end
            if anchor then
                local dx, dy = z.x - entry.x, z.y - entry.y
                local d2 = dx * dx + dy * dy
                if not bestD2 or d2 < bestD2 then
                    best, bestAnchor, bestD2 = z, anchor, d2
                end
            end
        end
    end
    return best, bestAnchor
end

local function runFromZombies(entry, zombies)
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
            if d2 <= FLEE_RANGE * FLEE_RANGE and (not nearestD2 or d2 < nearestD2) then
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

    for _, entry in ipairs(roster) do
        if not AAZ.isEngaged(entry.animal) then
            local points = entry.profile and getGuardPoints(entry, herds)
            if points then
                local range = getEngageRange(entry.animal, entry.profile)
                local target, anchor = pickTarget(entry, points, range, zombies)
                if target then
                    AAZ.engage(entry.animal, target.zombie, entry.profile, range, anchor.x, anchor.y)
                end
            else
                runFromZombies(entry, zombies)
            end
        end
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
