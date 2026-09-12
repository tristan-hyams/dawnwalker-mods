-- Bar discovery, visibility gating, teardown, and dead-bar cleanup.

return function(mock, run, support)
    local test = run.test
    local cfg = support.cfg
    local assertEq, assertNear, assertTrue = support.assertEq, support.assertNear, support.assertTrue
    local VIS_COLLAPSED, VIS_SHOWN = support.VIS_COLLAPSED, support.VIS_SHOWN

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


end
