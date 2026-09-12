-- Fake UE4SS environment so main.lua can be exercised without launching the game.
--
-- main.lua hands its tick body to LoopAsync and does all UObject work inside
-- ExecuteInGameThread. We capture the former and run the latter inline, which turns
-- the mod into a synchronous function we can step one tick at a time.

local M = {}

local nextAddr = 0x1000
local function newAddr()
    nextAddr = nextAddr + 0x40
    return nextAddr
end

---------------------------------------------------------------------------- slots

local Slot = {}
Slot.__index = Slot

function Slot.new()
    return setmetatable({ _valid = true }, Slot)
end

function Slot:IsValid() return self._valid end
function Slot:SetHorizontalAlignment(a) self.hAlign = a end
function Slot:SetVerticalAlignment(a) self.vAlign = a end
function Slot:SetPadding(p) self.padding = p end

--------------------------------------------------------------------------- widgets

local W = {}
W.__index = W

function W.new(class, name)
    return setmetatable({
        _class = class,
        _name = name,
        _valid = true,
        _addr = newAddr(),
        _children = {},
        _parent = nil,
        Font = { Size = 0 },
    }, W)
end

function W:IsValid() return self._valid end
function W:GetAddress() return self._addr end
function W:GetFullName() return self._class .. " World.PersistentLevel." .. self._name .. "_" .. tostring(self._addr) end

function W:GetFName()
    local n = self._name
    return { ToString = function() return n end }
end

function W:GetParent() return self._parent end
function W:GetChildrenCount() return #self._children end
function W:GetChildAt(i) return self._children[i + 1] end -- UMG child indices are 0-based

function W:IsVisible()
    if self._visible == nil then return true end
    return self._visible
end

-- Overlays and content widgets both go through here. `_failAdds` refuses the next N
-- attach attempts, which is how we simulate a host that is not ready yet.
local function attach(self, child)
    if self._failAdds and self._failAdds > 0 then
        self._failAdds = self._failAdds - 1
        return nil
    end
    child._parent = self
    self._children[#self._children + 1] = child
    -- Hang the slot off the child so tests can inspect alignment and padding, which
    -- are otherwise unreachable once the mod drops its reference to the slot.
    local slot = Slot.new()
    child._slot = slot
    return slot
end

W.AddChildToOverlay = attach
W.AddChild = attach

function W:RemoveFromParent()
    local p = self._parent
    if not p then return end
    for i, c in ipairs(p._children) do
        if c == self then
            table.remove(p._children, i)
            break
        end
    end
    self._parent = nil
end

function W:SetText(v)
    self._text = (type(v) == "table" and v.str) or tostring(v)
end

for _, name in ipairs({
    "SetColorAndOpacity", "SetShadowOffset", "SetShadowColorAndOpacity", "SetVisibility",
    "SetJustification", "SetWidthOverride", "SetHeightOverride", "SetBrushColor",
    "SetPadding", "SetRenderTransformAngle",
}) do
    W[name] = function(self, v) self["_" .. name] = v end
end

M.Widget = W

------------------------------------------------------------------------ scene parts

-- A gameplay attribute. CurrentValue goes through __index so we can count reads and
-- assert that the mod is not polling a value it claims to throttle.
local function newAttribute(value)
    local store = { _reads = 0, _value = value }
    return setmetatable(store, {
        __index = function(t, k)
            if k == "CurrentValue" then
                t._reads = t._reads + 1
                return t._value
            end
            if k == "IsValid" then return function() return true end end
            return nil
        end,
        __newindex = function(t, k, v)
            if k == "CurrentValue" then t._value = v else rawset(t, k, v) end
        end,
    })
end

-- A character whose attribute set exposes Health/MaxHealth the way the game's does.
function M.newCharacter(name, hp, maxHp)
    local attr = W.new("CharacterAttributeSet", name .. "_Attrs")
    attr.Health = newAttribute(hp)
    attr.MaxHealth = newAttribute(maxHp)

    local c = W.new("BP_Enemy_C", name)
    c.CharacterAttributeSet = attr
    return c
end

-- Read count for one attribute, e.g. mock.readsOf(ch, "MaxHealth").
function M.readsOf(character, attrName)
    return character.CharacterAttributeSet[attrName]._reads
end

function M.newIndicator(level, delta)
    local ind = W.new("WBP_LevelIndicator_C", "LevelIndicator")
    ind._level, ind._delta = level, delta
    ind["Get Enemy Level"] = function(self) return self._level end
    ind["Get Level Difference"] = function(self) return self._delta end
    return ind
end

-- Mirrors the hierarchy host() walks: SegmentedHealthBar -> parent -> parent.
-- The returned bar exposes `_host`, the overlay the mod injects into.
function M.newBar(opts)
    local hostOverlay = W.new("Overlay", "HostOverlay")
    local innerBox = W.new("SizeBox", "HealthBarBox")
    local seg = W.new("WBP_SegmentedBar_C", "SegmentedHealthBar")
    hostOverlay:AddChildToOverlay(innerBox)
    innerBox:AddChild(seg)

    local bar = W.new("WBP_CombatCharacterBar_C", opts.name or "Bar")
    -- poisonHost makes host() throw: the mod reads SegmentedHealthBar under `safe` but
    -- then calls valid() on the result unprotected, so the error escapes refresh().
    bar.SegmentedHealthBar = opts.poisonHost and M.newPoison() or seg
    bar.WidgetTree = W.new("WidgetTree", "WidgetTree")
    bar.LevelIndicator = opts.indicator
    bar["Target Character"] = opts.character
    bar._host = hostOverlay
    return bar
end

-- Any property read on this throws, standing in for a stale/garbage UObject pointer.
function M.newPoison()
    return setmetatable({}, {
        __index = function() error("simulated stale property read") end,
    })
end

----------------------------------------------------------------------------- world

function M.newWorld()
    local world = {
        bars = {},           -- what FindAllOf returns, mutable mid-test
        constructed = {},    -- every StaticConstructObject attempt, including failures
        failConstruct = {},  -- object name -> true, makes construction return nil
        missingUMG = {},     -- UMG class name -> true, makes StaticFindObject return nil
        umgClasses = {},
        notifyShouldFail = false,
        notifyCb = nil,
        loopCb = nil,
        loopMs = nil,
        logs = {},
        echo = os.getenv("ECHO_MOD_LOG") == "1",
    }

    _G.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do
            parts[#parts + 1] = tostring((select(i, ...)))
        end
        local line = table.concat(parts, "\t")
        world.logs[#world.logs + 1] = line
        if world.echo then io.write("      | " .. line) end
    end

    _G.StaticFindObject = function(path)
        local cls = tostring(path):match("^/Script/UMG%.(.+)$")
        if not cls or world.missingUMG[cls] then return nil end
        if not world.umgClasses[cls] then
            world.umgClasses[cls] = {
                name = cls,
                _valid = true,
                IsValid = function(self) return self._valid end,
            }
        end
        return world.umgClasses[cls]
    end

    _G.StaticConstructObject = function(cls, outer, fname)
        local name = (type(fname) == "table" and fname.str) or "Unnamed"
        world.constructed[#world.constructed + 1] = {
            class = cls and cls.name or "?",
            name = name,
            outer = outer and outer._name or "?",
        }
        if world.failConstruct[name] then return nil end
        return W.new(cls and cls.name or "Unknown", name)
    end

    _G.FName = function(s) return { str = s, ToString = function() return s end } end
    _G.FText = function(s) return { str = s } end

    _G.FindAllOf = function(className)
        if className ~= "WBP_CombatCharacterBar_C" then return nil end
        local out = {}
        for _, b in ipairs(world.bars) do out[#out + 1] = b end
        return out
    end

    _G.NotifyOnNewObject = function(path, cb)
        if world.notifyShouldFail then error("simulated NotifyOnNewObject failure") end
        world.notifyCb = cb
    end

    _G.LoopAsync = function(ms, cb)
        world.loopMs = ms
        world.loopCb = cb
    end

    _G.ExecuteInGameThread = function(fn) fn() end

    world.tick = function(n)
        for _ = 1, (n or 1) do world.loopCb() end
    end

    -- Simulates the notify hook firing for a newly spawned bar.
    world.spawn = function(bar)
        world.bars[#world.bars + 1] = bar
        if world.notifyCb then world.notifyCb(bar) end
        return bar
    end

    return world
end

function M.loadMod(world, cfg)
    package.loaded.config = cfg or {}
    -- utils.lua sits next to main.lua; resolve it from there rather than from the
    -- process working directory, and reload it per test for isolation.
    local modDir = M.MAIN_PATH:match("^(.*)[/\\][^/\\]*$") or "."
    if not package.path:find(modDir .. "/?.lua", 1, true) then
        package.path = modDir .. "/?.lua;" .. package.path
    end
    package.loaded.utils = nil
    package.loaded.bar = nil

    local chunk, err = loadfile(M.MAIN_PATH)
    if not chunk then error("could not load " .. tostring(M.MAIN_PATH) .. ": " .. tostring(err)) end
    chunk()
    if not world.loopCb then error("main.lua never registered a LoopAsync callback") end
    return world
end

--------------------------------------------------------------------------- queries

function M.findChild(parent, name)
    for _, c in ipairs(parent._children) do
        if c._name == name then return c end
    end
    return nil
end

function M.countChildren(parent, name)
    local n = 0
    for _, c in ipairs(parent._children) do
        if c._name == name then n = n + 1 end
    end
    return n
end

function M.deepFind(root, name)
    if root._name == name then return root end
    for _, c in ipairs(root._children) do
        local found = M.deepFind(c, name)
        if found then return found end
    end
    return nil
end

function M.textOf(root, name)
    local w = M.deepFind(root, name)
    if not w then return nil end
    return w._text
end

function M.countConstructed(world, name)
    local n = 0
    for _, rec in ipairs(world.constructed) do
        if rec.name == name then n = n + 1 end
    end
    return n
end

function M.logged(world, substr)
    for _, line in ipairs(world.logs) do
        if line:find(substr, 1, true) then return true end
    end
    return false
end

return M
