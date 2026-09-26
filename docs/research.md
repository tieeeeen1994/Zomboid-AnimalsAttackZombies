# Real-life behavior behind the roster

Farm animals are prey animals, and their first answer to a predator is to run. They turn and fight in three cases:

1. An intact male defending his ground and his females.
2. A mother defending her young.
3. An animal that is cornered.

The mod follows the first two. Animals on the roster do not hunt zombies across the map. They stand their ground when a zombie comes into their space, and everything else runs as in vanilla.

The game has no castration, so every bull, boar and ram counts as intact. In real life steers, barrows and wethers are far calmer.

## On the roster

| Game type | Animal | Why it fights | Trigger |
|---|---|---|---|
| `bull` | Bull | The most dangerous animal on a farm. Bulls defend their herd and ground, and charge rather than retreat. Dairy bulls (Holstein) are much more aggressive than beef bulls (Angus). | A zombie near him or his herd, all year |
| `boar` | Boar | Intact boars are aggressive all year and slash upward with their tusks. Vanilla already gives them `knockdownAttack` and `canDoLaceration`, but never lets them attack (no `attackBack` or `attackIfStressed`). | A zombie near him or his herd, all year |
| `ram` | Ram | Rams charge and head-butt, and are at their worst in the rut. The game's sheep mating season is September to February. | A zombie near him or his flock, stronger in the rut |
| `cockerel` | Rooster | The flock's guard. He keeps watch, sounds the alarm and fights hawks, foxes, dogs and people with his spurs. Vanilla already gives him `attackIfStressed` and `attackBack`. His damage is tiny (`baseDmg` 0.1). | A zombie near his hens |
| `gobblers` | Turkey tom | Territorial and known to attack people, most of all in the spring breeding season (April to May in the game). Tiny damage, like the rooster. | A zombie near him or his flock, stronger in spring |
| `sow` | Sow | Not a male. A sow with piglets is fiercely protective. Without a litter she is no more aggressive than any pig. | Only while she has piglets |
| `cow` | Cow | Not a male either, but she fits the same rule as the sow. Alongside bulls, cows with young calves cause most cattle attacks on people, often set off by a dog. A herd of cows will close in on a dog and trample it. | Only while she has a calf |

## Left off the roster

- **Ewe**: sheep bolt. A ewe may stamp at a dog near her lamb but rarely closes in.
- **Hen and turkey hen**: a broody hen defends her chicks, but the fight is a peck.
- **Buck (deer)**: real bucks are dangerous in the rut, but in the game deer are wild and always run first.
- **Rabbits, raccoons, rats, mice**: wild, and they run.
