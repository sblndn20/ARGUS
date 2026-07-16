-- AR HUD manager.
--
-- Owns one panel per pair of glasses and decides what each one shows: a pinned
-- view, or a rotation through every view when `cycle` is on.
--
-- Panels are rebuilt only when the settings that affect their geometry change.
-- A rebuild tears down and recreates every glasses object, so doing it per
-- frame would both flicker and leak.

local component = require("component")
local computer = require("computer")

local ar = require("lib.graphics.ar")
local configuration = require("config")

local arPanel = require("ar.panel")

local hud = {}
hud.__index = hud

function hud.new(config)
    return setmetatable({config = config, panels = {}, cleared = {}}, hud)
end

-- Remove leftovers from a previous run before drawing on a pair of glasses for
-- the first time. Objects from a crashed process cannot be removed individually
-- (their handles are gone), so this is the only way to reclaim them. Done once
-- per address per process — never on a rebuild, which would clear the panel we
-- are about to recreate anyway.
function hud:clearOnce(address, proxy)
    if self.cleared[address] or not self.config.clearGlassesOnStart then return end
    self.cleared[address] = true
    pcall(ar.clear, proxy)
end

-- Any change here means the existing objects are wrong and must be recreated.
local function signature(settings)
    return table.concat({
        tostring(settings.enabled), tostring(settings.compact),
        tostring(settings.scale), tostring(settings.resX), tostring(settings.resY),
        tostring(settings.anchor), tostring(settings.offsetX), tostring(settings.offsetY),
    }, "|")
end

function hud:drop(address)
    local panel = self.panels[address]
    if not panel then return end
    -- The glasses may already be gone; tearing down must not take the app with it.
    pcall(function() panel.instance:remove() end)
    self.panels[address] = nil
end

function hud:removeAll()
    for address in pairs(self.panels) do self:drop(address) end
end

-- Pick the view for one pair of glasses.
function hud:selectView(address, settings, monitor, now)
    if not settings.cycle then
        return monitor:resolve(settings.source)
    end

    local panel = self.panels[address]
    local views = monitor:list()
    if #views == 0 then return nil end

    panel.cycleIndex = panel.cycleIndex or 1
    panel.lastSwitch = panel.lastSwitch or now

    local interval = settings.cycleInterval or 8
    if (now - panel.lastSwitch) >= interval then
        panel.cycleIndex = panel.cycleIndex % #views + 1
        panel.lastSwitch = now
    end
    -- The view list can shrink between frames (a buffer went missing, wireless
    -- switched off), so clamp rather than index past the end.
    if panel.cycleIndex > #views then panel.cycleIndex = 1 end
    return views[panel.cycleIndex]
end

function hud:update(monitor)
    local now = computer.uptime()
    local seen = {}

    for address in component.list("glasses") do
        seen[address] = true
        local settings = configuration.glassesFor(self.config, address)
        local current = self.panels[address]
        local wanted = signature(settings)

        if current and current.signature ~= wanted then
            self:drop(address)
            current = nil
        end

        if not settings.enabled then
            if current then self:drop(address) end
        else
            if not current then
                local ok, proxy = pcall(component.proxy, address)
                if ok and proxy then
                    self:clearOnce(address, proxy)
                    local built, instance = pcall(arPanel.new, proxy, settings, self.config.theme)
                    if built then
                        self.panels[address] = {
                            instance = instance,
                            signature = wanted,
                            cycleIndex = 1,
                            lastSwitch = now,
                        }
                        current = self.panels[address]
                    end
                end
            end

            if current then
                local view = self:selectView(address, settings, monitor, now)
                local ok = pcall(function() current.instance:update(view) end)
                -- Glasses unplugged mid-frame: forget the panel and let the next
                -- pass rebuild it if they come back.
                if not ok then self:drop(address) end
            end
        end
    end

    -- Glasses that vanished from the component list.
    for address in pairs(self.panels) do
        if not seen[address] then self:drop(address) end
    end
end

return hud
