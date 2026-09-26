# Animals Attack Zombies

Livestock that would stand up to a predator in real life now stand up to zombies. Every other animal still runs, as in vanilla.

- **Bulls, boars and rams** charge zombies that come near them or their herd. Rams are at their worst in the breeding season.
- **Roosters and turkey toms** go after zombies that come near their flock. They are small, so they harass more than they hurt.
- **A sow with piglets or a cow with a calf** defends her young. Without them she runs like any other animal.

An animal charges, strikes with its own attack (a bull's head swipe, a boar's bite, a ram's head-butt, a rooster's spurs) and keeps at it until the zombie is dead, driven off or out of reach. Big animals knock zombies down, and a bull kills in about three hits.

Each species can be turned off in the sandbox options. There are also settings for how close a zombie has to come and for how hard animals hit. Install on both the server and clients.

Why these animals and not others: [docs/research.md](docs/research.md). Engine findings and how it works: [docs/implementation.md](docs/implementation.md).

## Status

The behavior is implemented and passes the offline tests (`python tests/run_tests.py`, needs `lupa`), but has not been played in game yet. [docs/implementation.md](docs/implementation.md) lists what to check first.

## Layout

```
AnimalsAttackZombies/
  workshop.txt
  preview.png                                            built by scripts/make_art.py
  scripts/make_art.py                                    preview, icon, poster, thumb from vanilla icons
  docs/research.md                                       real-life behavior -> roster
  docs/implementation.md                                 engine findings, design, what to test in game
  tests/                                                 offline tests: fake engine + fight scenarios
  Contents/mods/AnimalsAttackZombies/
    common/
    42/
      mod.info
      icon.png, poster.png, thumb.png                    built by scripts/make_art.py
      media/sandbox-options.txt                          one toggle per species, EngageRange, DamageMultiplier
      media/AnimSets/<animset>/idle/AnimalsAttackZombies_Strike.xml   strike animation (cow, pig, ram, cockerel, turkey)
      media/lua/shared/AnimalsAttackZombies.lua          roster, option reads, landing a hit on a zombie
      media/lua/shared/Definitions/animal/AnimalsAttackZombies_GeneralDefinitions.lua   roster animals stop fleeing on their own
      media/lua/shared/Translate/EN/Sandbox.json
      media/lua/server/AnimalsAttackZombies_Threat.lua   who fights, who runs
      media/lua/server/AnimalsAttackZombies_Attack.lua   charge, strike, hit, give up
      media/lua/client/AnimalsAttackZombies_Client.lua   multiplayer: play strikes, land hits on owned zombies
```
