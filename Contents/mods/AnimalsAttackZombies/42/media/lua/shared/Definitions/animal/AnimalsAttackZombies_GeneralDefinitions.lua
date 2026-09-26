-- The roster animals (AnimalsAttackZombies.roster) stop running from zombies on their own,
-- so they can stand their ground: with fleeZombies off, BaseAnimalBehavior.spotted() ignores
-- zombies altogether. Java reads these tables once, lazily, before the sandbox options are
-- guaranteed to exist, so this cannot follow the per-species options. Instead
-- server/AnimalsAttackZombies_Threat.lua makes every roster animal that is not fighting
-- (species turned off, or a mother without young) run from zombies the way vanilla does.
AnimalDefinitions.animals["bull"].fleeZombies = false;
AnimalDefinitions.animals["boar"].fleeZombies = false;
AnimalDefinitions.animals["ram"].fleeZombies = false;
AnimalDefinitions.animals["cockerel"].fleeZombies = false;
AnimalDefinitions.animals["gobblers"].fleeZombies = false;
AnimalDefinitions.animals["sow"].fleeZombies = false;
AnimalDefinitions.animals["cow"].fleeZombies = false;
