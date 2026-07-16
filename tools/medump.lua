-- ME network diagnostics.
--
--   cd /home/ARGUS && tools/medump.lua
--
-- Prints, for every attached ME component: which CPUs the network has, what each
-- busy one is building, and what ARGUS derives from it.
--
-- This exists because the crafting API is a GTNH addition, not upstream
-- OpenComputers. Upstream's ME driver exposes nothing about a running job, so on
-- a pack with stock OpenComputers the Cpu methods below simply will not be
-- there. If the Crafting page is empty, this output says which of the three it
-- is: no component at all, a driver without the methods, or a CPU with no
-- Crafting Monitor.

package.path = "/home/ARGUS/?.lua;/home/ARGUS/?/init.lua;" .. package.path

-- Same reason as init.lua: OpenOS keeps one package.loaded for the whole boot
-- session, so require() would hand back modules loaded before the last update
-- and this tool would report on code that is no longer on disk.
for name in pairs(package.loaded) do
    if name:match("^lib%.") or name:match("^core$") or name:match("^core%.") then
        package.loaded[name] = nil
    end
end

local component = require("component")

local craftLib = require("core.craft")
local util = require("core.util")

local function line(char)
    print(string.rep(char or "-", 60))
end

-- The methods this feature stands on. Each one is checked and reported
-- individually rather than as a single yes/no, because a partial driver is a
-- real possibility and "which one is missing" is the whole answer.
local CPU_METHODS = {"isActive", "isBusy", "activeItems", "pendingItems",
                     "storedItems", "finalOutput", "cancel"}

local all, total = {}, 0
for address, componentType in component.list() do
    total = total + 1
    table.insert(all, {address = address, type = componentType})
end
table.sort(all, function(a, b) return a.type < b.type end)

print("ARGUS ME dump")
line("=")
print("All components visible to this computer (" .. total .. "):")
for _, item in ipairs(all) do
    print(string.format("  %-22s %s", item.type, item.address))
end

local candidates = craftLib.discover()

if #candidates == 0 then
    line("=")
    print("No me_controller or me_interface among them.")
    print("")
    print("ARGUS reads crafting through an Adapter touching an ME Controller")
    print("(or an ME Interface). Check that:")
    print("  * the Adapter physically touches the block;")
    print("  * the Adapter is connected to this computer (adjacent or cabled);")
    print("  * the ME network is powered and the controller is formed.")
    return
end

line("=")
print("ME components: " .. #candidates)

for _, candidate in ipairs(candidates) do
    line("=")
    print("Address : " .. candidate.address)
    print("Type    : " .. candidate.kind)

    local ok, proxy = pcall(component.proxy, candidate.address)
    if not ok or not proxy then
        print("  <cannot proxy this component>")
    else
        -- If getCpus is absent the driver predates the GTNH crafting additions,
        -- and nothing else in this tool can work.
        if not util.callable(proxy.getCpus) then
            print("  getCpus(): ABSENT")
            print("")
            print("  This driver does not expose crafting CPUs. ARGUS needs the GTNH")
            print("  fork of OpenComputers (1.11.20-GTNH ships it); upstream OC has")
            print("  no such API — see OC issue #3786.")
        else
            local cpus = util.call(proxy, "getCpus")
            if type(cpus) ~= "table" then
                print("  getCpus() returned " .. type(cpus) .. ", expected table")
            else
                print("CPUs    : " .. #cpus)

                for index, entry in ipairs(cpus) do
                    line()
                    -- The driver numbers CPUs from 0 and the Cpu value carries
                    -- that index; match it so this lines up with a script that
                    -- calls getCpus() itself.
                    print(string.format("CPU #%d", index - 1))
                    print(string.format("  name         = %s", tostring(entry.name)))
                    print(string.format("  storage      = %s", tostring(entry.storage)))
                    print(string.format("  coprocessors = %s", tostring(entry.coprocessors)))
                    print(string.format("  busy         = %s", tostring(entry.busy)))

                    local cpu = entry.cpu
                    if cpu == nil then
                        print("  cpu value    : ABSENT (no per-CPU detail available)")
                    else
                        print("  cpu value    : " .. type(cpu))
                        local present = {}
                        for _, method in ipairs(CPU_METHODS) do
                            local got, fn = pcall(function() return cpu[method] end)
                            table.insert(present, method .. "=" .. ((got and fn ~= nil) and "yes" or "NO"))
                        end
                        print("  methods      : " .. table.concat(present, " "))

                        -- finalOutput is the one that fails for a reason worth
                        -- printing verbatim: it needs a Crafting Monitor block
                        -- inside the CPU cluster, and says so itself.
                        local gotFn, fn = pcall(function() return cpu.finalOutput end)
                        if gotFn and fn ~= nil then
                            local called, stack, err = pcall(fn)
                            if not called then
                                print("  finalOutput  : raised " .. tostring(stack))
                            elseif type(stack) == "table" then
                                print(string.format("  finalOutput  : %s x%s",
                                    tostring(stack.label or stack.name), tostring(stack.size)))
                            else
                                print("  finalOutput  : nil — " .. tostring(err))
                                if tostring(err):find("monitor") then
                                    print("                 (add a Crafting Monitor block to this CPU)")
                                end
                            end
                        end

                        for _, method in ipairs({"activeItems", "pendingItems", "storedItems"}) do
                            local list = craftLib.rawCall(cpu, method)
                            if type(list) ~= "table" then
                                print(string.format("  %-12s : %s", method, tostring(list)))
                            else
                                -- pairs, not ipairs: the driver's convert() can
                                -- return null and leave holes in this array.
                                local count = 0
                                for _ in pairs(list) do count = count + 1 end
                                print(string.format("  %-12s : %d entr%s",
                                    method, count, count == 1 and "y" or "ies"))
                                for _, item in pairs(list) do
                                    if type(item) == "table" then
                                        print(string.format("      %6s x %s [%s]",
                                            tostring(item.size),
                                            tostring(item.label or item.name),
                                            tostring(item.name)))
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

-- What the app itself makes of all this, so a disagreement between the raw dump
-- above and the Crafting page is visible in one place.
line("=")
print("What ARGUS derives:")
local monitor = craftLib.new({craft = {}})
monitor:update()
local summary = monitor:summary()
print(string.format("  %d CPU(s), %d busy, %d stalled%s",
    summary.total, summary.busy, summary.stalled,
    summary.error and (" — " .. summary.error) or ""))

for _, job in ipairs(monitor:list()) do
    line()
    print(string.format("  %s [%s]", job.cpuName, tostring(job.state)))
    if job.output then
        print(string.format("    ordered  : %s x%s", job.output.label, tostring(job.output.size)))
    elseif job.outputError then
        print("    ordered  : unknown — " .. tostring(job.outputError))
    end
    if job.now then print(string.format("    crafting : %s x%d", job.now.label, job.now.size)) end
    if job.next then print(string.format("    waiting  : %s x%d", job.next.label, job.next.size)) end
    print(string.format("    counts   : active=%d pending=%d stored=%d",
        #job.active, #job.pending, #job.stored))
end

-- One pass cannot see a stall: it is inferred from readings NOT changing, so
-- the timer above starts at zero on the first poll. Saying so beats printing a
-- reassuring CRAFTING that means nothing yet.
print("")
print("Note: stall detection compares readings over time, so a single run of")
print("this tool always reports 0s frozen. The app decides after " ..
      craftLib.STALL_SECONDS .. "s without change")
print("(" .. craftLib.EMPTY_STALL_SECONDS .. "s when nothing is dispatched at all).")
line("=")
