-- On-screen application: dashboard, buffer picker, glasses setup.
--
-- Redraws the whole screen each frame. NIDAS kept every window in a GPU buffer
-- and bitblt'd them, which is faster but needs a Tier 3 GPU; at this refresh
-- rate (a few frames per second) a plain redraw is cheap enough and keeps the
-- hardware requirement down.

local component = require("component")

local graphics = require("lib.graphics.graphics")
local palette = require("lib.graphics.colors")
local text = require("lib.utils.text")

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

local SCALE_ORDER = {"fast", "medium", "slow"}

function app.new(monitor, config)
    return setmetatable({
        monitor = monitor,
        config = config,
        page = "dashboard",
        running = true,
        dirty = true,
        status = nil,
    }, app)
end

function app:notify(message)
    self.status = message
end

function app:nextScale()
    local current = self.config.screen.graphScale
    for i, scale in ipairs(SCALE_ORDER) do
        if scale == current then
            self.config.screen.graphScale = SCALE_ORDER[i % #SCALE_ORDER + 1]
            return
        end
    end
    self.config.screen.graphScale = "medium"
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
    panel.draw(2, 4, width - 3, rows - 6, view, theme, palette, self.config.screen.graphScale)
end

function app:drawBuffers(width, rows, theme)
    graphics.text(2, 1, "Buffers", theme.primary, true)
    graphics.text(10, 1, "· click to show on screen, [on/off] to monitor", theme.muted, true)
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

        widgets.listItem(2, row, width - 14, caption, theme, isSelected, function()
            self.config.screen.source = isAggregate and nil or view.id
            self.dirty = true
        end, nil, entry and entry.enabled)

        if entry then
            widgets.button(width - 11, row, " on", theme, toggle(entry), nil, true)
        end
        row = row + 1
    end

    -- Disabled buffers are not polled, so the monitor builds no view for them
    -- and the loop above cannot show them. Listing them from the config too is
    -- what makes switching one back on possible at all.
    for _, entry in ipairs(self.config.buffers) do
        if entry.enabled == false and row <= rows - 4 then
            widgets.listItem(2, row, width - 14,
                text.fit(entry.name or entry.address, 28) .. "   not monitored",
                theme, false, toggle(entry), nil, false)
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
    label("Position")
    x = 14
    x = x + widgets.button(x, row, settings.anchor, theme, function()
        settings.anchor = cycleValue(arPanel.ANCHORS, settings.anchor)
        self.dirty = true
    end, nil, true) + 2
    graphics.text(x, row, "← chat sits bottom-left, hotbar bottom-centre", theme.muted, true)
    row = row + 1

    label("Nudge")
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
    graphics.text(x, row, string.format("(%+d, %+d) px", settings.offsetX or 0, settings.offsetY or 0),
        theme.muted, true)
    row = row + 1

    -- Rendering --------------------------------------------------------------
    label("Card")
    x = 14
    x = x + widgets.button(x, row, settings.compact and "compact" or "full", theme, function()
        settings.compact = not settings.compact self.dirty = true
    end, nil, settings.compact) + 2
    graphics.text(x, row, "GUI scale", theme.muted, true)
    x = x + 10
    x = x + widgets.button(x, row, tostring(settings.scale), theme, function()
        settings.scale = cycleValue(SCALES, settings.scale)
        self.dirty = true
    end, nil, true) + 2
    graphics.text(x, row, "must match Video Settings → GUI Scale", theme.muted, true)
    row = row + 2

    graphics.text(2, row, "Changes apply instantly. Press Save to keep them.", theme.muted, true)
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

    x = x + widgets.button(x, row, "Graph: " .. (panel.SCALE_LABELS[self.config.screen.graphScale] or "?"),
        theme, function() self:nextScale() self.dirty = true end, nil, false) + 1

    x = x + widgets.button(x, row, "Save", theme, function() self:save() end, nil, false) + 1
    widgets.button(x, row, "Quit", theme, function() self.running = false end, nil, false)

    if self.status then
        graphics.text(width - text.len(self.status) - 1, row, self.status, theme.muted, true)
    end
end

function app:draw()
    local context = graphics.context()
    local width, rows = context.width, context.height
    local theme = self.config.theme

    widgets.reset()
    graphics.clear()

    if self.page == "buffers" then
        self:drawBuffers(width, rows, theme)
    elseif self.page == "glasses" then
        self:drawGlasses(width, rows, theme)
    else
        self:drawDashboard(width, rows, theme)
    end

    self:footer(width, rows, theme)
end

function app:onTouch(x, row)
    self.status = nil
    widgets.dispatch(math.floor(x), math.floor(row))
end

return app
