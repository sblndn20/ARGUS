-- The energy panel (AR glasses HUD).
--
-- Same information as the on-screen panel, condensed into a card that does not
-- fight the game view. Redesigned rather than ported: NIDAS drew a full-width
-- bar welded to the bottom of the screen with a dozen chrome quads and an
-- animated charge pulse. This is a compact card with one bar and four fields.
--
-- Glasses objects are created ONCE and mutated per tick. Recreating them every
-- frame leaks objects into the glasses until it chokes — the AR API has no
-- implicit frame boundary.

local ar = require("lib.graphics.ar")
local palette = require("lib.graphics.colors")
local screen = require("lib.utils.screen")
local text = require("lib.utils.text")

local format = require("ui.format")
local states = require("core.states")

local panel = {}
panel.__index = panel

local WIDTH = 190
local HEIGHT = 34
local COMPACT_WIDTH = 120
local MARGIN = 4

-- Where the card sits. Minecraft's own HUD is not negotiable, so the anchor has
-- to be the user's choice: chat occupies the bottom-left, the hotbar and health
-- the bottom-centre, potion effects the top-right. top-left is the default
-- because it is usually the emptiest.
panel.ANCHORS = {
    "top-left", "top-center", "top-right",
    "bottom-left", "bottom-center", "bottom-right",
}

local function anchorPosition(anchor, resolution, width)
    local left = MARGIN
    local center = (resolution[1] - width) / 2
    local right = resolution[1] - width - MARGIN
    local top = MARGIN
    local bottom = resolution[2] - HEIGHT - MARGIN

    local positions = {
        ["top-left"]      = {left, top},
        ["top-center"]    = {center, top},
        ["top-right"]     = {right, top},
        ["bottom-left"]   = {left, bottom},
        ["bottom-center"] = {center, bottom},
        ["bottom-right"]  = {right, bottom},
    }
    local position = positions[anchor] or positions["top-left"]
    return position[1], position[2]
end

panel.anchorPosition = anchorPosition

local STATE_COLORS = {
    [states.ONLINE]  = palette.green,
    [states.IDLE]    = palette.muted,
    [states.OFF]     = palette.slate,
    [states.PROBLEM] = palette.amber,
    [states.MISSING] = palette.red,
}

local function chargeColor(fraction, theme)
    if fraction == nil then return theme.primary end
    if fraction < 0.10 then return palette.red end
    if fraction < 0.25 then return palette.amber end
    if fraction > 0.95 then return palette.green end
    return theme.primary
end

function panel.new(glasses, settings, theme)
    local resolution = screen.size({settings.resX, settings.resY}, settings.scale)
    local width = settings.compact and COMPACT_WIDTH or WIDTH

    -- Snap to the chosen corner, then apply the user's nudge on top.
    local x, y = anchorPosition(settings.anchor, resolution, width)
    x = x + (settings.offsetX or 0)
    y = y + (settings.offsetY or 0)

    local self = setmetatable({
        glasses = glasses,
        theme = theme,
        width = width,
        x = x,
        y = y,
        static = {},
        dynamic = {},
        lastColor = nil,
    }, panel)

    local barY = y + 14
    local barWidth = width - 16

    -- Chrome
    table.insert(self.static, ar.rectangle(glasses, {x, y}, width, HEIGHT, theme.background, 0.55))
    table.insert(self.static, ar.rectangle(glasses, {x, y}, 2, HEIGHT, theme.primary, 0.9))
    table.insert(self.static, ar.rectangle(glasses, {x + 8, barY}, barWidth, 4, theme.panel, 0.8))

    -- Live fields
    self.dynamic.name = ar.text(glasses, "", {x + 8, y + 4}, theme.muted, 0.7)
    self.dynamic.percent = ar.text(glasses, "", {x + width - 44, y + 3}, theme.primary, 1.0)
    self.dynamic.bar = ar.rectangle(glasses, {x + 8, barY}, 1, 4, theme.primary, 1.0)
    self.dynamic.stored = ar.text(glasses, "", {x + 8, y + 21}, palette.text, 0.7)
    self.dynamic.rate = ar.text(glasses, "", {x + width - 60, y + 21}, palette.text, 0.7)
    self.dynamic.projection = ar.text(glasses, "", {x + 8, y + 28}, theme.muted, 0.6)
    self.dynamic.state = ar.text(glasses, "", {x + width - 60, y + 28}, palette.muted, 0.6)

    self.barX = x + 8
    self.barY = barY
    self.barWidth = barWidth

    return self
end

function panel:setBar(fraction, color)
    local filled = math.max(1, self.barWidth * math.min(1, math.max(0, fraction or 0)))
    -- ar.rectangle lays vertices out as TL, BL, BR, TR — so widening the bar
    -- means moving the two right-hand vertices only.
    self.dynamic.bar.setVertex(3, self.barX + filled, self.barY + 4)
    self.dynamic.bar.setVertex(4, self.barX + filled, self.barY)
    if color ~= self.lastColor then
        self.dynamic.bar.setColor(screen.toRGB(color))
        self.dynamic.percent.setColor(screen.toRGB(color))
        self.lastColor = color
    end
end

function panel:update(view)
    if not view then return end

    local fraction = view.percent
    local color = chargeColor(fraction, self.theme)

    -- text.upper, not :upper — string.upper only handles ASCII and would leave
    -- a non-Latin buffer name untouched or mangled.
    self.dynamic.name.setText(text.upper(view.name or "?"))
    self.dynamic.percent.setText(format.percent(fraction))
    self:setBar(fraction or 0, color)

    -- Glasses text is small and the card is narrow, so exact digits do not fit;
    -- the compact form is the honest choice here.
    local stored = format.compact(view.stored)
    if view.capacity and view.capacity > 0 then
        stored = stored .. " / " .. format.compact(view.capacity)
    end
    self.dynamic.stored.setText(stored)

    self.dynamic.rate.setText(format.rate(view.net))
    self.dynamic.rate.setColor(screen.toRGB((view.net or 0) >= 0 and palette.green or palette.red))

    local projectionLabel, projectionValue = format.projection(view.fillSeconds, view.fillDirection)
    self.dynamic.projection.setText(projectionLabel and (projectionLabel .. " " .. projectionValue) or "")

    if view.state == states.ONLINE or view.state == states.IDLE then
        self.dynamic.state.setText(view.problems and view.problems > 0 and "MAINTENANCE" or "")
    else
        self.dynamic.state.setText(tostring(view.state or ""))
    end
    self.dynamic.state.setColor(screen.toRGB(STATE_COLORS[view.state] or palette.muted))
end

function panel:remove()
    ar.remove(self.glasses, self.static)
    local dynamic = {}
    for _, object in pairs(self.dynamic) do table.insert(dynamic, object) end
    ar.remove(self.glasses, dynamic)
    self.static, self.dynamic = {}, {}
end

return panel
