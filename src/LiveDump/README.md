# LiveDump

Press a key in-game, get a readable structure dump of whatever UE classes you name in
`config.lua`. Built while reverse-engineering the combat UI for
[BetterEnemyUI](../BetterEnemyUI), then generalised — it has no knowledge of any
particular game or class.

Answers the questions you actually have when modding blind:

- What functions does this Blueprint expose, and is any of them hookable?
- What properties does it have, and how exactly are they spelled?
- What does its widget tree look like, and what's in there but hidden?
- How many live instances exist, and which are visible?

## Install

```
Mods/LiveDump/
    enabled.txt
    Scripts/
        main.lua
        dump.lua
        config.lua
```

Restart, press **F8** in-game. Reports land next to `UE4SS.log` as
`LiveDump_<time>.txt`, timestamped so repeated presses never overwrite each other.

## Configuration

```lua
Targets = { "WBP_CombatCharacterBar_C" }   -- any class FindAllOf can resolve
Scalars = { "Health Segment Count" }       -- named properties to read values for
Follow  = { }                              -- named object properties to follow (risky)
Key     = "F8"
```

| Option | Default | Notes |
|---|---|---|
| `Key` | `"F8"` | Any name from `Mods/Keybinds/Scripts/main.lua` |
| `Targets` | — | Class names. Every live instance is found; the first is introspected |
| `DumpStructure` | `true` | Function and property *names*, plus the parent chain |
| `DumpWidgetTree` | `true` | Live widget tree, marking hidden widgets and their text |
| `Scalars` | `{}` | Named properties to read live values for |
| `Follow` | `{}` | Named object properties to follow. **Opt-in and risky — see below** |
| `StepLog` | `true` | Log each step before attempting it. Leave on |
| `MaxFunctions` / `MaxProperties` / `MaxTreeDepth` | 150 / 200 / 12 | Output bounds |
| `OutputDir` | `"ue4ss\\"` | Relative to the game's working directory |

To point it at something else, change `Targets`. That's the whole workflow.

## Safety — read this before setting `Follow`

**`pcall` does not make UE4SS calls safe.** It catches Lua errors. An access violation
inside UE4SS's C++ reflection or property marshalling is a *hardware exception*: it
bypasses `pcall` entirely and takes the game down with it.

An earlier, hardcoded version of this tool ignored that and **crashed the game three
times**, each time on an assurance that the surface was safe. The portable call stack
was consistently:

```
ucrtbase  +...        ← faulting frame, reading address 0x0
UE4SS     +...        ← string conversion
UE4SS     +...        ← property / reflection layer
UE4SS     +...        ← Lua binding layer
```

A C runtime function reading null, with no game frames anywhere near the top — the
signature of an FName-to-string conversion on a name that resolves to a null pointer.
Never inside engine code, always inside UE4SS marshalling.

The rules that came out of that, which this tool now enforces:

**Enumerating names is safe.** `ForEachFunction` and `ForEachProperty` read reflection
data. `DumpStructure` is on by default because it has never faulted.

**Reading a property value is only safe when named and plain-old-data.** `Scalars`
entries are checked against an allowlist — ints, floats, bools, bytes, enums, strings —
and anything else is reported as `(not read)`. Blind enumerate-and-read is what crashed
it the first two times.

**Introspecting an unfamiliar class is not safe.** That is what crashed it the third
time, after the value reads had already been fixed. So `Follow` is empty by default.
If you use it, **add one entry at a time**: the step log names the last operation
attempted, so one crash identifies the culprit rather than leaving you guessing.

**The class-chain walk stops at the first unresolvable name** rather than trusting the
hierarchy to terminate. Past the root of an unfamiliar chain, `GetSuperStruct` can
return a non-null but garbage `UStruct` that passes an `IsValid` check, and stringifying
its name faults.

## Diagnosing a crash

`UE4SS.log` is flushed, so it survives. The last `STEP:` line is the operation that
faulted:

```powershell
Select-String -Path "<game>\Binaries\Win64\ue4ss\UE4SS.log" -Pattern "LiveDump" |
    ForEach-Object { $_.Line }
```

`LiveDump_partial.txt` is rewritten after every followed object, so it shows how far the
dump got even if the log is unavailable. Crash reports land in
`%LOCALAPPDATA%\<Game>\Saved\Crashes\` — `CrashContext.runtime-xml` holds a
`<PCallStack>` with module names and offsets, which is enough to tell a UE4SS fault from
a game fault even without symbols.

## Comparing dumps

The output format is stable and line-oriented, so `diff` works. Keeping a dump from a
known-good game version makes checking a patch trivial — a structural diff tells you
immediately whether anything a mod depends on was renamed or moved. This is how
BetterEnemyUI was verified against game v1.0.4 in one pass.

## No tests

Deliberate. A mock of the UE4SS reflection API would be validating the mock, not the
tool — and the failure mode that actually matters here is crashing a real game process,
which no mock reproduces. The safety rules above are the substitute, and they came from
real crashes rather than from reasoning.
