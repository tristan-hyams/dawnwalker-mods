-- Regressions for the four original defects. These fail against the pre-fix main.lua,
-- which is how they are confirmed to discriminate rather than pass vacuously.

return function(mock, run, support)
    local test = run.test
    local cfg = support.cfg
    local assertEq, assertNear, assertTrue = support.assertEq, support.assertNear, support.assertTrue
    local VIS_COLLAPSED, VIS_SHOWN = support.VIS_COLLAPSED, support.VIS_SHOWN

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

    test("defect 3: a retired bar keeps no state, so a later sweep may retry it", function()
        local world = mock.newWorld()
        local bad = mock.newBar({
            name = "Bad",
            character = mock.newCharacter("EBad", 1, 1),
            indicator = mock.newIndicator(1, 0),
            poisonHost = true,
        })
        world.bars = { bad }
        mock.loadMod(world, cfg())

        local function retirements()
            local n = 0
            for _, line in ipairs(world.logs) do
                if line:find("giving up on", 1, true) then n = n + 1 end
            end
            return n
        end

        world.tick(15) -- past MAX_FAILS once
        assertEq(retirements(), 1, "retired once")

        -- The tracking key is released on retirement, so a sweep re-adds the bar and it
        -- fails its way out again rather than being remembered forever.
        world.tick(30)
        assertTrue(retirements() >= 2, "expected a retry, got " .. retirements())
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


end
