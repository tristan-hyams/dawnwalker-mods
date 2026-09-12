# BetterEnemyUI — custom build snapshot

A frozen copy of the reworked mod, taken 2026-09-07. UE4SS only auto-runs
`Scripts/main.lua`, so nothing in this folder executes — it is inert storage.

## Contents

| file | notes |
|---|---|
| `main.lua` | config resolution, bar discovery/registry, tick loop |
| `bar.lua` | the `Bar` class and everything that reads or decorates one combat bar |
| `utils.lua` | generic UE4SS/UMG plumbing, no game knowledge |
| `config.lua` | user-facing options |
| `tests/` | 46 tests plus a benchmark, self-contained against these copies |
| `original-main.lua` | **Caites' pre-rework version — the rollback point** |
| `WIDGET_STRUCTURE.txt` | in-game dump of `WBP_CombatCharacterBar_C` |

`original-main.lua` is the one file worth keeping above all others: it is the only
copy of the code that shipped, and restoring it is the fastest way back to a known
state if the rework misbehaves. It is a single file with no `require` of `utils`
or `bar`, so dropping it in as `Scripts/main.lua` is a complete rollback.

## What changed from the original

Four defects fixed: stale target on pooled/re-pointed bars; discovery relying
solely on a notify hook that could fail silently; one throwing bar stranding every
other bar; and widget accumulation on repeated failed builds.

Then added: collapse-on-hidden gating (bar hidden, target unbound, or character
flagged invisible), teardown of injected widgets when a bar is abandoned, and a
throttled max-health read with a precomputed denominator.

## Restoring

Copy files up one level, replacing what is there:

    copy custom\main.lua  ..\  (etc.)

For a full rollback to the shipped version instead:

    copy custom\original-main.lua ..\main.lua

then delete `..\bar.lua` and `..\utils.lua` — the original does not use them.
Leaving them in place is harmless, just dead files.

## Running the tests

Lua 5.4 is installed but not on PATH:

    C:\Users\cat\AppData\Local\Programs\Lua\bin\lua.exe custom\tests\test_main.lua
    C:\Users\cat\AppData\Local\Programs\Lua\bin\lua.exe custom\tests\bench.lua

The suite mocks the UE4SS globals and drives the tick loop synchronously, so it
needs no game. `MOD_MAIN=<path>` points it at a different `main.lua` — running it
against `original-main.lua` scores 24/46, which is how the tests were confirmed to
actually discriminate rather than passing vacuously.

Caveat: this folder sits inside a Vortex-managed mod directory. A Vortex redeploy
may not preserve it. Treat the real home for this as a source repo.
