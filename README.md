# Animals Attack Zombies

Livestock that would stand up to a predator in real life now stand up to zombies. Every other animal still runs, as in vanilla.

- **Bulls, boars and rams** charge zombies that come near them or their herd. Rams are at their worst in the breeding season.
- **Roosters and turkey toms** go after zombies that come near their flock. They are small, so they harass more than they hurt.
- **A sow with piglets or a cow with a calf** defends her young. Without them she runs like any other animal.

They behave like the real thing. Every number behind this is a sandbox option, over three pages (general, behavior and per-species), so you can tune any of it:

- **Sizing up.** An animal doesn't always charge the moment a zombie is in range. It stands and watches, and the closer the zombie gets to it or what it guards, the likelier it is to charge. One that comes right up is always charged. Mothers with young commit fastest and turkey toms bluff the most, and aggressive or stressed animals are quicker to go.
- **Warning.** Before charging, it stops, squares up to the zombie and calls out. Bulls warn longest; boars and roosters barely pause.
- **Crowds.** Four zombies (by default) make a lone animal run. Every fighter of its kind standing with it adds one to that, so a group of bulls holds out longer.
- **Injury.** Animals below 40% health (by default) don't fight.
- **Stress.** Fighting stresses them on vanilla's scale, with vanilla's effects. A very stressed bull, ram, rooster or tom may turn on a player it doesn't trust.

An animal charges, strikes with its own attack (a bull's head swipe, a boar's bite, a ram's head-butt, a rooster's spurs) and keeps at it until the zombie is dead, driven off or out of reach. Big animals knock zombies down, and a bull kills in about three hits.

Each species can be turned off in the sandbox options. There are also settings for how close a zombie has to come and for how hard animals hit. Install on both the server and clients; it works in multiplayer.

Why these animals and not others: [docs/research.md](docs/research.md). Engine findings and how it works: [docs/implementation.md](docs/implementation.md).
