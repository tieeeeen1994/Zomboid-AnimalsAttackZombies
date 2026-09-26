-- Offline stand-in for the parts of the Build 42 Lua API the mod touches, plus a tiny
-- world that moves animals along their paths and knocks zombies over. Method names mirror
-- the Java API (checked against the decompile, see docs/implementation.md); calling a
-- method that does not exist here is an error, on purpose.
--
-- run_tests.py sets MODE ("sp", "server" or "client") before loading this file.

MODE = MODE or "sp"

World = {
    time = 0,          -- seconds
    dt = 1 / 60,       -- GameTime.getTimeDelta() per tick
    animals = {},
    zombies = {},
    fenceX = nil,      -- a fence runs between x = fenceX - 1 and x = fenceX
    sent = {},         -- sendServerCommand calls
    varLog = {},       -- { time, animal, key, value } for every setVariable
    soundLog = {},     -- { time, animal, id } for every playBreedSound
    hitLog = {},       -- { time, zombie, health } for every setHealth
}

local nextId = 100

local function strict(obj, name)
    return setmetatable(obj, {
        __index = function(_, key)
            error("fake " .. name .. " has no member '" .. tostring(key) .. "'", 2)
        end,
    })
end

local function newList(values)
    local list = { values = values or {} }
    function list:size() return #self.values end
    function list:get(i) return self.values[i + 1] end
    function list:add(v) self.values[#self.values + 1] = v end
    return strict(list, "List")
end
NewList = newList

-- Vector2 ------------------------------------------------------------------------------

function NewVector2(x, y)
    local v = { x = x or 0, y = y or 0 }
    function v:set(nx, ny) self.x, self.y = nx, ny return self end
    function v:normalize()
        local len = math.sqrt(self.x * self.x + self.y * self.y)
        if len > 0 then self.x, self.y = self.x / len, self.y / len end
        return len
    end
    function v:getX() return self.x end
    function v:getY() return self.y end
    return strict(v, "Vector2")
end

-- Squares ------------------------------------------------------------------------------

local squares = {}

local function getSquare(x, y, z)
    local key = x .. "," .. y .. "," .. z
    local sq = squares[key]
    if sq then return sq end
    sq = { x = x, y = y, z = z }
    function sq:getX() return self.x end
    function sq:getY() return self.y end
    function sq:getZ() return self.z end
    function sq:isBlockedTo(other)
        local f = World.fenceX
        if not f then return false end
        return (self.x < f) ~= (other.x < f)
    end
    squares[key] = strict(sq, "IsoGridSquare")
    return squares[key]
end

local function squareOf(obj)
    return getSquare(math.floor(obj.s.x), math.floor(obj.s.y), math.floor(obj.s.z))
end

function FenceBetween(a, b)
    local f = World.fenceX
    return f ~= nil and ((a.s.x < f) ~= (b.s.x < f))
end

-- Zombies ------------------------------------------------------------------------------

function NewZombie(x, y, opts)
    opts = opts or {}
    nextId = nextId + 1
    local z = { s = {
        x = x, y = y, z = 0, health = opts.health or 2.0, id = nextId,
        fwdX = opts.fwdX or -1, fwdY = opts.fwdY or 0,
        vx = opts.vx or 0, vy = opts.vy or 0,
        onFloor = false, floorTime = 0, knockedDown = false, staggerBack = false,
        hitForce = 0, attackPosition = nil, hitFromBehind = false, hitReaction = nil,
        events = {}, owner = opts.owner, remote = opts.remote or false,
        fakeDead = opts.fakeDead or false, hitDir = NewVector2(),
    } }
    function z:getX() return self.s.x end
    function z:getY() return self.s.y end
    function z:getZ() return self.s.z end
    function z:isDead() return self.s.health <= 0 end
    function z:isFakeDead() return self.s.fakeDead end
    function z:getCurrentSquare() return squareOf(self) end
    function z:getHealth() return self.s.health end
    function z:setHealth(h)
        self.s.health = h
        World.hitLog[#World.hitLog + 1] = { time = World.time, zombie = self, health = h }
    end
    function z:isOnFloor() return self.s.onFloor end
    function z:getHitDir() return self.s.hitDir end
    function z:setHitReaction(r) self.s.hitReaction = r end
    function z:setForwardDirection(fx, fy)
        local len = math.sqrt(fx * fx + fy * fy)
        assert(len > 0, "Forward Direction cannot be zero length vector.")
        self.s.fwdX, self.s.fwdY = fx / len, fy / len
    end
    function z:getForwardDirectionX() return self.s.fwdX end
    function z:getForwardDirectionY() return self.s.fwdY end
    function z:setPlayerAttackPosition(p) self.s.attackPosition = p end
    function z:setHitFromBehind(b) self.s.hitFromBehind = b end
    function z:setKnockedDown(b) self.s.knockedDown = b end
    function z:setStaggerBack(b) self.s.staggerBack = b end
    function z:setHitForce(f) self.s.hitForce = f end
    function z:reportEvent(name)
        self.s.events[#self.s.events + 1] = name
        if name == "wasHit" and self.s.knockedDown then
            self.s.onFloor = true
            self.s.floorTime = 0
        end
    end
    function z:getOnlineID() return self.s.id end
    function z:getOwnerPlayer() return self.s.owner end
    function z:isRemoteZombie() return self.s.remote end
    strict(z, "IsoZombie")
    World.zombies[#World.zombies + 1] = z
    return z
end

-- Animals ------------------------------------------------------------------------------

function NewAnimal(animalType, x, y, opts)
    opts = opts or {}
    nextId = nextId + 1
    local a = { s = {
        type = animalType, x = x, y = y, z = 0, id = nextId, dead = false,
        vars = {}, moving = false, target = nil, fleeTo = nil,
        fightBehavior = false, blockMovement = false,
        babies = newList(), baby = opts.baby or false,
        breed = opts.breed, inSeason = opts.inSeason ~= false,
        genes = opts.genes or { aggressiveness = 0.4, strength = 0.5 },
        health = opts.health or 1.0, stress = opts.stress or 0,
        goAttackCalls = 0, fled = 0,
    } }
    local s = a.s

    local behavior = {}
    function behavior:goAttack(zombie)
        s.goAttackCalls = s.goAttackCalls + 1
        if s.blockMovement or s.fightBehavior then return end
        s.fightBehavior = true
        s.target = zombie
        s.fleeTo = nil
        -- The pathfinder finds no way through a fence.
        s.moving = not FenceBetween(a, zombie)
    end
    function behavior:resetBehaviorAction() s.fightBehavior = false end
    function behavior:setBlockMovement(b) s.blockMovement = b end
    function behavior:forceFleeFromChr(chr)
        s.fled = s.fled + 1
        local dx, dy = s.x - chr:getX(), s.y - chr:getY()
        local len = math.max(math.sqrt(dx * dx + dy * dy), 0.01)
        s.fleeTo = { x = s.x + dx / len * 10, y = s.y + dy / len * 10 }
        s.target = nil
        s.moving = true
    end
    strict(behavior, "BaseAnimalBehavior")

    function a:getAnimalType() return s.type end
    function a:getX() return s.x end
    function a:getY() return s.y end
    function a:getZ() return s.z end
    function a:isDead() return s.dead end
    function a:getCurrentSquare() return squareOf(self) end
    function a:getVehicle() return nil end
    function a:isOnHook() return false end
    function a:isHeld() return false end
    function a:getBabies() return s.babies end
    function a:isBaby() return s.baby end
    function a:getBreed()
        if not s.breed then return nil end
        return strict({ getName = function() return s.breed end }, "AnimalBreed")
    end
    function a:getUsedGene(name)
        local value = s.genes[name]
        if value == nil then return nil end
        return strict({ getCurrentValue = function() return value end }, "AnimalAllele")
    end
    function a:isInMatingSeason() return s.inSeason end
    function a:getHealth() return s.health end
    function a:getStress() return s.stress end
    function a:changeStress(inc)
        -- IsoAnimal.changeStress: a rise is scaled by 1 + the stress gene.
        if inc > 0 and s.genes.stress then inc = inc * (1 + s.genes.stress) end
        s.stress = math.min(100, math.max(0, s.stress + inc))
    end
    function a:playBreedSound(id)
        World.soundLog[#World.soundLog + 1] = { time = World.time, animal = a, id = id }
        return 1
    end
    function a:isAnimalMoving() return s.moving end
    function a:getBehavior() return behavior end
    function a:stopAllMovementNow()
        s.moving = false
        s.target = nil
        s.fleeTo = nil
        s.fightBehavior = false -- AnimalPathFindState.exit() -> doBehaviorAction()
    end
    function a:faceThisObject(obj) s.facing = obj end
    function a:setVariable(key, value)
        s.vars[key] = value
        World.varLog[#World.varLog + 1] = { time = World.time, animal = a, key = key, value = value }
    end
    function a:getVariableString(key)
        local v = s.vars[key]
        if v == nil then return "" end
        return tostring(v)
    end
    function a:clearVariable(key) s.vars[key] = nil end
    function a:getOnlineID() return s.id end
    strict(a, "IsoAnimal")
    World.animals[#World.animals + 1] = a
    return a
end

function AddBaby(mother, baby)
    mother.s.babies:add(baby)
end

-- Globals ------------------------------------------------------------------------------

-- LuaManager's copyTable: a deep copy. The vanilla animal definitions use it.
function copyTable(t)
    local copy = {}
    for k, v in pairs(t) do
        copy[k] = type(v) == "table" and copyTable(v) or v
    end
    return copy
end

function isClient() return MODE == "client" end
function isServer() return MODE == "server" end

local cell = {}
function cell:getAnimals()
    local list = newList()
    for _, a in ipairs(World.animals) do list:add(a) end
    return list
end
function cell:getZombieList()
    local list = newList()
    for _, z in ipairs(World.zombies) do list:add(z) end
    return list
end
function cell:getGridSquare(x, y, z) return getSquare(x, y, z) end
strict(cell, "IsoCell")
function getCell() return cell end

local gameTime = strict({ getTimeDelta = function() return World.dt end }, "GameTime")
function getGameTime() return gameTime end
function getTimestampMs() return math.floor(World.time * 1000) end

function ZombRandFloat(min, max) return min + math.random() * (max - min) end

function sendServerCommand(a, b, c, d)
    if type(a) == "string" then
        World.sent[#World.sent + 1] = { player = nil, module = a, command = b, args = c }
    else
        World.sent[#World.sent + 1] = { player = a, module = b, command = c, args = d }
    end
end

function getAnimal(id)
    for _, a in ipairs(World.animals) do
        if a.s.id == id then return a end
    end
    return nil
end

local handlers = { OnTick = {}, OnServerCommand = {} }
Events = {}
for name, list in pairs(handlers) do
    Events[name] = { Add = function(fn) list[#list + 1] = fn end }
end

function FireServerCommand(module, command, args)
    for _, fn in ipairs(handlers.OnServerCommand) do fn(module, command, args) end
end

-- Filled from the mod's own sandbox-options.txt by run_tests.py, so tests play by the
-- real defaults.
SandboxVars = { AnimalsAttackZombies = {} }

-- Simulation ---------------------------------------------------------------------------

local function stepAnimal(a, dt)
    local s = a.s
    if not s.moving or s.blockMovement then return end
    local tx, ty, stopAt
    if s.fleeTo then
        tx, ty, stopAt = s.fleeTo.x, s.fleeTo.y, 0.1
    elseif s.target then
        if FenceBetween(a, s.target) then
            s.moving = false
            s.fightBehavior = false
            return
        end
        tx, ty, stopAt = s.target:getX(), s.target:getY(), 0.9 -- collision keeps them apart
    else
        s.moving = false
        return
    end
    local speed = s.vars.animalRunning and 4 or 1.5
    local dx, dy = tx - s.x, ty - s.y
    local dist = math.sqrt(dx * dx + dy * dy)
    if dist <= stopAt then
        s.moving = false
        s.fightBehavior = false -- path done: doBehaviorAction()
        s.fleeTo = nil
        return
    end
    local step = math.min(speed * dt, dist - stopAt)
    s.x, s.y = s.x + dx / dist * step, s.y + dy / dist * step
end

local function stepZombie(z, dt)
    local s = z.s
    if s.health <= 0 then return end
    if s.onFloor then
        s.floorTime = s.floorTime + dt
        if s.floorTime > 3 then
            s.onFloor = false
            s.knockedDown = false
        end
        return
    end
    s.x, s.y = s.x + s.vx * dt, s.y + s.vy * dt
end

function Run(seconds)
    local ticks = math.floor(seconds / World.dt + 0.5)
    for _ = 1, ticks do
        World.time = World.time + World.dt
        for _, fn in ipairs(handlers.OnTick) do fn() end
        for _, a in ipairs(World.animals) do stepAnimal(a, World.dt) end
        for _, z in ipairs(World.zombies) do stepZombie(z, World.dt) end
    end
end
