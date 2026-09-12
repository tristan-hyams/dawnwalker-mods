# BetterEnemyUI

**Original mod by [Caites](https://www.nexusmods.com/profile/Caites) —
[BetterEnemyUI on Nexus Mods](https://www.nexusmods.com/thebloodofdawnwalker/mods/234).
This is a rework of it**, not a replacement: the structure, the defect fixes and the test
suite here are additions to their design. The injection strategy, the widget layout, the
config surface and the diamond badge are all Caites' work and are why the mod looks the
way it does.

## Thank you, Caites

This mod exists because Caites built it, and the decisions that mattered most were right
from the first version:

- **Injecting into the game's own combat bar** instead of drawing a separate overlay. The
  harder path, and the reason it inherits the game's art style, UI scaling, z-order and
  occlusion for free rather than looking bolted on.
- **Sentinel-named widgets** (`EI_HealthText`, `EI_LevelBox`) so re-running the injection
  finds and reuses what it already built. Quietly prevents a whole class of duplication.
- **Clamped config**, so a bad hand edit degrades instead of breaking the mod.
- **`pcall` discipline throughout**, because an unprotected Lua error on the game thread
  takes the entire game down with it.

Those are the choices that are hard to get right and invisible when they are. What
follows is four bug fixes and a test harness on top of a sound design — not a better
idea. Please go **[endorse the original](https://www.nexusmods.com/thebloodofdawnwalker/mods/234)**,
and consider their **[Patreon](https://www.patreon.com/caites)** if you get value from
their work.

## What it does

Adds to the enemy combat bar:

- a **numeric health readout** (`1541 / 1541`)
- a **level badge** with a difficulty-coloured rim
- an **amber blink** on both the number and the level badge when a target drops below
  a configurable share of its maximum health

It injects into the game's own `WBP_CombatCharacterBar_C` rather than drawing a separate
overlay, so it inherits the game's art style, UI scaling, z-order and occlusion.

## Install

Copy the four `.lua` files into `Mods/BetterEnemyUI/Scripts/` and create an empty
`enabled.txt` in `Mods/BetterEnemyUI/`:

```
Mods/BetterEnemyUI/
    enabled.txt
    Scripts/
        main.lua
        bar.lua
        utils.lua
        config.lua
```

Restart the game. In `UE4SS.log` you should see `[EnemyInfo] loaded`, then
`level badge built (diamond)` once you are in combat.

## Configuration

All of `config.lua`. Out-of-range values are clamped and non-numeric values fall back to
the default, so a bad edit degrades rather than breaking the mod.

| Option | Default | Notes |
|---|---|---|
| `ShowHealth` | `true` | The numeric readout |
| `ShowMaxHealth` | `true` | `50 / 200` vs just `50` |
| `ShowLevel` | `true` | The level badge |
| `Decimals` | `0` | 0–2 |
| `HealthFontSize` | `18` | 6–72 |
| `HealthAlign` | `2` | 1 left, 2 centre, 3 right |
| `HealthOffsetX` | `0` | Positive shifts right |
| `LevelPrefix` | `""` | e.g. `"Lv "` |
| `LevelFontSize` | `18` | 6–72 |
| `LevelAlign` | `1` | As above |
| `LevelOffsetX` | `12` | |
| `LevelStyle` | `"diamond"` | `diamond`, `plate`, or `none` |
| `LevelBoxSize` | `40` | Badge height, and width when diamond |
| `LevelPlateWidth` | `38` | Badge width when plate |
| `LevelRimThickness` | `3` | 0–8 |
| `LevelBgColor` | dark | Badge fill |
| `RefreshMs` | `150` | 100–1000. The single biggest performance lever |
| `LowHealthFlash` | `true` | |
| `LowHealthPercent` | `25` | Blink below this share of **that enemy's** max health |
| `LowHealthColor` | amber | Needs a large *luminance* gap from `TextColor` |
| `LowHealthPeriodMs` | `800` | Full blink cycle |
| `ColorByDifficulty` | `true` | |
| `ColorTarget` | `"rim"` | `rim`, `text`, or `both` |
| `ColorEqual` … `ColorCritical` | | Difficulty colours, thresholds at Δ4/6/9 |
| `TextColor` | white | Base colour for both readouts |

### On the low-health blink

The intent is a **peripheral cue to finish something off**, not a danger warning — a
nearly-empty segmented bar looks identical at 1 HP and at 0, so you end up staring at it
to work out why an enemy is still standing.

Three choices follow from that:

- **Amber, not red.** Red pulsing is the universal "you are in danger" signal, and for
  an enemy that is semantically backwards.
- **A hard blink, not a fade.** At `RefreshMs = 150` the tick rate is ~6.7 Hz. A fade
  would visibly step; a square blink looks deliberate. Peripheral vision also detects
  luminance transients far better than hue, which is why `LowHealthColor` wants a big
  brightness gap rather than just a different colour.
- **Phase from a shared clock.** Every low bar blinks in step. Independent per-bar
  timers read as static when three enemies are low at once.

The window has to be wider than a single hit. At 10% on a 1541 HP wolf the cue first
fired at 2 HP: one swing had crossed the entire 154 HP window in a single tick. 25%
gives a 385 HP window, which a hit lands inside rather than skipping.

The threshold is a percentage of each enemy's own maximum and is recomputed as that
maximum changes, so it behaves the same on a 200 HP wolf and a 2000 HP boss — including
a multi-phase fight that buffs the pool mid-encounter.

## What changed from the original

Four defects, found while testing and each covered by a regression test:

**Stale target on pooled bars.** The combat bar is pooled — it gets hidden and re-shown
pointed at a different enemy, and the previous character stays alive and valid. The
target was cached and only refreshed once it became *invalid*, so a recycled bar kept
displaying the previous enemy's health indefinitely. Most visible when juggling three or
four enemies, invisible in a duel.

**Discovery had no working fallback.** A `lastSweep` variable was initialised and never
read, so discovery rested entirely on `NotifyOnNewObject`. That registration was inside
a `pcall` whose result was discarded, so a failure was never retried and never logged —
the mod would silently show nothing for the session. There is now a periodic sweep, and
registration only latches on success.

**One throwing bar stranded all the others.** A single `pcall` wrapped the entire sweep,
so a bar that threw aborted the loop at the same index every tick and every bar after it
stopped updating. Protection is now per bar.

**Widget accumulation on failed builds.** Construction happened before attachment, so a
failed attach orphaned the widget and the next tick built another — and a half-built
badge was found again and a second one slotted beside it, every tick. Unattached widgets
are now parked and reused, and an incomplete badge is detached before rebuild.

Also added: the readout collapses when the bar is hidden or unbound instead of leaving
stale numbers; injected widgets are detached if a bar is abandoned; `TextColor` now
applies to the health readout (it previously never did); max health is read on an
interval rather than every tick, with the formatted denominator precomputed; and
`LevelStyle`/`ColorTarget` are validated rather than silently selecting a wrong branch.

## Tests

```bash
lua tests/run.lua                                  # 56 tests
MOD_MAIN=reference/original-main.lua lua tests/run.lua  # the pre-rework version: 29/56
ECHO_MOD_LOG=1 lua tests/run.lua                   # also print the mod's log lines
lua tests/bench.lua                                # tick-cost benchmark
```

No game required. `mock_ue4ss.lua` fakes the UE4SS globals; `main.lua` hands its tick
body to `LoopAsync`, so the mock captures it and drives ticks synchronously.

`MOD_MAIN` matters more than the pass count: running the suite against
`reference/original-main.lua` scores **29/56**, which is how the tests were confirmed to
discriminate rather than pass vacuously. A test that passes against both versions is not
testing the fix.

**What the tests cannot tell you:** the mock encodes the same assumptions as the code. If
a patch renames `Target Character`, all 56 still pass while the mod does nothing. See
*Game dependencies* below for what to check after an update.

## Architecture

| File | Responsibility |
|---|---|
| `main.lua` | Config resolution, bar discovery and registry, the tick loop |
| `bar.lua` | The `Bar` class — everything that reads or decorates one combat bar |
| `utils.lua` | Generic UE4SS/UMG plumbing, no game knowledge |

`bar.lua` returns a factory (`require("bar")({ config, log, once })`) so config and the
logger are injected rather than reached for, and `now` is passed into `refresh` instead
of read from shared state — which keeps the time dependency explicit and testable.

Two things worth knowing before editing:

**`pcall` does not make UE4SS calls safe.** It catches Lua errors. An access violation
inside UE4SS's C++ reflection or property marshalling is a hardware exception and takes
the game down regardless. Reading *named* properties of known shape is fine; enumerating
and reading arbitrary ones is not.

**A thrown Lua error is expensive.** Raising and catching one per bar per tick measured
at roughly 2× the cost of everything else in the loop combined. Anything that might
throw on a missing property or function resolves its capability once and remembers the
answer rather than retrying.

## Performance

`tests/bench.lua`, 12 bars × 20 000 ticks, three runs averaged. Lua-side cost only — the
mock reads plain tables where the game does real UObject property reads, so treat these
as the overhead the mod adds *on top* of those, not as frame cost.

| | idle | sustained damage | sub-integer churn |
|---|---|---|---|
| original | 327 ms | 425 ms | 347 ms |
| current | 292 ms | 441 ms | 372 ms |
| | **−11%** | **+4%** | **+7%** |

Idle is the common case and it is faster: hot-path reads use shared non-capturing
accessors instead of allocating a closure per read, and the readout compares raw numbers
before formatting. The damage-heavy cases are slightly *slower* than the original — that
is the low-health threshold check running every tick, and `LowHealthFlash = false`
removes it.

## Game dependencies

What a patch could break, and where. `reference/WIDGET_STRUCTURE.txt` is a dump of
`WBP_CombatCharacterBar_C` from v1.0.4; diffing a fresh dump against it is the quickest
way to check an update.

- Class `WBP_CombatCharacterBar_C`, asset path under `/Game/_Dawnwalker/UI/_Unified/Combat/`
- Properties `SegmentedHealthBar`, `Target Character` (note the space), `LevelIndicator`
- The host panel, resolved by walking **two parents up** from `SegmentedHealthBar` — the
  most fragile assumption here, since it depends on a `SizeBox` sitting in between
- `CharacterAttributeSet` on the pawn, with `Health` / `MaxHealth` and `.CurrentValue`
- Blueprint calls `Get Enemy Level` and `Get Level Difference` on the level indicator

Most breakage announces itself in `UE4SS.log`: `not found`, `could not construct`,
`could not slot`, `NotifyOnNewObject failed`, `refresh error`, `giving up on`.

## Known limitations

- **`HealthFontSize` / `LevelFontSize` may do nothing.** They are applied by writing
  through a nested struct property, which may not propagate. Unconfirmed either way.
- **Polling, not events.** The widget exposes `Attach To Pawn`, `Update Target Character`
  and `On Attribute Changed`, all of which look hookable. Every defect above traces back
  to polling state the game already pushes through events, so hooking `Attach To Pawn`
  would make target changes exact and remove the per-tick identity check.
  `Bar:invalidateTarget()` exists as the seam for it.
- **`host()` counts two parent hops** rather than walking up to the nearest `Overlay`.
  Correct on v1.0.4, fragile across layout changes.
- **Difficulty thresholds** are Δ4/6/9, so a 1–3 level gap reads as "equal" and all
  negative deltas collapse to the same colour. Left as-is: that is a design decision
  rather than a defect.
- **`lastErr` dedupes globally**, so two bars failing identically log once between them.

## Credits

**[Caites](https://www.nexusmods.com/profile/Caites)** wrote the original mod. Everything
this one does visually is their design.

- Original mod: **[BetterEnemyUI](https://www.nexusmods.com/thebloodofdawnwalker/mods/234)** on Nexus Mods
- Nexus profile: <https://www.nexusmods.com/profile/Caites>
- Patreon: <https://www.patreon.com/caites>

Rework, test suite and tooling by Tristan Hyams.

## Licence

The repository is MIT, but this mod is derived from Caites' work, which carries no stated
licence. Their terms take precedence over the repository's, and the licensing of this
derivative is subject to their agreement.
