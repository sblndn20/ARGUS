-- The crafting panel (AR glasses HUD).
--
-- A second, independent card next to the energy one: one row per busy CPU,
-- showing what was ordered, what is in a machine right now, and what is waiting.
-- A stalled job turns the row amber and says how long it has been frozen and
-- what should have gone next.
--
-- Same rules as ar/panel.lua, for the same reasons:
--   * objects are created ONCE and mutated per tick — the AR API has no frame
--     boundary, so recreating them leaks into the glasses until it chokes;
--   * "buttons" are rectangles plus hit boxes we test ourselves, because
--     OCGlasses offers drawing primitives and nothing interactive.
--
-- Row count is fixed at construction. The rows are real glasses objects, so a
-- list that grew and shrank with the number of busy CPUs would mean creating and
-- destroying objects every poll — exactly the leak above. Instead every row is
-- built up front and emptied when unused.

local ar = require("lib.graphics.ar")
local palette = require("lib.graphics.colors")
local screen = require("lib.utils.screen")
local text = require("lib.utils.text")

local craftLib = require("core.craft")
local time = require("lib.utils.time")

local panel = {}
panel.__index = panel

local WIDTH = 230
local HEADER = 13
local ROW_HEIGHT = 15
local MARGIN = 4
local PADDING = 3

-- Same six corners as the energy card, plus "manual". Duplicated deliberately
-- rather than imported: the two cards are independent, and pinning them to one
-- another's anchor list is exactly the coupling that makes moving one move the
-- other later on.
panel.ANCHORS = {
    "top-left", "top-center", "top-right",
    "bottom-left", "bottom-center", "bottom-right",
    "manual",
}

local STATE_COLORS = {
    [craftLib.CRAFTING] = palette.green,
    [craftLib.STALLED]  = palette.amber,
    [craftLib.IDLE]     = palette.muted,
    [craftLib.MISSING]  = palette.red,
}

local function height(rows)
    return HEADER + rows * ROW_HEIGHT + PADDING
end

panel.height = height

local function anchorPosition(anchor, resolution, width, cardHeight)
    local left = MARGIN
    local center = (resolution[1] - width) / 2
    local right = resolution[1] - width - MARGIN
    local top = MARGIN
    local bottom = resolution[2] - cardHeight - MARGIN

    local positions = {
        ["top-left"]      = {left, top},
        ["top-center"]    = {center, top},
        ["top-right"]     = {right, top},
        ["bottom-left"]   = {left, bottom},
        ["bottom-center"] = {center, bottom},
        ["bottom-right"]  = {right, bottom},
        -- Origin, so the caller's offsets become absolute coordinates.
        ["manual"]        = {0, 0},
    }
    local position = positions[anchor] or positions["top-right"]
    return position[1], position[2]
end

panel.anchorPosition = anchorPosition

-- "64x Titanium Ingot", clipped to fit.
--
-- text.fit, not :sub — a byte slice cuts a UTF-8 item name mid-character, and
-- modded item labels are full of non-ASCII.
local function itemLabel(item, width)
    if not item then return "" end
    local size = item.size or 1
    local prefix = (size > 1) and (size .. "x ") or ""
    return prefix .. text.fit(item.label or "?", width)
end

function panel.new(glasses, settings, theme, resolution)
    local rows = math.max(1, math.min(8, math.floor(settings.rows or 4)))
    local cardHeight = height(rows)

    local x, y = anchorPosition(settings.anchor, resolution, WIDTH, cardHeight)
    x = x + (settings.offsetX or 0)
    y = y + (settings.offsetY or 0)

    local self = setmetatable({
        glasses = glasses,
        theme = theme,
        rows = rows,
        width = WIDTH,
        height = cardHeight,
        x = x,
        y = y,
        page = 0,
        static = {},
        dynamic = {},
        rowObjects = {},
        regions = {},
    }, panel)

    -- Chrome. The accent stripe distinguishes this card from the energy one at a
    -- glance, which matters when both are on screen.
    table.insert(self.static, ar.rectangle(glasses, {x, y}, WIDTH, cardHeight, theme.background, 0.55))
    table.insert(self.static, ar.rectangle(glasses, {x, y}, 2, cardHeight, theme.accent, 0.9))

    -- Header
    self.dynamic.title = ar.text(glasses, "CRAFTING", {x + 7, y + 3}, theme.accent, 0.7)
    self.dynamic.summary = ar.text(glasses, "", {x + 62, y + 3}, theme.muted, 0.6)

    -- Paging arrows, for when more CPUs are busy than there are rows. Hit boxes
    -- are deliberately larger than the glyphs: aimed with a free cursor over a
    -- moving game view.
    self.dynamic.prev = ar.text(glasses, "‹", {x + WIDTH - 26, y + 2}, theme.accent, 0.8)
    self.dynamic.next = ar.text(glasses, "›", {x + WIDTH - 14, y + 2}, theme.accent, 0.8)
    self:addRegion(x + WIDTH - 29, y, 12, 12, "craft:prev")
    self:addRegion(x + WIDTH - 17, y, 12, 12, "craft:next")

    -- Clicking the header toggles the stalled-only filter, mirroring how the
    -- energy card's name toggles cycling: one card, one obvious place to click.
    self:addRegion(x + 4, y, WIDTH - 36, 12, "craft:filter")

    for i = 1, rows do
        local rowY = y + HEADER + (i - 1) * ROW_HEIGHT
        self.rowObjects[i] = {
            -- Line 1: the ordered item and the job state.
            output = ar.text(glasses, "", {x + 7, rowY}, palette.text, 0.7),
            state = ar.text(glasses, "", {x + WIDTH - 62, rowY}, palette.muted, 0.6),
            -- Line 2: where the chain is right now.
            chain = ar.text(glasses, "", {x + 7, rowY + 8}, theme.muted, 0.6),
        }
    end

    -- Shown instead of the rows when there is nothing to list, so an enabled
    -- card is never a blank rectangle with no explanation.
    self.dynamic.empty = ar.text(glasses, "", {x + 7, y + HEADER + 2}, theme.muted, 0.6)

    return self
end

function panel:addRegion(x, y, width, rowHeight, action)
    table.insert(self.regions, {x = x, y = y, width = width, height = rowHeight, action = action})
end

-- Returns the action under a hud_click, or nil when the click missed the card.
function panel:hitTest(x, y)
    for i = 1, #self.regions do
        local region = self.regions[i]
        if x >= region.x and x < region.x + region.width
            and y >= region.y and y < region.y + region.height then
            return region.action
        end
    end
    return nil
end

local function clearRow(row)
    row.output.setText("")
    row.state.setText("")
    row.chain.setText("")
end

-- What the chain line says for one job.
--
-- "next" is the largest pending stack, not AE2's actual scheduling order — the
-- API exposes a set, not a queue (see core/craft.lua). The wording says
-- "waiting" rather than implying a promise about what runs next.
local function chainText(job)
    if job.state == craftLib.STALLED then
        local frozen = time.format(job.stalledFor or 0)
        if job.next then
            return "PAUSED " .. frozen .. " · expected: " .. itemLabel(job.next, 22)
        end
        return "PAUSED " .. frozen .. " · " .. (job.stallReason or "no progress")
    end

    local parts = {}
    if job.now then
        table.insert(parts, "now " .. itemLabel(job.now, 18))
    end
    if job.next then
        table.insert(parts, "next " .. itemLabel(job.next, 18))
    end
    if #parts == 0 then
        -- Busy with everything already built and nothing dispatched: the job is
        -- assembling its final output from stored intermediates.
        return #job.stored > 0 and "finishing up" or "starting"
    end
    return table.concat(parts, " → ")
end

-- The ordered item, or why it is not known.
--
-- The driver reads the final output off a Crafting Monitor block inside the CPU
-- cluster. Without one it returns "No crafting monitor" and there is no
-- fallback — so the card says which block to add rather than showing "?".
local function outputText(job)
    if job.output then
        return itemLabel(job.output, 26)
    end
    if job.outputError and tostring(job.outputError):find("monitor") then
        return job.cpuName .. " · add Crafting Monitor"
    end
    return job.cpuName
end

function panel:update(craftMonitor, settings)
    local summary = craftMonitor:summary()
    local jobs = craftMonitor:busy()

    if settings and settings.stalledOnly then
        local filtered = {}
        for _, job in ipairs(jobs) do
            if job.state == craftLib.STALLED then table.insert(filtered, job) end
        end
        jobs = filtered
    end

    -- Header ------------------------------------------------------------------
    local stalled = summary.stalled or 0
    self.dynamic.title.setText(stalled > 0 and "CRAFTING ⚠" or "CRAFTING")
    self.dynamic.title.setColor(screen.toRGB(stalled > 0 and palette.amber or self.theme.accent))

    local caption
    if summary.error then
        caption = summary.error
    else
        caption = string.format("%d/%d busy", summary.busy or 0, summary.total or 0)
        if stalled > 0 then caption = caption .. " · " .. stalled .. " stalled" end
        if settings and settings.stalledOnly then caption = caption .. " · filtered" end
    end
    self.dynamic.summary.setText(caption)

    -- Paging ------------------------------------------------------------------
    -- Clamp before drawing: the list shrinks as jobs finish, and a page index
    -- left pointing past the end would show an empty card while work is running.
    local pages = math.max(1, math.ceil(#jobs / self.rows))
    if self.page >= pages then self.page = pages - 1 end
    if self.page < 0 then self.page = 0 end

    local paged = pages > 1
    self.dynamic.prev.setAlpha(paged and 0.9 or 0)
    self.dynamic.next.setAlpha(paged and 0.9 or 0)
    if paged then
        self.dynamic.summary.setText(caption .. string.format(" · %d/%d", self.page + 1, pages))
    end

    -- Rows --------------------------------------------------------------------
    if #jobs == 0 then
        for i = 1, self.rows do clearRow(self.rowObjects[i]) end
        if summary.error then
            self.dynamic.empty.setText("no ME network reachable")
        elseif settings and settings.stalledOnly and (summary.busy or 0) > 0 then
            self.dynamic.empty.setText("no stalled jobs · " .. summary.busy .. " running")
        else
            self.dynamic.empty.setText("idle · nothing queued")
        end
        return
    end
    self.dynamic.empty.setText("")

    local offset = self.page * self.rows
    for i = 1, self.rows do
        local row = self.rowObjects[i]
        local job = jobs[offset + i]
        if not job then
            clearRow(row)
        else
            local color = STATE_COLORS[job.state] or palette.muted

            row.output.setText(outputText(job))
            row.output.setColor(screen.toRGB(job.state == craftLib.STALLED and palette.amber or palette.text))

            row.state.setText(job.state == craftLib.STALLED and "STALLED" or text.fit(job.cpuName, 12))
            row.state.setColor(screen.toRGB(color))

            row.chain.setText(chainText(job))
            row.chain.setColor(screen.toRGB(job.state == craftLib.STALLED and palette.amber or self.theme.muted))
        end
    end
end

-- Page through the list. Returns true when the page actually moved, so the
-- caller can tell a handled input from an ignored one.
function panel:scroll(step)
    local before = self.page
    self.page = math.max(0, self.page + step)
    return self.page ~= before
end

function panel:remove()
    ar.remove(self.glasses, self.static)

    local dynamic = {}
    for _, object in pairs(self.dynamic) do table.insert(dynamic, object) end
    for _, row in ipairs(self.rowObjects) do
        table.insert(dynamic, row.output)
        table.insert(dynamic, row.state)
        table.insert(dynamic, row.chain)
    end
    ar.remove(self.glasses, dynamic)

    self.static, self.dynamic, self.rowObjects, self.regions = {}, {}, {}, {}
end

return panel
