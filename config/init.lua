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
config.directory = "/home/ARGUS/settings"
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
            -- Graph window in seconds. The sample step follows from it
            -- (window / 120 columns), so 120 plots one point per second.
            graphWindow = 600,
            -- Seconds between component reads. Independent of the redraw rate:
            -- the UI animates at ~10 Hz regardless, so raising this costs
            -- freshness, not smoothness.
            pollInterval = 0.4,
        },

        -- ME crafting monitor.
        craft = {
            enabled = true,
            -- Much slower than the energy poll on purpose: a read costs
            -- getCpus() plus up to four calls per BUSY CPU, and a crafting job
            -- changes on the scale of seconds, not tenths of one.
            pollInterval = 2,
            -- Busy but nothing changed for this long -> STALLED. Generous
            -- because a single GregTech recipe legitimately runs for minutes.
            stallSeconds = 120,
            -- Busy, work pending, but nothing in any machine. Not slow — stuck,
            -- so this fires far sooner. See core/craft.lua.
            emptyStallSeconds = 15,
        },

        -- Distributed mode.
        --
        -- OpenComputers cannot join component networks wirelessly — that is a
        -- deliberate design of the mod, not a limitation to work around (a Relay
        -- passes messages and explicitly does not expose components). So a
        -- remote base runs its own ARGUS as a `client`, reads its own buffers
        -- locally, and sends finished numbers to the `server`.
        network = {
            role = "standalone", -- standalone | server | client
            port = 42069,
            -- Which bases are YOURS. A shared server means other players may be
            -- running ARGUS too, and a wireless broadcast reaches every modem in
            -- range that opened the port — so without this their server would
            -- poll your clients and their buffers would appear on your screen.
            -- Defaults to this computer's address (unique, stable); copy the
            -- server's key onto each client. See net/init.lua for why this is an
            -- SSID and not a password.
            key = nil,
            -- Shown on the server's Network page. Defaults to the computer's
            -- own address when unset.
            name = nil,
            -- Server: seconds between polls of its clients. Deliberately slower
            -- than the local poll — this is network traffic, and a remote base's
            -- charge does not need sub-second freshness.
            pollInterval = 2,
            -- Server: seconds without an answer before a client is OFFLINE.
            -- Wireless has no link-down signal, so silence is the only symptom.
            timeout = 15,
        },

        -- AR HUD, keyed by glasses component address.
        -- source: a view id, or nil for the aggregate.
        -- cycle:  rotate through every view instead of pinning one.
        glasses = {},

        -- Wipe every AR object on the glasses at startup. If ARGUS is killed or
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

-- The crafting card is a second, independent card on the same glasses, so it
-- carries its own placement rather than hanging off the energy card's.
function config.craftCardDefaults()
    return {
        -- Off by default: the card is only useful on a network with autocrafting,
        -- and an empty card in the corner of every player's view is worse than
        -- one they had to switch on.
        enabled = false,

        -- top-right by default, so it does not land on the energy card's
        -- top-left. Potion effects live here, which is the lesser conflict.
        anchor = "top-right",
        offsetX = 0,
        offsetY = 0,

        -- Busy CPUs to list. Beyond a handful the card stops being a HUD and
        -- starts being a wall; the Crafting page on the monitor is where the
        -- full list belongs.
        rows = 4,

        -- Show only what needs attention. On a big network most CPUs are busy
        -- with something routine, and the stalled one is the reason to look.
        stalledOnly = false,
    }
end

function config.glassesDefaults()
    return {
        enabled = true,
        source = nil,
        cycle = false,
        cycleInterval = 8,
        compact = false,

        -- The crafting card, sharing these glasses with the energy card.
        craft = config.craftCardDefaults(),

        -- Take the viewport from the glasses_on signal, which reports the
        -- player's real ScaledResolution. That is the space hud_click reports
        -- clicks in, so matching it is what makes the HUD buttons hittable.
        -- The manual values below are only used until the player wears the
        -- glasses once, or when autoResolution is off.
        autoResolution = true,
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

-- What setup.lua recorded at install time: the ref it fetched and the mirror it
-- came from. Returns nil when ARGUS was installed some other way (files copied
-- straight onto the disk, for instance).
function config.installedRef()
    local file = io.open(config.directory .. "/installed", "r")
    if not file then return nil end
    local ref = file:read("*l")
    file:close()
    if not ref or ref == "" then return nil end
    -- A commit SHA is unreadable in full and the first characters identify it.
    if #ref > 12 then return ref:sub(1, 7) end
    return ref
end

function config.glassesFor(data, address)
    local settings = util.defaults(data.glasses[address], config.glassesDefaults())
    -- util.defaults is shallow, so a `glasses` entry written before the crafting
    -- card existed keeps its own table for every key it already has — and would
    -- never gain new nested fields. merge() cannot help either: it skips the
    -- `glasses` subtree entirely, because entries there are keyed by address and
    -- there are no defaults to walk. So this level is merged by hand.
    settings.craft = util.defaults(settings.craft, config.craftCardDefaults())
    data.glasses[address] = settings
    return settings
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
