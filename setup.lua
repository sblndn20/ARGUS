-- EMON installer.
--
--   wget -f https://raw.githubusercontent.com/sblndn20/monitoring-app/main/setup.lua && setup
--
-- Files are fetched individually from raw.githubusercontent.com rather than as
-- a release tarball. NIDAS pulls a third-party tar binary into /bin first
-- because OpenOS has no archiver; with ~20 files that dependency is not worth
-- it, and this way the installer works straight from a branch with no release
-- pipeline behind it.
--
-- Unlike NIDAS, this does NOT replace /lib/core/boot.lua or /etc/profile.lua.
-- Those swaps are cosmetic branding and they make an install fragile.

local component = require("component")
local filesystem = require("filesystem")
local shell = require("shell")

-- Override with `setup --repo=user/repo --branch=name` when installing a fork.
local REPO = "sblndn20/monitoring-app"
local BRANCH = "main"

local INSTALL_DIR = "/home/EMON"

local FILES = {
    "init.lua",
    "version.lua",
    "config/init.lua",
    "core/states.lua",
    "core/util.lua",
    "core/ring.lua",
    "core/sensor.lua",
    "core/metrics.lua",
    "core/monitor.lua",
    "core/sources/init.lua",
    "core/sources/lsc.lua",
    "core/sources/batterybuffer.lua",
    "core/sources/ic2.lua",
    "core/sources/energycontainer.lua",
    "lib/graphics/ar.lua",
    "lib/graphics/colors.lua",
    "lib/graphics/graphics.lua",
    "lib/utils/parser.lua",
    "lib/utils/screen.lua",
    "lib/utils/text.lua",
    "lib/utils/time.lua",
    "ui/format.lua",
    "ui/widgets.lua",
    "ui/graph.lua",
    "ui/panel.lua",
    "ui/app.lua",
    "ar/init.lua",
    "ar/panel.lua",
    "tools/sensordump.lua",
}

local args, options = shell.parse(...)
local repo = options.repo or REPO
local branch = options.branch or args[1] or BRANCH
local base = "https://raw.githubusercontent.com/" .. repo .. "/" .. branch .. "/"

if not component.isAvailable("internet") then
    io.stderr:write("An Internet Card is required to install EMON.\n")
    return
end

print("Installing EMON from " .. repo .. "@" .. branch)

local failed = {}
for _, file in ipairs(FILES) do
    local target = INSTALL_DIR .. "/" .. file
    local directory = filesystem.path(target)
    if not filesystem.exists(directory) then
        filesystem.makeDirectory(directory)
    end
    -- -f overwrites, -q keeps the log readable.
    local ok = shell.execute("wget -f -q " .. base .. file .. " " .. target)
    if ok then
        io.write(".")
    else
        io.write("!")
        table.insert(failed, file)
    end
end
io.write("\n")

if #failed > 0 then
    io.stderr:write("Failed to download " .. #failed .. " file(s):\n")
    for _, file in ipairs(failed) do io.stderr:write("  " .. file .. "\n") end
    io.stderr:write("Check the repo/branch and try again.\n")
    return
end

-- Settings live under the install dir and are never fetched, so a reinstall
-- keeps the user's configuration.
if not filesystem.exists(INSTALL_DIR .. "/settings") then
    filesystem.makeDirectory(INSTALL_DIR .. "/settings")
end

-- Autostart via /home/.shrc, which /etc/profile.lua sources on every shell
-- login. `cd` first: OpenOS resolves program names against the working dir.
io.write("Run EMON automatically on boot? [Y/n] ")
local answer = (io.read() or ""):lower()
if answer ~= "n" then
    local shrc = io.open("/home/.shrc", "w")
    if shrc then
        shrc:write("cd " .. INSTALL_DIR .. "\ninit\ncd\n")
        shrc:close()
        print("Autostart enabled (/home/.shrc).")
    else
        io.stderr:write("Could not write /home/.shrc; skipping autostart.\n")
    end
end

print("")
print("Installed to " .. INSTALL_DIR)
print("Start it now with:  cd " .. INSTALL_DIR .. " && init")
print("Sensor diagnostics: cd " .. INSTALL_DIR .. " && tools/sensordump.lua")
