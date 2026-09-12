	-- author: Caites

local TAG = "[EnemyInfo] "
local function log(s) print(TAG .. tostring(s) .. "\n") end

local ok, cfg = pcall(require, "config")
if not ok or type(cfg) ~= "table" then cfg = {} end
local function opt(k, d) local v = cfg[k] if v == nil then return d end return v end

local SHOW_HP    = opt("ShowHealth", true)
local SHOW_MAX   = opt("ShowMaxHealth", true)
local SHOW_LVL   = opt("ShowLevel", true)
local DECIMALS   = math.max(0, math.min(2, math.floor(tonumber(opt("Decimals", 0)) or 0)))
local HP_SIZE    = math.max(6, math.min(72, math.floor(tonumber(opt("HealthFontSize", 18)) or 18)))
local HP_ALIGN   = math.max(1, math.min(3, math.floor(tonumber(opt("HealthAlign", 2)) or 2)))
local HP_OFFSET  = tonumber(opt("HealthOffsetX", 0)) or 0
local LVL_PREFIX = tostring(opt("LevelPrefix", ""))
local LVL_SIZE   = math.max(6, math.min(72, math.floor(tonumber(opt("LevelFontSize", 15)) or 15)))
local LVL_ALIGN  = math.max(1, math.min(3, math.floor(tonumber(opt("LevelAlign", 1)) or 1)))
local LVL_OFFSET = tonumber(opt("LevelOffsetX", -44)) or -44
local STYLE      = tostring(opt("LevelStyle", "diamond")):lower()
local BOX_SIZE   = math.max(10, math.min(96, tonumber(opt("LevelBoxSize", 26)) or 26))
local PLATE_W    = math.max(10, math.min(160, tonumber(opt("LevelPlateWidth", 38)) or 38))
local RIM        = math.max(0, math.min(8, tonumber(opt("LevelRimThickness", 2)) or 2))
local BG         = opt("LevelBgColor", { R = 0.02, G = 0.018, B = 0.018, A = 0.88 })
local TICK       = math.max(100, math.min(1000, tonumber(opt("RefreshMs", 200)) or 200))
local COLORIZE   = opt("ColorByDifficulty", true)
local C_TARGET   = tostring(opt("ColorTarget", "rim")):lower()
local C_EQUAL    = opt("ColorEqual",    { R = 0.62, G = 0.60, B = 0.56 })
local C_SLIGHT   = opt("ColorSlightly", { R = 1, G = 0.64448, B = 0.036889 })
local C_MUCH     = opt("ColorMuch",     { R = 0.904661, G = 0.181164, B = 0.002125 })
local C_CRIT     = opt("ColorCritical", { R = 0.760525, G = 0.016807, B = 0.016807 })
local C_TEXT     = opt("TextColor", { R = 1, G = 1, B = 1 })

local FMT = "%." .. DECIMALS .. "f"
local BAR_PATH  = "/Game/_Dawnwalker/UI/_Unified/Combat/WBP_CombatCharacterBar.WBP_CombatCharacterBar_C"
local BAR_CLASS = "WBP_CombatCharacterBar_C"
local HP_NAME, BOX_NAME, LVL_NAME = "EI_HealthText", "EI_LevelBox", "EI_LevelText"
local VIS_HITTESTINVISIBLE = 3
local LEVEL_INTERVAL = 1000

local function safe(fn) local o, r = pcall(fn) if o then return r end return nil end
local function valid(o) return o ~= nil and o.IsValid ~= nil and o:IsValid() end
local function num(v) if type(v) == "number" then return v end return nil end

local bars, tracked = {}, {}
local nowMs, lastSweep, inFlight = 0, -99999, false
local notified, said = false, {}
local function once(k, s) if not said[k] then said[k] = true log(s) end end

local UMG = {}
local function umg(name)
    local c = UMG[name]
    if valid(c) then return c end
    c = StaticFindObject("/Script/UMG." .. name)
    UMG[name] = c
    return valid(c) and c or nil
end

local function host(bar)
    local hp = safe(function() return bar.SegmentedHealthBar end)
    if not valid(hp) then return nil end
    local box = safe(function() return hp:GetParent() end)
    if not valid(box) then return nil end
    local ov = safe(function() return box:GetParent() end)
    if valid(ov) then return ov end
    return nil
end

local function findChild(parent, name)
    local n = safe(function() return parent:GetChildrenCount() end) or 0
    for i = 0, n - 1 do
        local c = safe(function() return parent:GetChildAt(i) end)
        if valid(c) and safe(function() return c:GetFName():ToString() end) == name then return c end
    end
    return nil
end

local function make(bar, clsName, objName)
    local cls = umg(clsName)
    if not cls then once("cls" .. clsName, "UMG." .. clsName .. " not found") return nil end
    local tree = safe(function() return bar.WidgetTree end)
    local w = StaticConstructObject(cls, valid(tree) and tree or bar, FName(objName))
    if not valid(w) then once("ctor" .. clsName, "could not construct " .. clsName) return nil end
    return w
end

local function styleText(tb, size)
    pcall(function() tb.Font.Size = size end)
    pcall(function() tb:SetColorAndOpacity({ SpecifiedColor = { R = 1, G = 1, B = 1, A = 1 }, ColorUseRule = 0 }) end)
    pcall(function() tb:SetShadowOffset({ X = 1, Y = 1 }) end)
    pcall(function() tb:SetShadowColorAndOpacity({ R = 0, G = 0, B = 0, A = 0.9 }) end)
    pcall(function() tb:SetVisibility(VIS_HITTESTINVISIBLE) end)
    pcall(function() tb:SetJustification(2) end)
end

local function padOverlaySlot(slot, align, offsetX)
    pcall(function() slot:SetHorizontalAlignment(align) end)
    pcall(function() slot:SetVerticalAlignment(2) end)
    if align == 3 then
        pcall(function() slot:SetPadding({ Left = 0, Top = 0, Right = -offsetX, Bottom = 0 }) end)
    else
        pcall(function() slot:SetPadding({ Left = offsetX, Top = 0, Right = 0, Bottom = 0 }) end)
    end
end

local function buildHealth(bar, h)
    local existing = findChild(h, HP_NAME)
    if valid(existing) then return existing end
    local tb = make(bar, "TextBlock", HP_NAME)
    if not valid(tb) then return nil end
    styleText(tb, HP_SIZE)
    local slot = safe(function() return h:AddChildToOverlay(tb) end)
    if not valid(slot) then once("hpslot", "could not slot health text") return nil end
    padOverlaySlot(slot, HP_ALIGN, HP_OFFSET)
    return tb
end

local function buildBadge(bar, h)
    local box = findChild(h, BOX_NAME)
    if valid(box) then
        local stack = safe(function() return box:GetChildAt(0) end)
        if valid(stack) then
            local tb = findChild(stack, LVL_NAME)
            if valid(tb) then return tb, findChild(stack, "EI_LevelRim") end
        end
    end

    if STYLE == "none" then
        local tb = make(bar, "TextBlock", LVL_NAME)
        if not valid(tb) then return nil end
        styleText(tb, LVL_SIZE)
        local slot = safe(function() return h:AddChildToOverlay(tb) end)
        if not valid(slot) then return nil end
        padOverlaySlot(slot, LVL_ALIGN, LVL_OFFSET)
        return tb, nil
    end

    local diamond = (STYLE == "diamond")
    box = make(bar, "SizeBox", BOX_NAME)
    if not valid(box) then return nil end
    pcall(function() box:SetWidthOverride(diamond and BOX_SIZE or PLATE_W) end)
    pcall(function() box:SetHeightOverride(BOX_SIZE) end)
    pcall(function() box:SetVisibility(VIS_HITTESTINVISIBLE) end)

    local boxSlot = safe(function() return h:AddChildToOverlay(box) end)
    if not valid(boxSlot) then once("boxslot", "could not slot level badge") return nil end
    padOverlaySlot(boxSlot, LVL_ALIGN, LVL_OFFSET)

    local stack = make(bar, "Overlay", "EI_LevelStack")
    if not valid(stack) then return nil end
    local ss = safe(function() return box:AddChild(stack) end)
    if valid(ss) then
        pcall(function() ss:SetHorizontalAlignment(0) end)
        pcall(function() ss:SetVerticalAlignment(0) end)
    end

    local rim = make(bar, "Border", "EI_LevelRim")
    if valid(rim) then
        pcall(function() rim:SetBrushColor({ R = C_EQUAL.R, G = C_EQUAL.G, B = C_EQUAL.B, A = 1 }) end)
        pcall(function() rim:SetPadding({ Left = RIM, Top = RIM, Right = RIM, Bottom = RIM }) end)
        pcall(function() rim:SetVisibility(VIS_HITTESTINVISIBLE) end)
        if diamond then pcall(function() rim:SetRenderTransformAngle(45.0) end) end
        local rs = safe(function() return stack:AddChildToOverlay(rim) end)
        if valid(rs) then
            pcall(function() rs:SetHorizontalAlignment(0) end)
            pcall(function() rs:SetVerticalAlignment(0) end)
        end

        local fill = make(bar, "Border", "EI_LevelFill")
        if valid(fill) then
            pcall(function() fill:SetBrushColor({ R = BG.R, G = BG.G, B = BG.B, A = BG.A or 1 }) end)
            pcall(function() fill:SetVisibility(VIS_HITTESTINVISIBLE) end)
            pcall(function() rim:AddChild(fill) end)
        end
    end

    local tb = make(bar, "TextBlock", LVL_NAME)
    if not valid(tb) then return nil end
    styleText(tb, LVL_SIZE)
    local ts = safe(function() return stack:AddChildToOverlay(tb) end)
    if valid(ts) then
        pcall(function() ts:SetHorizontalAlignment(2) end)
        pcall(function() ts:SetVerticalAlignment(2) end)
    end

    once("badge", "level badge built (" .. STYLE .. ")")
    return tb, rim
end

local function attrSet(character)
    if not valid(character) then return nil end
    local s = safe(function() return character.CharacterAttributeSet end)
    if valid(s) then return s end
    return nil
end

local function colorFor(delta)
    if not COLORIZE or delta == nil then return C_EQUAL end
    if delta >= 9 then return C_CRIT end
    if delta >= 6 then return C_MUCH end
    if delta >= 4 then return C_SLIGHT end
    return C_EQUAL
end

local function applyColor(e, delta)
    local c = colorFor(delta)
    if valid(e.rim) and (C_TARGET == "rim" or C_TARGET == "both") then
        pcall(function() e.rim:SetBrushColor({ R = c.R, G = c.G, B = c.B, A = 1 }) end)
    end
    local t = (C_TARGET == "text" or C_TARGET == "both") and c or C_TEXT
    if valid(e.lvl) then
        pcall(function()
            e.lvl:SetColorAndOpacity({ SpecifiedColor = { R = t.R, G = t.G, B = t.B, A = 1 }, ColorUseRule = 0 })
        end)
    end
end

local function refresh(e)
    local bar = e.bar
    if not bar:IsVisible() then return end

    local character = e.character
    if not valid(character) then
        character = safe(function() return bar["Target Character"] end)
        if not valid(character) then return end

        e.character = character
        e.attr = nil
        e.health = nil
        e.maxHealth = nil
        e.ind = nil
    end

    if (SHOW_HP and not valid(e.hp)) or (SHOW_LVL and not valid(e.lvl)) then
        local h = host(bar)
        if not valid(h) then return end
        if SHOW_HP and not valid(e.hp) then e.hp = buildHealth(bar, h) e.lastHp = nil end
        if SHOW_LVL and not valid(e.lvl) then
            e.lvl, e.rim = buildBadge(bar, h)
            e.lastLvl, e.lastDelta = nil, nil
        end
    end

    if SHOW_HP and valid(e.hp) then
        local set = e.attr
        if not valid(set) then
            set = attrSet(character)
            e.attr = set
            if valid(set) then
                e.health = safe(function() return set.Health end)
                e.maxHealth = safe(function() return set.MaxHealth end)
            end
        end

        local health = e.health
        local maxHealth = e.maxHealth
        local cur = valid(health) and num(safe(function() return health.CurrentValue end))
        local mx  = valid(maxHealth) and num(safe(function() return maxHealth.CurrentValue end))
        if cur and mx and mx > 0 then
            local s = SHOW_MAX and (string.format(FMT, cur) .. " / " .. string.format(FMT, mx)) or string.format(FMT, cur)
            if s ~= e.lastHp then
                e.lastHp = s
                pcall(function() e.hp:SetText(FText(s)) end)
            end
        end
    end

    if SHOW_LVL and valid(e.lvl) and nowMs - (e.lvlAt or -99999) >= LEVEL_INTERVAL then
        e.lvlAt = nowMs

        local ind = e.ind
        if not valid(ind) then
            ind = safe(function() return bar.LevelIndicator end)
            e.ind = ind
        end

        if valid(ind) then
            local lv = num(safe(function() return ind["Get Enemy Level"](ind) end))
            if lv then
                local s = LVL_PREFIX .. tostring(math.floor(lv))
                if s ~= e.lastLvl then
                    e.lastLvl = s
                    pcall(function() e.lvl:SetText(FText(s)) end)
                end
                local d = num(safe(function() return ind["Get Level Difference"](ind) end))
                if d ~= e.lastDelta then
                    e.lastDelta = d
                    applyColor(e, d)
                end
            end
        end
    end
end

local function add(bar)
    if not valid(bar) then return end
    local key = safe(function() return bar:GetFullName() end)
    if not key or key:find("Default__", 1, true) then return end
    if tracked[key] then return end
    local e = { bar = bar, key = key }
    tracked[key] = e
    bars[#bars + 1] = e
end

local function sweepOnce()
    local found = FindAllOf(BAR_CLASS)
    if not found then return end
    for _, b in ipairs(found) do add(b) end
end

local function setupNotify()
    if notified then return end

    pcall(NotifyOnNewObject, BAR_PATH, function(obj)
        add(obj)
    end)

    notified = true
end

sweepOnce()
setupNotify()

local function update()
    for i = #bars, 1, -1 do
        local e = bars[i]
        if not valid(e.bar) then
            tracked[e.key] = nil
            bars[i] = bars[#bars]
            bars[#bars] = nil
        else
            refresh(e)
        end
    end
end

local lastErr

LoopAsync(TICK, function()
    nowMs = nowMs + TICK
    if inFlight then return false end
    inFlight = true
    ExecuteInGameThread(function()
        local o, err = pcall(update)
        if not o then
            err = tostring(err)
            if err ~= lastErr then
                lastErr = err
                log("error: " .. err)
            end
        end
        inFlight = false
    end)
    return false
end)

log("loaded")
