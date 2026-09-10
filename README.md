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

| Application | Alpha status |
|---|---|
| Minesweeper, Snake, 2048, Tetris | Portable candidate; needs broader testing |
| Transformer | Requires PowerGrid-compatible gameplay setup |
| RTC | Requires RS/material peripherals and configuration |
| Factory, RS Store, Hub | Legacy integration; not portable yet |

## Development

Every app is a Lua module implementing MineboomOS `init`, `draw` and `onEvent`.
After changing an app, bump its version in `apps/index.lua`. Run `luac -p` on
every changed Lua file before committing.

The catalog format and richer requirement metadata are still evolving during
alpha. Do not rely on it as a stable third-party API yet.

## Future work

- [Authenticate automation messages received over Rednet](docs/issues/authenticate-automation-rednet-messages.md)
