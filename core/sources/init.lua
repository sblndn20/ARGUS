-- Source registry: turns a raw OpenComputers component into a normalised
-- energy reading, picking the best adapter for whatever is actually plugged in.
--
-- Adapters are scored rather than matched on component type alone, because
-- GTNH merges several drivers onto one proxy: an LSC and a plain energy hatch
-- are both `gt_machine`, and only their sensor text tells them apart.
--
-- Every adapter exposes:
--   kind, label, componentTypes
--   detect(proxy, lines, componentType) -> confidence (0 = not mine)
--   read(proxy, lines)                  -> reading table

local component = require("component")
local sensor = require("core.sensor")
local states = require("core.states")
local util = require("core.util")

local sources = {}

-- Order is irrelevant (selection is by score), but keep the generic fallback last
-- for readability.
local adapters = {
    require("core.sources.lsc"),
    require("core.sources.batterybuffer"),
    require("core.sources.ic2"),
    require("core.sources.energycontainer"),
}

sources.adapters = adapters

function sources.byKind(kind)
    for i = 1, #adapters do
        if adapters[i].kind == kind then return adapters[i] end
    end
    return nil
end

-- getName() can hand back an unlocalized key rather than a name — a live LSC
-- answers "multimachine.supercapacitor". Showing that verbatim is worse than
-- showing what the adapter already knows the machine is. A key is recognisable
-- by having dots and no spaces; a real name never looks like that.
local function displayName(reported, adapter)
    if type(reported) ~= "string" or reported == "" then return adapter.label end
    if reported:find("%.") and not reported:find("%s") then return adapter.label end
    return reported
end

local function handlesType(adapter, componentType)
    for i = 1, #adapter.componentTypes do
        if adapter.componentTypes[i] == componentType then return true end
    end
    return false
end

-- Resolve an address (full or abbreviated) to a live proxy plus its type.
function sources.resolve(address)
    if not address then return nil end
    local ok, full = pcall(component.get, address)
    if not ok or not full then return nil end
    local proxy = select(2, pcall(component.proxy, full))
    if type(proxy) ~= "table" then return nil end
    -- component.list() is keyed by full UUID; looking it up with an abbreviated
    -- address silently returns nil. That mistake disabled NIDAS's battery-buffer
    -- support entirely, so always resolve to the full address first.
    return proxy, component.list()[full], full
end

-- Choose the best adapter for a component.
function sources.identify(proxy, componentType)
    local lines = sensor.lines(proxy)
    local best, bestScore = nil, 0
    for i = 1, #adapters do
        local adapter = adapters[i]
        if handlesType(adapter, componentType) or componentType == nil then
            local ok, score = pcall(adapter.detect, proxy, lines, componentType)
            if ok and type(score) == "number" and score > bestScore then
                best, bestScore = adapter, score
            end
        end
    end
    return best, lines
end

-- Scan every attached component and return the candidates worth monitoring.
-- Each entry: {address, componentType, kind, label, name}
function sources.discover()
    local found = {}
    for address, componentType in component.list() do
        local interesting = false
        for i = 1, #adapters do
            if handlesType(adapters[i], componentType) then interesting = true break end
        end
        if interesting then
            local ok, proxy = pcall(component.proxy, address)
            if ok and type(proxy) == "table" then
                local adapter, lines = sources.identify(proxy, componentType)
                if adapter then
                    table.insert(found, {
                        address = address,
                        componentType = componentType,
                        kind = adapter.kind,
                        label = adapter.label,
                        name = displayName(util.call(proxy, "getName"), adapter),
                        hasWireless = adapter.kind == "lsc"
                            and lines ~= nil
                            and sensor.find(lines, "Wireless mode") ~= nil,
                    })
                end
            end
        end
    end
    table.sort(found, function(a, b) return a.address < b.address end)
    return found
end

local missing = {
    state = states.MISSING,
    stored = 0, capacity = 0,
    euIn = 0, euOut = 0, passiveLoss = 0, problems = 0,
}

-- Read one configured buffer. Never raises: a yanked adapter or a broken
-- multiblock yields a MISSING reading instead of taking the monitor down.
function sources.read(entry)
    local proxy, componentType = sources.resolve(entry.address)
    if not proxy then
        return util.defaults({name = entry.name, kind = entry.kind, address = entry.address}, missing)
    end

    local adapter = entry.kind and sources.byKind(entry.kind)
    local lines
    if adapter and handlesType(adapter, componentType or "") then
        lines = sensor.lines(proxy)
    else
        -- Configured kind no longer fits what is plugged in; re-identify.
        adapter, lines = sources.identify(proxy, componentType)
    end
    if not adapter then
        return util.defaults({name = entry.name, kind = entry.kind, address = entry.address}, missing)
    end

    local ok, reading = pcall(adapter.read, proxy, lines)
    if not ok or type(reading) ~= "table" then
        return util.defaults({name = entry.name, kind = adapter.kind, address = entry.address}, missing)
    end

    reading.address = entry.address
    reading.kind = adapter.kind
    -- A name the user typed always wins.
    reading.name = entry.name or displayName(util.call(proxy, "getName"), adapter)
    reading.state = reading.state or states.IDLE
    return reading
end

return sources
