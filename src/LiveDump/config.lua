-- What to dump. Nothing here is specific to any one mod or game - point Targets at
-- whatever class you want to inspect and press the key in-game.
return {
    -- Key to trigger a dump. Any name from Mods/Keybinds/Scripts/main.lua.
    Key = "F8",

    -- Classes to find, as UE knows them. FindAllOf is used, so every live instance is
    -- located and the first one is introspected; all of them are summarised.
    Targets = {
        "WBP_CombatCharacterBar_C",
    },

    -- Function and property *names* declared by the class, plus its parent chain.
    -- Safe: this reads reflection data, never a property value.
    DumpStructure = true,

    -- Walk the live widget tree, if the object has one. Marks hidden widgets and shows
    -- any text they hold, which is usually the fastest way to understand a UMG asset.
    DumpWidgetTree = true,

    -- Named properties to read live VALUES for. Safe only because they are named and
    -- their type is checked against a plain-old-data allowlist first. See README.
    Scalars = {
        "Health Segment Count",
    },

    -- Named object properties to follow and introspect as their own sections.
    --
    -- OPT-IN AND RISKY. Introspecting an unfamiliar class is what crashed the game
    -- three times while this tool was being written - see the crash notes in README.
    -- Leave empty unless you are willing to lose unsaved progress, and add one entry
    -- at a time so the step log tells you which one is unsafe.
    Follow = {},

    -- Announce each step to UE4SS.log before attempting it. A crash inside UE4SS is a
    -- hardware exception that no amount of pcall will catch, so the log is the only
    -- record of how far the dump got. Leave this on.
    StepLog = true,

    -- Bounds, so an unexpectedly large class cannot produce a useless 50k-line file.
    MaxFunctions  = 150,
    MaxProperties = 200,
    MaxTreeDepth  = 12,

    -- Where reports go, relative to the game's working directory.
    OutputDir = "ue4ss\\",
}
