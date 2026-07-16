-- Settings: a serialized Lua table on disk.
--
-- Follows the NIDAS approach (OpenOS `serialization` + a flat file) but adds
-- the parts it lacked: a schema version, defaults merged on load so an old
-- config never yields nil fields, and an atomic write so a power cut mid-save
-- cannot leave a truncated file that bricks the next boot.

local filesystem = require("filesystem")
local serialization = require("serialization")

local util = require("core.util")

local config = {}

config.VERSION = 1
config.directory = "/home/EMON/settings"
config.path = config.directory .. "/config"

local function defaults()
    return {
        version = config.VERSION,

        -- Monitored buffers: {address, name, kind, enabled}
        -- Populated by the settings screen from core.sources.discover().
        buffers = {},

        -- On-screen panel.
        screen = {
            enabled = true,
            source = nil,          -- nil = aggregate
            graphScale = "medium", -- fast | medium | slow
            pollInterval = 0.25,   -- seconds between component reads
        },

        -- AR HUD, keyed by glasses component address.
        -- source: a view id, or nil for the aggregate.
        -- cycle:  rotate through every view instead of pinning one.
        glasses = {},

        -- Wipe every AR object on the glasses at startup. If EMON is killed or
        -- crashes, its overlay objects stay in the glasses forever: the handles
        -- needed to remove them died with the process, and removeAll() is the
        -- only way back. Turn this off if you run other AR programs on the same
        -- glasses, since it clears their objects too.
        clearGlassesOnStart = true,

        -- Older OpenGlasses builds scale text about the origin rather than the
        -- label's own position. Enable if HUD text lands in the wrong place.
        legacyTextScaling = false,

        theme = {
            background = 0x0B0E14,
            panel      = 0x151A23,
            primary    = 0x22D3EE,
            accent     = 0xD946EF,
            text       = 0xC8D3E0,
            muted      = 0x6B7A8F,
        },

        resolution = {x = 120, y = 40},
    }
end

config.defaults = defaults

function config.glassesDefaults()
    return {
        enabled = true,
        source = nil,
        cycle = false,
        cycleInterval = 8,
        compact = false,
        scale = 3,          -- Minecraft GUI scale: 1 Small, 2 Normal, 3 Large, 4+ Auto
        resX = 2560,
        resY = 1440,

        -- Corner the HUD card snaps to. Defaults to top-left: chat sits in the
        -- bottom-left, the hotbar bottom-centre, potion effects top-right.
        anchor = "top-left",
        -- Nudge from that corner, in glasses pixels.
        offsetX = 0,
        offsetY = 0,
    }
end

-- Deep-merge stored values over defaults so a config written by an older build
-- gains new fields instead of returning nil for them.
local function merge(stored, base)
    if type(stored) ~= "table" then return base end
    for key, value in pairs(base) do
        if type(value) == "table" and not (key == "buffers" or key == "glasses") then
            stored[key] = merge(stored[key], value)
        elseif stored[key] == nil then
            stored[key] = value
        end
    end
    return stored
end

function config.load()
    local data
    local file = io.open(config.path, "r")
    if file then
        local contents = file:read("*a")
        file:close()
        local ok, parsed = pcall(serialization.unserialize, contents)
        if ok and type(parsed) == "table" then data = parsed end
    end
    data = merge(data, defaults())
    data.buffers = data.buffers or {}
    data.glasses = data.glasses or {}
    return data
end

function config.save(data)
    if not filesystem.exists(config.directory) then
        filesystem.makeDirectory(config.directory)
    end
    data.version = config.VERSION

    -- Write-then-rename: a partial write lands on the temp file, and the real
    -- config is only replaced once the bytes are safely on disk.
    local temp = config.path .. ".tmp"
    local file, err = io.open(temp, "w")
    if not file then return false, err end
    file:write(serialization.serialize(data))
    file:close()

    filesystem.remove(config.path)
    local ok, moveErr = filesystem.rename(temp, config.path)
    if not ok then return false, moveErr end
    return true
end

function config.glassesFor(data, address)
    data.glasses[address] = util.defaults(data.glasses[address], config.glassesDefaults())
    return data.glasses[address]
end

-- Merge freshly discovered components into the buffer list, keeping any
-- existing per-buffer settings (name, enabled) untouched.
function config.syncBuffers(data, discovered)
    local known = {}
    for _, entry in ipairs(data.buffers) do known[entry.address] = entry end

    for _, found in ipairs(discovered) do
        local entry = known[found.address]
        if entry then
            entry.kind = found.kind
            entry.detectedName = found.name
        else
            table.insert(data.buffers, {
                address = found.address,
                name = found.name,
                kind = found.kind,
                enabled = true,
            })
        end
    end
    return data
end

return config
