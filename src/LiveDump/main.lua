-- LiveDump - press a key in-game, get a readable structure dump of whatever classes
-- config.lua names. Reads only; nothing here modifies the game.
--
-- See README.md for why the safe/risky split exists. Short version: pcall does not
-- catch an access violation inside UE4SS, so this tool is deliberately conservative
-- about what it dereferences, and logs each step so a crash names the culprit.

local TAG = "[LiveDump] "
local function log(s) print(TAG .. tostring(s) .. "\n") end

local dok, dump = pcall(require, "dump")
if not dok or type(dump) ~= "table" then
    log("FATAL: dump.lua missing or invalid; utility disabled")
    return
end

local cok, cfg = pcall(require, "config")
if not cok or type(cfg) ~= "table" then
    log("config.lua missing or invalid; falling back to defaults")
    cfg = {}
end

local function opt(k, d) local v = cfg[k] if v == nil then return d end return v end

local KEY        = tostring(opt("Key", "F8"))
local TARGETS    = opt("Targets", {})
local FOLLOW     = opt("Follow", {})
local STEP_LOG   = opt("StepLog", true)
local OUTPUT_DIR = tostring(opt("OutputDir", "ue4ss\\"))

local OPTS = {
    structure     = opt("DumpStructure", true),
    widgetTree    = opt("DumpWidgetTree", true),
    scalars       = opt("Scalars", {}),
    maxFunctions  = tonumber(opt("MaxFunctions", 150)) or 150,
    maxProperties = tonumber(opt("MaxProperties", 200)) or 200,
    maxTreeDepth  = tonumber(opt("MaxTreeDepth", 12)) or 12,
}

-- Goes to UE4SS.log, which is flushed and so survives a crash. Anything that might
-- fault announces itself here first, turning the log into a breadcrumb trail.
local function step(s)
    if STEP_LOG then log("STEP: " .. tostring(s)) end
end

local function safe(fn) local o, r = pcall(fn) if o then return r end return nil end

---------------------------------------------------------------------------- the dump

local function runDump()
    if #TARGETS == 0 then
        log("no Targets configured - nothing to dump")
        return
    end

    local report = dump.newReport()
    report.add("LiveDump report")
    report.add(os.date("%Y-%m-%d %H:%M:%S"))
    report.add("targets: " .. table.concat(TARGETS, ", "))

    local total = 0

    for _, className in ipairs(TARGETS) do
        step("finding " .. className)
        local found = dump.findAll(className)

        if #found == 0 then
            report.add("")
            report.add("== " .. className .. " ==")
            report.add("  no live instances found")
            log(className .. ": no live instances")
        else
            total = total + #found
            dump.summarise(className, found, report)

            -- Structure is per class, so the first instance is representative.
            step("introspecting " .. className)
            dump.object(found[1], className, report, OPTS)
            step("  done " .. className)

            -- Following out to other classes is the risky part, so it is opt-in, done
            -- one named property at a time, and logged before each attempt.
            for _, propName in ipairs(FOLLOW) do
                step("following " .. className .. "." .. propName)
                local child = safe(function() return found[1][propName] end)
                if dump.valid(child) then
                    step("  reached " .. propName .. " -> " .. dump.classOf(child))
                    dump.object(child, className .. "." .. propName, report, OPTS)
                    step("  done " .. propName)
                else
                    step("  " .. propName .. " not available")
                    report.add("")
                    report.add("== " .. className .. "." .. propName .. " ==")
                    report.add("  not set or not an object right now")
                end

                -- Flushed after each followed object, so a crash still leaves a file
                -- showing how far it got even if the log is lost.
                dump.write(OUTPUT_DIR .. "LiveDump_partial.txt", report)
            end
        end
    end

    local path = OUTPUT_DIR .. "LiveDump_" .. os.date("%H%M%S") .. ".txt"
    if dump.write(path, report) then
        log(string.format("wrote %s (%d instances, %d lines)", path, total, #report.lines))
    else
        log("could not write " .. path .. "; dumping to log instead")
        for _, line in ipairs(report.lines) do log(line) end
    end
end

--------------------------------------------------------------------------- keybind

local keyId = Key and Key[KEY]
if keyId == nil then
    log("FATAL: unknown key '" .. KEY .. "'; see Mods/Keybinds/Scripts/main.lua for valid names")
    return
end

RegisterKeyBind(keyId, function()
    -- UObject work has to happen on the game thread.
    ExecuteInGameThread(function()
        local ok, err = pcall(runDump)
        if not ok then log("dump failed: " .. tostring(err)) end
    end)
end)

log(string.format("loaded - press %s to dump: %s", KEY,
    #TARGETS > 0 and table.concat(TARGETS, ", ") or "(no targets configured)"))
