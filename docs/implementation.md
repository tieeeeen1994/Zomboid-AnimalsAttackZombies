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
- `AnimalPacket` (`NetworkPlayerAI.set`/`parse`) carries position, facing, `idleAction` (the client sets it, or clears it when absent, on every packet), the on-floor, dead, running and attacking flags, stress and health. `AnimalSynchronizationManager` sends it every 800 ms on screen, 1000 ms off it, at once when the animal changes square on screen, or after `IsoAnimal.sendExtraUpdateToClients()` (public; throws outside a server, `GameServer.udpEngine` is null). A remote animal takes the packet's facing only while it stands still.
- A zombie is simulated by one client, the nearest player's (`NetworkZombieManager.moveZombie`). `getOwnerPlayer()` names that player on the server. On that client `isRemoteZombie()` is false (`NetworkZombieSimulator.becomeLocal()` sets the owner connection). The owner's updates overwrite whatever the server does to the zombie.
- `ZombiePacket` carries health (the server applies the owner's, `NetworkZombiePacker.applyZombie`; other clients ignore it for a zombie they already have) but no stagger, knockdown or hit reaction. Vanilla shows a weapon hit to everyone by relaying the hit packet, whose `fields/hit/Character.process` and `Zombie.process` set those flags on every client. When the owner's health reaches 0, the server's `parseZombie` calls `die()`, which broadcasts `ZombieDeath`; `DeadZombiePacket.postpone` sets each other client's health to 0, so the zombie falls there too.
- Dragging a corpse (`IsoDeadBody.reanimateZombieForGrapple`) turns it into a live, on-floor `IsoZombie` with `isReanimatedForGrappleOnly()`. Vanilla animals skip it (`IsoAnimal.updateLOS`).
- The dedicated server runs `IngameState.update()`, so `OnTick` fires there.
- `AnimalPacket` carries the animal's position and facing (`Prediction.direction`) and its stress, so `faceThisObject()` and `changeStress()` on the server reach every client.
- Animal voices are played by each client's own `AnimalSoundState`. `IsoAnimal.playBreedSound(id)` on the server is never heard.

### Stress and health

- Animal health runs 0 to 1 (the info panel shows ×100). Stress runs 0 to 100.
- `IsoAnimal.changeStress(inc)` scales a rise by 1 + the `stress` gene. Vanilla adds 10–30 to a zone's animals when one is killed and 20–40 when an animal is hit, and a calm animal loses `multiplier / 5500` per update, about 0.5 a minute. Stress is saved with the animal.
- `changeStress()` scales a fall by the stress gene too, so a calm animal really loses about 0.1–0.3 a real minute. At 80 or more: `attackIfStressed` animals (bull, ram, rooster, tom) may attack a player whose acceptance is under 30 (`BaseAnimalBehavior.spotted()`); `animalShouldThump()` lets every `canThump` animal (the default; not chickens, turkeys or babies) thump fences and doors whenever it moves; `checkPregnancy()` loses the baby 1 time in 50; `tryLure()` fails. Above 40, milk and wool come 40/stress as fast; above 50 the animal picks its stressed call more often. `setDebugStress(v)` sets it outright.
- Vanilla starts a wander (`wanderIdle()`) or an eat/drink trip (`checkBehavior()`) whenever an animal is idle, not blocked and doing no behavior; `blockMovement` keeps both out, and `wanderIdle()` clears it after 8000 multiplier units (about 3 minutes) as a failsafe. `stopAllMovementNow()` also clears `idleAction` (`AnimalData.resetEatingCheck()`).
- Every roster species has a `stressed` breed sound (`AnimalVoiceBullStressed` and so on), used here as the warning call.

## How the mod works

Every gameplay number is a sandbox option, 71 in all, read through `AnimalsAttackZombies.opt(name, default)` so a save or server missing one falls back to the default. They are on three pages: *Animals Attack Zombies* (species on/off, range, damage, guarding distances, run distance, gene influence), *Behavior* (sizing up, warning, crowds, injury, chasing and giving up, strike pacing) and *Species* (each species' damage, knockdown chance, temper and warning length; the rut and bull breed ranges). Custom pages are listed separately in the sandbox screen, titled by `Sandbox_<page>` (`ServerSettingsScreen`). The numbers below are the defaults.

A few numbers stay fixed because they fit the engine or mirror vanilla rather than set the balance: the attack clip timings (from the animation files), the strike reach (1.25–1.75 tiles, so the swipe looks like it lands) and its 0.5 tile slack (vanilla's), the half-second scan and re-charge intervals, and the 4-second wait between flee attempts (vanilla's `timerFleeAgain`).

- **Definitions** (`shared/Definitions/animal/AnimalsAttackZombies_GeneralDefinitions.lua`): `fleeZombies = false` for the seven roster types, so they stand their ground. Java copies the Lua table lazily on the first `getAnimalDefs()`, and `Reset()` clears it. There is no guarantee this happens after the sandbox options load, so the flag is static.
- **Threat** (`server/AnimalsAttackZombies_Threat.lua`), twice a second:
  - Runners first. A roster animal runs from zombies instead of fighting when its species is off or it is a mother without young (zombie within 6 tiles), or when it is hurt below `RetreatHealth` percent (within 8 tiles). A runner breaks off any fight it is in.
  - Crowds. A fighter with `CrowdLimit` or more zombies within 8 tiles, plus one for every other fighter of its group within 8 tiles, breaks off and runs. 0 turns this off.
  - A roster animal whose species is on and that has something to guard fights. A male guards himself and his group's animals (`AnimalDefinitions.animals[type].group`) within 8 tiles. A mother guards her babies (`getBabies()`, `isBaby()`) within 15 tiles.
  - It targets the zombie nearest to it among those within range of anything it guards, on the same floor, with a clear straight line from the animal (`AAZ.isLineBlocked`: a voxel walk asking `isBlockedTo()` at every edge it crosses), skipping fake-dead zombies, corpses being dragged and zombies it gave up on.
  - Range = `EngageRange` × 0.5 outside the mating season for rams and toms (`isInMatingSeason()`) × breed factor (bulls: Holstein 1, Simmental 0.85, Angus 0.75) × (0.75 + 0.625 × aggressiveness gene).
  - Sizing up (`Hesitation`). With closeness = 1 − (the zombie's distance to the nearest spot guarded) / range, the animal commits for certain at closeness ≥ 0.85. Below that, it commits each scan with chance (0.04 + 0.56 × closeness²) × species temper × (0.5 + aggressiveness gene) × `Aggression`. Temper is 1.3 for sows and cows, 1.1 for roosters, 1 for bulls and boars, 0.9 for rams and 0.8 for toms. Until it commits, it faces the zombie when standing still. For a typical bull that is about 4% a scan at the edge of range, 16% halfway in, and 32% three-quarters in.
  - Every other roster animal runs from a zombie within 6 tiles with `forceFleeFromChr()`, at most every 4 s and only when not already moving, as vanilla does.
- **Attack** (`server/AnimalsAttackZombies_Attack.lua`), every tick, for each fight:
  - *Warn* (`WarningDisplay`; skipped when the zombie is already in reach): the animal stops, gets `blockMovement`, faces the zombie and gives its `stressed` call, for the species' warn time (bull 1.5–3 s, cow 1–2, ram 1–2, tom 1–2.5, boar 0.5–1.5, sow 0.5–1.2, rooster 0.3–0.8) × (1.3 − 0.6 × aggressiveness). A zombie that walks into reach is struck at once. One that gets further than 1.25 × range from the guarded spot ends the fight without the animal giving up on it.
  - *Charge*: `resetBehaviorAction()` + `goAttack()` whenever the animal has stopped, lifting `blockMovement` just before. It runs when more than 2 tiles away. A moving animal whose path no longer leads to the zombie (`getPathFindBehavior2()`: not the zombie as goal, path end more than 3 tiles from it) has been walked off by vanilla, and is stopped and charged again.
  - *Strike*: within reach (`attackDist`, clamped to 1.25–1.75 tiles) with a clear line, the animal stops, gets `blockMovement`, faces the zombie and sets `idleAction`. The hit lands at the connect time if the zombie is still within reach + 0.5.
  - *Recover*: a 0.3–1 s pause, still blocked, then back to charge.
  - Fighting adds no stress. With `fleeZombies` off, vanilla adds none for zombies either (its zombie stress is inside `spotted()`), and zombies never hit animals or kill herd mates, so a fighter's stress is the same after a fight as before it; every other vanilla source still applies.
  - Breaking off stops a charge in progress (`stopAllMovementNow()`); otherwise the animal would carry on down its path at the zombie.
  - It ends when the zombie dies, gets further than 1.5 × range + 3 from the guarded spot, or has changed floor. It gives up after 6 s without gaining ground (a fence) or 60 s of fighting, and then leaves that zombie alone for 20 s; an animal keeps every zombie it gave up on, not just the last. Any end lifts `blockMovement` and the strike, even for an animal that left the world (carried, trailered), which comes back as the same object.
- **Hit** (`AnimalsAttackZombies.applyHit` = damage + `applyHitReaction`): damage = roster damage × (0.5 + strength gene) × `DamageMultiplier`. Knockdown chance is the roster value, +0.25 on the first hit after a run of 3 or more tiles. A knockdown or a killing hit turns the zombie to face the animal and knocks it over FRONT. Any other hit staggers it from the side the animal is on. A zombie already on the ground only takes damage.
- **Multiplayer**: every decision is made on the server, which owns the animals. Facing, running and stress reach clients through the animal's own sync, pushed at once with `sendExtraUpdateToClients()` on the warning and every strike. The server broadcasts `Warn` and `Strike` so every client plays the call and starts the animation at once. It broadcasts `Hit` with the damage, the knockdown roll and whether the server's last known health makes it lethal: the client that owns the zombie applies the damage and reaction (its next update carries the health to the server), every other client only the reaction (a knockdown when lethal). A zombie nobody owns takes the damage on the server.
- **Animation** (`AnimSets/<animset>/idle/AnimalsAttackZombies_Strike.xml`): one non-looping node per animset, with `idleAction == "aazStrike"`, the vanilla attack clip, its breed-sound events, and `idleActionEnd` at the end.

## Tests

`python tests/run_tests.py` (needs `lupa`). Each test loads `tests/fake_pz.lua`, the real vanilla Cow, Pig, Sheep, Chicken and Turkey definitions from the game folder, and the mod's Lua in game order (shared, client, server). Then it runs a fight in a small simulated world: animals follow their paths, fences block paths and squares, and knocked-down zombies get up after 3 s. The fake is strict, so calling a method it doesn't define fails the test. Every method the mod calls was checked against the decompile.

The runner reads the defaults from `sandbox-options.txt`, so the tests play by the real ones. The 67 tests cover:

- the core fight, run with the behaviors below switched off (`Plain()`): definitions, strike timing, kills, range rules (herd mates, calves, rut, breed, gene), running, fences (never engaging across one, giving up when cut off, remembering every zombie given up on), dragged corpses, being driven off, damage scaling and the hit itself;
- the behaviors: sizing up (hesitation at the edge, always charging close in, the option off), the warning (length, a zombie walking into reach, backing off, the option off), crowds (a lone bull runs, three bulls hold, a fight broken off, the option off), injury (runs, breaks off mid-fight, the option off), no stress from fighting, staying blocked between strikes, a charge taken over by vanilla, a mother losing her young mid-fight and an animal carried off mid-fight;
- the options: species damage and knockdown, gene influence, the charge-chance curve, rut and breed ranges, herd, young, flee and crowd distances, swapped min/max bounds, chase distance and fight length;
- the multiplayer split for the warning, strike and hit (owner damage, reaction on every other client, the state push).

Deliberately broken versions of the timing, the rut, the young-only rule, the fence check, the multiplayer dispatch, the breed factor, the certain-charge zone, the allies count, the warning, its interruption and stand-down, the warning broadcast, the injury break-off, stopping the charge, the line-of-sight check, the given-up memory, the dragged-corpse skip, the state push, the block between strikes, the off-course recharge, disengaging every runner, unfreezing a carried animal and the hit broadcast each fail a test.

## Still to check in game

The offline tests cannot show these:

- The strike node plays: the idle state picks it, it runs once, and `idleActionEnd` clears it. Check on a dedicated server's clients too.
- The zombie falls when knocked down, for the player who owns it and for every other player, and a zombie killed by an animal dies on a multiplayer client as it does in single player.
- Animals do not wander off mid-fight, and a charge vanilla took over is resumed.
- A fighter's stress on the animal info panel is unchanged by a fight, including on multiplayer clients.
- The warning looks right: the animal stands facing the zombie and its call is heard, including on multiplayer clients.
- Performance with a large herd and a horde loaded. The scan walks every loaded animal and zombie twice a second.
