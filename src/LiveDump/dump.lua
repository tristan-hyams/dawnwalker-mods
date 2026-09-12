-- Introspection for LiveDump. Knows nothing about any particular game or class.
--
-- SAFETY, which is the whole design constraint here:
--
-- pcall catches Lua errors. It does NOT catch an access violation inside UE4SS's C++
-- reflection or property marshalling - that is a hardware exception and it takes the
-- game down with it. So the rules are:
--
--   * Enumerating property and function NAMES is safe. It reads reflection data.
--   * Reading a property VALUE is only safe when the property is named by the caller
--     and its type is plain-old-data. Pointer-following types are listed, never read.
--   * Introspecting a class you have never introspected before is not safe, and is
--     therefore opt-in via config.Follow rather than automatic.
--
-- An earlier version of this tool ignored the second and third rules and crashed the
-- game three times running.

local M = {}

-- Types whose values can be read without following a pointer. Everything else -
-- objects, structs, delegates, interfaces, arrays, maps, sets, weak pointers - is
-- listed by name and type but never dereferenced.
local POD = {
    IntProperty = true, Int8Property = true, Int16Property = true, Int64Property = true,
    UInt16Property = true, UInt32Property = true, UInt64Property = true,
    FloatProperty = true, DoubleProperty = true,
    BoolProperty = true, ByteProperty = true, EnumProperty = true,
    StrProperty = true, NameProperty = true,
}

local function safe(fn) local o, r = pcall(fn) if o then return r end return nil end
local function try(fn, a) local o, r = pcall(fn, a) if o then return r end return nil end

function M.valid(o) return o ~= nil and o.IsValid ~= nil and o:IsValid() end
local valid = M.valid

local function getProp(o, k) return o[k] end

function M.nameOf(o) return safe(function() return o:GetFName():ToString() end) or "?" end
function M.fullOf(o) return safe(function() return o:GetFullName() end) or "?" end
function M.classOf(o) return safe(function() return o:GetClass():GetFName():ToString() end) or "?" end

local nameOf, fullOf, classOf = M.nameOf, M.fullOf, M.classOf

-- Renders a value compactly. Objects are summarised as class plus name rather than
-- followed, structs and anything else as a type marker.
local function describe(v)
    if v == nil then return "nil" end
    local t = type(v)
    if t == "number" or t == "boolean" or t == "string" then return tostring(v) end
    if valid(v) then return classOf(v) .. " " .. nameOf(v) end
    return "<" .. t .. ">"
end

--------------------------------------------------------------------------- reporting

-- Collects lines. Passed around rather than held in a module-level table, so two dumps
-- cannot interleave.
function M.newReport()
    local lines = {}
    return {
        lines = lines,
        add = function(s) lines[#lines + 1] = tostring(s) end,
    }
end

function M.write(path, report)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(table.concat(report.lines, "\n"))
    f:write("\n")
    f:close()
    return true
end

--------------------------------------------------------------------- class structure

-- Stops at the first name it cannot resolve rather than trusting the walk to
-- terminate: past the root of an unfamiliar hierarchy GetSuperStruct can return a
-- non-null but garbage UStruct that passes valid(), and stringifying its name faults.
local function classChain(cls, limit)
    local names, c, guard = {}, cls, 0
    while valid(c) and guard < (limit or 12) do
        local n = nameOf(c)
        if n == "?" or n == "" then
            names[#names + 1] = "<unresolvable - stopping walk>"
            break
        end
        names[#names + 1] = n
        if n == "Object" then break end
        c = safe(function() return c:GetSuperStruct() end)
        guard = guard + 1
    end
    return names
end

local function functionNames(cls, limit)
    local names = {}
    local ok = pcall(function()
        cls:ForEachFunction(function(fn)
            if #names < limit then names[#names + 1] = nameOf(fn) end
        end)
    end)
    return names, ok
end

local function propertyList(cls, limit)
    local props = {}
    local ok = pcall(function()
        cls:ForEachProperty(function(p)
            if #props >= limit then return end
            props[#props + 1] = {
                name = nameOf(p),
                type = safe(function() return p:GetClass():GetFName():ToString() end) or "?",
            }
        end)
    end)
    return props, ok
end

------------------------------------------------------------------------ widget tree

local function walkTree(node, depth, seen, report, maxDepth)
    if depth > maxDepth or not valid(node) then return end

    local vis = safe(function() return node:IsVisible() end)
    local text = safe(function() return node:GetText():ToString() end)
    report.add(string.format("%s%s  [%s]%s%s",
        string.rep("  ", depth), nameOf(node), classOf(node),
        vis == false and "  <HIDDEN>" or "",
        text and ("  text=\"" .. tostring(text) .. "\"") or ""))

    local count = safe(function() return node:GetChildrenCount() end) or 0
    for i = 0, count - 1 do
        local child = safe(function() return node:GetChildAt(i) end)
        if valid(child) and not seen[child] then
            seen[child] = true
            walkTree(child, depth + 1, seen, report, maxDepth)
        end
    end
end

------------------------------------------------------------------------------ object

-- opts: { structure, widgetTree, scalars, maxFunctions, maxProperties, maxTreeDepth }
function M.object(obj, label, report, opts)
    local add = report.add
    add("")
    add("================================================================")
    add("OBJECT: " .. label)
    add("================================================================")
    add("instance: " .. fullOf(obj))

    local cls = safe(function() return obj:GetClass() end)
    if not valid(cls) then
        add("FAILED: could not resolve class")
        return
    end

    add("")
    add("== CLASS CHAIN ==")
    for _, n in ipairs(classChain(cls)) do add("  " .. n) end

    -- Named scalars first: usually the reason you ran the dump.
    if opts.scalars and #opts.scalars > 0 then
        add("")
        add("== NAMED SCALARS ==")
        add("Values read only where the declared type is plain-old-data.")
        add("")
        local types = {}
        local props = propertyList(cls, opts.maxProperties)
        for _, p in ipairs(props) do types[p.name] = p.type end

        for _, name in ipairs(opts.scalars) do
            local t = types[name]
            local shown
            if t == nil then
                shown = "(no such property on this class)"
            elseif POD[t] then
                shown = describe(try(getProp, obj, name))
            else
                shown = "(not read - " .. t .. " is not plain-old-data)"
            end
            add(string.format("  %-34s %-18s %s", name, t or "-", shown))
        end
    end

    if opts.structure then
        local funcs, fok = functionNames(cls, opts.maxFunctions)
        add("")
        add("== FUNCTIONS ==  (" .. #funcs .. ")")
        add("RegisterHook candidates look like SetX / UpdateX / OnXChanged / AttachToX.")
        add("")
        if not fok then add("  FAILED: ForEachFunction unavailable on this build") end
        for _, n in ipairs(funcs) do add("  " .. n) end

        local props, pok = propertyList(cls, opts.maxProperties)
        add("")
        add("== PROPERTIES ==  (" .. #props .. ")")
        add("")
        if not pok then add("  FAILED: ForEachProperty unavailable on this build") end
        for _, p in ipairs(props) do
            add(string.format("  %-40s %s", p.name, p.type))
        end
    end

    if opts.widgetTree then
        local tree = safe(function() return obj.WidgetTree end)
        local root = valid(tree) and safe(function() return tree.RootWidget end) or nil
        if valid(root) then
            add("")
            add("== WIDGET TREE ==")
            add("<HIDDEN> marks widgets that exist but are not currently visible.")
            add("")
            walkTree(root, 1, {}, report, opts.maxTreeDepth)
        end
    end
end

-- Which instances exist, whether they are visible, and what they hold. Uses only the
-- cheapest reads, so it is safe to run against anything.
function M.summarise(className, objects, report)
    local add = report.add
    add("")
    add("== INSTANCES OF " .. className .. " ==  (" .. #objects .. ")")
    add("")
    for i, o in ipairs(objects) do
        local vis = safe(function() return o:IsVisible() end)
        add(string.format("  %d. %-46s visible=%s", i, nameOf(o), tostring(vis)))
    end
end

-- Live instances of a class, class-default objects excluded.
function M.findAll(className)
    local found = safe(function() return FindAllOf(className) end)
    if not found then return {} end

    local out = {}
    for _, o in ipairs(found) do
        local full = valid(o) and fullOf(o) or nil
        if full and not full:find("Default__", 1, true) then
            out[#out + 1] = o
        end
    end
    return out
end

return M
