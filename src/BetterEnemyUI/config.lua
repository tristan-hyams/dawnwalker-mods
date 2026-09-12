	-- author: Caites
return {
    ShowHealth        = true,
    ShowMaxHealth     = true,
    ShowLevel         = true,

    Decimals          = 0,

    -- Align: 1 = left, 2 = centre, 3 = right.
    -- OffsetX shifts right when positive, left when negative, whichever edge it is
    -- anchored to. Out-of-range and non-numeric values are clamped or defaulted, not
    -- rejected, so a bad edit here degrades rather than breaking the mod.
    HealthFontSize    = 18,
    HealthAlign       = 2,
    HealthOffsetX     = 0,

    LevelPrefix       = "",
    LevelFontSize     = 18,
    LevelAlign        = 1,
    LevelOffsetX      = 12,
	
	-- Presets: Style - None, LevelOffsetX - 20; Style - diamond, LevelOffsetX = 12, LevelRimThickness = 3; Style - Plate, LevelOffsetX = 12, LevelRimThickness = 2
	
    LevelStyle        = "diamond", -- Styles: diamond, plate, none
    LevelBoxSize      = 40,
    LevelPlateWidth   = 38,
    LevelRimThickness = 3,
    LevelBgColor      = { R = 0.020, G = 0.018, B = 0.018, A = 0.88 },

    RefreshMs         = 150,

    -- Blinks the readout, and the badge fill behind it, once health drops below
    -- LowHealthPercent of maximum. A peripheral cue to finish them off, not a danger
    -- warning - hence amber rather than red.
    --
    -- The window must be wider than a single hit: if one swing does more damage than
    -- the whole window is wide, health jumps clean over it and the cue never fires.
    -- Observed at 10% on a 1541 HP wolf - it first flashed at 2 HP.
    --
    -- The threshold is a percentage of that enemy's own max health, recomputed as max
    -- changes, so it works the same on a 200 HP wolf and a 2000 HP boss - including a
    -- multi-phase fight that buffs the pool mid-encounter.
    --
    -- LowHealthColor wants a large luminance gap from TextColor, not just a hue shift.
    -- Peripheral vision detects brightness changes far better than colour, so a pale
    -- tint next to white is effectively invisible.
    LowHealthFlash    = true,
    LowHealthPercent  = 25,

    LowHealthColor    = { R = 1, G = 0.55, B = 0.00 },
    LowHealthPeriodMs = 800,

    ColorByDifficulty = true,
    ColorTarget       = "rim",
    ColorEqual        = { R = 0.62, G = 0.60, B = 0.56 },
    ColorSlightly     = { R = 1.000000, G = 0.644480, B = 0.036889 },
    ColorMuch         = { R = 0.904661, G = 0.181164, B = 0.002125 },
    ColorCritical     = { R = 0.760525, G = 0.016807, B = 0.016807 },
    TextColor         = { R = 1, G = 1, B = 1 },
}
