# Implementation notes

Engine findings for Build 42 (Steam build 24909800), recorded so they do not have to be re-derived. Java names come from a Vineflower 1.11.1 decompile of `projectzomboid.jar`.

## Paths and decompiling (this Windows machine)

- Game: `C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid`
- Game Lua: `<game>\media\lua`. Animal definitions are in `media\lua\shared\Definitions\animal\*Definitions.lua`.
- Bundled Java 25: `<game>\jre64\bin\java.exe`
- The game folder also holds about 310 loose `.class` files from the `pzopt` patcher, including `IsoZombie`. Workshop players run vanilla, so read the classes from the jar, not the folder.

`unzip 'zombie/*'` silently extracts only 131 of the jar's 5,080 game classes, and a plain Python extract hits Windows' 260-character path limit in a long scratch folder. Extract with Python using a `\\?\` path prefix, then decompile the folder. A full decompile takes a few minutes and gives 3,078 files:

```python
import os, zipfile
z = zipfile.ZipFile(r"C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid\projectzomboid.jar")
base = "\\\\?\\" + os.path.abspath("classes")
for n in z.namelist():
    if n.startswith("zombie/") and n.endswith(".class"):
        p = os.path.join(base, *n.split("/"))
        os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, "wb").write(z.read(n))
```

```sh
JAVA="/c/Program Files (x86)/Steam/steamapps/common/ProjectZomboid/jre64/bin/java.exe"
curl -sSLo vineflower.jar https://repo1.maven.org/maven2/org/vineflower/vineflower/1.11.1/vineflower-1.11.1.jar
"$JAVA" -Xmx8g -jar vineflower.jar -dgs=1 -rsy=1 -log=WARN -thr=8 classes src
```

## What vanilla does

### Animals and zombies

- **Spotting**: `BaseAnimalBehavior.spotted()`. With `adef.fleeZombies` true (the Java default; no vanilla Lua changes it), a zombie within 10 tiles adds a negligible amount of stress, and one within 6 tiles makes the animal run 10 tiles away (`fleeFromChr()`). With it false, the whole block is skipped for zombies: no stress and no fleeing.
- **Attacking when stressed**: the `attackIfStressed` path in `spotted()` only fires at an `IsoPlayer`.
- **Being attacked**: `fleeFromAttacker()` fights back (`attackBack`) only against an `IsoPlayer`.
- **Being hit**: `IsoAnimal.hitConsequences()`, on a dedicated server only, sets `atkTarget` and calls `goAttack()` when the wielder is an `IsoPlayer` or an `IsoZombie` and `attackBack` is set.
- **Landing a hit**: `AnimalAttackState.animEvent("AttackConnect")` damages an `IsoAnimal` or `IsoPlayer` target. **An `IsoZombie` target falls through, so it takes no damage.**
- **Zombies never hurt animals.** `AttackState.triggerPlayerReaction()` drops an `IsoAnimal` target (`zombie.target = null`) at the moment it would hit. Fights are therefore one-sided.
- `IsoAnimal` extends `IsoPlayer`.

### Why the vanilla fight cannot be reused

- The attack animation state runs while `isAnimalAttacking` is true. That is a **read-only** callback variable bound to `isAnimalAttacking()`, which is `atkTarget != null` (or, on a client, a synced flag). `AnimationVariableSlotCallback.trySetValue()` refuses the write.
- `atkTarget`, `fightingOpponent` and `thumpTarget` are public fields with no setters. Lua can read them (`getClassFieldVal`) but not write them. `IsoMovingObject.setThumpTarget()` sets the base class's private field, which `IsoAnimal.thumpTarget` hides.
- `goAttack(chr)` accepts any character and paths to it, but `fightAnimal()` drops the fight when `fightingOpponent` is null. It still makes a good charge, though: it keeps the animal's other behaviors out of the way, and `doBehaviorAction()` resets it when the path ends or `stopAllMovementNow()` exits the pathfind state. It does nothing while `blockMovement` is set or a FIGHTANIMAL behavior is already running, so call `resetBehaviorAction()` first.

### Animation

- Animation nodes live in `media/AnimSets/<animset>/<state>/*.xml`. `AnimationSet` loads a state's nodes with `ZomboidFileSystem.resolveAllFiles()`, which merges every mod's files, so a mod can add a node to a vanilla state.
- Idle nodes are picked by the string variable `idleAction`. `AnimalIdleState.animEvent("idleActionEnd")` clears it, so a non-looping node plays once. `BaseAnimalBehavior.clearIdleAction()` wipes values that start with "idle", and `checkBehavior()` starts no new behavior while `idleAction` is set.
- Animsets: `cow` (cow, bull), `pig` (sow, boar), `ram`, `cockerel`, `turkey` (turkey hen, tom).
- Attack clips (length from the `.x` file's AnimTicksPerSecond and last key; connect from the vanilla attack node):

  | Animset | Clip | Length | AttackConnect | Hit lands at |
  |---|---|---|---|---|
  | cow | Cow_Attack_HeadSwipe | 1.93 s | 35% | 0.68 s |
  | pig | FarmPig_Attack_Bite | 1.63 s | 95% | 1.55 s |
  | ram | SheepRam_Attack_Headbutt | 1.50 s | 35% | 0.53 s |
  | cockerel | Chk_Cock_Attack_Claw | 1.83 s | 95% | 1.74 s |
  | turkey | Turk_Attack_Claw | 1.73 s | 95% | 1.64 s |

- `AnimationPlayer` advances by `GameTime.getTimeDelta()` each update, so summing that per tick keeps timers in step with animations at any game speed.

### Zombie hits

- Zombie health at normal toughness is 1.8 to 2.1 (`IsoZombie`, `lore.toughness`).
- `IsoZombie.Hit()` needs a `HandWeapon` and runs `CombatManager.processHit()`, so it is not usable without a weapon.
- `IsoZombie.knockDown()` sets knocked down, stagger back, an empty hit reaction, hit force 1 and `playerAttackPosition`, then reports `wasHit`. The knockdown transitions need `playerAttackPosition` to be "FRONT"; the from-behind ones test for "BACK", which nothing sets (`knockDown(true)` writes "BEHIND"). A plain stagger only needs `bStaggerBack`.
- `hitDir` is the target's position minus the attacker's, normalized (`calculateHitDirection()`). `playerAttackPosition` for a weapon hit is `testDotSide(attacker)`.
- A dead zombie in the stagger state goes to falldown (`bDead`). On the ground, `ZombieOnGroundState.execute()` calls `die()` on a dead zombie; on a client that reports the death to the server.

### Multiplayer

- Animal AI runs only on the server and in single player: `IsoAnimal.updateInternal()` skips `behavior.update()` on a client.
- Clients receive only on-floor, dead, running and attacking for an animal (`AnimalStateVariables`), not `idleAction`.
- A zombie is simulated by one client, the nearest player's (`NetworkZombieManager.moveZombie`). `getOwnerPlayer()` names that player on the server. On that client `isRemoteZombie()` is false (`NetworkZombieSimulator.becomeLocal()` sets the owner connection). The owner's updates overwrite whatever the server does to the zombie.
- The dedicated server runs `IngameState.update()`, so `OnTick` fires there.

## How the mod works

- **Definitions** (`shared/Definitions/animal/AnimalsAttackZombies_GeneralDefinitions.lua`): `fleeZombies = false` for the seven roster types, so they stand their ground. Java copies the Lua table lazily on the first `getAnimalDefs()`, and `Reset()` clears it. There is no guarantee this happens after the sandbox options load, so the flag is static.
- **Threat** (`server/AnimalsAttackZombies_Threat.lua`), twice a second:
  - A roster animal whose species is on and that has something to guard fights. A male guards himself and his group's animals (`AnimalDefinitions.animals[type].group`) within 8 tiles. A mother guards her babies (`getBabies()`, `isBaby()`) within 15 tiles.
  - It targets the zombie nearest to it among those within range of anything it guards, on the same floor, skipping fake-dead zombies.
  - Range = `EngageRange` × 0.5 outside the mating season for rams and toms (`isInMatingSeason()`) × breed factor (bulls: Holstein 1, Simmental 0.85, Angus 0.75) × (0.75 + 0.625 × aggressiveness gene).
  - Every other roster animal runs from a zombie within 6 tiles with `forceFleeFromChr()`, at most every 4 s and only when not already moving, as vanilla does.
- **Attack** (`server/AnimalsAttackZombies_Attack.lua`), every tick, for each fight:
  - *Charge*: `resetBehaviorAction()` + `goAttack()` whenever the animal has stopped. It runs when more than 2 tiles away.
  - *Strike*: within reach (`attackDist`, clamped to 1.25–1.75 tiles) with nothing in between (`isBlockedTo()` along the squares), the animal stops, gets `blockMovement`, faces the zombie and sets `idleAction`. The hit lands at the connect time if the zombie is still within reach + 0.5.
  - *Recover*: a 0.3–1 s pause, then back to charge.
  - It ends when the zombie dies, gets further than 1.5 × range + 3 from the guarded spot, or has changed floor. It gives up after 6 s without gaining ground (a fence) or 60 s of fighting, and then leaves that zombie alone for 20 s.
- **Hit** (`AnimalsAttackZombies.applyHit`): damage = roster damage × (0.5 + strength gene) × `DamageMultiplier`. Knockdown chance is the roster value, +0.25 on the first hit after a run of 3 or more tiles. A knockdown or a killing hit turns the zombie to face the animal and knocks it over FRONT. Any other hit staggers it from the side the animal is on. A zombie already on the ground only takes damage.
- **Multiplayer**: the server broadcasts `Strike` so every client plays the animation. It sends `Hit` to the zombie's owner, whose client applies it only if it still owns the zombie. A zombie nobody owns is hit on the server.
- **Animation** (`AnimSets/<animset>/idle/AnimalsAttackZombies_Strike.xml`): one non-looping node per animset, with `idleAction == "aazStrike"`, the vanilla attack clip, its breed-sound events, and `idleActionEnd` at the end.

## Tests

`python tests/run_tests.py` (needs `lupa`). Each test loads `tests/fake_pz.lua`, the real vanilla Cow, Pig, Sheep, Chicken and Turkey definitions from the game folder, and the mod's Lua in game order (shared, client, server). Then it runs a fight in a small simulated world: animals follow their paths, fences block paths and squares, and knocked-down zombies get up after 3 s. The fake is strict, so calling a method it doesn't define fails the test. Every method the mod calls was checked against the decompile.

The 28 tests cover the definitions, strike timing, kills, range rules (herd mates, calves, rut, breed, gene), running, fences and giving up, being driven off, damage scaling, the hit itself, and the multiplayer split. Deliberately broken versions of the timing, the rut, the young-only rule, the fence check, the multiplayer dispatch and the breed factor each fail a test.

## Still to check in game

The offline tests cannot show these:

- The strike node plays: the idle state picks it, it runs once, and `idleActionEnd` clears it. Check on a dedicated server's clients too.
- The zombie falls when knocked down, and a zombie killed by an animal dies on a multiplayer client as it does in single player.
- Animals do not wander off mid-fight. Vanilla can start an eating trip in the short pause between strikes; the charge then waits until that walk ends.
- Performance with a large herd and a horde loaded. The scan walks every loaded animal and zombie twice a second.
