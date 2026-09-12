-- The readout itself: formatting, change detection, and read throttling.

return function(mock, run, support)
    local test = run.test
    local cfg = support.cfg
    local assertEq, assertNear, assertTrue = support.assertEq, support.assertNear, support.assertTrue
    local VIS_COLLAPSED, VIS_SHOWN = support.VIS_COLLAPSED, support.VIS_SHOWN

    -- Low-health flash. Threshold is max/LowHealthSegments: the point below which the
    -- game's own segmented bar cannot show a difference.
    local function lowBar(world, hp, max, over)
        local bar = mock.newBar({
            name = "Bar1",
            character = mock.newCharacter("EnemyA", hp, max),
            indicator = mock.newIndicator(5, 0),
        })
        world.bars = { bar }
        mock.loadMod(world, cfg(over or {}))
        return bar
    end

    -- All three channels, because the default TextColor and LowHealthColor share R=1
    -- and differ only in G and B. Sampling one channel silently misses the change.
    local function hpColour(bar)
        local w = mock.deepFind(bar._host, "EI_HealthText")
        local c = w and w._SetColorAndOpacity
        if not (c and c.SpecifiedColor) then return nil end
        local s = c.SpecifiedColor
        return string.format("%.3f,%.3f,%.3f", s.R or -1, s.G or -1, s.B or -1)
    end

    local function hpColourR(bar)
        local w = mock.deepFind(bar._host, "EI_HealthText")
        local c = w and w._SetColorAndOpacity
        return c and c.SpecifiedColor and c.SpecifiedColor.R or nil
    end

    -- Distinct colour values seen across n ticks; >1 means it is alternating.
    local function coloursOver(world, bar, n)
        local seen, count = {}, 0
        for _ = 1, n do
            world.tick(1)
            local r = hpColour(bar)
            if r ~= nil and not seen[r] then seen[r] = true count = count + 1 end
        end
        return count
    end

    test("low health: the readout flashes below one segment's worth", function()
        local world = mock.newWorld()
        -- 10 segments of 100 max = threshold 10; 4 HP is inside it.
        local bar = lowBar(world, 4, 100, { LowHealthPercent = 10 })
        assertTrue(coloursOver(world, bar, 16) >= 2,
            "expected the colour to alternate while low")
    end)

    test("low health: no flash when above the threshold", function()
        local world = mock.newWorld()
        local bar = lowBar(world, 50, 100, { LowHealthPercent = 10 })
        assertEq(coloursOver(world, bar, 16), 1, "colour should never change")
    end)

    test("low health: no flash at zero - dead is not low", function()
        local world = mock.newWorld()
        local bar = lowBar(world, 0, 100, { LowHealthPercent = 10 })
        assertEq(coloursOver(world, bar, 16), 1, "colour should never change")
    end)

    test("low health: stops flashing once healed back up", function()
        local world = mock.newWorld()
        local bar = lowBar(world, 4, 100, { LowHealthPercent = 10 })
        assertTrue(coloursOver(world, bar, 16) >= 2, "flashing while low")

        local ch = bar["Target Character"]
        ch.CharacterAttributeSet.Health.CurrentValue = 80
        world.tick(12) -- settle past a full flash period
        assertEq(coloursOver(world, bar, 16), 1, "colour should be steady again")
        assertNear(hpColourR(bar), 1, "back to the TextColor base")
    end)

    test("low health: every low bar flashes in phase", function()
        local world = mock.newWorld()
        local bars = {}
        for i = 1, 3 do
            bars[i] = mock.newBar({
                name = "Bar" .. i,
                character = mock.newCharacter("Enemy" .. i, 3 + i, 100),
                indicator = mock.newIndicator(5, 0),
            })
        end
        world.bars = bars
        mock.loadMod(world, cfg({ LowHealthPercent = 10 }))

        -- Phase is derived from the shared clock, not a per-bar timer, so all three
        -- must agree at every tick rather than drifting apart.
        for _ = 1, 16 do
            world.tick(1)
            local a = hpColour(bars[1])
            assertEq(hpColour(bars[2]), a, "bar 2 in phase with bar 1")
            assertEq(hpColour(bars[3]), a, "bar 3 in phase with bar 1")
        end
    end)

    test("low health: LowHealthFlash = false disables it", function()
        local world = mock.newWorld()
        local bar = lowBar(world, 4, 100, { LowHealthPercent = 10, LowHealthFlash = false })
        assertEq(coloursOver(world, bar, 16), 1, "colour should never change")
    end)

    test("the health readout honours TextColor", function()
        local world = mock.newWorld()
        local bar = lowBar(world, 50, 100, { TextColor = { R = 0.25, G = 0.5, B = 0.75 } })
        world.tick(2)
        assertNear(hpColourR(bar), 0.25, "health text uses TextColor, not hardcoded white")
    end)


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


end
