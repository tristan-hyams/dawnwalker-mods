# reference

Not loaded by anything. Kept because both files are hard to reproduce.

- **`original-main.lua`** — Caites' unmodified single-file version, before the rework.
  This is the diff baseline and the rollback point: drop it in as `main.lua` and delete
  `bar.lua`/`utils.lua` to return to the shipped mod. It is also what the test suite
  runs against via `MOD_MAIN` to prove the tests actually discriminate.

- **`WIDGET_STRUCTURE.txt`** — a LiveDump of `WBP_CombatCharacterBar_C` taken on game
  v1.0.4. Diffing a fresh dump against this is the quickest way to check whether a
  patch moved anything the mod depends on.
