# dawnwalker-mods

UE4SS Lua mods for [The Blood of Dawnwalker](https://store.steampowered.com/), aimed at
the quality-of-life gaps rather than at changing how the game plays.

Tested against **game v1.0.4** (UE 5.5.4, `dw1-pc-258042-shipping-patch2`) with
**UE4SS v3.0.1 Beta**.

## Mods

| Mod | What it does | Status |
|---|---|---|
| [BetterEnemyUI](src/BetterEnemyUI) | Adds a numeric health readout and a level badge to the enemy combat bar, and blinks both when a target is nearly dead. | Working. Originally by **Caites**; reworked here. |
| [LiveDump](src/LiveDump) | Development tool. Press a key in-game to dump the structure of any UE class named in config — functions, properties, widget tree, live instances. | Working. |

## Installing

`LiveDump` is a development tool rather than something you would play with — it is how
the others were reverse-engineered.

Each mod is a folder under `Mods/` in your UE4SS install:

```
<game>/Dawnwalker/Binaries/Win64/ue4ss/Mods/<ModName>/
    enabled.txt          empty marker file; UE4SS loads the mod when present
    Scripts/
        main.lua         plus whatever else the mod ships
```

Copy a mod's `src/<ModName>/*.lua` into `Mods/<ModName>/Scripts/`, create an empty
`enabled.txt` in `Mods/<ModName>/`, and restart the game. The marker-file mechanism is
used in preference to `mods.txt`/`mods.json` because it survives Vortex deployment.

Mods load at startup. `EnableHotReloadSystem = 1` in `UE4SS-settings.ini` lets you
re-run a script without relaunching, which is worth turning on if you intend to change
anything.

## Development

Everything here is plain Lua 5.4 against the UE4SS Lua API. Where a mod ships tests,
they run **without the game**: the UE4SS globals are mocked and the mod's tick loop is
driven synchronously, so logic is verifiable in under a second.

```bash
lua src/BetterEnemyUI/tests/run.lua
```

Lua is not bundled. Install it however you like — `winget install DEVCOM.Lua` puts
`lua.exe` in `%LOCALAPPDATA%\Programs\Lua\bin` and does not add it to `PATH`.

One limitation worth stating up front, because it shapes how much the tests are worth:
**a mock encodes the same assumptions as the code it tests.** If a game patch renames a
property, the suite still passes while the mod silently does nothing. The tests catch
logic errors; only the game catches wrong assumptions. Each mod's README says what it
depends on so a patch can be checked against it.

## Credits

Mods here that started from someone else's work say so in their own README, and the
original author is named at the top of the source. Nothing in this repo is a from-scratch
replacement for an existing mod.

## Licence

MIT, see [LICENSE](LICENSE) — with the caveat that a mod derived from someone else's
work is only as freely licensed as the original allows. Where a mod is a rework, the
original author's terms take precedence and the derivative's licence is subject to their
agreement.
