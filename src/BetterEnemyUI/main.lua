-- author: Caites
-- sub-author: Cain
--
-- Discovery, scheduling and the tick loop. Reading and decorating a single combat bar
-- lives in bar.lua; generic UE4SS/UMG plumbing lives in utils.lua.

local TAG = "[EnemyInfo] "

-- utils is the bootstrap dependency: it carries the loader every other module goes
-- through, so it is the one require that cannot use it.
local uok, utils = pcall(require, "utils")
if not uok or type(utils) ~= "table" then
    print(TAG .. "FATAL: utils.lua missing or invalid; mod disabled\n")
    return
end

local log, once = utils.logger(TAG)
local valid, try, getFullName = utils.valid, utils.try, utils.getFullName

local defineBar = utils.need("bar", "function", log)
if not defineBar then return end

---------------------------------------------------------------------------- config

local ok, cfg = pcall(require, "config")
if not ok or type(cfg) ~= "table" then cfg = {} end
local function opt(k, d) local v = cfg[k] if v == nil then return d end return v end

local function int(k, d, lo, hi) return utils.clampInt(opt(k, d), d, lo, hi) end
local function real(k, d, lo, hi) return utils.clampNum(opt(k, d), d, lo, hi) end

-- Both of these used to be passed through unchecked, and a typo in either silently
-- selected a different branch: an unknown style fell through to plate, and an unknown
-- colour target disabled difficulty colouring altogether.
local KNOWN_STYLES  = { diamond = true, plate = true, none = true }
local KNOWN_TARGETS = { rim = true, text = true, both = true }

local levelStyle  = utils.oneOf(opt("LevelStyle", "diamond"), KNOWN_STYLES, "diamond", log, "LevelStyle")
local colorTarget = utils.oneOf(opt("ColorTarget", "rim"), KNOWN_TARGETS, "rim", log, "ColorTarget")

local CFG = {
    showHealth = opt("ShowHealth", true),
    showMax    = opt("ShowMaxHealth", true),
    showLevel  = opt("ShowLevel", true),

    decimals = int("Decimals", 0, 0, 2),

    hpSize   = int("HealthFontSize", 18, 6, 72),
    hpAlign  = int("HealthAlign", 2, 1, 3),
    hpOffset = tonumber(opt("HealthOffsetX", 0)) or 0,

    lvlPrefix = tostring(opt("LevelPrefix", "")),
    lvlSize   = int("LevelFontSize", 15, 6, 72),
    lvlAlign  = int("LevelAlign", 1, 1, 3),
    lvlOffset = tonumber(opt("LevelOffsetX", -44)) or -44,

    style        = levelStyle,
    boxSize      = real("LevelBoxSize", 26, 10, 96),
    plateWidth   = real("LevelPlateWidth", 38, 10, 160),
    rimThickness = real("LevelRimThickness", 2, 0, 8),
    bgColor      = opt("LevelBgColor", { R = 0.02, G = 0.018, B = 0.018, A = 0.88 }),

    colorize    = opt("ColorByDifficulty", true),
    colorTarget = colorTarget,
    cEqual      = opt("ColorEqual",    { R = 0.62, G = 0.60, B = 0.56 }),
    cSlight     = opt("ColorSlightly", { R = 1, G = 0.64448, B = 0.036889 }),
    cMuch       = opt("ColorMuch",     { R = 0.904661, G = 0.181164, B = 0.002125 }),
    cCrit       = opt("ColorCritical", { R = 0.760525, G = 0.016807, B = 0.016807 }),
    cText       = opt("TextColor", { R = 1, G = 1, B = 1 }),

    lowFlash    = opt("LowHealthFlash", true),
    lowPercent  = int("LowHealthPercent", 25, 1, 90),
    lowPeriodMs = int("LowHealthPeriodMs", 800, 200, 3000),
    lowColor    = opt("LowHealthColor", { R = 1, G = 0.55, B = 0.00 }),

    -- Blueprint calls and a near-static ceiling do not need the health cadence.
    levelIntervalMs = 1000,
    maxHpIntervalMs = 1000,
}

local TICK = int("RefreshMs", 200, 100, 1000)

local BAR_PATH  = "/Game/_Dawnwalker/UI/_Unified/Combat/WBP_CombatCharacterBar.WBP_CombatCharacterBar_C"
local BAR_CLASS = "WBP_CombatCharacterBar_C"
local SWEEP_IDLE_MS   = 1000
local SWEEP_ACTIVE_MS = 5000
local MAX_FAILS = 10

local Bar = defineBar({ config = CFG, log = log, once = once })

-------------------------------------------------------------------------- registry

local bars, tracked = {}, {}
local nowMs, lastSweep, inFlight, lastErr = 0, -99999, false, nil
local notified = false

local function add(widget)
    if not valid(widget) then return end
    local key = try(getFullName, widget)
    if not key or key:find("Default__", 1, true) then return end
    if tracked[key] then return end
    local bar = Bar.new(widget, key)
    tracked[key] = bar
    bars[#bars + 1] = bar
end

local function sweepOnce()
    local found = FindAllOf(BAR_CLASS)
    if not found then return end
    for _, w in ipairs(found) do add(w) end
end

local function setupNotify()
    if notified then return end

    -- Only latch `notified` if registration actually succeeded, otherwise we would
    -- silently fall back to a single startup sweep and never show a bar again.
    local o = pcall(NotifyOnNewObject, BAR_PATH, function(obj) add(obj) end)
    if o then
        notified = true
    else
        once("notify", "NotifyOnNewObject failed; falling back to periodic sweep")
    end
end

-- Deduped, so a persistent failure costs one log line rather than one per tick. Shared
-- by the per-bar path and the game-thread boundary, which report identically.
local function reportError(prefix, err)
    err = tostring(err)
    if err == lastErr then return end
    lastErr = err
    log(prefix .. err)
end

-- Sole owner of the bars/tracked pair, so the two cannot drift apart.
--
-- Swapping the tail into the hole is safe given the reverse walk in `update`: the tail
-- is always either an entry that pass has already visited, or the hole itself. It reads
-- like the classic skip-an-element bug and is not one.
local function removeAt(i)
    tracked[bars[i].key] = nil
    bars[i] = bars[#bars]
    bars[#bars] = nil
end

local function maybeSweep()
    -- FindAllOf walks the whole object array, so only poll quickly when we actually
    -- depend on it: the hook is broken, or we have nothing tracked (between fights,
    -- where the next bar to appear is the one the player is waiting on).
    local interval = (notified and #bars > 0) and SWEEP_ACTIVE_MS or SWEEP_IDLE_MS
    if nowMs - lastSweep < interval then return end

    lastSweep = nowMs
    setupNotify()
    sweepOnce()
end

-- Refreshes one bar and applies the failure policy. Returns false when the entry should
-- be dropped from the registry.
local function refreshBar(bar)
    -- The widget is gone and took our injected children with it; nothing to detach.
    if not valid(bar.widget) then return false end

    -- Protected per bar, not per sweep: one throwing bar used to abort the whole loop
    -- at the same index every tick, so every bar below it stopped updating.
    local o, err = pcall(Bar.refresh, bar, nowMs)
    if o then
        bar.fails = 0
        return true
    end

    bar.fails = bar.fails + 1
    reportError("refresh error: ", err)
    if bar.fails < MAX_FAILS then return true end

    -- Failing consistently on a live widget. A thrown Lua error costs measurably more
    -- than everything else in the tick, so stop asking. The widget itself is still
    -- alive, so put it back the way we found it rather than abandoning frozen numbers
    -- on someone's health bar. A later sweep may re-add it, in which case it fails and
    -- retires again - one wasted cycle per sweep, and no state kept between them.
    log("giving up on " .. tostring(bar.key))
    pcall(Bar.teardown, bar)
    return false
end

local function update()
    maybeSweep()
    for i = #bars, 1, -1 do
        if not refreshBar(bars[i]) then removeAt(i) end
    end
end

------------------------------------------------------------------------- scheduler

-- LoopAsync keeps looping while the callback returns false; returning true would stop
-- it permanently.
local LOOP_CONTINUE = false

-- Runs on the game thread. Everything that touches a UObject must be in here, and
-- nothing may escape: an error reaching LoopAsync would kill the loop for the session.
local function tickGameThread()
    local o, err = pcall(update)

    -- Cleared before the reporting below, so a failure in `log` itself cannot strand
    -- the guard and silently stop the mod for the rest of the session.
    inFlight = false

    if not o then reportError("error: ", err) end
end

-- Runs on the LoopAsync worker thread, where touching a UObject is not safe, so this
-- only advances the mod clock and hands the work over. `inFlight` drops a tick rather
-- than letting dispatches queue up behind a slow frame; the clock still advances, so
-- the interval throttles inside `update` stay honest about elapsed time.
local function tick()
    nowMs = nowMs + TICK
    if inFlight then return LOOP_CONTINUE end
    inFlight = true
    ExecuteInGameThread(tickGameThread)
    return LOOP_CONTINUE
end

------------------------------------------------------------------------------ init

sweepOnce()
setupNotify()
LoopAsync(TICK, tick)

log("loaded")
