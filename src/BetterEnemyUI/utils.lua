-- Generic UE4SS / UMG plumbing, with no knowledge of this mod's config or widgets.
-- Anything that knows a game-specific property name belongs in main.lua, not here.
--
-- The two stateful helpers are factories rather than module-level caches, so this
-- module holds no mutable state and reloading it cannot leak state between runs.

local M = {}

--------------------------------------------------------------------------- modules

-- Requires a module and checks its shape, reporting through `log` instead of throwing.
-- The shape check matters: a module that forgets its `return` yields `true`, which
-- slips past a bare nil check and then dies confusingly at the first field access.
--
-- utils itself cannot be loaded this way, for obvious reasons - that one require stays
-- a bootstrap in main.lua.
function M.need(name, kind, log)
    local o, m = pcall(require, name)
    if o and type(m) == kind then return m end
    log("FATAL: " .. name .. ".lua missing or invalid; mod disabled")
    return nil
end

------------------------------------------------------------------ protected access

-- Reading a UObject property can throw if the property is absent or the object died,
-- so every read goes through one of these.

-- Closure form. Convenient, but allocates a closure per call to capture arguments -
-- use it for one-off build work, not on the per-tick path.
function M.safe(fn)
    local o, r = pcall(fn)
    if o then return r end
    return nil
end

-- Argument-passing form. Used with the shared accessors below so that hot-path reads
-- allocate nothing.
function M.try(fn, a, b)
    local o, r = pcall(fn, a, b)
    if o then return r end
    return nil
end

-- As `try`, for accessors returning two values.
function M.try2(fn, a)
    local o, r, s = pcall(fn, a)
    if o then return r, s end
    return nil
end

------------------------------------------------------------------------- accessors

-- Shared, non-capturing. Pass to try/try2 rather than wrapping in a closure.
function M.getProp(o, k) return o[k] end
function M.callFn(o, k) return o[k](o) end
function M.isVisible(o) return o:IsVisible() end
function M.getAddress(o) return o:GetAddress() end
function M.getFullName(o) return o:GetFullName() end
function M.removeFromParent(w) w:RemoveFromParent() end
function M.setVisibility(w, v) w:SetVisibility(v) end
function M.setText(w, s) w:SetText(FText(s)) end

function M.setColor(w, c)
    w:SetColorAndOpacity({ SpecifiedColor = { R = c.R, G = c.G, B = c.B, A = 1 }, ColorUseRule = 0 })
end

function M.setBrush(w, c, a)
    w:SetBrushColor({ R = c.R, G = c.G, B = c.B, A = a or c.A or 1 })
end

---------------------------------------------------------------------------- config

-- Clamped readers for user-supplied values. `d` is both the fallback for anything
-- non-numeric and, deliberately, not clamped itself - a bad default is a code bug, not
-- a config one.
function M.clampInt(v, d, lo, hi)
    return math.max(lo, math.min(hi, math.floor(tonumber(v) or d)))
end

function M.clampNum(v, d, lo, hi)
    return math.max(lo, math.min(hi, tonumber(v) or d))
end

-- Case-insensitive enum check. An unrecognised value is reported and replaced rather
-- than passed through, because a typo that silently picks a different branch is the
-- worst outcome for a hand-edited config file.
function M.oneOf(v, allowed, default, log, label)
    local s = tostring(v):lower()
    if allowed[s] then return s end
    log("unknown " .. label .. " '" .. s .. "'; using " .. default)
    return default
end

--------------------------------------------------------------------------- testing

function M.valid(o)
    return o ~= nil and o.IsValid ~= nil and o:IsValid()
end

function M.num(v)
    if type(v) == "number" then return v end
    return nil
end

------------------------------------------------------------------------------ UMG

-- ESlateVisibility
M.VIS_VISIBLE           = 0
M.VIS_COLLAPSED         = 1
M.VIS_HIDDEN            = 2
M.VIS_HITTESTINVISIBLE  = 3

-- EHorizontalAlignment / EVerticalAlignment
M.ALIGN_FILL   = 0
M.ALIGN_LEFT   = 1
M.ALIGN_CENTER = 2
M.ALIGN_RIGHT  = 3

function M.findChild(parent, name)
    local n = M.safe(function() return parent:GetChildrenCount() end) or 0
    for i = 0, n - 1 do
        local c = M.safe(function() return parent:GetChildAt(i) end)
        if M.valid(c) and M.safe(function() return c:GetFName():ToString() end) == name then
            return c
        end
    end
    return nil
end

-- Positive offsets push right, negative push left, regardless of which edge the slot
-- is anchored to.
function M.padOverlaySlot(slot, align, offsetX)
    pcall(function() slot:SetHorizontalAlignment(align) end)
    pcall(function() slot:SetVerticalAlignment(M.ALIGN_CENTER) end)
    if align == M.ALIGN_RIGHT then
        pcall(function() slot:SetPadding({ Left = 0, Top = 0, Right = -offsetX, Bottom = 0 }) end)
    else
        pcall(function() slot:SetPadding({ Left = offsetX, Top = 0, Right = 0, Bottom = 0 }) end)
    end
end

-- Returns a lookup for /Script/UMG.<name> classes, cached per instance.
function M.umgCache()
    local cache = {}
    return function(name)
        local c = cache[name]
        if M.valid(c) then return c end
        c = StaticFindObject("/Script/UMG." .. name)
        cache[name] = c
        if M.valid(c) then return c end
        return nil
    end
end

--------------------------------------------------------------------------- logging

-- Returns `log` and `once` bound to a tag. `once` keeps its own seen-set, so distinct
-- loggers do not silence each other.
function M.logger(tag)
    local said = {}

    local function log(s)
        print(tag .. tostring(s) .. "\n")
    end

    local function once(key, s)
        if said[key] then return end
        said[key] = true
        log(s)
    end

    return log, once
end

return M
