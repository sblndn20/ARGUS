-- ARGUS — GregTech energy monitor for OpenComputers.
-- Entry point: run from the OpenOS shell (`cd /home/ARGUS && init`).

-- Prepend rather than append so our own modules win against same-named OpenOS
-- libraries. `?/init.lua` is what makes require("core.sources") resolve to
-- core/sources/init.lua.
package.path = "/home/ARGUS/?.lua;/home/ARGUS/?/init.lua;" .. package.path

-- Drop our own modules from the require cache before loading any of them.
--
-- OpenComputers runs the entire computer in ONE Lua state, and OpenOS keeps a
-- single package table for the whole boot session (boot/01_process.lua); there
-- is no per-program sandbox. lib/package.lua:76 returns package.loaded[module]
-- if present, so a module stays in memory until the machine reboots.
--
-- That makes updating actively dangerous. This file is a script, so it is
-- re-read from disk every run and is always current — but everything it
-- require()s would come back as the version loaded at boot. The result is not
-- "the update did nothing", it is a mix of new and old code that fails as
-- `attempt to call a nil value` on functions that plainly exist on disk.
--
-- Purging here means `init` alone picks up an update, with no reboot.
--
-- EVERY namespace this app ships must be listed. A missing one is invisible
-- until an update changes that module, and then it fails as a method that
-- plainly exists being nil — `net` was forgotten when distributed mode landed
-- and did exactly that. tests/run.lua checks this list against what actually
-- loads, so a new namespace cannot be forgotten again.
local OWN_MODULES = {"^lib%.", "^core$", "^core%.", "^ui%.", "^ar$", "^ar%.",
                     "^net$", "^net%.", "^config$", "^version$"}
for name in pairs(package.loaded) do
    for _, pattern in ipairs(OWN_MODULES) do
        if name:match(pattern) then
            package.loaded[name] = nil
            break
        end
    end
end

local component = require("component")
local computer = require("computer")
local event = require("event")
local term = require("term")

local ar = require("lib.graphics.ar")
local graphics = require("lib.graphics.graphics")

local configuration = require("config")
local craftLib = require("core.craft")
local monitorLib = require("core.monitor")
local sources = require("core.sources")

local app = require("ui.app")
local arHud = require("ar")

local netTransport = require("net")
local netServer = require("net.server")
local netClient = require("net.client")

-- How often the loop wakes to animate. Component polling runs on its own,
-- slower schedule (config.screen.pollInterval).
local ANIMATION_INTERVAL = 0.1

local function setupScreen(config)
    if not component.isAvailable("gpu") or not component.isAvailable("screen") then
        return false
    end
    local gpu = component.gpu
    local maxWidth, maxHeight = gpu.maxResolution()
    local width = math.min(config.resolution.x or maxWidth, maxWidth)
    local height = math.min(config.resolution.y or maxHeight, maxHeight)
    gpu.setResolution(width, height)
    gpu.setBackground(config.theme.background)
    gpu.fill(1, 1, width, height, " ")
    graphics.setContext(nil)
    return true
end

local function restoreScreen()
    if not component.isAvailable("gpu") then return end
    -- Hand the offscreen buffer back; GPU buffers are a finite resource and
    -- would otherwise stay claimed until the machine reboots.
    graphics.release()
    local gpu = component.gpu
    pcall(gpu.setBackground, 0x000000)
    pcall(gpu.setForeground, 0xFFFFFF)
    local width, height = gpu.getResolution()
    pcall(gpu.fill, 1, 1, width, height, " ")
    pcall(term.setCursor, 1, 1)
end

local function run()
    local config = configuration.load()
    ar.setLegacyScaling(config.legacyTextScaling)

    -- First run: adopt whatever is attached so the app is useful before the
    -- user has touched any settings.
    if #config.buffers == 0 then
        configuration.syncBuffers(config, sources.discover())
        configuration.save(config)
    end

    local hasScreen = setupScreen(config)
    local monitor = monitorLib.new(config)
    local hud = arHud.new(config)

    -- nil when crafting is switched off, and that nil is the off switch all the
    -- way down: the AR card and the Crafting page both treat "no craft monitor"
    -- as "do not exist" rather than as an error state.
    local craftMonitor = (config.craft and config.craft.enabled ~= false)
        and craftLib.new(config) or nil

    -- Both roles are constructed regardless of the configured one: each is inert
    -- unless config.network.role names it, and building both means switching
    -- role in the UI takes effect without a restart.
    local transport = netTransport.new(config)
    local server = netServer.new(config, transport)
    local client = netClient.new(config, transport)

    local application = app.new(monitor, config, hud, server, craftMonitor)

    if not hasScreen then
        config.screen.enabled = false
    end

    local lastPoll = -math.huge
    local lastCraftPoll = -math.huge
    local frame = 0

    while application.running do
        local now = computer.uptime()

        -- Reading every buffer is the expensive part, so it keeps its own slower
        -- schedule. Animation must not be tied to it: when the two were the same
        -- tick, the bar could only move at the poll rate and jumped between
        -- readings instead of gliding.
        -- Both self-throttle, so they can be called every tick. The server must
        -- run first: it hands the monitor the remote readings that the update
        -- below folds into the views and the aggregate.
        server:update(monitor)
        client:update()

        if (now - lastPoll) >= (config.screen.pollInterval or 0.4) then
            monitor:update()
            lastPoll = now
        end

        -- Crafting keeps its own, much slower schedule: one poll costs getCpus()
        -- plus up to four calls per busy CPU, and a job changes on the scale of
        -- seconds. Tying it to the energy rate would multiply ME network calls
        -- for readings that cannot have changed.
        if craftMonitor and (now - lastCraftPoll) >= (config.craft.pollInterval or 2) then
            craftMonitor:update()
            lastCraftPoll = now
        end

        -- Cheap: mutates glasses objects that already exist.
        hud:update(monitor, craftMonitor)

        -- A full screen redraw is not cheap, so it runs at half the animation
        -- rate — still smooth, at a fraction of the GPU calls.
        if config.screen.enabled and (frame % 2 == 0 or application.dirty) then
            application:draw()
            application.dirty = false
        end
        frame = frame + 1

        local signal = {event.pull(ANIMATION_INTERVAL)}
        local name = signal[1]
        if name == "touch" then
            application:onTouch(signal[3], signal[4])
        elseif name == "interrupted" then
            application.running = false
        elseif name == "component_added" or name == "component_removed" then
            -- A buffer was plugged in or pulled; refresh the known component list.
            configuration.syncBuffers(config, sources.discover())
        elseif name == "modem_message" then
            -- modem_message(localAddress, remoteAddress, port, distance, ...)
            -- A Linked Card delivers the same signal, which is what lets one
            -- protocol serve both transports.
            local localAddress, remoteAddress = signal[2], signal[3]
            local port, distance = signal[4], signal[5]
            -- Protocol tag keeps other programs off this port; network key keeps
            -- other PLAYERS' ARGUS installs out. A wireless broadcast reaches
            -- every modem in range that opened the port, so without the key a
            -- neighbour's server would poll our clients and collect our buffers.
            if transport:accepts(signal[6], signal[7]) then
                local command, payload = signal[8], signal[9]
                server:onMessage(monitor, localAddress, remoteAddress, port, distance,
                    command, payload)
                client:onMessage(monitor, localAddress, remoteAddress, port, command)
            end
        elseif name == "hud_click" or name == "hud_keyboard" or name == "glasses_on" then
            -- Input from the glasses themselves, so the wearer can switch source
            -- without walking back to the computer.
            hud:handleSignal(monitor, name, table.unpack(signal, 2))
            application.dirty = true
        end
    end

    hud:removeAll()
    restoreScreen()
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
    -- Leave the terminal usable, then surface the failure.
    restoreScreen()
    io.stderr:write("ARGUS crashed:\n" .. tostring(err) .. "\n")
    computer.beep(880, 0.2)
end
