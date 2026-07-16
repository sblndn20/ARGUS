-- Per-buffer rate tracking.
--
-- The net rate is measured from how `stored` actually changes over time rather
-- than from EU IN minus EU OUT. That works for every source (IC2 storage
-- exposes no throughput at all) and it accounts for passive loss automatically.
--
-- Three rings keep memory flat. Each is a fixed number of slots, so an hour of
-- history costs exactly what a minute does:
--   fast   — the live rate, sampled every poll
--   graph  — whatever the user is looking at; its interval is derived from the
--            chosen window, so a 2-minute window means one point per second
--   slow   — the 1-hour average
--
-- The graph gets its own ring rather than a fixed set of scales: one ring that
-- follows the window is both cheaper and lets any window be chosen.
--
-- Precision note: `stored` is a Lua double, so past 2^53 EU its ULP grows to
-- hundreds of EU. That is irrelevant for a rate — the delta over a multi-second
-- window dwarfs it — but it is why exact display uses the string variant.

local ring = require("core.ring")

local metrics = {}

local FAST_CAPACITY = 60      -- the live rate window
local SLOW_CAPACITY = 130     -- ~65min at 1 sample / 30s
local SLOW_INTERVAL = 30

-- Points the graph keeps. Also the width it is drawn at, so one sample is one
-- column and nothing is thrown away or interpolated.
local GRAPH_COLUMNS = 120
metrics.GRAPH_COLUMNS = GRAPH_COLUMNS

local TICKS_PER_SECOND = 20

-- Sample spacing for a given window. This is the whole point of the design: the
-- window divided by the column count IS the step, so a 2-minute window plots one
-- point per second. Floored at the poll rate, below which there is nothing new
-- to record.
function metrics.intervalFor(windowSeconds)
    return math.max(0.25, (windowSeconds or 600) / GRAPH_COLUMNS)
end

function metrics.new(graphInterval)
    return {
        fast = ring.new(FAST_CAPACITY),
        graph = ring.new(GRAPH_COLUMNS),
        slow = ring.new(SLOW_CAPACITY),
        graphInterval = graphInterval or metrics.intervalFor(600),
        lastGraph = nil,
        lastSlow = nil,
    }
end

-- Re-space the graph. The samples already collected sit at the old spacing, so
-- keeping them would draw a curve whose X axis lies; drop them and refill.
function metrics.setGraphInterval(tracker, interval)
    if tracker.graphInterval == interval then return end
    tracker.graphInterval = interval
    tracker.graph:clear()
    tracker.lastGraph = nil
end

function metrics.update(tracker, stored, now)
    tracker.fast:push(now, stored)
    if not tracker.lastGraph or (now - tracker.lastGraph) >= tracker.graphInterval then
        tracker.graph:push(now, stored)
        tracker.lastGraph = now
    end
    if not tracker.lastSlow or (now - tracker.lastSlow) >= SLOW_INTERVAL then
        tracker.slow:push(now, stored)
        tracker.lastSlow = now
    end
end

-- Reset after a source disappears or is swapped, so the rate is not computed
-- across a discontinuity in `stored`.
function metrics.reset(tracker)
    tracker.fast:clear()
    tracker.graph:clear()
    tracker.slow:clear()
    tracker.lastGraph, tracker.lastSlow = nil, nil
end

-- The ring behind the graph, so the UI can plot history without the monitor
-- keeping a second copy of it.
function metrics.series(tracker)
    return tracker.graph
end

local function slope(buffer, now, window)
    if buffer.count < 2 then return nil end
    local newT, newV = buffer:newest()
    local oldT, oldV = buffer:since(now, window)
    if not oldT or not newT then return nil end
    local dt = newT - oldT
    if dt <= 0 then return nil end
    return (newV - oldV) / (dt * TICKS_PER_SECOND)
end

-- Live net rate in EU/t (positive = charging).
function metrics.rate(tracker, now, window)
    return slope(tracker.fast, now, window or 5)
end

-- Long-window average in EU/t, or nil until enough history exists.
function metrics.average(tracker, now, window)
    local oldest = tracker.slow:oldest()
    if not oldest then return nil end
    -- Refuse to label a 2-minute sample as a 1-hour average.
    if (now - oldest) < math.min(window, 60) then return nil end
    return slope(tracker.slow, now, window)
end

-- Seconds until full (net > 0) or empty (net < 0).
-- Returns: seconds, direction ("full" | "empty"), or nil when static.
function metrics.projection(stored, capacity, net)
    if not net or net == 0 then return nil, nil end
    if net > 0 then
        if capacity <= 0 or stored >= capacity then return nil, nil end
        return (capacity - stored) / (net * TICKS_PER_SECOND), "full"
    end
    if stored <= 0 then return nil, nil end
    return stored / (-net * TICKS_PER_SECOND), "empty"
end

return metrics
