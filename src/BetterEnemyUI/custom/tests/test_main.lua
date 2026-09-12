-- Integration tests for main.lua against the fake UE4SS environment.
--   lua tests/test_main.lua
--   ECHO_MOD_LOG=1 lua tests/test_main.lua   (also prints the log lines from the mod)
-- the mock replaces the global print, so keep our own handle on the real one
local print = print


local here = (arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/?.lua;" .. package.path

local mock = require("mock_ue4ss")
mock.MAIN_PATH = os.getenv("MOD_MAIN") or (here .. "/../main.lua")

---------------------------------------------------------------- tiny test harness

local passed, failed = 0, {}

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("  ok   " .. name)
    else
        failed[#failed + 1] = { name = name, err = tostring(err) }
        print("  FAIL " .. name)
        print("       " .. tostring(err))
    end
end

local function assertEq(got, want, what)
    if got ~= want then
        error(string.format("%s: got %s, want %s", what or "value",
            tostring(got), tostring(want)), 2)
    end
end

local function assertNear(got, want, what)
    if type(got) ~= "number" or math.abs(got - want) > 1e-4 then
        error(string.format("%s: got %s, want ~%s", what or "value",
            tostring(got), tostring(want)), 2)
    end
end

local function assertTrue(cond, what)
    if not cond then error(what or "expected true", 2) end
end

local function cfg(over)
    local c = {
        ShowHealth = true, ShowMaxHealth = true, ShowLevel = true,
        Decimals = 0, RefreshMs = 100,
        LevelStyle = "diamond",
        ColorByDifficulty = true, ColorTarget = "rim",
    }
    for k, v in pairs(over or {}) do c[k] = v end
    return c
end

------------------------------------------------------------------------ baseline

test("injects a health readout showing current / max", function()
    local world = mock.newWorld()
    local bar = mock.newBar({
        name = "Bar1",
        character = mock.newCharacter("EnemyA", 42, 100),
        indicator = mock.newIndicator(5, 0),
    })
    world.bars = { bar }
    mock.loadMod(world, cfg())
    world.tick(2)

    assertEq(mock.textOf(bar._host, "EI_HealthText"), "42 / 100", "health text")
    assertEq(mock.textOf(bar._host, "EI_LevelText"), "5", "level text")
end)

test("follows health changes on the same character", function()
    local world = mock.newWorld()
    local ch = mock.newCharacter("EnemyA", 42, 100)
    local bar = mock.newBar({ name = "Bar1", character = ch, indicator = mock.newIndicator(5, 0) })
    world.bars = { bar }
    mock.loadMod(world, cfg())
    world.tick(2)

    ch.CharacterAttributeSet.Health.CurrentValue = 17
    world.tick(1)
    assertEq(mock.textOf(bar._host, "EI_HealthText"), "17 / 100", "health text after damage")
end)

test("reuses existing widgets instead of re-injecting each tick", function()
    local world = mock.newWorld()
    local bar = mock.newBar({
        name = "Bar1",
        character = mock.newCharacter("EnemyA", 42, 100),
        indicator = mock.newIndicator(5, 0),
    })
    world.bars = { bar }
    mock.loadMod(world, cfg())
    world.tick(20)

    assertEq(mock.countChildren(bar._host, "EI_HealthText"), 1, "health texts")
    assertEq(mock.countChildren(bar._host, "EI_LevelBox"), 1, "level boxes")
    assertEq(mock.countConstructed(world, "EI_HealthText"), 1, "health text constructions")
end)

------------------------------------------------- defect 1: pooled / re-pointed bar

test("defect 1: re-pointed pooled bar follows the new character", function()
    local world = mock.newWorld()
    local a = mock.newCharacter("EnemyA", 42, 100)
    local b = mock.newCharacter("EnemyB", 13, 50)
    local ind = mock.newIndicator(5, 0)
    local bar = mock.newBar({ name = "Bar1", character = a, indicator = ind })
    world.bars = { bar }
    mock.loadMod(world, cfg())
    world.tick(2)

    assertEq(mock.textOf(bar._host, "EI_HealthText"), "42 / 100", "initial health")
    assertEq(mock.textOf(bar._host, "EI_LevelText"), "5", "initial level")

    -- The pool hands this same widget to a different enemy. EnemyA is still alive,
    -- so a cache that only refreshes on invalidation keeps showing 42 / 100.
    bar["Target Character"] = b
    ind._level, ind._delta = 9, 7
    assertTrue(a:IsValid(), "EnemyA should still be valid")
    world.tick(2)

    assertEq(mock.textOf(bar._host, "EI_HealthText"), "13 / 50", "health after re-point")
    assertEq(mock.textOf(bar._host, "EI_LevelText"), "9", "level after re-point")

    local rim = mock.deepFind(bar._host, "EI_LevelRim")
    assertTrue(rim ~= nil, "rim should exist")
    assertNear(rim._SetBrushColor.R, 0.904661, "rim recoloured for the new delta")
end)

test("defect 1: level is re-read at once on re-point, not up to a second later", function()
    local world = mock.newWorld()
    local a = mock.newCharacter("EnemyA", 42, 100)
    local b = mock.newCharacter("EnemyB", 13, 50)
    local ind = mock.newIndicator(5, 0)
    local bar = mock.newBar({ name = "Bar1", character = a, indicator = ind })
    world.bars = { bar }
    mock.loadMod(world, cfg())
    world.tick(1)
    assertEq(mock.textOf(bar._host, "EI_LevelText"), "5", "initial level")

    bar["Target Character"] = b
    ind._level = 12
    world.tick(1) -- a single 100ms tick, well inside LEVEL_INTERVAL
    assertEq(mock.textOf(bar._host, "EI_LevelText"), "12", "level on the very next tick")
end)

test("defect 1: does not thrash when the target has not changed", function()
    local world = mock.newWorld()
    local bar = mock.newBar({
        name = "Bar1",
        character = mock.newCharacter("EnemyA", 42, 100),
        indicator = mock.newIndicator(5, 0),
    })
    world.bars = { bar }
    mock.loadMod(world, cfg())
    world.tick(30)

    -- Nothing should be rebuilt just because identity is now re-checked every tick.
    assertEq(mock.countConstructed(world, "EI_HealthText"), 1, "health text constructions")
    assertEq(mock.countConstructed(world, "EI_LevelBox"), 1, "level box constructions")
end)

-------------------------------------------------------- defect 2: discovery of bars

test("defect 2: bars spawned after load are found when the notify hook failed", function()
    local world = mock.newWorld()
    world.notifyShouldFail = true
    mock.loadMod(world, cfg()) -- no bars exist yet
    world.tick(1)

    local bar = mock.newBar({
        name = "LateBar",
        character = mock.newCharacter("EnemyLate", 7, 20),
        indicator = mock.newIndicator(3, 1),
    })
    world.bars = { bar } -- appears in the world; the hook never fires

    world.tick(12) -- past SWEEP_IDLE_MS at 100ms per tick
    assertEq(mock.textOf(bar._host, "EI_HealthText"), "7 / 20", "late bar decorated by sweep")
    assertTrue(mock.logged(world, "NotifyOnNewObject failed"), "expected the fallback log line")
end)

test("defect 2: notify registration is retried until it succeeds", function()
    local world = mock.newWorld()
    world.notifyShouldFail = true
    mock.loadMod(world, cfg())
    world.tick(1)
    assertEq(world.notifyCb, nil, "hook should not be registered yet")

    world.notifyShouldFail = false
    world.tick(12) -- the next sweep retries registration
    assertTrue(world.notifyCb ~= nil, "hook should have been registered on retry")
end)

test("defect 2: a bar the hook missed is still picked up later", function()
    local world = mock.newWorld()
    mock.loadMod(world, cfg())
    world.tick(1)
    assertTrue(world.notifyCb ~= nil, "hook registered")

    local bar = mock.newBar({
        name = "MissedBar",
        character = mock.newCharacter("EnemyMissed", 30, 60),
        indicator = mock.newIndicator(2, 0),
    })
    world.bars = { bar } -- deliberately not routed through world.spawn()

    world.tick(12)
    assertEq(mock.textOf(bar._host, "EI_HealthText"), "30 / 60", "missed bar decorated by sweep")
end)

test("defect 2: the notify hook still works for bars it does see", function()
    local world = mock.newWorld()
    mock.loadMod(world, cfg())
    local bar = world.spawn(mock.newBar({
        name = "HookBar",
        character = mock.newCharacter("EnemyHook", 5, 5),
        indicator = mock.newIndicator(1, 0),
    }))
    world.tick(1) -- decorated without waiting for a sweep
    assertEq(mock.textOf(bar._host, "EI_HealthText"), "5 / 5", "hook-discovered bar")
end)

------------------------------------------------------- defect 3: per-entry failures

test("defect 3: one throwing bar does not stop the others", function()
    local world = mock.newWorld()
    local good1 = mock.newBar({
        name = "Good1",
        character = mock.newCharacter("E1", 10, 10),
        indicator = mock.newIndicator(1, 0),
    })
    local bad = mock.newBar({
        name = "Bad",
        character = mock.newCharacter("EBad", 1, 1),
        indicator = mock.newIndicator(1, 0),
        poisonHost = true, -- throws out of host(), which refresh() does not guard
    })
    local good2 = mock.newBar({
        name = "Good2",
        character = mock.newCharacter("E2", 20, 40),
        indicator = mock.newIndicator(2, 0),
    })
    -- `bad` sits between the two, and update() walks the list from the end, so a
    -- single pcall around the whole sweep leaves Good1 permanently unvisited.
    world.bars = { good1, bad, good2 }
    mock.loadMod(world, cfg())
    world.tick(3)

    assertEq(mock.textOf(good1._host, "EI_HealthText"), "10 / 10", "bar before the bad one")
    assertEq(mock.textOf(good2._host, "EI_HealthText"), "20 / 40", "bar after the bad one")
end)

test("defect 3: a persistently failing bar is dropped and the rest keep updating", function()
    local world = mock.newWorld()
    local good = mock.newBar({
        name = "Good",
        character = mock.newCharacter("E1", 10, 10),
        indicator = mock.newIndicator(1, 0),
    })
    local bad = mock.newBar({
        name = "Bad",
        character = mock.newCharacter("EBad", 1, 1),
        indicator = mock.newIndicator(1, 0),
        poisonHost = true, -- throws out of host(), which refresh() does not guard
    })
    world.bars = { good, bad }
    mock.loadMod(world, cfg())
    world.tick(15) -- past MAX_FAILS

    assertTrue(mock.logged(world, "giving up on"), "bad bar should be dropped")

    good["Target Character"].CharacterAttributeSet.Health.CurrentValue = 3
    world.tick(1)
    assertEq(mock.textOf(good._host, "EI_HealthText"), "3 / 10", "good bar still updating")
end)

test("defect 3: a stale target pointer is contained without throwing", function()
    local world = mock.newWorld()
    local good = mock.newBar({
        name = "Good",
        character = mock.newCharacter("E1", 10, 10),
        indicator = mock.newIndicator(1, 0),
    })
    local stale = mock.newBar({
        name = "Stale",
        character = mock.newPoison(), -- every property read on the target throws
        indicator = mock.newIndicator(1, 0),
    })
    world.bars = { good, stale }
    mock.loadMod(world, cfg())
    world.tick(15)

    -- The target probe is protected, so this bar simply renders nothing rather than
    -- erroring, and it is never counted as a failure or dropped.
    assertEq(mock.countChildren(stale._host, "EI_HealthText"), 0, "stale bar undecorated")
    assertTrue(not mock.logged(world, "giving up on"), "stale bar should not be dropped")
    assertEq(mock.textOf(good._host, "EI_HealthText"), "10 / 10", "healthy bar unaffected")
end)

test("a repeated failure is logged once, not every tick", function()
    local world = mock.newWorld()
    local bad = mock.newBar({
        name = "Bad",
        character = mock.newCharacter("EBad", 1, 1),
        indicator = mock.newIndicator(1, 0),
        poisonHost = true, -- throws out of host(), which refresh() does not guard
    })
    world.bars = { bad }
    mock.loadMod(world, cfg())
    world.tick(8)

    local n = 0
    for _, line in ipairs(world.logs) do
        if line:find("simulated stale property read", 1, true) then n = n + 1 end
    end
    assertEq(n, 1, "error log lines")
end)

------------------------------------------------------ defect 4: widget accumulation

test("defect 4: a failing attach does not construct a new widget every tick", function()
    local world = mock.newWorld()
    local bar = mock.newBar({
        name = "Bar1",
        character = mock.newCharacter("E1", 5, 10),
        indicator = mock.newIndicator(1, 0),
    })
    bar._host._failAdds = 5 -- host refuses the first five attach attempts
    world.bars = { bar }
    mock.loadMod(world, cfg({ ShowLevel = false }))
    world.tick(8)

    assertEq(mock.countConstructed(world, "EI_HealthText"), 1, "health text constructions")
    assertEq(mock.countChildren(bar._host, "EI_HealthText"), 1, "attached health texts")
    assertEq(mock.textOf(bar._host, "EI_HealthText"), "5 / 10", "text set once attached")
end)

test("defect 4: a half-built level badge is rebuilt in place, not stacked", function()
    local world = mock.newWorld()
    local bar = mock.newBar({
        name = "Bar1",
        character = mock.newCharacter("E1", 5, 10),
        indicator = mock.newIndicator(4, 2),
    })
    world.bars = { bar }
    -- The badge always fails halfway: the box gets slotted, its contents never do.
    world.failConstruct["EI_LevelStack"] = true
    mock.loadMod(world, cfg({ ShowHealth = false }))
    world.tick(10)

    assertEq(mock.countChildren(bar._host, "EI_LevelBox"), 1, "level boxes attached")
    assertEq(mock.countConstructed(world, "EI_LevelBox"), 1, "level box constructions")
end)

test("defect 4: a pre-existing half-built badge is adopted, not duplicated", function()
    local world = mock.newWorld()
    local bar = mock.newBar({
        name = "Bar1",
        character = mock.newCharacter("E1", 5, 10),
        indicator = mock.newIndicator(4, 2),
    })
    -- Leftover from an earlier partial build: right name, no contents.
    local orphan = mock.Widget.new("SizeBox", "EI_LevelBox")
    bar._host:AddChildToOverlay(orphan)
    world.bars = { bar }
    mock.loadMod(world, cfg({ ShowHealth = false }))
    world.tick(5)

    assertEq(mock.countChildren(bar._host, "EI_LevelBox"), 1, "level boxes attached")
    assertEq(mock.textOf(bar._host, "EI_LevelText"), "4", "badge finished building")
end)

test("defect 4: an unattachable host does not leak widgets", function()
    local world = mock.newWorld()
    local bar = mock.newBar({
        name = "Bar1",
        character = mock.newCharacter("E1", 5, 10),
        indicator = mock.newIndicator(1, 0),
    })
    bar._host._failAdds = math.huge -- never accepts children
    world.bars = { bar }
    mock.loadMod(world, cfg())
    world.tick(20)

    assertEq(mock.countConstructed(world, "EI_HealthText"), 1, "health text constructions")
    assertEq(mock.countConstructed(world, "EI_LevelBox"), 1, "level box constructions")
end)

------------------------------------------------------------------------- lifecycle

test("dead bars are dropped and their tracking key released", function()
    local world = mock.newWorld()
    local bar = mock.newBar({
        name = "Bar1",
        character = mock.newCharacter("E1", 5, 10),
        indicator = mock.newIndicator(1, 0),
    })
    world.bars = { bar }
    mock.loadMod(world, cfg())
    world.tick(2)

    bar._valid = false
    world.bars = {}
    world.tick(2) -- must not throw

    local replacement = mock.newBar({
        name = "Bar2",
        character = mock.newCharacter("E2", 8, 8),
        indicator = mock.newIndicator(1, 0),
    })
    world.bars = { replacement }
    world.tick(12)
    assertEq(mock.textOf(replacement._host, "EI_HealthText"), "8 / 8", "replacement decorated")
end)

test("class default objects are ignored", function()
    local world = mock.newWorld()
    local cdo = mock.newBar({
        name = "Default__WBP_CombatCharacterBar_C",
        character = mock.newCharacter("E1", 5, 10),
        indicator = mock.newIndicator(1, 0),
    })
    world.bars = { cdo }
    mock.loadMod(world, cfg())
    world.tick(3)

    assertEq(mock.countChildren(cdo._host, "EI_HealthText"), 0, "CDO must not be decorated")
end)

test("hidden bars are skipped until shown", function()
    local world = mock.newWorld()
    local bar = mock.newBar({
        name = "Bar1",
        character = mock.newCharacter("E1", 5, 10),
        indicator = mock.newIndicator(1, 0),
    })
    bar._visible = false
    world.bars = { bar }
    mock.loadMod(world, cfg())
    world.tick(3)
    assertEq(mock.countChildren(bar._host, "EI_HealthText"), 0, "hidden bar untouched")

    bar._visible = true
    world.tick(1)
    assertEq(mock.textOf(bar._host, "EI_HealthText"), "5 / 10", "decorated once shown")
end)

test("survives a missing UMG class", function()
    local world = mock.newWorld()
    world.missingUMG.TextBlock = true
    local bar = mock.newBar({
        name = "Bar1",
        character = mock.newCharacter("E1", 5, 10),
        indicator = mock.newIndicator(1, 0),
    })
    world.bars = { bar }
    mock.loadMod(world, cfg())
    world.tick(5) -- must not throw
    assertTrue(mock.logged(world, "not found"), "expected a diagnostic")
end)

test("decimals and ShowMaxHealth are honoured", function()
    local world = mock.newWorld()
    local bar = mock.newBar({
        name = "Bar1",
        character = mock.newCharacter("E1", 42.567, 100),
        indicator = mock.newIndicator(1, 0),
    })
    world.bars = { bar }
    mock.loadMod(world, cfg({ Decimals = 2, ShowMaxHealth = false }))
    world.tick(2)
    assertEq(mock.textOf(bar._host, "EI_HealthText"), "42.57", "formatted health")
end)

--------------------------------------------------------------- visibility gating

local VIS_COLLAPSED, VIS_SHOWN = 1, 3

test("gating: an unbound bar collapses instead of keeping stale numbers", function()
    local world = mock.newWorld()
    local ch = mock.newCharacter("EnemyA", 42, 100)
    local bar = mock.newBar({ name = "Bar1", character = ch, indicator = mock.newIndicator(5, 0) })
    world.bars = { bar }
    mock.loadMod(world, cfg())
    world.tick(2)

    local hp = mock.deepFind(bar._host, "EI_HealthText")
    assertEq(hp._text, "42 / 100", "painted initially")
    assertEq(hp._SetVisibility, VIS_SHOWN, "shown initially")

    -- Unbind From Pawn without the bar being hidden yet.
    bar["Target Character"] = nil
    world.tick(1)
    assertEq(hp._SetVisibility, VIS_COLLAPSED, "collapsed once unbound")

    -- Re-bound to someone else, as a pooled bar would be.
    bar["Target Character"] = mock.newCharacter("EnemyB", 13, 50)
    world.tick(1)
    assertEq(hp._SetVisibility, VIS_SHOWN, "shown again")
    assertEq(hp._text, "13 / 50", "repainted for the new target")
end)

test("gating: a hidden bar collapses our widgets and forgets what it painted", function()
    local world = mock.newWorld()
    local ch = mock.newCharacter("EnemyA", 42, 100)
    local bar = mock.newBar({ name = "Bar1", character = ch, indicator = mock.newIndicator(5, 0) })
    world.bars = { bar }
    mock.loadMod(world, cfg())
    world.tick(2)

    local hp = mock.deepFind(bar._host, "EI_HealthText")
    bar._visible = false
    world.tick(1)
    assertEq(hp._SetVisibility, VIS_COLLAPSED, "collapsed while the bar is hidden")

    bar._visible = true
    world.tick(1)
    assertEq(hp._SetVisibility, VIS_SHOWN, "shown when the bar returns")
    assertEq(hp._text, "42 / 100", "still correct")
end)

test("gating: an invisible character gets no readout", function()
    local world = mock.newWorld()
    local ch = mock.newCharacter("EnemyA", 42, 100)
    local bar = mock.newBar({ name = "Bar1", character = ch, indicator = mock.newIndicator(5, 0) })
    world.bars = { bar }
    mock.loadMod(world, cfg())
    world.tick(2)

    local hp = mock.deepFind(bar._host, "EI_HealthText")
    assertEq(hp._SetVisibility, VIS_SHOWN, "shown initially")

    ch.bHidden = true
    world.tick(1)
    assertEq(hp._SetVisibility, VIS_COLLAPSED, "collapsed while the character is hidden")

    ch.bHidden = false
    world.tick(1)
    assertEq(hp._SetVisibility, VIS_SHOWN, "shown when the character reappears")
end)

test("gating: HideWhenInvisible = false ignores character visibility", function()
    local world = mock.newWorld()
    local ch = mock.newCharacter("EnemyA", 42, 100)
    local bar = mock.newBar({ name = "Bar1", character = ch, indicator = mock.newIndicator(5, 0) })
    world.bars = { bar }
    mock.loadMod(world, cfg({ HideWhenInvisible = false }))
    world.tick(2)

    ch.bHidden = true
    world.tick(1)
    local hp = mock.deepFind(bar._host, "EI_HealthText")
    assertEq(hp._SetVisibility, VIS_SHOWN, "still shown with the gate off")
end)

test("gating: a character with no visibility flag at all is treated as visible", function()
    local world = mock.newWorld()
    local ch = mock.newCharacter("EnemyA", 42, 100)
    ch.bHidden = nil -- neither bHidden nor IsHidden exists on this build
    local bar = mock.newBar({ name = "Bar1", character = ch, indicator = mock.newIndicator(5, 0) })
    world.bars = { bar }
    mock.loadMod(world, cfg())
    world.tick(20)

    assertEq(mock.textOf(bar._host, "EI_HealthText"), "42 / 100", "shown by default")
    -- The probe must latch rather than re-testing a missing spelling every tick, which
    -- would mean raising and catching an error per bar per tick.
    local n = 0
    for _, line in ipairs(world.logs) do
        if line:find("no actor visibility flag", 1, true) then n = n + 1 end
    end
    assertEq(n, 1, "capability probe should resolve once")
end)

--------------------------------------------------------------------------- cleanup

test("cleanup: a dropped bar has its injected widgets detached", function()
    local world = mock.newWorld()
    local ch = mock.newCharacter("EnemyA", 42, 100)
    local bar = mock.newBar({ name = "Bar1", character = ch, indicator = mock.newIndicator(5, 0) })
    world.bars = { bar }
    -- The badge builds, the health text never does, so the build path keeps being
    -- retried - which is what lets a later failure there reach the fail counter.
    world.failConstruct["EI_HealthText"] = true
    mock.loadMod(world, cfg())
    world.tick(1)
    assertEq(mock.countChildren(bar._host, "EI_LevelBox"), 1, "badge attached")

    -- Widget tree partly torn down mid-session: resolving the host now throws.
    bar.SegmentedHealthBar = mock.newPoison()
    world.tick(15) -- past MAX_FAILS

    assertTrue(mock.logged(world, "giving up on"), "bar should be dropped")
    assertEq(mock.countChildren(bar._host, "EI_LevelBox"), 0, "badge detached on teardown")
end)

------------------------------------------------------- precomputed / throttled reads

test("max health is not polled every tick", function()
    local world = mock.newWorld()
    local ch = mock.newCharacter("EnemyA", 100, 100)
    local bar = mock.newBar({ name = "Bar1", character = ch, indicator = mock.newIndicator(5, 0) })
    world.bars = { bar }
    mock.loadMod(world, cfg({ ShowLevel = false }))
    world.tick(30) -- 3000ms of simulated time at 100ms per tick

    local hpReads = mock.readsOf(ch, "Health")
    local maxReads = mock.readsOf(ch, "MaxHealth")
    assertTrue(hpReads >= 28, "health should be read every tick, got " .. hpReads)
    assertTrue(maxReads <= 5, "max health should be throttled, got " .. maxReads)
end)

test("a mid-fight max health increase is still picked up", function()
    local world = mock.newWorld()
    local ch = mock.newCharacter("EnemyA", 100, 100)
    local bar = mock.newBar({ name = "Bar1", character = ch, indicator = mock.newIndicator(5, 0) })
    world.bars = { bar }
    mock.loadMod(world, cfg())
    world.tick(2)
    assertEq(mock.textOf(bar._host, "EI_HealthText"), "100 / 100", "initial")

    -- Phase two: the game buffs the pool without re-pointing the bar.
    ch.CharacterAttributeSet.MaxHealth.CurrentValue = 200
    world.tick(12) -- past MAX_HP_INTERVAL
    assertEq(mock.textOf(bar._host, "EI_HealthText"), "100 / 200", "new ceiling picked up")
end)

test("a max health change repaints even when current health has not moved", function()
    local world = mock.newWorld()
    local ch = mock.newCharacter("EnemyA", 50, 100)
    local bar = mock.newBar({ name = "Bar1", character = ch, indicator = mock.newIndicator(5, 0) })
    world.bars = { bar }
    mock.loadMod(world, cfg())
    world.tick(2)
    assertEq(mock.textOf(bar._host, "EI_HealthText"), "50 / 100", "initial")

    ch.CharacterAttributeSet.MaxHealth.CurrentValue = 400
    world.tick(12)
    assertEq(mock.textOf(bar._host, "EI_HealthText"), "50 / 400", "denominator updated")
end)

----------------------------------------------------------------------- badge styles

local function styledBar(world, style, over)
    local bar = mock.newBar({
        name = "Bar1",
        character = mock.newCharacter("EnemyA", 42, 100),
        indicator = mock.newIndicator(5, 0),
    })
    world.bars = { bar }
    local c = over or {}
    c.LevelStyle = style
    mock.loadMod(world, cfg(c))
    world.tick(2)
    return bar
end

test("style diamond: box is square and the rim is rotated", function()
    local world = mock.newWorld()
    local bar = styledBar(world, "diamond", { LevelBoxSize = 30, LevelPlateWidth = 64 })

    local box = mock.deepFind(bar._host, "EI_LevelBox")
    assertEq(box._SetWidthOverride, 30, "diamond uses the box size for width")
    assertEq(box._SetHeightOverride, 30, "box height")
    assertEq(mock.deepFind(bar._host, "EI_LevelRim")._SetRenderTransformAngle, 45.0, "rotated")
end)

test("style plate: box uses the plate width and is not rotated", function()
    local world = mock.newWorld()
    local bar = styledBar(world, "plate", { LevelBoxSize = 30, LevelPlateWidth = 64 })

    local box = mock.deepFind(bar._host, "EI_LevelBox")
    assertEq(box._SetWidthOverride, 64, "plate uses the plate width")
    assertEq(box._SetHeightOverride, 30, "box height")
    assertEq(mock.deepFind(bar._host, "EI_LevelRim")._SetRenderTransformAngle, nil, "not rotated")
    assertEq(mock.textOf(bar._host, "EI_LevelText"), "5", "level shown")
end)

test("style none: level text is slotted bare, with no badge built", function()
    local world = mock.newWorld()
    local bar = styledBar(world, "none")

    assertEq(mock.countChildren(bar._host, "EI_LevelBox"), 0, "no box attached")
    assertEq(mock.countConstructed(world, "EI_LevelBox"), 0, "no box constructed")
    assertEq(mock.countConstructed(world, "EI_LevelRim"), 0, "no rim constructed")
    assertEq(mock.countChildren(bar._host, "EI_LevelText"), 1, "text slotted on the host")
    assertEq(mock.textOf(bar._host, "EI_LevelText"), "5", "level shown")
end)

test("style none: gating collapses the bare level text", function()
    local world = mock.newWorld()
    local bar = styledBar(world, "none")
    local lvl = mock.deepFind(bar._host, "EI_LevelText")

    bar._visible = false
    world.tick(1)
    assertEq(lvl._SetVisibility, VIS_COLLAPSED, "collapsed with no box to stand in for it")

    bar._visible = true
    world.tick(1)
    assertEq(lvl._SetVisibility, VIS_SHOWN, "shown again")
end)

test("an unknown LevelStyle warns and falls back to diamond", function()
    local world = mock.newWorld()
    local bar = styledBar(world, "sparkle", { LevelBoxSize = 30, LevelPlateWidth = 64 })

    assertTrue(mock.logged(world, "LevelStyle"), "expected a warning naming the option")
    assertEq(mock.deepFind(bar._host, "EI_LevelBox")._SetWidthOverride, 30, "fell back to diamond")
    assertEq(mock.deepFind(bar._host, "EI_LevelRim")._SetRenderTransformAngle, 45.0, "rotated")
end)

------------------------------------------------------------------------ colour target

test("ColorTarget rim: the rim takes the delta colour, the text stays TextColor", function()
    local world = mock.newWorld()
    local bar = mock.newBar({
        name = "Bar1",
        character = mock.newCharacter("EnemyA", 42, 100),
        indicator = mock.newIndicator(5, 7), -- delta 7 -> ColorMuch
    })
    world.bars = { bar }
    mock.loadMod(world, cfg({ ColorTarget = "rim", TextColor = { R = 0.25, G = 0.5, B = 0.75 } }))
    world.tick(2)

    assertNear(mock.deepFind(bar._host, "EI_LevelRim")._SetBrushColor.R, 0.904661, "rim recoloured")
    local lvl = mock.deepFind(bar._host, "EI_LevelText")
    assertNear(lvl._SetColorAndOpacity.SpecifiedColor.R, 0.25, "text uses TextColor")
end)

test("ColorTarget text: the text takes the delta colour, the rim is left alone", function()
    local world = mock.newWorld()
    local bar = mock.newBar({
        name = "Bar1",
        character = mock.newCharacter("EnemyA", 42, 100),
        indicator = mock.newIndicator(5, 7),
    })
    world.bars = { bar }
    mock.loadMod(world, cfg({ ColorTarget = "text" }))
    world.tick(2)

    -- The rim keeps the equal colour it was built with.
    assertNear(mock.deepFind(bar._host, "EI_LevelRim")._SetBrushColor.R, 0.62, "rim untouched")
    local lvl = mock.deepFind(bar._host, "EI_LevelText")
    assertNear(lvl._SetColorAndOpacity.SpecifiedColor.R, 0.904661, "text recoloured")
end)

test("ColorTarget both: rim and text both take the delta colour", function()
    local world = mock.newWorld()
    local bar = mock.newBar({
        name = "Bar1",
        character = mock.newCharacter("EnemyA", 42, 100),
        indicator = mock.newIndicator(5, 10), -- delta 10 -> ColorCritical
    })
    world.bars = { bar }
    mock.loadMod(world, cfg({ ColorTarget = "both" }))
    world.tick(2)

    assertNear(mock.deepFind(bar._host, "EI_LevelRim")._SetBrushColor.R, 0.760525, "rim critical")
    local lvl = mock.deepFind(bar._host, "EI_LevelText")
    assertNear(lvl._SetColorAndOpacity.SpecifiedColor.R, 0.760525, "text critical")
end)

test("difficulty thresholds pick the documented colours", function()
    local cases = {
        { delta = 0,  r = 0.62 },      -- equal
        { delta = 3,  r = 0.62 },      -- still equal: thresholds start at 4
        { delta = 4,  r = 1.0 },       -- slightly
        { delta = 6,  r = 0.904661 },  -- much
        { delta = 9,  r = 0.760525 },  -- critical
        { delta = -5, r = 0.62 },      -- weaker enemies collapse to equal
    }
    for _, case in ipairs(cases) do
        local world = mock.newWorld()
        local bar = mock.newBar({
            name = "Bar1",
            character = mock.newCharacter("EnemyA", 42, 100),
            indicator = mock.newIndicator(5, case.delta),
        })
        world.bars = { bar }
        mock.loadMod(world, cfg())
        world.tick(2)
        assertNear(mock.deepFind(bar._host, "EI_LevelRim")._SetBrushColor.R, case.r,
            "delta " .. case.delta)
    end
end)

test("ColorByDifficulty false keeps everything at the equal colour", function()
    local world = mock.newWorld()
    local bar = mock.newBar({
        name = "Bar1",
        character = mock.newCharacter("EnemyA", 42, 100),
        indicator = mock.newIndicator(5, 10),
    })
    world.bars = { bar }
    mock.loadMod(world, cfg({ ColorByDifficulty = false }))
    world.tick(2)
    assertNear(mock.deepFind(bar._host, "EI_LevelRim")._SetBrushColor.R, 0.62, "no colourisation")
end)

------------------------------------------------------------------ alignment & prefix

test("right alignment offsets through right padding", function()
    local world = mock.newWorld()
    local bar = mock.newBar({
        name = "Bar1",
        character = mock.newCharacter("EnemyA", 42, 100),
        indicator = mock.newIndicator(5, 0),
    })
    world.bars = { bar }
    mock.loadMod(world, cfg({ HealthAlign = 3, HealthOffsetX = 20 }))
    world.tick(2)

    local slot = mock.deepFind(bar._host, "EI_HealthText")._slot
    assertEq(slot.hAlign, 3, "right aligned")
    assertEq(slot.padding.Right, -20, "offset applied to the right edge")
    assertEq(slot.padding.Left, 0, "no left padding")
end)

test("centre alignment offsets through left padding", function()
    local world = mock.newWorld()
    local bar = mock.newBar({
        name = "Bar1",
        character = mock.newCharacter("EnemyA", 42, 100),
        indicator = mock.newIndicator(5, 0),
    })
    world.bars = { bar }
    mock.loadMod(world, cfg({ HealthAlign = 2, HealthOffsetX = -12, LevelAlign = 1, LevelOffsetX = 44 }))
    world.tick(2)

    local hpSlot = mock.deepFind(bar._host, "EI_HealthText")._slot
    assertEq(hpSlot.hAlign, 2, "centred")
    assertEq(hpSlot.padding.Left, -12, "negative offset pushes left")

    local boxSlot = mock.deepFind(bar._host, "EI_LevelBox")._slot
    assertEq(boxSlot.hAlign, 1, "badge left aligned")
    assertEq(boxSlot.padding.Left, 44, "badge offset applied")
end)

test("LevelPrefix is prepended to the level", function()
    local world = mock.newWorld()
    local bar = mock.newBar({
        name = "Bar1",
        character = mock.newCharacter("EnemyA", 42, 100),
        indicator = mock.newIndicator(17, 0),
    })
    world.bars = { bar }
    mock.loadMod(world, cfg({ LevelPrefix = "Lv " }))
    world.tick(2)
    assertEq(mock.textOf(bar._host, "EI_LevelText"), "Lv 17", "prefixed level")
end)

test("a level indicator that appears late is picked up promptly", function()
    local world = mock.newWorld()
    local bar = mock.newBar({
        name = "Bar1",
        character = mock.newCharacter("EnemyA", 42, 100),
        indicator = nil, -- not wired up yet
    })
    world.bars = { bar }
    mock.loadMod(world, cfg())
    world.tick(1)
    assertEq(mock.textOf(bar._host, "EI_LevelText"), nil, "nothing to show yet")

    bar.LevelIndicator = mock.newIndicator(7, 0)
    world.tick(1) -- must not burn a whole LEVEL_INTERVAL first
    assertEq(mock.textOf(bar._host, "EI_LevelText"), "7", "picked up on the next tick")
end)

--------------------------------------------------------------------------- report

print("")
print(string.format("%d passed, %d failed", passed, #failed))
if #failed > 0 then
    print("")
    for _, f in ipairs(failed) do print("FAILED: " .. f.name) end
    os.exit(1)
end
os.exit(0)
