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
        remote = {},
    }, monitor)
end

-- Readings from other bases, supplied by the server role (net/server.lua).
--
-- Held apart from config.buffers because they are not components on this
-- network and must never be polled locally — component networks cannot be
-- bridged, which is the whole reason distributed mode exists. They still become
-- ordinary views, so every renderer treats them like any other buffer.
function monitor:setRemote(list)
    self.remote = list or {}
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

    -- The change in `stored` is the truth. EU IN/OUT is only a fallback.
    --
    -- Briefly the other way round, on the theory that GregTech's own counters
    -- are faster and more precise. They are — but they only see what crossed a
    -- hatch. An LSC in wireless mode drains to the network without EU OUT ever
    -- registering it, and NET read as -1.9k EU/t (exactly the passive loss)
    -- while the buffer shed 700M. Wrong and fast is worse than right and a
    -- couple of seconds late, so the charge wins; the window is short instead.
    local measured = metrics.rate(tracker, now, metrics.RATE_WINDOW)
    if measured then
        view.net = measured
    else
        -- Only until enough samples exist — a fresh view, or one just reset.
        view.net = (view.euIn or 0) - (view.euOut or 0) - (view.passiveLoss or 0)
    end

    -- Same rule over the long windows: the charge is the truth.
    --
    -- GregTech's own windowed averages are used only until enough history
    -- exists, and they carry the same blind spot as EU IN/OUT — they count
    -- hatch traffic, so `received - sent` can read as nothing while the buffer
    -- visibly drains to a wireless network. When the two disagree, that gap is
    -- itself the information: energy moved somewhere the counters do not watch.
    view.avg5m = metrics.average(tracker, now, 300)
        or (view.avg5mIn and view.avg5mOut and (view.avg5mIn - view.avg5mOut))
        or view.avg5m
    view.avg1h = metrics.average(tracker, now, 3600)
        or (view.avg1hIn and view.avg1hOut and (view.avg1hIn - view.avg1hOut))
        or view.avg1h

    -- How much energy actually moved over each window. In and out separately
    -- when the source tracks them, because a net figure alone cannot tell a busy
    -- hour that balanced out from an idle one.
    view.total5m = {
        received = metrics.energyOver(view.avg5mIn, 300),
        sent = metrics.energyOver(view.avg5mOut, 300),
        net = metrics.energyOver(view.avg5m, 300),
    }
    view.total1h = {
        received = metrics.energyOver(view.avg1hIn, 3600),
        sent = metrics.energyOver(view.avg1hOut, 3600),
        net = metrics.energyOver(view.avg1h, 3600),
    }
    view.fillSeconds, view.fillDirection = metrics.projection(view.stored, view.capacity, view.net)

    -- A buffer whose charge is moving beyond its own leakage is not idle,
    -- whatever the throughput counters say.
    --
    -- Passive loss is subtracted first, because an untouched LSC always leaks —
    -- comparing the raw rate against zero would call every capacitor in the game
    -- ONLINE forever. And the comparison is against the noise floor rather than
    -- zero so that rounding on a nearly-full LSC cannot flicker the state.
    if view.state == states.IDLE then
        local beyondLeak = math.abs((view.net or 0) + (view.passiveLoss or 0))
        local floor = metrics.noiseFloor(view.stored, metrics.RATE_WINDOW)
        if beyondLeak > math.max(floor, 1) then
            view.state = states.ONLINE
        end
    end

    return view
end

local function worstState(a, b)
    if not a then return b end
    if not b then return a end
    return (STATE_SEVERITY[b] or 0) > (STATE_SEVERITY[a] or 0) and b or a
end

-- Fold one buffer into the aggregate.
--
-- Windowed averages are summed only while EVERY contributing buffer reports
-- them: a partial sum would silently understate "received in the last hour",
-- which is worse than admitting the figure is unavailable.
local function foldIntoTotal(total, view)
    if view.state ~= states.MISSING then
        total.stored = total.stored + (view.stored or 0)
        total.capacity = total.capacity + (view.capacity or 0)
        total.euIn = total.euIn + (view.euIn or 0)
        total.euOut = total.euOut + (view.euOut or 0)
        total.passiveLoss = total.passiveLoss + (view.passiveLoss or 0)
        total.members = total.members + 1

        if view.ratesUnavailable then total.ratesUnavailable = true end

        if view.avg5mIn and view.avg1hIn then
            total.avg5mIn = (total.avg5mIn or 0) + view.avg5mIn
            total.avg5mOut = (total.avg5mOut or 0) + (view.avg5mOut or 0)
            total.avg1hIn = (total.avg1hIn or 0) + view.avg1hIn
            total.avg1hOut = (total.avg1hOut or 0) + (view.avg1hOut or 0)
        else
            total.windowsIncomplete = true
        end
    end
    total.problems = total.problems + (view.problems or 0)
    total.state = worstState(total.state, view.state)
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
            foldIntoTotal(total, view)

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
                    -- Nothing reports throughput for the wireless network, so its
                    -- rate can only be measured from how the balance moves.
                    -- Without this the zeroes above would read as a flat zero.
                    ratesUnavailable = true,
                }, now)
                add(wirelessView)
            end
        end
    end

    -- Remote buffers. Folded into the aggregate on purpose: "all buffers" that
    -- silently meant "all buffers on this one network" would be worse than
    -- useless on a multi-base setup.
    for _, reading in ipairs(self.remote or {}) do
        -- Copy: buildView decorates the table it is handed, and these are owned
        -- by the server and reused between polls.
        local base = {}
        for key, value in pairs(reading) do base[key] = value end

        local view = self:buildView(base.id, base, now)
        view.remote = true
        add(view)
        foldIntoTotal(total, view)
    end

    -- Any buffer that could not report a windowed average makes the aggregate's
    -- in/out totals an undercount, so drop them rather than mislead.
    if total.windowsIncomplete then
        total.avg5mIn, total.avg5mOut = nil, nil
        total.avg1hIn, total.avg1hOut = nil, nil
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
