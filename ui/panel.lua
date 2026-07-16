-- The energy panel (on-screen).
--
-- A ground-up redesign rather than a port of the NIDAS AR overlay: that layout
-- was shaped by the constraints of a glasses HUD strip (one line, fixed 29px
-- tall, everything crammed around a charge bar). A monitor has room, so the
-- panel is laid out as a readable dashboard.
--
-- Text is drawn in terminal rows (standardY), boxes in graphics.lua's doubled
-- drawing space. Row `r` covers drawing rows 2r-1 and 2r.

local graphics = require("lib.graphics.graphics")
local screen = require("lib.utils.screen")
local text = require("lib.utils.text")

local format = require("ui.format")
local graph = require("ui.graph")
local widgets = require("ui.widgets")
local metrics = require("core.metrics")
local states = require("core.states")

local panel = {}

local STATE_COLORS = {
    [states.ONLINE]  = "green",
    [states.IDLE]    = "muted",
    [states.OFF]     = "slate",
    [states.PROBLEM] = "amber",
    [states.MISSING] = "red",
}

-- Eased bar position per view, so the fill glides instead of snapping between
-- readings. Keyed by view id and kept here rather than on the view because a
-- view is rebuilt from scratch on every poll.
local displayed = {}

local BAR_EASE = 0.3

local function easeBar(id, target)
    local current = displayed[id]
    if current == nil then current = target end
    current = current + (target - current) * BAR_EASE
    -- Settle exactly, or it creeps forever on floating-point remainder.
    if math.abs(target - current) < 0.0005 then current = target end
    displayed[id] = current
    return current
end

local function drawingY(row) return row * 2 - 1 end

-- Charge colour tracks how alarming the level is, not the theme accent: a
-- nearly-empty capacitor should read as red at a glance.
local function chargeColor(fraction, theme, palette)
    if fraction == nil then return theme.primary end
    if fraction < 0.10 then return palette.red end
    if fraction < 0.25 then return palette.amber end
    if fraction > 0.95 then return palette.green end
    return theme.primary
end

local function label(x, row, text, theme)
    graphics.text(x, row, text, theme.muted, true)
end

-- A label above its value, used for the metrics grid.
local function stat(x, row, name, value, theme, valueColor)
    label(x, row, name, theme)
    graphics.text(x + 7, row, value, valueColor or theme.text, true)
end

-- Draws the dashboard body into the given rectangle.
-- `rows` is the number of terminal rows available.
function panel.draw(x, row, width, rows, view, theme, palette, graphWindow)
    local bottom = row + rows - 1

    -- Charge headline -------------------------------------------------------
    local fraction = view.percent
    local fill = chargeColor(fraction, theme, palette)

    graphics.text(x, row, format.percent(fraction), fill, true)

    local projectionLabel, projectionValue = format.projection(view.fillSeconds, view.fillDirection)
    if projectionLabel then
        local caption = projectionLabel .. "  " .. projectionValue
        graphics.text(x + width - text.len(caption), row, caption, theme.muted, true)
    end

    -- Charge bar ------------------------------------------------------------
    local barRow = row + 1
    if fraction then
        -- The percentage above shows the real reading; only the bar is eased.
        widgets.bar(x, drawingY(barRow), width, 3, easeBar(view.id, fraction), fill,
            screen.blend(theme.panel, theme.background, 0.4))
    else
        -- A wireless network has no capacity, so there is nothing to fill.
        graphics.rectangle(x, drawingY(barRow) + 1, width, 1,
            screen.blend(theme.panel, theme.background, 0.4))
        graphics.text(x, barRow, " unbounded — no capacity ", theme.muted, true)
    end

    -- Absolute figures ------------------------------------------------------
    local storedRow = barRow + 3
    local stored = format.exact(view.stored, view.storedText)
    graphics.text(x, storedRow, stored, theme.text, true)
    if view.capacity and view.capacity > 0 then
        graphics.text(x + text.len(stored), storedRow,
            " / " .. format.compact(view.capacity), theme.muted, true)
    end

    -- Metrics grid ----------------------------------------------------------
    local gridRow = storedRow + 2
    local column = math.floor(width / 2)
    local netColor = (view.net or 0) >= 0 and palette.green or palette.red

    stat(x, gridRow, "NET", format.rate(view.net), theme, netColor)
    stat(x, gridRow + 1, "5 min", format.rate(view.avg5m), theme)
    stat(x, gridRow + 2, "1 h", format.rate(view.avg1h), theme)

    if view.kind ~= "wireless" then
        stat(x + column, gridRow, "IN", format.magnitude(view.euIn), theme, palette.green)
        stat(x + column, gridRow + 1, "OUT", format.magnitude(view.euOut), theme, palette.orange)
        stat(x + column, gridRow + 2, "LOSS", format.magnitude(view.passiveLoss), theme, palette.slate)
    end

    if view.problems and view.problems > 0 then
        graphics.text(x + column, gridRow + 3,
            "⚠ maintenance: " .. view.problems, palette.amber, true)
    end

    -- Graph -----------------------------------------------------------------
    local graphTop = gridRow + 5
    -- Cap the height: on a tall screen an uncapped graph swallows the panel and
    -- the numbers above it stop being the focus.
    local graphRows = math.min(bottom - graphTop, 12)
    if graphRows >= 3 then
        -- Spell out the resolution: the same curve means very different things
        -- at one point per second and one per half-minute.
        label(x, graphTop - 1, "Charge · last " .. format.window(graphWindow)
            .. " · " .. format.step(view.tracker.graphInterval), theme)

        local series = metrics.series(view.tracker)
        local height = graphRows * 2
        local min, max = graph.draw(x, drawingY(graphTop), width - 12, height, series, {
            muted = screen.blend(theme.muted, theme.background, 0.5),
            primary = theme.primary,
        })

        if min and max then
            -- The graph auto-scales, so the window bounds have to be visible or
            -- the shape of the line means nothing.
            graphics.text(x + width - 11, graphTop, format.compact(max), theme.muted, true)
            graphics.text(x + width - 11, graphTop + graphRows - 1, format.compact(min), theme.muted, true)
        end
    end
end

-- Header line: source name on the left, state pill on the right.
function panel.header(x, row, width, view, theme, palette)
    graphics.text(x, row, "EMON", theme.primary, true)

    local stateColor = palette[STATE_COLORS[view.state] or "muted"] or theme.muted
    local pill = "● " .. (view.state or "?")
    local pillWidth = text.len(pill)

    -- Truncate the name rather than let it collide with the state pill.
    graphics.text(x + 5, row, text.fit("· " .. (view.name or "?"), width - pillWidth - 6),
        theme.text, true)
    graphics.text(x + width - pillWidth, row, pill, stateColor, true)
end

function panel.rule(x, row, width, theme)
    graphics.rectangle(x, drawingY(row), width, 1, theme.panel)
end

return panel
