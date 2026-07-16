-- Polls the configured buffers and turns raw readings into display-ready views.
--
-- Produces three kinds of view, all the same shape so any renderer can show any
-- of them without special cases:
--   * one per configured physical buffer
--   * a virtual "Wireless EU" view per LSC that has wireless mode enabled
--     (the wireless network is not a component — it is only readable through
--     the owning LSC's sensor text)
--   * an "All buffers" aggregate summing every enabled buffer
--
-- Each view carries its own metrics tracker, so the aggregate gets a real
-- measured rate and graph rather than a sum of rounded per-buffer rates.

local computer = require("computer")
local metrics = require("core.metrics")
local sources = require("core.sources")
local states = require("core.states")

local monitor = {}
monitor.__index = monitor

monitor.AGGREGATE_ID = "@aggregate"

local STATE_SEVERITY = {
    [states.PROBLEM] = 5,
    [states.MISSING] = 4,
    [states.OFF]     = 3,
    [states.ONLINE]  = 2,
    [states.IDLE]    = 1,
}

function monitor.new(config)
    return setmetatable({
        config = config,
        trackers = {},
        views = {},
        order = {},
    }, monitor)
end

-- Sample spacing the graph should currently use, from the chosen window.
function monitor:graphInterval()
    local screen = self.config.screen or {}
    return metrics.intervalFor(screen.graphWindow or 600)
end

function monitor:tracker(id)
    local tracker = self.trackers[id]
    if not tracker then
        tracker = metrics.new(self:graphInterval())
        self.trackers[id] = tracker
    end
    return tracker
end

-- Build a view and fold in the derived numbers.
function monitor:buildView(id, base, now)
    local tracker = self:tracker(id)
    -- Picks up a window the user changed since the last poll.
    metrics.setGraphInterval(tracker, self:graphInterval())

    if base.state == states.MISSING then
        -- Do not let a gap in readings become a fake spike in the rate.
        metrics.reset(tracker)
    else
        metrics.update(tracker, base.stored or 0, now)
    end

    local view = base
    view.id = id
    view.tracker = tracker
    view.capacity = view.capacity or 0
    view.stored = view.stored or 0
    view.percent = (view.capacity > 0) and math.min(view.stored / view.capacity, 1.0) or nil

    -- Measured rate is authoritative: it already includes passive loss and works
    -- for sources that report no throughput at all. EU IN/OUT is the fallback
    -- until enough samples exist.
    local measured = metrics.rate(tracker, now, 5)
    if measured then
        view.net = measured
    else
        view.net = (view.euIn or 0) - (view.euOut or 0) - (view.passiveLoss or 0)
    end

    view.avg5m = view.avg5m or metrics.average(tracker, now, 300)
    view.avg1h = view.avg1h or metrics.average(tracker, now, 3600)
    view.fillSeconds, view.fillDirection = metrics.projection(view.stored, view.capacity, view.net)

    return view
end

local function worstState(a, b)
    if not a then return b end
    if not b then return a end
    return (STATE_SEVERITY[b] or 0) > (STATE_SEVERITY[a] or 0) and b or a
end

function monitor:update()
    local now = computer.uptime()
    local views, order = {}, {}

    local function add(view)
        views[view.id] = view
        table.insert(order, view.id)
    end

    local total = {
        name = "All buffers", kind = "aggregate",
        stored = 0, capacity = 0, euIn = 0, euOut = 0,
        passiveLoss = 0, problems = 0, state = nil, members = 0,
    }

    for _, entry in ipairs(self.config.buffers or {}) do
        if entry.enabled ~= false then
            local reading = sources.read(entry)
            local view = self:buildView(entry.address, reading, now)
            add(view)

            if view.state ~= states.MISSING then
                total.stored = total.stored + view.stored
                total.capacity = total.capacity + view.capacity
                total.euIn = total.euIn + (view.euIn or 0)
                total.euOut = total.euOut + (view.euOut or 0)
                total.passiveLoss = total.passiveLoss + (view.passiveLoss or 0)
                total.members = total.members + 1
            end
            total.problems = total.problems + (view.problems or 0)
            total.state = worstState(total.state, view.state)

            -- The wireless network has no component of its own; surface it as a
            -- separate selectable view hanging off the LSC that reports it.
            local wireless = view.wireless
            if wireless and wireless.enabled then
                local wirelessView = self:buildView(entry.address .. ":wireless", {
                    name = (entry.name or view.name) .. " · Wireless",
                    kind = "wireless",
                    address = entry.address,
                    state = view.state == states.MISSING and states.MISSING or states.ONLINE,
                    stored = wireless.stored or 0,
                    storedText = wireless.storedText,
                    -- A wireless network is unbounded: there is no capacity, so
                    -- renderers must fall back to a rate-only layout.
                    capacity = 0,
                    euIn = 0, euOut = 0, passiveLoss = 0, problems = 0,
                }, now)
                add(wirelessView)
            end
        end
    end

    total.state = total.state or states.MISSING
    add(self:buildView(monitor.AGGREGATE_ID, total, now))

    self.views, self.order = views, order
    return self
end

function monitor:get(id)
    return self.views[id]
end

-- Views in configuration order, aggregate last.
function monitor:list()
    local out = {}
    for _, id in ipairs(self.order) do table.insert(out, self.views[id]) end
    return out
end

-- Resolve what a display should show: an explicit id, or the aggregate.
-- Falls back to the aggregate when a configured id no longer exists (buffer
-- removed from the config, wireless mode switched off).
function monitor:resolve(id)
    if id and self.views[id] then return self.views[id] end
    return self.views[monitor.AGGREGATE_ID]
end

return monitor
