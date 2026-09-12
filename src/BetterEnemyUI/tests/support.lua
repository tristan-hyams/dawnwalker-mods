-- Shared test scaffolding: a runner, assertions, and a config builder.
--
-- The mock replaces the global `print`, so this module captures the real one at load
-- time. Every spec and the benchmark route their output through `support.print`,
-- otherwise their results vanish into the captured mod log.

local M = {}

M.print = print

-- ESlateVisibility values the specs assert against.
M.VIS_COLLAPSED = 1
M.VIS_SHOWN = 3

--------------------------------------------------------------------------- asserts

function M.assertEq(got, want, what)
    if got ~= want then
        error(string.format("%s: got %s, want %s", what or "value",
            tostring(got), tostring(want)), 2)
    end
end

function M.assertNear(got, want, what)
    if type(got) ~= "number" or math.abs(got - want) > 1e-4 then
        error(string.format("%s: got %s, want ~%s", what or "value",
            tostring(got), tostring(want)), 2)
    end
end

function M.assertTrue(cond, what)
    if not cond then error(what or "expected true", 2) end
end

---------------------------------------------------------------------------- config

-- A known-good baseline so each spec only states what it is actually varying.
-- RefreshMs is 100 (the clamped minimum) so tick counts map to round numbers of
-- simulated milliseconds against the mod's 1000ms intervals.
function M.cfg(over)
    local c = {
        ShowHealth = true, ShowMaxHealth = true, ShowLevel = true,
        Decimals = 0, RefreshMs = 100,
        LevelStyle = "diamond",
        ColorByDifficulty = true, ColorTarget = "rim",
    }
    for k, v in pairs(over or {}) do c[k] = v end
    return c
end

---------------------------------------------------------------------------- runner

function M.newRunner()
    local print = M.print
    local passed, failed = 0, {}

    local runner = {}

    function runner.test(name, fn)
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

    -- Returns a process exit code.
    function runner.report()
        print("")
        print(string.format("%d passed, %d failed", passed, #failed))
        if #failed == 0 then return 0 end
        print("")
        for _, f in ipairs(failed) do print("FAILED: " .. f.name) end
        return 1
    end

    return runner
end

return M
