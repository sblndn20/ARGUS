-- EMON test suite.
--
-- Runs on a desktop Lua 5.2+ interpreter, outside Minecraft:
--   lua tests/run.lua        (from the repo root)
--
-- Everything below the renderers is pure Lua, so the sensor parsing, the rate
-- maths and the formatting can all be verified without an OpenComputers
-- machine. The sensor fixtures reproduce GTNH 2.8.3 (GT5U 5.09.51.482) output,
-- including its § colour codes and its duplicated
-- separator-formatted/scientific value pairs.

package.path = "./?.lua;./?/init.lua;" .. package.path

-- Stub the OpenComputers API for modules that reach for it.
local fakeComponents = {} -- address -> proxy
local fakeTypes = {}      -- address -> component type

package.preload["component"] = function()
    return {
        -- The real component.list() returns a table that is ALSO callable as an
        -- iterator, and is keyed by full address. Both properties matter: code
        -- indexes it (component.list()[address]) and loops over it.
        list = function(filter, exact)
            local out = {}
            for address, componentType in pairs(fakeTypes) do
                local match = not filter
                    or (exact and componentType == filter)
                    or (not exact and componentType:find(filter, 1, true) ~= nil)
                if match then out[address] = componentType end
            end
            local key
            return setmetatable(out, {__call = function()
                local address, componentType = next(out, key)
                key = address
                return address, componentType
            end})
        end,
        get = function(address) return fakeComponents[address] and address or nil end,
        proxy = function(address) return fakeComponents[address] end,
        isAvailable = function() return false end,
    }
end

local clock = 0
package.preload["computer"] = function()
    return {uptime = function() return clock end}
end

package.preload["filesystem"] = function()
    return {
        exists = function() return false end,
        makeDirectory = function() return true end,
        remove = function() return true end,
        rename = function() return true end,
        path = function(p) return p:match("^(.*)/[^/]*$") or "/" end,
    }
end
package.preload["serialization"] = function()
    return {serialize = tostring, unserialize = function() return nil end}
end

-- Records every object created on it, so the AR panel can be inspected without
-- a pair of glasses. Mirrors the OpenGlasses API surface EMON actually uses.
local function fakeGlasses()
    local glasses = {objects = {}, nextId = 0}
    local function newObject(kind)
        glasses.nextId = glasses.nextId + 1
        local id = glasses.nextId
        local object = {kind = kind, id = id, vertices = {}, scale = 1, alpha = 1}
        object.setColor = function(r, g, b) object.color = {r, g, b} end
        object.setAlpha = function(a) object.alpha = a end
        object.setVertex = function(i, x, y) object.vertices[i] = {x, y} end
        object.setText = function(s) object.text = s end
        object.setPosition = function(x, y) object.position = {x, y} end
        object.getPosition = function() return object.position[1], object.position[2] end
        object.setScale = function(s) object.scale = s end
        object.getScale = function() return object.scale end
        object.getID = function() return id end
        glasses.objects[id] = object
        return object
    end
    glasses.addQuad = function() return newObject("quad") end
    glasses.addTextLabel = function() return newObject("text") end
    glasses.removeObject = function(id) glasses.objects[id] = nil end
    glasses.removeAll = function() glasses.objects = {} end
    return glasses
end

local function countObjects(glasses)
    local n = 0
    for _ in pairs(glasses.objects) do n = n + 1 end
    return n
end

-- Tiny harness ---------------------------------------------------------------

local passed, failed = 0, 0

local function check(name, ok, detail)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL  " .. name .. (detail and ("\n        " .. detail) or ""))
    end
end

local function eq(name, actual, expected)
    check(name, actual == expected,
        "expected: " .. tostring(expected) .. "\n        actual:   " .. tostring(actual))
end

-- Compare floats with a relative tolerance.
local function near(name, actual, expected, tolerance)
    tolerance = tolerance or 1e-6
    local ok = type(actual) == "number"
        and math.abs(actual - expected) <= tolerance * math.max(1, math.abs(expected))
    check(name, ok, "expected ~" .. tostring(expected) .. ", got " .. tostring(actual))
end

-- Fixtures -------------------------------------------------------------------

-- A GTNH 2.8.3 LSC in wireless mode. 24 lines, colour codes intact.
local function lscSensor(overrides)
    local lines = {
        "§eOperational Data:§r",
        "EU Stored: §a1,234,567,890§r EU",
        "EU Stored: §a1.234E9§r EU",
        "Used Capacity: §e12.34%§r",
        "Total Capacity: §e10,000,000,000§r EU",
        "Total Capacity: §e1.000E10§r EU",
        "Passive Loss: §c1,328§r EU/t",
        "EU IN: §a32,768§r EU/t",
        "EU OUT: §c0§r EU/t",
        "Avg EU IN: §a30,000§r (last 20 seconds)",
        "Avg EU OUT: §c1,000§r (last 20 seconds)",
        "Avg EU IN: §a28,000§r (last 5 minutes)",
        "Avg EU OUT: §c2,000§r (last 5 minutes)",
        "Avg EU IN: §a25,000§r (last 1 hour)",
        "Avg EU OUT: §c5,000§r (last 1 hour)",
        "Time to Full: §e3 hours§r",
        "Maintenance Status: §aWorking perfectly§r",
        "Wireless mode: §aenabled§r",
        "UHV Capacitors detected: §e4§r",
        "UEV Capacitors detected: §e0§r",
        "UIV Capacitors detected: §e0§r",
        "UMV Capacitors detected: §e0§r",
        "Total wireless EU: §a9,876,543,210§r EU",
        "Total wireless EU: §a9.876E9§r EU",
    }
    for index, value in pairs(overrides or {}) do lines[index] = value end
    return lines
end

local function proxy(lines, extra)
    local p = {getSensorInformation = function() return lines end}
    for key, value in pairs(extra or {}) do p[key] = value end
    return p
end

-- parser ---------------------------------------------------------------------

local parser = require("lib.utils.parser")

eq("splitNumber groups thousands", parser.splitNumber(1234567), "1,234,567")
eq("splitNumber keeps small numbers intact", parser.splitNumber(42), "42")
eq("splitNumber handles zero", parser.splitNumber(0), "0")
eq("splitNumber handles negatives", parser.splitNumber(-1234567), "-1,234,567")
-- Formatting from a string is what keeps >2^53 EU exact.
eq("splitNumber formats exact decimal strings",
    parser.splitNumber("9223372036854775807"), "9,223,372,036,854,775,807")

eq("metricNumber leaves sub-thousand alone", parser.metricNumber(999), "999")
eq("metricNumber promotes at exactly 1000", parser.metricNumber(1000), "1.0k")
-- NIDAS used `> 1000` here and rendered 1000.0k instead of 1.0M.
eq("metricNumber rolls over to the next unit", parser.metricNumber(1000000), "1.0M")
eq("metricNumber handles negatives", parser.metricNumber(-2500000), "-2.5M")

eq("getInteger strips separators and units", parser.getInteger("EU IN: 32,768EU/t"), 32768)
eq("getInteger keeps the sign", parser.getInteger("Net: -1,500 EU/t"), -1500)
eq("stripColors removes section codes", parser.stripColors("§aWorking perfectly§r"), "Working perfectly")

-- sensor ---------------------------------------------------------------------

local sensor = require("core.sensor")

local value, exact = sensor.amount("EU Stored: §a1,234,567,890§r EU")
eq("amount parses a separator-formatted value", value, 1234567890)
eq("amount returns exact digits", exact, "1234567890")

value, exact = sensor.amount("EU Stored: §a1.234E9§r EU")
near("amount parses scientific notation", value, 1.234e9)
eq("amount has no exact form for scientific input", exact, nil)

-- The parenthesised qualifier carries digits that a naive digits-only scrape
-- would splice into the number.
value = sensor.amount("Avg EU IN: §a28,000§r (last 5 minutes)")
eq("amount ignores parenthesised qualifiers", value, 28000)

eq("amount strips EU/t units", sensor.amount("Passive Loss: §c1,328§r EU/t"), 1328)
eq("amount reads negatives", sensor.amount("Net: -1,500 EU/t"), -1500)
eq("amount returns nil when there is no number", sensor.amount("Maintenance Status: Working perfectly"), nil)

local lines = require("core.sensor").lines(proxy(lscSensor()))
eq("lines strips colour codes", lines[17], "Maintenance Status: Working perfectly")

-- Both an exact and a scientific line exist; the exact one must win.
value, exact = sensor.bestValue(lines, "^%s*EU Stored")
eq("bestValue prefers the exact variant", exact, "1234567890")

-- lsc ------------------------------------------------------------------------

local lsc = require("core.sources.lsc")
local states = require("core.states")

check("lsc detects a capacitor", lsc.detect(nil, lines) > 0)

local reading = lsc.read(proxy(lscSensor()), lines)
eq("lsc reads stored", reading.stored, 1234567890)
eq("lsc reads stored exactly", reading.storedText, "1234567890")
eq("lsc reads capacity", reading.capacity, 10000000000)
eq("lsc reads passive loss", reading.passiveLoss, 1328)
-- "EU IN:" must not be confused with "Avg EU IN:".
eq("lsc reads EU IN, not Avg EU IN", reading.euIn, 32768)
eq("lsc reads EU OUT", reading.euOut, 0)
eq("lsc reads no problems", reading.problems, 0)
eq("lsc is online when power flows", reading.state, states.ONLINE)
-- GTNH computes these windows itself, so EMON uses them rather than resampling.
eq("lsc takes the 5-minute average from the sensor", reading.avg5m, 26000)
eq("lsc takes the 1-hour average from the sensor", reading.avg1h, 20000)
check("lsc reports wireless mode", reading.wireless ~= nil and reading.wireless.enabled == true)
eq("lsc reads the wireless balance", reading.wireless.stored, 9876543210)

-- Prefer the structured getters for rates when they exist.
reading = lsc.read(proxy(lscSensor(), {
    getEUInputAverage = function() return 12345 end,
    getEUOutputAverage = function() return 678 end,
}), lines)
eq("lsc prefers getEUInputAverage", reading.euIn, 12345)
eq("lsc prefers getEUOutputAverage", reading.euOut, 678)

-- Maintenance and disabled states.
local brokenLines = require("core.sensor").lines(
    proxy(lscSensor({[17] = "Maintenance Status: §cHas Problems§r"})))
reading = lsc.read(proxy(lscSensor({[17] = "Maintenance Status: §cHas Problems§r"})), brokenLines)
eq("lsc flags maintenance", reading.state, states.PROBLEM)
check("lsc counts at least one problem", reading.problems >= 1)

reading = lsc.read(proxy(lscSensor(), {isWorkAllowed = function() return false end}), lines)
eq("lsc reports disabled", reading.state, states.OFF)

-- A wireless-disabled LSC must not advertise a wireless view.
local offLines = require("core.sensor").lines(
    proxy(lscSensor({[18] = "Wireless mode: §cdisabled§r"})))
reading = lsc.read(proxy(lscSensor({[18] = "Wireless mode: §cdisabled§r"})), offLines)
eq("wireless off is reported as disabled", reading.wireless.enabled, false)

-- battery buffer --------------------------------------------------------------

local batteryBuffer = require("core.sources.batterybuffer")

local bufferLines = {
    "§9Battery Buffer§r",
    "Stored Items: §a1,234§r EU / §e5,678§r EU",
    "Average input: §a12§r EU/t",
    "Average output: §c34§r EU/t",
}
local strippedBuffer = require("core.sensor").lines(proxy(bufferLines))

eq("battery buffer detected by component type",
    batteryBuffer.detect(nil, strippedBuffer, "gt_batterybuffer"), 100)

-- "X EU / Y EU" on one line: scraping digits from the whole line would yield
-- 12345678. Both figures must be split apart first.
reading = batteryBuffer.read(proxy(bufferLines), strippedBuffer)
eq("battery buffer splits stored from capacity", reading.stored, 1234)
eq("battery buffer reads capacity", reading.capacity, 5678)
eq("battery buffer reads input", reading.euIn, 12)
eq("battery buffer reads output", reading.euOut, 34)

-- ring -----------------------------------------------------------------------

local ring = require("core.ring")

local r = ring.new(3)
r:push(1, 10) r:push(2, 20)
eq("ring counts samples", r.count, 2)
local t, v = r:oldest()
eq("ring oldest time", t, 1) eq("ring oldest value", v, 10)

r:push(3, 30) r:push(4, 40) -- wraps, dropping (1, 10)
eq("ring caps at capacity", r.count, 3)
t, v = r:oldest()
eq("ring drops the oldest on wrap", t, 2)
t, v = r:newest()
eq("ring newest survives wrap", v, 40)

t, v = r:since(4, 1) -- window covers t >= 3
eq("ring:since finds the first sample in the window", t, 3)
t, v = r:since(4, 100) -- window predates all samples
eq("ring:since degrades to the oldest sample", t, 2)

-- metrics ---------------------------------------------------------------------

local metrics = require("core.metrics")

local tracker = metrics.new()
-- Charge climbing by 20,000 EU/s = 1,000 EU/t.
for i = 0, 40 do metrics.update(tracker, i * 20000, i * 1.0) end
near("rate is measured in EU per tick", metrics.rate(tracker, 40, 5), 1000, 1e-6)

tracker = metrics.new()
metrics.update(tracker, 5000, 0)
eq("rate needs two samples", metrics.rate(tracker, 0, 5), nil)

local seconds, direction = metrics.projection(0, 1000000, 100)
eq("projection direction is full when charging", direction, "full")
near("projection time to full", seconds, 500) -- 1e6 EU / (100 EU/t * 20 t/s)

seconds, direction = metrics.projection(400000, 1000000, -100)
eq("projection direction is empty when draining", direction, "empty")
near("projection time to empty", seconds, 200)

eq("projection is nil at a standstill", (metrics.projection(500, 1000, 0)), nil)
eq("projection is nil when already full", (metrics.projection(1000, 1000, 5)), nil)

-- format ----------------------------------------------------------------------

local format = require("ui.format")

eq("format.exact groups digits", format.exact(1234567), "1,234,567 EU")
-- The whole point of the exact string: this value is unrepresentable as a double.
eq("format.exact uses the exact string past 2^53",
    format.exact(9.2233720368548e18, "9223372036854775807"),
    "9,223,372,036,854,775,807 EU")
-- Without an exact string, grouped digits would imply precision we lack.
check("format.exact avoids fake precision past 2^53",
    format.exact(9.2233720368548e18, nil):find("e") ~= nil)

eq("format.rate signs positive rates", format.rate(1200000), "+1.2M EU/t")
eq("format.rate signs negative rates", format.rate(-1200000), "-1.2M EU/t")
eq("format.rate handles unknown", format.rate(nil), "--")

eq("format.percent rounds to one decimal", format.percent(0.6243), "62.4%")
eq("format.percent clamps a full buffer", format.percent(0.99999), "100%")
-- A nearly-empty buffer rounding to "0.0%" hides that it is still draining.
check("format.percent keeps detail near empty", format.percent(0.00005) ~= "0.0%")

-- monitor ---------------------------------------------------------------------

local monitorLib = require("core.monitor")

fakeComponents["lsc-address"] = proxy(lscSensor())
fakeTypes["lsc-address"] = "gt_machine"
local config = {buffers = {{address = "lsc-address", name = "Main LSC", kind = "lsc", enabled = true}}}
local monitor = monitorLib.new(config)

clock = 0
monitor:update()

local view = monitor:get("lsc-address")
check("monitor builds a view for the buffer", view ~= nil)
near("monitor computes the fill fraction", view.percent, 0.123456789)
eq("monitor names the view from config", view.name, "Main LSC")

-- Wireless is not a component; it must surface as its own view off the LSC.
local wirelessView = monitor:get("lsc-address:wireless")
check("monitor exposes a wireless view", wirelessView ~= nil)
eq("wireless view has no capacity", wirelessView.capacity, 0)
eq("wireless view has no percentage", wirelessView.percent, nil)
eq("wireless view reads the balance", wirelessView.stored, 9876543210)

local aggregate = monitor:get(monitorLib.AGGREGATE_ID)
check("monitor builds an aggregate", aggregate ~= nil)
-- The aggregate must sum only real buffers; counting the wireless view too
-- would double-count energy that is not in the capacitor.
eq("aggregate sums real buffers only", aggregate.stored, 1234567890)

eq("resolve falls back to the aggregate for an unknown id",
    monitor:resolve("nope").id, monitorLib.AGGREGATE_ID)
eq("resolve returns the aggregate for nil", monitor:resolve(nil).id, monitorLib.AGGREGATE_ID)

-- A missing component must not raise.
config.buffers[1].address = "gone"
local ok, err = pcall(function() monitor:update() end)
check("monitor survives a missing component", ok, tostring(err))
eq("missing component yields a MISSING state", monitor:get("gone").state, states.MISSING)

-- AR panel ---------------------------------------------------------------------

local configuration = require("config")
local arPanel = require("ar.panel")

local theme = configuration.defaults().theme
local settings = configuration.glassesDefaults()
local glasses = fakeGlasses()

local arView = {
    name = "Main LSC", kind = "lsc", state = states.ONLINE,
    stored = 500, capacity = 1000, percent = 0.5,
    net = 1200000, euIn = 10, euOut = 5, passiveLoss = 0, problems = 0,
}

local arInstance = arPanel.new(glasses, settings, theme)
check("ar panel creates objects", countObjects(glasses) > 0)
local createdCount = countObjects(glasses)

arInstance:update(arView)
-- Updating must MUTATE the existing objects. Recreating them each frame is the
-- classic AR leak: the glasses have no frame boundary and would accumulate
-- objects until they choke.
eq("ar update does not create new objects", countObjects(glasses), createdCount)

eq("ar panel shows the percentage", arInstance.dynamic.percent.text, "50.0%")
eq("ar panel uppercases the name", arInstance.dynamic.name.text, "MAIN LSC")
check("ar panel shows the rate", arInstance.dynamic.rate.text:find("1.2M") ~= nil)

-- The bar is a quad laid out TL, BL, BR, TR; a 50% fill moves vertices 3 and 4
-- to the midpoint and leaves 1 and 2 pinned at the left edge.
local bar = arInstance.dynamic.bar
near("ar bar fills to the midpoint", bar.vertices[3][1], arInstance.barX + arInstance.barWidth * 0.5)
eq("ar bar left edge stays put", bar.vertices[1][1], arInstance.barX)

arView.percent = 1.0
arInstance:update(arView)
near("ar bar fills completely", bar.vertices[3][1], arInstance.barX + arInstance.barWidth)

-- A wireless view has no capacity, so the panel must not divide by it.
local ok2 = pcall(function()
    arInstance:update({name = "Wireless", kind = "wireless", state = states.ONLINE,
        stored = 1e9, capacity = 0, percent = nil, net = 0})
end)
check("ar panel survives a capacity-less view", ok2)

arInstance:remove()
eq("ar panel removes every object", countObjects(glasses), 0)

-- AR anchoring -----------------------------------------------------------------
--
-- The card must be movable: anchored bottom-left it lands on top of Minecraft's
-- chat, which is what the default of top-left avoids.

eq("default anchor keeps clear of the chat", configuration.glassesDefaults().anchor, "top-left")

-- Glasses space for the default 2560x1440 at GUI scale 3.
local resolution = require("lib.utils.screen").size({2560, 1440}, 3)
local cardWidth = 190

local ax, ay = arPanel.anchorPosition("top-left", resolution, cardWidth)
near("top-left sits at the left margin", ax, 4)
near("top-left sits at the top margin", ay, 4)

local bx, by = arPanel.anchorPosition("bottom-right", resolution, cardWidth)
near("bottom-right is inset from the right edge", bx, resolution[1] - cardWidth - 4)
check("bottom-right stays on screen", bx + cardWidth <= resolution[1])
check("bottom-right sits below top-left", by > ay)

local cx = arPanel.anchorPosition("top-center", resolution, cardWidth)
near("top-center is horizontally centred", cx, (resolution[1] - cardWidth) / 2)

-- Every declared anchor must resolve, and none may push the card off screen.
for _, anchor in ipairs(arPanel.ANCHORS) do
    local px, py = arPanel.anchorPosition(anchor, resolution, cardWidth)
    check("anchor " .. anchor .. " stays within the viewport",
        px >= 0 and py >= 0 and px + cardWidth <= resolution[1] and py <= resolution[2])
end

-- An unknown anchor (hand-edited config) must not crash or return nil.
local fx, fy = arPanel.anchorPosition("nonsense", resolution, cardWidth)
check("unknown anchor falls back rather than failing", type(fx) == "number" and type(fy) == "number")

-- The nudge offsets apply on top of the anchor.
local anchored = fakeGlasses()
local nudged = configuration.glassesDefaults()
nudged.anchor = "top-left"
nudged.offsetX, nudged.offsetY = 12, 20
local nudgedPanel = arPanel.new(anchored, nudged, theme)
near("offsetX shifts the card right", nudgedPanel.x, 4 + 12)
near("offsetY shifts the card down", nudgedPanel.y, 4 + 20)

-- AR manager -------------------------------------------------------------------

local arHud = require("ar")

fakeComponents["glasses-1"] = fakeGlasses()
fakeTypes["glasses-1"] = "glasses"

local hudConfig = configuration.defaults()
hudConfig.buffers = {}
local hud = arHud.new(hudConfig)

-- Rebuild the monitor with two views so cycling has something to rotate through.
config.buffers[1].address = "lsc-address"
clock = 100
monitor:update()

local glassesSettings = configuration.glassesFor(hudConfig, "glasses-1")
glassesSettings.cycle = true
glassesSettings.cycleInterval = 5

hud:update(monitor)
check("hud builds a panel for the glasses", hud.panels["glasses-1"] ~= nil)
local firstIndex = hud.panels["glasses-1"].cycleIndex

-- Before the interval elapses the source must stay put.
hud:update(monitor)
eq("hud does not cycle early", hud.panels["glasses-1"].cycleIndex, firstIndex)

clock = clock + 10
hud:update(monitor)
check("hud cycles after the interval", hud.panels["glasses-1"].cycleIndex ~= firstIndex)

-- Toggling a geometry setting must rebuild rather than leave stale objects.
glassesSettings.compact = true
hud:update(monitor)
check("hud rebuilds when geometry changes", hud.panels["glasses-1"] ~= nil)

glassesSettings.enabled = false
hud:update(monitor)
eq("hud drops the panel when disabled", hud.panels["glasses-1"], nil)

-- Installer manifest -----------------------------------------------------------
--
-- setup.lua lists every file to download. A module that exists in the repo but
-- is missing from that list installs a broken copy that only fails in-game, at
-- require() time — so the list is checked against what actually loads here.

-- Pull in the renderers too, so they are covered by the manifest check and get
-- a load-time smoke test.
require("ui.app")
require("ui.panel")
require("ui.graph")
require("ui.widgets")

local function fileExists(path)
    local handle = io.open(path, "r")
    if handle then handle:close() return true end
    return false
end

local manifestSource = io.open("setup.lua", "r")
check("setup.lua is readable", manifestSource ~= nil)

if manifestSource then
    local source = manifestSource:read("*a")
    manifestSource:close()

    local manifest = {}
    local block = source:match("local FILES = {(.-)\n}")
    for path in (block or ""):gmatch('"([^"]+)"') do manifest[path] = true end
    check("setup.lua declares a file list", next(manifest) ~= nil)

    -- Every declared file must exist.
    for path in pairs(manifest) do
        check("manifest file exists: " .. path, fileExists(path))
    end

    -- Every module the app loads must be declared.
    for name in pairs(package.loaded) do
        if name:match("^lib%.") or name:match("^core") or name:match("^ui%.")
            or name == "ar" or name:match("^ar%.") or name == "config" then
            local flat = name:gsub("%.", "/") .. ".lua"
            local nested = name:gsub("%.", "/") .. "/init.lua"
            local path = fileExists(flat) and flat or nested
            check("setup.lua ships " .. name, manifest[path] == true,
                "add \"" .. path .. "\" to FILES in setup.lua")
        end
    end
end

-- Result ----------------------------------------------------------------------

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
