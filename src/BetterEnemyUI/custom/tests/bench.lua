-- Measures the Lua-side cost of the tick loop.
--   lua tests/bench.lua
--   MOD_MAIN=/path/to/other/main.lua lua tests/bench.lua
--
-- Caveat: the mock reads plain Lua tables where the game does real UObject property
-- reads, which are far more expensive. So the absolute numbers here mean nothing about
-- in-game frame cost. What this does measure honestly is the overhead the mod adds on
-- top of those reads: closure allocation, string formatting, and GC pressure.

local print = print

local here = (arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/?.lua;" .. package.path

local mock = require("mock_ue4ss")
mock.MAIN_PATH = os.getenv("MOD_MAIN") or (here .. "/../main.lua")

local BARS = tonumber(os.getenv("BENCH_BARS") or "12")
local TICKS = tonumber(os.getenv("BENCH_TICKS") or "20000")

local function build()
    local world = mock.newWorld()
    local chars = {}
    for i = 1, BARS do
        local ch = mock.newCharacter("Enemy" .. i, 100, 100)
        chars[i] = ch
        world.bars[i] = mock.newBar({
            name = "Bar" .. i,
            character = ch,
            indicator = mock.newIndicator(5 + i, i % 12),
        })
    end
    mock.loadMod(world, {
        ShowHealth = true, ShowMaxHealth = true, ShowLevel = true,
        Decimals = 0, RefreshMs = 100, LevelStyle = "diamond",
        ColorByDifficulty = true, ColorTarget = "rim",
    })
    world.tick(5) -- build the widgets so we time steady state, not construction
    return world, chars
end

local function run(label, mutate)
    local world, chars = build()
    collectgarbage("collect")
    collectgarbage("collect")
    local kb0 = collectgarbage("count")
    local t0 = os.clock()

    for i = 1, TICKS do
        if mutate then mutate(chars, i) end
        world.tick(1)
    end

    local elapsed = os.clock() - t0
    local kb1 = collectgarbage("count")
    collectgarbage("collect")

    print(string.format("  %-22s %8.1f ms total  %7.3f us/bar-tick  %8.1f KB live delta",
        label, elapsed * 1000, (elapsed * 1e6) / (TICKS * BARS), kb1 - kb0))
end

print(string.format("main.lua: %s", mock.MAIN_PATH))
print(string.format("%d bars x %d ticks", BARS, TICKS))
print("")

run("idle (no damage)", nil)

run("every bar changing", function(chars, i)
    for j = 1, #chars do
        chars[j].CharacterAttributeSet.Health.CurrentValue = 100 - ((i + j) % 100)
    end
end)

-- Fractional churn that rounds to the same displayed integer: the case where a numeric
-- guard alone would still repaint and a string guard still suppresses it.
run("sub-integer churn", function(chars, i)
    for j = 1, #chars do
        chars[j].CharacterAttributeSet.Health.CurrentValue = 50 + ((i * 0.01) % 0.9)
    end
end)
