-- Config-driven appearance: badge styles, colour targets, alignment, clamping.

return function(mock, run, support)
    local test = run.test
    local cfg = support.cfg
    local assertEq, assertNear, assertTrue = support.assertEq, support.assertNear, support.assertTrue
    local VIS_COLLAPSED, VIS_SHOWN = support.VIS_COLLAPSED, support.VIS_SHOWN

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

    test("an unknown ColorTarget warns and falls back to rim", function()
        local world = mock.newWorld()
        local bar = mock.newBar({
            name = "Bar1",
            character = mock.newCharacter("EnemyA", 42, 100),
            indicator = mock.newIndicator(5, 7), -- delta 7 -> ColorMuch
        })
        world.bars = { bar }
        mock.loadMod(world, cfg({ ColorTarget = "rimm", TextColor = { R = 0.25, G = 0.5, B = 0.75 } }))
        world.tick(2)

        assertTrue(mock.logged(world, "ColorTarget"), "expected a warning naming the option")
        assertNear(mock.deepFind(bar._host, "EI_LevelRim")._SetBrushColor.R, 0.904661, "rim recoloured")
        local lvl = mock.deepFind(bar._host, "EI_LevelText")
        assertNear(lvl._SetColorAndOpacity.SpecifiedColor.R, 0.25, "text left on TextColor")
    end)

    -------------------------------------------------------------------- config clamping

    test("out-of-range numeric config is clamped, not rejected", function()
        local world = mock.newWorld()
        local bar = mock.newBar({
            name = "Bar1",
            character = mock.newCharacter("EnemyA", 42.567, 100),
            indicator = mock.newIndicator(5, 0),
        })
        world.bars = { bar }
        mock.loadMod(world, cfg({
            Decimals = 9,            -- clamps to 2
            HealthFontSize = 999,    -- clamps to 72
            LevelRimThickness = -5,  -- clamps to 0
        }))
        world.tick(2)

        assertEq(mock.textOf(bar._host, "EI_HealthText"), "42.57 / 100.00", "decimals clamped to 2")
        assertEq(mock.deepFind(bar._host, "EI_HealthText").Font.Size, 72, "font size clamped")
        assertEq(mock.deepFind(bar._host, "EI_LevelRim")._SetPadding.Left, 0, "rim thickness clamped")
    end)

    test("non-numeric config falls back to the default rather than throwing", function()
        local world = mock.newWorld()
        local bar = mock.newBar({
            name = "Bar1",
            character = mock.newCharacter("EnemyA", 42, 100),
            indicator = mock.newIndicator(5, 0),
        })
        world.bars = { bar }
        mock.loadMod(world, cfg({ Decimals = "abc", HealthFontSize = {}, LevelBoxSize = "wide" }))
        world.tick(2)

        assertEq(mock.textOf(bar._host, "EI_HealthText"), "42 / 100", "default decimals")
        assertEq(mock.deepFind(bar._host, "EI_HealthText").Font.Size, 18, "default font size")
        assertEq(mock.deepFind(bar._host, "EI_LevelBox")._SetWidthOverride, 26, "default box size")
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


end
