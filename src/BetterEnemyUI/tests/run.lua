-- Test suite entry point.
--
--   lua tests/run.lua
--   MOD_MAIN=<path-to-main.lua> lua tests/run.lua   run against another copy of the mod
--   ECHO_MOD_LOG=1 lua tests/run.lua                also print the mod's own log lines
--
-- Each spec is a function of (mock, run, support) that registers and runs its tests
-- immediately, so ordering is explicit and there is no global registry to reason about.

local here = (arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/?.lua;" .. package.path

local support = require("support")
local mock = require("mock_ue4ss")

mock.MAIN_PATH = os.getenv("MOD_MAIN") or (here .. "/../main.lua")

local SPECS = {
    "spec_health",    -- the readout itself: format, change detection, throttling
    "spec_defects",   -- regressions for the four original defects
    "spec_lifecycle", -- discovery, gating, teardown, dead bars
    "spec_styles",    -- config-driven appearance: badge styles, colours, alignment
}

local run = support.newRunner()

for _, name in ipairs(SPECS) do
    support.print("-- " .. name)
    require(name)(mock, run, support)
end

os.exit(run.report())
