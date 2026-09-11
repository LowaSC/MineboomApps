# MineboomApps

> [!CAUTION]
> **EARLY ALPHA.** This catalog is under active development. Applications may
> crash, lose settings or depend on peripherals, mods and computer IDs that are
> specific to the maintainer's Minecraft world. It is not currently ready for
> normal use on other servers. Test on disposable computers and keep backups.

MineboomApps is the user-application catalog for
[MineboomOS](https://github.com/LowaSC/MineboomOS). System applications remain
part of the OS; games and optional automation tools live here.

## Catalog source

MineboomOS alpha uses this HTTP source:

```text
https://raw.githubusercontent.com/LowaSC/MineboomApps/main
```

Configure it in **Settings → Connections → App catalog**. The Apps application
loads `apps/index.lua`, then downloads the selected file from `apps/`.

## Current compatibility

The games are the most portable applications. Factory, RS Store and Hub still
expect services and IDs from the maintainer's legacy world and are included for
development/migration work. RTC and Transformer depend on their respective
modded peripherals or gameplay setup.

| Application | Status | Controls | Required mods | Description |
|---|---|---|---|---|
| Factory | Works only in the developer's world | Mouse | None | Legacy factory control mirror |
| RS Store | On hold | Mouse | RS Bridge peripheral (Refined Storage + Advanced Peripherals) | Legacy RS storage dashboard |
| RTC — RS to chest | On hold | Mouse | RS Bridge peripheral (Refined Storage + Advanced Peripherals) | Pulls Material Checklist items from RS into a chest or buffer |
| Hub | On hold | Mouse | None | Legacy server hub monitor |
| Transformer | Works, not fully tested | Mouse, keyboard | PowerGrid | Winding calculator (turns ratio for target voltage) |
| Minesweeper | Fully working | Mouse | None | Classic mines game with touch open/flag mode |
| Snake | Fully working | Mouse or keyboard | None | Classic snake game with saved best scores |
| 2048 | Fully working | Mouse or keyboard | None | Classic 2048 sliding tile puzzle with saved best score |
| Tetris | Works, not fully tested | Mouse or keyboard | None | Falling blocks with next preview, ghost drop and saved best scores |
| Sky Raid | Works, not fully tested | Mouse, touch or keyboard | None | Vertical bullet-hell shooter with enemy waves, grazing, power-ups and bosses |

### Sky Raid

Fly through a scrolling starfield, destroy enemy waves and fight a three-phase
boss every fifth wave. Only the plane's central hull cell is vulnerable, so its
wings can overlap bullets safely. Grazing bullets awards bonus points; defeated
enemies may drop shot-power upgrades or bombs, and each difficulty keeps its own
best score.

Use the arrow keys or **WASD** to move, **Space**, **X** or **B** to use a bomb,
**Enter** or **P** to pause, **R** or **N** to restart, and **Tab** to select the
difficulty for the next game. On a monitor, tap the playfield to move and use
the on-screen controls. The minimum supported window size is 20 by 12 cells.

## Development

Every app is a Lua module implementing MineboomOS `init`, `draw` and `onEvent`.
After changing an app, bump its version in `apps/index.lua`. Run `luac -p` on
every changed Lua file before committing. Sky Raid's gameplay regression suite
can be run from the repository root with `lua tests/skyraid_test.lua`.

The catalog format and richer requirement metadata are still evolving during
alpha. Do not rely on it as a stable third-party API yet.
