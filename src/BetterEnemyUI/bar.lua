-- One tracked WBP_CombatCharacterBar_C, and everything that knows how to read or
-- decorate one. Discovery, scheduling and the tick loop live in main.lua.
--
-- Returns a factory so that config and the logger are injected rather than reached for:
--   local Bar = require("bar")({ config = ..., log = ..., once = ... })
--
-- `now` is passed into refresh rather than read from a shared clock, which keeps the
-- time dependency explicit and testable.

local utils = require("utils")

local safe, try, try2 = utils.safe, utils.try, utils.try2
local valid, num = utils.valid, utils.num
local findChild, padOverlaySlot = utils.findChild, utils.padOverlaySlot
local getProp, callFn = utils.getProp, utils.callFn
local isVisible, getAddress, getFullName = utils.isVisible, utils.getAddress, utils.getFullName
local setText, setVisibility = utils.setText, utils.setVisibility
local setColor, setBrush = utils.setColor, utils.setBrush
local removeFromParent = utils.removeFromParent

local VIS_COLLAPSED, VIS_HITTESTINVISIBLE = utils.VIS_COLLAPSED, utils.VIS_HITTESTINVISIBLE
local ALIGN_FILL, ALIGN_CENTER = utils.ALIGN_FILL, utils.ALIGN_CENTER

local HP_NAME, BOX_NAME, LVL_NAME = "EI_HealthText", "EI_LevelBox", "EI_LevelText"
local STACK_NAME, RIM_NAME, FILL_NAME = "EI_LevelStack", "EI_LevelRim", "EI_LevelFill"

--------------------------------------------------------------- game-specific reads

-- Returns the pawn on success, `false` when the widget definitively has no live target,
-- and (via a thrown error) nil when the read itself failed. That distinction matters:
-- an unbound bar must forget its target, but a transient read failure must not.
local function probeTarget(widget)
    local t = widget["Target Character"]
    if t == nil or t.IsValid == nil or not t:IsValid() then return false end
    local o, a = pcall(getAddress, t)
    if not o or a == nil then
        o, a = pcall(getFullName, t)
    end
    return t, (o and a) or nil
end

--------------------------------------------------------------------------- factory

return function(deps)
    local C = deps.config
    local log, once = deps.log, deps.once
    local umg = utils.umgCache()

    local SHOW_HP, SHOW_MAX, SHOW_LVL = C.showHealth, C.showMax, C.showLevel
    local HP_SIZE, HP_ALIGN, HP_OFFSET = C.hpSize, C.hpAlign, C.hpOffset
    local LVL_PREFIX, LVL_SIZE, LVL_ALIGN, LVL_OFFSET = C.lvlPrefix, C.lvlSize, C.lvlAlign, C.lvlOffset
    local STYLE, BOX_SIZE, PLATE_W, RIM, BG = C.style, C.boxSize, C.plateWidth, C.rimThickness, C.bgColor
    local COLORIZE, C_TARGET = C.colorize, C.colorTarget
    local C_EQUAL, C_SLIGHT, C_MUCH, C_CRIT, C_TEXT = C.cEqual, C.cSlight, C.cMuch, C.cCrit, C.cText
    local LEVEL_INTERVAL, MAX_HP_INTERVAL = C.levelIntervalMs, C.maxHpIntervalMs
    local LOW_FLASH, LOW_COLOR = C.lowFlash, C.lowColor
    -- Precomputed once: the per-tick path multiplies rather than dividing.
    local LOW_FRACTION = C.lowPercent / 100
    local LOW_HALF_MS = math.max(1, math.floor(C.lowPeriodMs / 2))

    local FMT = "%." .. C.decimals .. "f"

    local function styleText(tb, size)
        pcall(function() tb.Font.Size = size end)
        -- TextColor rather than hardcoded white: the health readout never honoured the
        -- option before, and the low-health flash needs a base colour to return to.
        pcall(setColor, tb, C_TEXT)
        pcall(function() tb:SetShadowOffset({ X = 1, Y = 1 }) end)
        pcall(function() tb:SetShadowColorAndOpacity({ R = 0, G = 0, B = 0, A = 0.9 }) end)
        pcall(function() tb:SetVisibility(VIS_HITTESTINVISIBLE) end)
        pcall(function() tb:SetJustification(ALIGN_CENTER) end)
    end

    local function colorFor(delta)
        if not COLORIZE or delta == nil then return C_EQUAL end
        if delta >= 9 then return C_CRIT end
        if delta >= 6 then return C_MUCH end
        if delta >= 4 then return C_SLIGHT end
        return C_EQUAL
    end

    ------------------------------------------------------------------------- Bar

    -- State is grouped by what owns its lifetime: `target` is everything derived from
    -- the current enemy and is dropped wholesale when the bar is re-pointed, `ui` is
    -- the widgets we injected and lives as long as the bar does, `shown` is what is
    -- currently painted.
    local Bar = {}
    Bar.__index = Bar

    function Bar.new(widget, key)
        return setmetatable({
            widget = widget,
            key = key,
            fails = 0,
            showing = nil, -- tri-state: nil = not decided yet
            lvlAt = nil,
            maxAt = nil,
            target = {}, -- pawn, id, attr, health, max, indicator
            ui = {},     -- hp, box, lvl, rim, pending
            shown = {},  -- hp, cur, max, suffix, lvl, delta
        }, Bar)
    end

    -- Forgets what is on screen without touching the widgets themselves, so the next
    -- update repaints from scratch. Clearing the interval stamps re-reads the level and
    -- the health ceiling now rather than up to an interval from now.
    function Bar:forgetPainted()
        local s = self.shown
        s.hp, s.cur, s.max, s.suffix, s.lvl, s.delta, s.flash = nil, nil, nil, nil, nil, nil, nil
        self.lvlAt, self.maxAt = nil, nil
    end

    -- Drops every read derived from the current target. This is the seam a hook on
    -- `Attach To Pawn` / `Update Target Character` calls directly, which is why it is a
    -- named method rather than inlined field clearing.
    function Bar:invalidateTarget()
        local t = self.target
        t.pawn, t.id, t.attr, t.health, t.max, t.indicator = nil, nil, nil, nil, nil, nil
        self:forgetPainted()
    end

    -- True when the bar has a live target. These bars are pooled: one gets hidden and
    -- re-shown pointed at a different enemy while the previous character is still
    -- valid, so until something pushes that change to us, identity is re-checked every
    -- tick.
    function Bar:syncTarget()
        local pawn, id = try2(probeTarget, self.widget)

        if pawn == false then
            -- The widget told us it has no live target. Forget ours rather than keep
            -- painting numbers for whoever this pooled bar was bound to before.
            if self.target.pawn ~= nil then self:invalidateTarget() end
            return false
        end

        -- pawn == nil means the read itself failed; keep the last known target.
        if pawn ~= nil and (id == nil or id ~= self.target.id) then
            self:invalidateTarget()
            self.target.pawn = pawn
            self.target.id = id
        end
        return valid(self.target.pawn)
    end

    -- Shows or collapses only the widgets we injected, leaving the game's own bar
    -- alone. Transitions only, so a steady state costs nothing.
    function Bar:setShown(on)
        if self.showing == on then return end
        self.showing = on

        local ui = self.ui
        local vis = on and VIS_HITTESTINVISIBLE or VIS_COLLAPSED
        if valid(ui.hp) then pcall(setVisibility, ui.hp, vis) end
        if valid(ui.box) then
            pcall(setVisibility, ui.box, vis)
        elseif valid(ui.lvl) then
            pcall(setVisibility, ui.lvl, vis) -- STYLE == "none", no box to collapse
        end

        if not on then
            -- Otherwise re-showing a pooled bar trusts text that may belong to whoever
            -- it was pointed at before, for one tick.
            self:forgetPainted()
        end
    end

    -- Detaches everything we injected, leaving the bar as we found it. A widget that
    -- has already gone invalid is left alone: RemoveFromParent on a dead UObject is at
    -- best a no-op, and UMG has already dropped it from the tree.
    function Bar:teardown()
        local ui = self.ui
        -- Removing a top-level injected widget takes its subtree with it, so the rim,
        -- fill and stack need no separate handling.
        if valid(ui.hp) then pcall(removeFromParent, ui.hp) end
        if valid(ui.box) then
            pcall(removeFromParent, ui.box)
        elseif valid(ui.lvl) then
            pcall(removeFromParent, ui.lvl)
        end
        -- Drop our references too, including any parked unattached widgets, so nothing
        -- we built outlives the entry.
        self.ui = {}
        self.showing = nil
        self:invalidateTarget()
    end

    function Bar:host()
        local widget = self.widget
        local seg = safe(function() return widget.SegmentedHealthBar end)
        if not valid(seg) then return nil end
        local box = safe(function() return seg:GetParent() end)
        if not valid(box) then return nil end
        local ov = safe(function() return box:GetParent() end)
        if valid(ov) then return ov end
        return nil
    end

    -- A widget we constructed but failed to attach is not reachable by findChild, so a
    -- naive retry would construct a fresh one every tick. Park unattached widgets on
    -- the bar and reuse them until they land.
    function Bar:construct(clsName, objName)
        local pending = self.ui.pending
        if pending then
            local prev = pending[objName]
            if valid(prev) then return prev end
            pending[objName] = nil
        end

        local cls = umg(clsName)
        if not cls then once("cls" .. clsName, "UMG." .. clsName .. " not found") return nil end

        local widget = self.widget
        local tree = safe(function() return widget.WidgetTree end)
        local w = safe(function() return StaticConstructObject(cls, valid(tree) and tree or widget, FName(objName)) end)
        if not valid(w) then once("ctor" .. clsName, "could not construct " .. clsName) return nil end

        self.ui.pending = pending or {}
        self.ui.pending[objName] = w
        return w
    end

    function Bar:settle(...)
        local pending = self.ui.pending
        if not pending then return end
        for _, n in ipairs({ ... }) do pending[n] = nil end
    end

    function Bar:buildHealth(host)
        local existing = findChild(host, HP_NAME)
        if valid(existing) then return existing end
        local tb = self:construct("TextBlock", HP_NAME)
        if not valid(tb) then return nil end
        styleText(tb, HP_SIZE)
        local slot = safe(function() return host:AddChildToOverlay(tb) end)
        if not valid(slot) then once("hpslot", "could not slot health text") return nil end
        padOverlaySlot(slot, HP_ALIGN, HP_OFFSET)
        self:settle(HP_NAME)
        return tb
    end

    -- Looks for a badge we built earlier - on a previous tick, or a previous session.
    -- Returns the level text and rim if one is complete, `false` if an incomplete one is
    -- stuck in the tree and must not be rebuilt around, or nil to build fresh.
    function Bar:adoptBadge(host)
        local box = findChild(host, BOX_NAME)
        if not valid(box) then return nil end

        local stack = safe(function() return box:GetChildAt(0) end)
        if valid(stack) then
            local tb = findChild(stack, LVL_NAME)
            if valid(tb) then
                self.ui.box = box
                return tb, findChild(stack, RIM_NAME)
            end
        end

        -- A box whose innards are incomplete would be found again next tick and we
        -- would slot a second box beside it, forever. Detach it and rebuild.
        pcall(removeFromParent, box)
        if valid(safe(function() return box:GetParent() end)) then
            once("boxstuck", "could not detach incomplete level badge")
            return false
        end
        return nil
    end

    -- STYLE == "none": the level text goes straight onto the host, no badge around it.
    function Bar:buildBareLevel(host)
        local tb = self:construct("TextBlock", LVL_NAME)
        if not valid(tb) then return nil end
        styleText(tb, LVL_SIZE)
        local slot = safe(function() return host:AddChildToOverlay(tb) end)
        if not valid(slot) then return nil end
        padOverlaySlot(slot, LVL_ALIGN, LVL_OFFSET)
        self:settle(LVL_NAME)
        return tb
    end

    -- The badge outline, with the dark fill nested inside it. Returns nil if the rim
    -- could not be built; the caller treats that as cosmetic and carries on.
    function Bar:buildRim(stack, diamond)
        local rim = self:construct("Border", RIM_NAME)
        if not valid(rim) then return nil end

        pcall(function() rim:SetBrushColor({ R = C_EQUAL.R, G = C_EQUAL.G, B = C_EQUAL.B, A = 1 }) end)
        pcall(function() rim:SetPadding({ Left = RIM, Top = RIM, Right = RIM, Bottom = RIM }) end)
        pcall(function() rim:SetVisibility(VIS_HITTESTINVISIBLE) end)
        if diamond then pcall(function() rim:SetRenderTransformAngle(45.0) end) end

        local rs = safe(function() return stack:AddChildToOverlay(rim) end)
        if valid(rs) then
            pcall(function() rs:SetHorizontalAlignment(ALIGN_FILL) end)
            pcall(function() rs:SetVerticalAlignment(ALIGN_FILL) end)
        end

        local fill = self:construct("Border", FILL_NAME)
        if valid(fill) then
            pcall(function() fill:SetBrushColor({ R = BG.R, G = BG.G, B = BG.B, A = BG.A or 1 }) end)
            pcall(function() fill:SetVisibility(VIS_HITTESTINVISIBLE) end)
            pcall(function() rim:AddChild(fill) end)
        end
        return rim
    end

    function Bar:buildBadge(host)
        local adopted, adoptedRim = self:adoptBadge(host)
        if adopted == false then return nil end
        if valid(adopted) then return adopted, adoptedRim end

        if STYLE == "none" then return self:buildBareLevel(host) end

        local diamond = (STYLE == "diamond")
        local box = self:construct("SizeBox", BOX_NAME)
        if not valid(box) then return nil end
        pcall(function() box:SetWidthOverride(diamond and BOX_SIZE or PLATE_W) end)
        pcall(function() box:SetHeightOverride(BOX_SIZE) end)
        pcall(function() box:SetVisibility(VIS_HITTESTINVISIBLE) end)

        local boxSlot = safe(function() return host:AddChildToOverlay(box) end)
        if not valid(boxSlot) then once("boxslot", "could not slot level badge") return nil end
        padOverlaySlot(boxSlot, LVL_ALIGN, LVL_OFFSET)
        self.ui.box = box

        local stack = self:construct("Overlay", STACK_NAME)
        if not valid(stack) then return nil end
        local ss = safe(function() return box:AddChild(stack) end)
        if valid(ss) then
            pcall(function() ss:SetHorizontalAlignment(ALIGN_FILL) end)
            pcall(function() ss:SetVerticalAlignment(ALIGN_FILL) end)
        end

        local rim = self:buildRim(stack, diamond)

        local tb = self:construct("TextBlock", LVL_NAME)
        if not valid(tb) then return nil end
        styleText(tb, LVL_SIZE)
        local ts = safe(function() return stack:AddChildToOverlay(tb) end)
        if valid(ts) then
            pcall(function() ts:SetHorizontalAlignment(ALIGN_CENTER) end)
            pcall(function() ts:SetVerticalAlignment(ALIGN_CENTER) end)
        end

        self:settle(BOX_NAME, STACK_NAME, RIM_NAME, FILL_NAME, LVL_NAME)
        once("badge", "level badge built (" .. STYLE .. ")")
        return tb, rim
    end

    function Bar:ensureWidgets()
        local ui = self.ui
        local needHp  = SHOW_HP  and not valid(ui.hp)
        local needLvl = SHOW_LVL and not valid(ui.lvl)
        if not (needHp or needLvl) then return end

        local host = self:host()
        if not valid(host) then return end

        if needHp then
            ui.hp = self:buildHealth(host)
            self.shown.hp = nil
        end
        if needLvl then
            ui.lvl, ui.rim = self:buildBadge(host)
            -- Resolve the fill from the rim, so both the freshly-built and the adopted
            -- badge paths end up with the same handles.
            ui.fill = valid(ui.rim) and findChild(ui.rim, FILL_NAME) or nil
            self.shown.lvl, self.shown.delta = nil, nil
        end

        -- Anything just built has not been through setShown, so make it re-apply rather
        -- than leaving visibility to whatever the build path happened to set.
        self.showing = nil
    end

    -- Resolves the target's attribute set and caches the two attribute objects, so the
    -- per-tick path is a property read on each rather than a walk from the pawn.
    function Bar:resolveAttributes()
        local t = self.target
        local pawn = t.pawn
        local set = safe(function() return pawn.CharacterAttributeSet end)
        if not valid(set) then
            -- All three together: leaving health/max pointing at a previous set is not
            -- reachable today, but a partial invalidation is a trap for later.
            t.attr, t.health, t.max = nil, nil, nil
            return false
        end
        t.attr = set
        t.health = try(getProp, set, "Health")
        t.max    = try(getProp, set, "MaxHealth")
        self.maxAt = nil -- new attribute set, re-read the ceiling
        return true
    end

    function Bar:updateHealth(now)
        local ui, t, shown = self.ui, self.target, self.shown
        if not valid(ui.hp) then return end

        -- Dispatch only when the cache is cold; the steady-state tick skips the call.
        if not valid(t.attr) and not self:resolveAttributes() then return end

        local cur = valid(t.health) and num(try(getProp, t.health, "CurrentValue"))
        if not cur then return end

        -- Max health is static within an engagement, but multi-phase fights disengage
        -- and re-engage with buffed stats, so it is re-read on an interval rather than
        -- cached once. The formatted denominator is rebuilt only when the value moves,
        -- leaving the steady-state tick one format and one concat.
        if shown.max == nil or now - (self.maxAt or -99999) >= MAX_HP_INTERVAL then
            local mx = valid(t.max) and num(try(getProp, t.max, "CurrentValue"))
            if mx and mx > 0 then
                self.maxAt = now
                if mx ~= shown.max then
                    shown.max = mx
                    shown.suffix = SHOW_MAX and (" / " .. string.format(FMT, mx)) or ""
                    shown.cur = nil -- force a repaint against the new denominator
                end
            end
        end
        if shown.max == nil then return end

        if cur ~= shown.cur then
            shown.cur = cur
            local s = string.format(FMT, cur) .. shown.suffix
            if s ~= shown.hp then
                shown.hp = s
                pcall(setText, ui.hp, s)
            end
        end
    end

    function Bar:applyColor(delta)
        local c = colorFor(delta)
        local ui = self.ui
        if valid(ui.rim) and (C_TARGET == "rim" or C_TARGET == "both") then
            pcall(function() ui.rim:SetBrushColor({ R = c.R, G = c.G, B = c.B, A = 1 }) end)
        end
        local t = (C_TARGET == "text" or C_TARGET == "both") and c or C_TEXT
        if valid(ui.lvl) then pcall(setColor, ui.lvl, t) end
    end

    -- Below one segment's worth of health the game's own bar has run out of resolution:
    -- 1 HP and dead render identically, which is the "why is he still standing" window.
    -- Deriving the threshold from the segment count rather than picking a percentage is
    -- what makes this a legibility fix instead of a preference.
    --
    -- Phase comes from the shared clock, so every low bar blinks in step; independent
    -- timers would read as static in a camp fight. The hard on/off is deliberate - at
    -- this tick rate a fade would visibly step, and peripheral vision picks up
    -- luminance transients far better than hue.
    function Bar:updateLowHealth(now)
        local ui, shown = self.ui, self.shown
        if not valid(ui.hp) then return end

        local low = LOW_FLASH
            and shown.cur ~= nil and shown.max ~= nil
            and shown.cur > 0
            and shown.cur < (shown.max * LOW_FRACTION)

        local on = (low and math.floor(now / LOW_HALF_MS) % 2 == 0) or false
        if on == shown.flash then return end -- transitions only
        shown.flash = on

        if on then once("lowflash", "low-health flash engaged") end

        pcall(setColor, ui.hp, on and LOW_COLOR or C_TEXT)

        -- The badge fill is the real peripheral target: a solid block going from near
        -- black to saturated is a far larger luminance transient than recolouring thin
        -- glyphs, which is what the eye actually catches off-centre.
        if valid(ui.fill) then
            if on then
                pcall(setBrush, ui.fill, LOW_COLOR, 1)
            else
                pcall(setBrush, ui.fill, BG, BG.A or 1)
            end
        end
    end

    -- Throttled separately from health: these are Blueprint calls, far more expensive
    -- than the attribute property reads, and a level cannot change as fast as a health
    -- pool.
    function Bar:updateLevel(now)
        local ui, t, shown = self.ui, self.target, self.shown
        if not valid(ui.lvl) then return end
        if now - (self.lvlAt or -99999) < LEVEL_INTERVAL then return end

        if not valid(t.indicator) then
            t.indicator = try(getProp, self.widget, "LevelIndicator")
        end
        local ind = t.indicator
        -- No stamp yet: an indicator the widget has not wired up would otherwise cost a
        -- full interval before the badge ever populates, and re-reading a nil property
        -- next tick is cheap. The stamp goes in below, before the Blueprint calls, so a
        -- failing call still backs off instead of throwing every tick.
        if not valid(ind) then return end
        self.lvlAt = now

        local lv = num(try(callFn, ind, "Get Enemy Level"))
        if not lv then return end

        local s = LVL_PREFIX .. tostring(math.floor(lv))
        if s ~= shown.lvl then
            shown.lvl = s
            pcall(setText, ui.lvl, s)
        end

        local d = num(try(callFn, ind, "Get Level Difference"))
        if d ~= shown.delta then
            shown.delta = d
            self:applyColor(d)
        end
    end

    function Bar:refresh(now)
        -- The game hides these bars itself when they are not wanted - the widget owns a
        -- `Should Combat Bar Be Visible` / `Unbind From Pawn And Hide` pair - so reading
        -- its visibility is both the out-of-combat gate and cheaper than asking again.
        if try(isVisible, self.widget) ~= true then self:setShown(false) return end
        if not self:syncTarget() then self:setShown(false) return end

        local ui = self.ui
        if (SHOW_HP and not valid(ui.hp)) or (SHOW_LVL and not valid(ui.lvl)) then
            self:ensureWidgets()
        end
        self:setShown(true)

        -- Protection sits at the section boundary rather than around every individual
        -- read: fewer protected calls, and health and level still fail independently.
        if SHOW_HP then
            pcall(Bar.updateHealth, self, now)
            -- Separately protected and unconditional, so the flash still clears itself
            -- if the health read stops working rather than latching on.
            pcall(Bar.updateLowHealth, self, now)
        end
        if SHOW_LVL then pcall(Bar.updateLevel, self, now) end
    end

    return Bar
end
