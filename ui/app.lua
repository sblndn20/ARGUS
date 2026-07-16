-- On-screen application: dashboard, buffer picker, glasses setup.
--
-- Redraws the whole screen each frame. NIDAS kept every window in a GPU buffer
-- and bitblt'd them, which is faster but needs a Tier 3 GPU; at this refresh
-- rate (a few frames per second) a plain redraw is cheap enough and keeps the
-- hardware requirement down.

local component = require("component")
local computer = require("computer")

local graphics = require("lib.graphics.graphics")
local palette = require("lib.graphics.colors")
local text = require("lib.utils.text")
local time = require("lib.utils.time")

local configuration = require("config")
local monitorLib = require("core.monitor")
local sources = require("core.sources")

local format = require("ui.format")
local panel = require("ui.panel")
local widgets = require("ui.widgets")

-- For the anchor list: ar.panel owns the HUD layout, so it owns the corners.
local arPanel = require("ar.panel")

local app = {}
app.__index = app

-- Graph windows offered by the footer button, in seconds. The sample step
-- follows from the window (window / 120 columns), so 120 gives one point per
-- second and 30 gives four per second — anything finer than the poll rate is
-- floored by metrics.intervalFor.
local GRAPH_WINDOWS = {30, 60, 120, 300, 600, 1800, 3600}

-- Build identity, shown in the footer. An install that silently did not update
-- is otherwise indistinguishable from one that did — mirrors serve cached
-- copies of a branch for hours without saying so.
local function buildLabel()
    local ok, version = pcall(require, "version")
    local label = "v" .. (ok and tostring(version) or "?")
    local ref = configuration.installedRef()
    return ref and (label .. " @" .. ref) or label
end

-- `hud` and `server` are optional: the Glasses page uses hud to report the
-- viewport detected from glasses_on, and the Network page uses server to list
-- connected clients. Neither is required for the app to run.
function app.new(monitor, config, hud, server)
    return setmetatable({
        monitor = monitor,
        config = config,
        hud = hud,
        server = server,
        page = "dashboard",
        running = true,
        dirty = true,
        status = nil,
    }, app)
end

function app:notify(message)
    self.status = message
end

function app:nextGraphWindow()
    local current = self.config.screen.graphWindow or 600
    -- Land on the next preset larger than the current value, so a typed window
    -- rejoins the cycle at a sensible place instead of jumping to the start.
    for _, window in ipairs(GRAPH_WINDOWS) do
        if window > current then
            self.config.screen.graphWindow = window
            return
        end
    end
    self.config.screen.graphWindow = GRAPH_WINDOWS[1]
end

function app:typeGraphWindow(rows)
    local typed = widgets.prompt(2, rows - 2, 20,
        self.config.screen.graphWindow or 600, self.config.theme, true)
    local seconds = tonumber(typed)
    if seconds then
        -- Below ~15s the window is shorter than the graph is wide and the curve
        -- is mostly empty; above a day it is meaningless.
        self.config.screen.graphWindow = math.floor(math.min(86400, math.max(15, seconds)))
        self:notify("Graph window: " .. format.window(self.config.screen.graphWindow))
    end
    self.dirty = true
end

function app:save()
    local ok, err = configuration.save(self.config)
    self:notify(ok and "Settings saved" or ("Save failed: " .. tostring(err)))
end

-- Pages ---------------------------------------------------------------------

function app:drawDashboard(width, rows, theme)
    local view = self.monitor:resolve(self.config.screen.source)
    if not view then
        graphics.text(2, 4, "No buffers configured — open Buffers", theme.muted, true)
        return
    end
    panel.header(2, 1, width - 2, view, theme, palette)
    panel.rule(2, 2, width - 2, theme)
    panel.draw(2, 4, width - 3, rows - 6, view, theme, palette,
        self.config.screen.graphWindow or 600)
end

function app:drawBuffers(width, rows, theme)
    graphics.text(2, 1, "Buffers", theme.primary, true)
    graphics.text(10, 1, "· click a row to show it on screen · rename to name it yourself",
        theme.muted, true)
    panel.rule(2, 2, width - 2, theme)

    local row = 4
    local views = self.monitor:list()
    local selected = self.config.screen.source

    local function toggle(entry)
        return function()
            entry.enabled = not (entry.enabled ~= false)
            self.dirty = true
        end
    end

    -- A custom name replaces the machine's own everywhere: the dashboard header,
    -- the AR card, this list. sources.read prefers entry.name, and syncBuffers
    -- only ever refreshes detectedName, so a rescan cannot clobber it.
    local function rename(entry)
        return function()
            local typed = widgets.prompt(2, rows - 2, 40,
                entry.name or entry.detectedName or "", theme)
            if typed then
                typed = typed:gsub("^%s+", ""):gsub("%s+$", "")
                -- An empty name falls back to what the machine reports rather
                -- than leaving a nameless row.
                entry.name = (typed ~= "") and typed or entry.detectedName
                self:notify("Renamed — press Save to keep it")
            end
            self.dirty = true
        end
    end

    for _, view in ipairs(views) do
        if row > rows - 4 then break end

        local isAggregate = view.id == monitorLib.AGGREGATE_ID
        local isSelected = (selected == view.id) or (selected == nil and isAggregate)

        -- text.fit, not :sub — a byte-slice can cut a UTF-8 name mid-character.
        local caption = string.format("%s %10s  %12s",
            text.fit(view.name or "?", 28),
            format.percent(view.percent),
            format.rate(view.net))

        -- The aggregate and the virtual wireless views are not components, so
        -- there is nothing to enable or disable for them.
        local entry
        if not isAggregate and view.kind ~= "wireless" then
            for _, candidate in ipairs(self.config.buffers) do
                if candidate.address == view.address then entry = candidate break end
            end
        end

        widgets.listItem(2, row, width - 24, caption, theme, isSelected, function()
            self.config.screen.source = isAggregate and nil or view.id
            self.dirty = true
        end, nil, entry and entry.enabled)

        if entry then
            widgets.button(width - 22, row, "rename", theme, rename(entry), nil, false)
            widgets.button(width - 11, row, " on", theme, toggle(entry), nil, true)
        end
        row = row + 1
    end

    -- Disabled buffers are not polled, so the monitor builds no view for them
    -- and the loop above cannot show them. Listing them from the config too is
    -- what makes switching one back on possible at all.
    for _, entry in ipairs(self.config.buffers) do
        if entry.enabled == false and row <= rows - 4 then
            widgets.listItem(2, row, width - 24,
                text.fit(entry.name or entry.address, 28) .. "   not monitored",
                theme, false, toggle(entry), nil, false)
            widgets.button(width - 22, row, "rename", theme, rename(entry), nil, false)
            widgets.button(width - 11, row, "off", theme, toggle(entry), nil, false)
            row = row + 1
        end
    end

    row = row + 1
    widgets.button(2, row, "Rescan components", theme, function()
        local found = sources.discover()
        configuration.syncBuffers(self.config, found)
        self:notify(#found .. " component(s) found")
        self.dirty = true
    end, nil, true)

    if #self.config.buffers == 0 then
        graphics.text(2, row + 2, "Nothing detected. The Adapter must touch the multiblock's",
            theme.muted, true)
        graphics.text(2, row + 3, "CONTROLLER block and be connected to this computer.",
            theme.muted, true)
        graphics.text(2, row + 4, "Run tools/sensordump.lua to see every component.",
            theme.muted, true)
    end
end

-- Step to the next entry of a list, wrapping around.
local function cycleValue(list, current, step)
    local index = 1
    for i, value in ipairs(list) do
        if value == current then index = i break end
    end
    return list[(index - 1 + (step or 1)) % #list + 1]
end

local NUDGE = 4
local SCALES = {1, 2, 3, 4}
local INTERVALS = {4, 8, 15, 30}

function app:nextSource(settings)
    local views = self.monitor:list()
    if #views == 0 then return end
    local index = 1
    for i, view in ipairs(views) do
        if view.id == (settings.source or monitorLib.AGGREGATE_ID) then index = i break end
    end
    local nextView = views[index % #views + 1]
    settings.source = (nextView.id ~= monitorLib.AGGREGATE_ID) and nextView.id or nil
    self.dirty = true
end

function app:drawGlasses(width, rows, theme)
    graphics.text(2, 1, "AR Glasses", theme.primary, true)
    graphics.text(13, 1, "· click a pair to configure it below", theme.muted, true)
    panel.rule(2, 2, width - 2, theme)

    local addresses = {}
    for address in component.list("glasses") do table.insert(addresses, address) end
    table.sort(addresses)

    if #addresses == 0 then
        graphics.text(2, 4, "No glasses component found.", theme.muted, true)
        graphics.text(2, 5, "Link a Terminal Glasses Bridge to this computer,", theme.muted, true)
        graphics.text(2, 6, "and put the glasses in the bridge.", theme.muted, true)
        return
    end

    -- Keep the selection valid: glasses can be unlinked while this page is open.
    local stillPresent = false
    for _, address in ipairs(addresses) do
        if address == self.selectedGlasses then stillPresent = true break end
    end
    if not stillPresent then self.selectedGlasses = addresses[1] end

    local row = 4
    for _, address in ipairs(addresses) do
        if row > rows - 12 then break end
        local settings = configuration.glassesFor(self.config, address)
        local view = self.monitor:resolve(settings.source)
        local caption = string.format("%-10s %-4s %s",
            address:sub(1, 8),
            settings.enabled and "on" or "off",
            settings.cycle and "cycling all buffers" or ("→ " .. ((view and view.name) or "?")))

        widgets.listItem(2, row, width - 4, caption, theme, address == self.selectedGlasses,
            function() self.selectedGlasses = address self.dirty = true end, nil, settings.enabled)
        row = row + 1
    end

    -- Detail panel for the selected pair --------------------------------------
    local settings = configuration.glassesFor(self.config, self.selectedGlasses)
    row = row + 1
    panel.rule(2, row, width - 2, theme)
    row = row + 1
    graphics.text(2, row, "Configuring " .. self.selectedGlasses:sub(1, 8), theme.text, true)
    row = row + 2

    local function label(name) graphics.text(2, row, name, theme.muted, true) end

    label("Display")
    widgets.button(14, row, settings.enabled and "on" or "off", theme, function()
        settings.enabled = not settings.enabled self.dirty = true
    end, nil, settings.enabled)
    row = row + 1

    label("Mode")
    local x = 14
    x = x + widgets.button(x, row, settings.cycle and "cycle" or "pinned", theme, function()
        settings.cycle = not settings.cycle self.dirty = true
    end, nil, settings.cycle) + 2

    if settings.cycle then
        graphics.text(x, row, "every", theme.muted, true)
        widgets.button(x + 6, row, settings.cycleInterval .. "s", theme, function()
            settings.cycleInterval = cycleValue(INTERVALS, settings.cycleInterval)
            self.dirty = true
        end, nil, true)
    else
        local view = self.monitor:resolve(settings.source)
        widgets.button(x, row, "source: " .. ((view and view.name) or "?"), theme, function()
            self:nextSource(settings)
        end, nil, true)
    end
    row = row + 1

    -- Position ---------------------------------------------------------------
    local manual = settings.anchor == "manual"

    label("Position")
    x = 14
    x = x + widgets.button(x, row, settings.anchor, theme, function()
        settings.anchor = cycleValue(arPanel.ANCHORS, settings.anchor)
        self.dirty = true
    end, nil, true) + 2
    graphics.text(x, row, manual and "← X/Y are exact coordinates in the glasses viewport"
        or "← chat sits bottom-left, hotbar bottom-centre", theme.muted, true)
    row = row + 1

    -- With a corner anchor these nudge the card away from it; with "manual"
    -- they ARE the position, so the same two numbers serve both.
    label(manual and "X / Y" or "Nudge")
    x = 14
    local function nudge(dx, dy)
        return function()
            settings.offsetX = (settings.offsetX or 0) + dx
            settings.offsetY = (settings.offsetY or 0) + dy
            self.dirty = true
        end
    end
    x = x + widgets.button(x, row, "←", theme, nudge(-NUDGE, 0), nil, true) + 1
    x = x + widgets.button(x, row, "→", theme, nudge(NUDGE, 0), nil, true) + 1
    x = x + widgets.button(x, row, "↑", theme, nudge(0, -NUDGE), nil, true) + 1
    x = x + widgets.button(x, row, "↓", theme, nudge(0, NUDGE), nil, true) + 2
    x = x + widgets.button(x, row, "reset", theme, function()
        settings.offsetX, settings.offsetY = 0, 0
        self.dirty = true
    end, nil, false) + 2

    -- Typing beats nudging four pixels at a time when you know the number.
    local function typeCoordinate(axis)
        return function()
            local typed = widgets.prompt(2, rows - 2, 20, settings[axis] or 0, theme, true)
            local number = tonumber(typed)
            if number then settings[axis] = math.floor(number) end
            self.dirty = true
        end
    end
    x = x + widgets.button(x, row, "X " .. (settings.offsetX or 0), theme,
        typeCoordinate("offsetX"), nil, false) + 1
    x = x + widgets.button(x, row, "Y " .. (settings.offsetY or 0), theme,
        typeCoordinate("offsetY"), nil, false) + 2
    graphics.text(x, row, "click X/Y to type exact values", theme.muted, true)
    row = row + 1

    -- Rendering --------------------------------------------------------------
    label("Card")
    x = 14
    x = x + widgets.button(x, row, settings.compact and "compact" or "full", theme, function()
        settings.compact = not settings.compact self.dirty = true
    end, nil, settings.compact) + 2

    -- Viewport comes from the glasses_on signal; the manual GUI scale is only a
    -- fallback for before they have been worn.
    local viewport = self.hud and self.hud.viewport[self.selectedGlasses]
    x = x + widgets.button(x, row, settings.autoResolution ~= false and "auto size" or "manual",
        theme, function()
            settings.autoResolution = not (settings.autoResolution ~= false)
            self.dirty = true
        end, nil, settings.autoResolution ~= false) + 2

    if settings.autoResolution ~= false then
        if viewport then
            graphics.text(x, row, string.format("detected %dx%d", viewport.width, viewport.height),
                theme.muted, true)
        else
            graphics.text(x, row, "put the glasses on to detect the size", theme.muted, true)
        end
    else
        graphics.text(x, row, "GUI scale", theme.muted, true)
        x = x + 10
        widgets.button(x, row, tostring(settings.scale), theme, function()
            settings.scale = cycleValue(SCALES, settings.scale)
            self.dirty = true
        end, nil, true)
    end
    row = row + 2

    -- The category shows up as "OC Glasses"; openGlasses is only the lang key.
    -- Both bindings ship unbound, which is the single most common reason the HUD
    -- looks unresponsive.
    graphics.text(2, row, "In-game: Controls → \"OC Glasses\" → bind \"Free Cursor (Toggle)\".",
        theme.muted, true)
    graphics.text(2, row + 1, "It is UNBOUND by default. Then: ← → switch, 1-9 pick, C cycles.",
        theme.muted, true)
    row = row + 3
    graphics.text(2, row, "Changes apply instantly. Press Save to keep them.", theme.muted, true)
end

local ROLES = {"standalone", "server", "client"}

local ROLE_HELP = {
    standalone = "this computer only — no networking",
    server     = "collects buffers from the clients below and shows them alongside its own",
    client     = "answers a server's polls with this base's buffers",
}

function app:drawNetwork(width, rows, theme)
    local network = self.config.network

    graphics.text(2, 1, "Network", theme.primary, true)
    graphics.text(10, 1, "· one server, one client per remote base", theme.muted, true)
    panel.rule(2, 2, width - 2, theme)

    local row = 4
    local function label(name) graphics.text(2, row, name, theme.muted, true) end

    -- Role -------------------------------------------------------------------
    label("Role")
    local x = 14
    for _, role in ipairs(ROLES) do
        x = x + widgets.button(x, row, role, theme, function()
            network.role = role
            self.dirty = true
        end, nil, network.role == role) + 1
    end
    row = row + 1
    graphics.text(14, row, ROLE_HELP[network.role] or "", theme.muted, true)
    row = row + 2

    -- Settings ---------------------------------------------------------------
    local function typeNumber(key, low, high, suffix)
        return function()
            local typed = widgets.prompt(2, rows - 2, 20, network[key] or 0, theme, true)
            local value = tonumber(typed)
            if value then
                network[key] = math.floor(math.min(high, math.max(low, value)))
                self:notify(key .. ": " .. network[key] .. (suffix or ""))
            end
            self.dirty = true
        end
    end

    label("Port")
    -- Both ends must agree, and a modem silently drops messages on a port it
    -- has not opened — so a mismatch looks exactly like "no clients".
    x = 14 + widgets.button(14, row, tostring(network.port), theme,
        typeNumber("port", 1, 65535), nil, false) + 2
    graphics.text(x, row, "must match on every base", theme.muted, true)
    row = row + 1

    -- The one setting a shared server makes non-optional.
    label("Network key")
    local key = self.server and self.server.transport:key() or "?"
    x = 14 + widgets.button(14, row, key, theme, function()
        local typed = widgets.prompt(2, rows - 2, 32, network.key or key, theme)
        if typed then
            typed = typed:gsub("%s+", ""):upper()
            network.key = (typed ~= "") and typed or nil
            self:notify("Key set — every base must use the same one")
        end
        self.dirty = true
    end, nil, true) + 2
    if network.role == "server" then
        graphics.text(x, row, "copy this onto every client of yours", theme.muted, true)
    else
        graphics.text(x, row, "must match your server's key", theme.muted, true)
    end
    row = row + 1
    graphics.text(14, row, "keeps other players' ARGUS out — a broadcast reaches everyone in range",
        theme.muted, true)
    row = row + 1

    label("This node")
    x = 14 + widgets.button(14, row, self.server and self.server.transport:nodeName() or "?",
        theme, function()
            local typed = widgets.prompt(2, rows - 2, 32, network.name or "", theme)
            if typed then
                typed = typed:gsub("^%s+", ""):gsub("%s+$", "")
                network.name = (typed ~= "") and typed or nil
            end
            self.dirty = true
        end, nil, false) + 2
    graphics.text(x, row, "name this base reports to the server", theme.muted, true)
    row = row + 1

    if network.role == "server" then
        label("Poll")
        x = 14 + widgets.button(14, row, (network.pollInterval or 2) .. "s", theme,
            typeNumber("pollInterval", 1, 60, "s"), nil, false) + 2
        x = x + widgets.button(x, row, "timeout " .. (network.timeout or 15) .. "s", theme,
            typeNumber("timeout", 5, 300, "s"), nil, false) + 2
        graphics.text(x, row, "silence longer than the timeout marks a base offline",
            theme.muted, true)
        row = row + 1
    end
    row = row + 1

    -- Cards ------------------------------------------------------------------
    label("Cards")
    local modems, tunnels = 0, 0
    if self.server then
        for _, card in pairs(self.server.transport:cardList()) do
            if card.kind == "tunnel" then tunnels = tunnels + 1 else modems = modems + 1 end
        end
    end
    if modems + tunnels == 0 then
        graphics.text(14, row, "none — install a Network Card, Wireless Network Card,",
            palette.amber, true)
        graphics.text(14, row + 1, "or a Linked Card (crosses dimensions, pairs 1:1)",
            palette.amber, true)
        row = row + 2
    else
        graphics.text(14, row, string.format("%d modem, %d tunnel (linked card)", modems, tunnels),
            theme.text, true)
        row = row + 1
    end
    row = row + 1

    -- Clients ----------------------------------------------------------------
    if network.role ~= "server" then
        graphics.text(2, row, "Switch to `server` to see connected clients here.",
            theme.muted, true)
        return
    end

    local nodes = self.server and self.server:list() or {}
    panel.rule(2, row, width - 2, theme)
    row = row + 1
    graphics.text(2, row, "Clients (" .. #nodes .. ")", theme.primary, true)
    row = row + 1

    if #nodes == 0 then
        graphics.text(2, row, "None yet. On the other base: set role to `client`, use the",
            theme.muted, true)
        graphics.text(2, row + 1, "same port, and make sure a card links the two (wireless",
            theme.muted, true)
        graphics.text(2, row + 2, "range is 400 blocks at T2 and does not cross dimensions).",
            theme.muted, true)
        return
    end

    local now = computer.uptime()
    for _, node in ipairs(nodes) do
        if row > rows - 3 then break end
        local age = now - node.lastSeen
        local status = node.offline and "OFFLINE" or "online"
        local color = node.offline and palette.red or palette.green

        graphics.text(2, row, text.fit(node.name, 26), theme.text, true)
        graphics.text(29, row, node.address:sub(1, 8), theme.muted, true)
        graphics.text(39, row, #(node.buffers or {}) .. " buf", theme.muted, true)
        graphics.text(47, row, status, color, true)
        -- Distance is 0 over a wired modem or a linked card, which is not a
        -- fault — only a wireless hop has one.
        local detail = time.format(math.floor(age)) .. " ago"
        if (node.distance or 0) > 0 then
            detail = detail .. string.format("  %.0f blocks", node.distance)
        end
        graphics.text(57, row, detail, theme.muted, true)

        widgets.button(width - 11, row, "forget", theme, function()
            self.server:forget(node.address)
            self.dirty = true
        end, nil, false)
        row = row + 1
    end
end

-- Frame ---------------------------------------------------------------------

function app:footer(width, rows, theme)
    local row = rows
    panel.rule(2, rows - 1, width - 2, theme)

    local x = 2
    x = x + widgets.button(x, row, "Dashboard", theme, function()
        self.page = "dashboard" self.dirty = true
    end, nil, self.page == "dashboard") + 1

    x = x + widgets.button(x, row, "Buffers", theme, function()
        self.page = "buffers" self.dirty = true
    end, nil, self.page == "buffers") + 1

    x = x + widgets.button(x, row, "Glasses", theme, function()
        self.page = "glasses" self.dirty = true
    end, nil, self.page == "glasses") + 1

    x = x + widgets.button(x, row, "Network", theme, function()
        self.page = "network" self.dirty = true
    end, nil, self.page == "network") + 1

    x = x + widgets.button(x, row, "Graph: " .. format.window(self.config.screen.graphWindow or 600),
        theme, function() self:nextGraphWindow() self.dirty = true end, nil, false) + 1
    x = x + widgets.button(x, row, "set", theme, function() self:typeGraphWindow(rows) end,
        nil, false) + 1

    x = x + widgets.button(x, row, "Save", theme, function() self:save() end, nil, false) + 1
    x = x + widgets.button(x, row, "Quit", theme, function() self.running = false end, nil, false) + 2

    local build = self.build or buildLabel()
    self.build = build
    graphics.text(width - text.len(build) - 1, row, build, theme.muted, true)

    if self.status then
        graphics.text(x, row, self.status, theme.primary, true)
    end
end

function app:draw()
    local context = graphics.context()
    local width, rows = context.width, context.height
    local theme = self.config.theme

    widgets.reset()
    -- Render the whole frame offscreen, then blit it in one go. Painting
    -- directly to the screen shows the clear() and the repaint as separate
    -- steps, which is what made the UI flicker.
    graphics.beginFrame()
    graphics.clear()

    if self.page == "buffers" then
        self:drawBuffers(width, rows, theme)
    elseif self.page == "glasses" then
        self:drawGlasses(width, rows, theme)
    elseif self.page == "network" then
        self:drawNetwork(width, rows, theme)
    else
        self:drawDashboard(width, rows, theme)
    end

    self:footer(width, rows, theme)
    graphics.endFrame()
end

function app:onTouch(x, row)
    self.status = nil
    widgets.dispatch(math.floor(x), math.floor(row))
end

return app
