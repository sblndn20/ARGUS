-- Renders the on-screen UI to stdout against a fake GPU.
--
--   lua tests/preview.lua [dashboard|buffers]
--
-- The panel cannot be exercised inside Minecraft from a test suite, but the
-- renderer only ever talks to the gpu component through set/fill/getResolution.
-- Stubbing those three renders the real layout to a character grid, which
-- catches off-by-one placement, overflow past the right edge and crashes in
-- draw() without launching the game.

package.path = "./?.lua;./?/init.lua;" .. package.path

local WIDTH, HEIGHT = 120, 40

-- Fake GPU -------------------------------------------------------------------

local cells, colorsAt = {}, {}
local foreground = 0xFFFFFF

local function clearCells()
    for y = 1, HEIGHT do
        cells[y], colorsAt[y] = {}, {}
        for x = 1, WIDTH do cells[y][x] = " " colorsAt[y][x] = 0 end
    end
end
clearCells()

local function put(x, y, char)
    if x >= 1 and x <= WIDTH and y >= 1 and y <= HEIGHT then
        cells[y][x] = char
        colorsAt[y][x] = foreground
    end
end

-- A terminal preview has no colour, so block glyphs are rendered as shades by
-- luminance. Without this a dark progress-bar track and its bright fill both
-- print as █ and the bar always looks 100% full.
local function shade(char, color)
    if char ~= "█" and char ~= "▀" and char ~= "▄" then return char end
    local r = (color >> 16) & 0xFF
    local g = (color >> 8) & 0xFF
    local b = color & 0xFF
    local luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
    if luminance < 30 then return "░" end
    if luminance < 90 then return "▒" end
    return char
end

-- Split a UTF-8 string into characters: gpu.set advances per character, not per
-- byte, so the fake must too or the preview would not reflect real placement.
local function chars(s)
    local out = {}
    for _, code in utf8.codes(s) do table.insert(out, utf8.char(code)) end
    return out
end

local gpu = {
    getResolution = function() return WIDTH, HEIGHT end,
    maxResolution = function() return WIDTH, HEIGHT end,
    setResolution = function() end,
    setForeground = function(c) foreground = c end,
    setBackground = function() end,
    set = function(x, y, s)
        local list = chars(s)
        for i = 1, #list do put(math.floor(x) + i - 1, math.floor(y), list[i]) end
    end,
    fill = function(x, y, w, h, char)
        for dy = 0, h - 1 do
            for dx = 0, w - 1 do put(math.floor(x) + dx, math.floor(y) + dy, char) end
        end
    end,
}

-- One fake pair of glasses, so the Glasses page has something to configure.
local fakeTypes = {["3a2f1c9e-0000-4000-8000-000000000001"] = "glasses"}

package.preload["component"] = function()
    return {
        gpu = gpu,
        isAvailable = function(name) return name == "gpu" or name == "screen" end,
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
                local k, v = next(out, key) key = k return k, v
            end})
        end,
        get = function(a) return a end,
        proxy = function() return nil end,
    }
end

local clock = 0
package.preload["computer"] = function() return {uptime = function() return clock end} end

-- config.load() falls back to defaults when the file is absent, which is what
-- the preview wants — these stubs only need to keep require() satisfied.
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

-- Scene ----------------------------------------------------------------------

local graphics = require("lib.graphics.graphics")
local configuration = require("config")
local monitorLib = require("core.monitor")
local app = require("ui.app")
local states = require("core.states")

graphics.setContext({gpu = gpu, width = WIDTH, height = HEIGHT})

local config = configuration.load()
config.buffers = {}

-- Hand-built views: this previews the layout, so the numbers are staged rather
-- than read from a component.
local monitor = monitorLib.new(config)

local function stage(id, name, stored, storedText, capacity, euIn, euOut, loss, state)
    clock = 0
    local view = monitor:buildView(id, {
        name = name, kind = "lsc", state = state or states.ONLINE,
        stored = stored, storedText = storedText, capacity = capacity,
        euIn = euIn, euOut = euOut, passiveLoss = loss, problems = 0,
    }, clock)
    -- Feed a rising charge history so the graph has something to draw.
    for i = 1, 120 do
        clock = i * 5
        local wave = stored * (0.86 + 0.14 * math.sin(i / 9))
        require("core.metrics").update(view.tracker, wave, clock)
    end
    view = monitor:buildView(id, {
        name = name, kind = "lsc", state = state or states.ONLINE,
        stored = stored, storedText = storedText, capacity = capacity,
        euIn = euIn, euOut = euOut, passiveLoss = loss, problems = 0,
    }, clock + 1)
    monitor.views[id] = view
    table.insert(monitor.order, id)
    return view
end

-- A late-game LSC: stored is past 2^53, so only the exact string is truthful.
stage(monitorLib.AGGREGATE_ID, "All buffers",
    9.2233720368548e18, "9223372036854775807", 1.4757395258968e19,
    32768, 1200000, 1328)
stage("lsc-1", "Main LSC", 4.4e17, "440000000000000000", 1.4757395258968e19,
    32768, 12000, 1328)
stage("bb-1", "Battery Buffer", 1234, nil, 5678, 12, 34, 0, states.IDLE)

local page = (...) or "dashboard"
local application = app.new(monitor, config)
application.page = page
application:draw()

-- Output ---------------------------------------------------------------------

print("+" .. string.rep("-", WIDTH) .. "+")
for y = 1, HEIGHT do
    local row = {}
    for x = 1, WIDTH do row[x] = shade(cells[y][x], colorsAt[y][x]) end
    print("|" .. table.concat(row) .. "|")
end
print("+" .. string.rep("-", WIDTH) .. "+")
