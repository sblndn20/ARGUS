-- Polls Applied Energistics crafting CPUs and turns them into display-ready jobs.
--
-- Reads through the OpenComputers ME driver (an Adapter touching an ME
-- Controller or ME Interface). Everything here depends on the GTNH fork of
-- OpenComputers: upstream exposes nothing about a running job beyond isDone()
-- on a request you issued yourself (OC issue #3786, still open). The GTNH fork's
-- NetworkControl.scala adds a Cpu value with activeItems / pendingItems /
-- storedItems / finalOutput, which is what makes this module possible at all.
--
-- Two things AE2 does NOT give us, and which are therefore derived here:
--
--   * Order. A crafting job is a tree of parallel subtasks, not a queue.
--     getListOfItem(PENDING) returns a SET. "Next" below is a heuristic — the
--     largest pending stack — and is labelled as "waiting", never as a promise
--     about what AE2 will actually schedule next.
--
--   * Stalls. There is no isStalled(). A stall is inferred from readings not
--     changing, which is why this module keeps per-job history at all.
--
-- Polling is not cheap: getCpus() plus up to four calls per CPU. Detail is only
-- read for busy CPUs, and the caller drives this on its own slower schedule.

local component = require("component")
local computer = require("computer")

local util = require("core.util")

local craft = {}
craft.__index = craft

-- Component types carrying the NetworkControl trait. An Adapter next to either
-- block sees the whole network, so whichever the user has is fine.
craft.COMPONENT_TYPES = {"me_controller", "me_interface"}

craft.CRAFTING = "CRAFTING"  -- work is being dispatched to machines
craft.STALLED  = "STALLED"   -- busy, but nothing has moved for too long
craft.IDLE     = "IDLE"      -- CPU free
craft.MISSING  = "MISSING"   -- controller unreachable

-- Nothing at all changed for this long while busy. Deliberately generous: a
-- single GT recipe legitimately runs for minutes, so a short timeout here would
-- cry wolf on every large machine.
craft.STALL_SECONDS = 120

-- Busy, work still pending, but NOTHING in any machine. This is the strong
-- signal — the job is not slow, it is not running: a missing ingredient, a
-- broken pattern, or no machine to take the recipe. It fires much sooner
-- because there is no legitimate reading that looks like this for long.
craft.EMPTY_STALL_SECONDS = 15

-- Attached ME components.
function craft.discover()
    local found = {}
    for _, componentType in ipairs(craft.COMPONENT_TYPES) do
        for address in component.list(componentType, true) do
            table.insert(found, {address = address, kind = componentType})
        end
    end
    table.sort(found, function(a, b) return a.address < b.address end)
    return found
end

-- One item entry from activeItems/pendingItems/storedItems.
--
-- convert() in the driver returns null when the stack cannot be described, and
-- a null lands in the Lua table as a hole — so this iterates with pairs(), not
-- ipairs(), which would stop dead at the first gap and silently under-report.
local function items(list)
    local out = {}
    if type(list) ~= "table" then return out end

    for _, entry in pairs(list) do
        if type(entry) == "table" then
            local size = tonumber(entry.size) or 0
            if size > 0 then
                table.insert(out, {
                    -- label is the human name ("Titanium Ingot"); name is the
                    -- registry id, and is the fallback because a modded item
                    -- without a label is still identifiable by it.
                    label = entry.label or entry.name or "?",
                    name = entry.name,
                    damage = tonumber(entry.damage) or 0,
                    size = size,
                })
            end
        end
    end

    -- pairs() has no defined order, so an unsorted list would reshuffle itself
    -- between polls and make the card flicker. Biggest first: that is the bulk
    -- of the work, and ties break by name to stay stable.
    table.sort(out, function(a, b)
        if a.size ~= b.size then return a.size > b.size end
        return (a.label or "") < (b.label or "")
    end)
    return out
end

-- A stack that survives being compared between polls.
local function signature(active, pending)
    local parts = {}
    for _, item in ipairs(active) do
        table.insert(parts, "a:" .. (item.name or item.label) .. ":" .. item.damage .. "x" .. item.size)
    end
    for _, item in ipairs(pending) do
        table.insert(parts, "p:" .. (item.name or item.label) .. ":" .. item.damage .. "x" .. item.size)
    end
    return table.concat(parts, "|")
end

function craft.new(config)
    return setmetatable({
        config = config,
        -- Per-job history, keyed by job id. This is the only reason a stall can
        -- be detected: the API is stateless, so the state lives here.
        history = {},
        jobs = {},
        order = {},
        controllers = {},
        error = nil,
    }, craft)
end

-- The final output of a job.
--
-- HARDWARE REQUIREMENT: the driver reads this off a TileCraftingMonitorTile
-- found inside the CPU cluster, so a CPU assembled without a Crafting Monitor
-- block reports nothing — there is no software fallback, AE2 keeps the job's
-- final output nowhere else the driver can reach. The error string is kept so
-- the UI can say which of the two it is ("no monitor" vs "no job").
-- Unlike the item lists this needs BOTH return values — the driver answers
-- `(null, "No crafting monitor")` or `(null, "Nothing is crafted")`, and telling
-- those apart is the difference between "add a block" and "nothing is running".
-- That is why it does not go through rawCall, which keeps only the first.
local function finalOutput(cpu)
    local got, fn = pcall(function() return cpu.finalOutput end)
    if not got or fn == nil then return nil, nil end

    local ok, stack, err = pcall(fn)
    if not ok then return nil, "unreadable" end
    if type(stack) ~= "table" then
        return nil, tostring(err or "unknown")
    end
    return {
        label = stack.label or stack.name or "?",
        name = stack.name,
        size = tonumber(stack.size) or 1,
    }, nil
end

-- Decide CRAFTING vs STALLED, and for how long.
--
-- Only ever called for a BUSY CPU: readCpu returns early for a free one, and is
-- responsible for clearing its history when it does.
function craft:classify(id, active, pending, now)
    local record = self.history[id]
    local current = signature(active, pending)

    if not record or record.signature ~= current then
        record = {signature = current, changedAt = now, startedAt = record and record.startedAt or now}
        self.history[id] = record
    end

    local frozenFor = now - record.changedAt
    local dispatchedNothing = #active == 0 and #pending > 0

    local limit = dispatchedNothing and craft.EMPTY_STALL_SECONDS or craft.STALL_SECONDS
    if self.config and self.config.craft then
        limit = dispatchedNothing
            and (self.config.craft.emptyStallSeconds or limit)
            or (self.config.craft.stallSeconds or limit)
    end

    if frozenFor >= limit then
        return craft.STALLED, frozenFor,
            dispatchedNothing and "nothing dispatched to any machine" or "no progress"
    end
    return craft.CRAFTING, frozenFor, nil
end

-- Read one CPU entry from getCpus().
function craft:readCpu(address, index, entry, now)
    local id = address .. "#" .. index
    local busy = entry.busy and true or false
    local name = entry.name
    -- AE2 leaves a CPU unnamed unless the player names it; index is all we have.
    if not name or name == "" then name = "CPU " .. index end

    local job = {
        id = id,
        address = address,
        cpuName = name,
        busy = busy,
        storage = tonumber(entry.storage) or 0,
        coprocessors = tonumber(entry.coprocessors) or 0,
        active = {},
        pending = {},
        stored = {},
    }

    -- An idle CPU has nothing to read, and reading it anyway would quadruple
    -- the call count on networks where most CPUs sit free.
    --
    -- Dropping the history here is not tidying, it is correctness: the next job
    -- on this CPU must start its stall clock from zero. Two consecutive jobs can
    -- produce an identical reading — the same recipe ordered twice does exactly
    -- that — and a kept record would carry the finished job's timestamp into the
    -- new one and flag it as stalled the moment it started.
    if not busy then
        self.history[id] = nil
        job.state = craft.IDLE
        job.stalledFor = 0
        return job
    end

    local cpu = entry.cpu
    if type(cpu) ~= "table" and type(cpu) ~= "userdata" then
        job.state = craft.MISSING
        return job
    end

    job.active = items(craft.rawCall(cpu, "activeItems"))
    job.pending = items(craft.rawCall(cpu, "pendingItems"))
    job.stored = items(craft.rawCall(cpu, "storedItems"))

    job.output, job.outputError = finalOutput(cpu)

    -- The heuristics the card shows. `next` is the largest pending stack, NOT a
    -- claim about AE2's scheduling order — see the note at the top of the file.
    job.now = job.active[1]
    job.next = job.pending[1]

    job.state, job.stalledFor, job.stallReason = self:classify(id, job.active, job.pending, now)
    return job
end

-- Call a method on a CPU value.
--
-- The Cpu value arrives as OpenComputers userdata, so its methods are looked up
-- through __index rather than being fields on a table — util.call's callable()
-- check is built for component proxies and does not describe this shape. The
-- value can also die between polls (the cluster was broken up, the controller
-- was mined), and getCpu() in the driver throws "Broken CPU cluster" when it
-- does, so every call is guarded.
function craft.rawCall(cpu, method, ...)
    local ok, fn = pcall(function() return cpu[method] end)
    if not ok or fn == nil then return nil end
    local called, result = pcall(fn, ...)
    if not called then return nil end
    return result
end

function craft:update()
    local now = computer.uptime()
    local jobs, order = {}, {}
    local controllers = {}
    self.error = nil

    local discovered = craft.discover()
    if #discovered == 0 then
        self.jobs, self.order, self.controllers = {}, {}, {}
        self.error = "no ME controller or interface found"
        return self
    end

    for _, found in ipairs(discovered) do
        local ok, proxy = pcall(component.proxy, found.address)
        if ok and proxy then
            local list = util.call(proxy, "getCpus")
            if type(list) == "table" then
                table.insert(controllers, {address = found.address, kind = found.kind, cpus = 0})
                local controller = controllers[#controllers]

                -- getCpus() is built from a Scala ListBuffer, so it is dense and
                -- 1-based; unlike the item lists it has no holes to skip.
                for index, entry in ipairs(list) do
                    if type(entry) == "table" then
                        -- The driver indexes CPUs from 0 and the Cpu value keeps
                        -- that index, so number them the same way. A player
                        -- comparing this against a script that calls getCpus()
                        -- directly should see the same CPU under the same number.
                        local job = self:readCpu(found.address, index - 1, entry, now)
                        jobs[job.id] = job
                        table.insert(order, job.id)
                        controller.cpus = controller.cpus + 1
                    end
                end
            else
                table.insert(controllers, {address = found.address, kind = found.kind, cpus = 0,
                                           error = "getCpus() returned nothing"})
            end
        end
    end

    -- Forget history for jobs whose CPU is gone, or the table grows for the
    -- lifetime of the process every time a cluster is rebuilt.
    for id in pairs(self.history) do
        if not jobs[id] then self.history[id] = nil end
    end

    self.jobs, self.order, self.controllers = jobs, order, controllers
    return self
end

-- Every CPU, in controller then CPU order.
function craft:list()
    local out = {}
    for _, id in ipairs(self.order) do table.insert(out, self.jobs[id]) end
    return out
end

-- Only the CPUs doing something, worst first.
--
-- Ordering is the point: the card has room for a few rows, and a stalled job is
-- the one worth the space. Ties fall back to id so rows do not swap around
-- between polls.
function craft:busy()
    local out = {}
    for _, id in ipairs(self.order) do
        local job = self.jobs[id]
        if job.busy then table.insert(out, job) end
    end
    table.sort(out, function(a, b)
        local aStalled = a.state == craft.STALLED
        local bStalled = b.state == craft.STALLED
        if aStalled ~= bStalled then return aStalled end
        return a.id < b.id
    end)
    return out
end

function craft:get(id)
    return self.jobs[id]
end

-- Whole-network summary for a header line.
function craft:summary()
    local total, busy, stalled = 0, 0, 0
    for _, id in ipairs(self.order) do
        local job = self.jobs[id]
        total = total + 1
        if job.busy then busy = busy + 1 end
        if job.state == craft.STALLED then stalled = stalled + 1 end
    end
    return {total = total, busy = busy, stalled = stalled, error = self.error}
end

return craft
