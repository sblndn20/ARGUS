-- EMON installer.
--
--   wget -f https://cdn.jsdelivr.net/gh/sblndn20/monitoring-app@main/setup.lua && setup
--
-- Files are fetched individually rather than as a release tarball. NIDAS pulls
-- a third-party tar binary into /bin first because OpenOS has no archiver; with
-- ~30 files that dependency is not worth it, and this way the installer works
-- straight from a branch with no release pipeline behind it.
--
-- MIRRORS: raw.githubusercontent.com is not reliably reachable from inside
-- OpenComputers everywhere. Its TLS handshake is dropped on some networks,
-- which surfaces as "Remote host terminated the handshake" — the connection is
-- cut after ClientHello, so there is nothing the mod or its config can do. The
-- installer therefore probes several hosts and uses the first that answers.
-- Redirect-based mirrors (githack, statically) are deliberately absent: they
-- answer 301 to another host, and OpenComputers uses a bare HttpURLConnection,
-- which refuses to follow a cross-host redirect. wget would save the HTML.
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

-- `branch` may equally be a tag or a full commit SHA. A SHA is worth knowing
-- about: jsDelivr caches a branch reference for hours, so right after a push
-- `@main` can still serve the previous version, while `@<sha>` is immutable.
local MIRRORS = {
    {
        name = "cdn.jsdelivr.net",
        url = function(repo, branch, file)
            return "https://cdn.jsdelivr.net/gh/" .. repo .. "@" .. branch .. "/" .. file
        end,
    },
    {
        name = "raw.githubusercontent.com",
        url = function(repo, branch, file)
            return "https://raw.githubusercontent.com/" .. repo .. "/" .. branch .. "/" .. file
        end,
    },
}

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

if not component.isAvailable("internet") then
    io.stderr:write("An Internet Card is required to install EMON.\n")
    return
end

-- -f overwrites, -q keeps the log readable.
local function fetch(url, target)
    return shell.execute("wget -f -q " .. url .. " " .. target) and true or false
end

local function ensureDirectory(target)
    local directory = filesystem.path(target)
    if directory and not filesystem.exists(directory) then
        filesystem.makeDirectory(directory)
    end
end

-- Pick a mirror by actually downloading a small file from it. Probing beats
-- guessing: which hosts are reachable depends on the network, not on anything
-- knowable ahead of time.
local function selectMirror()
    if options.mirror then
        for _, mirror in ipairs(MIRRORS) do
            if mirror.name:find(options.mirror, 1, true) then return mirror end
        end
        io.stderr:write("Unknown mirror: " .. tostring(options.mirror) .. "\n")
        return nil
    end

    local probe = "/tmp/emon-probe"
    for _, mirror in ipairs(MIRRORS) do
        io.write("Trying " .. mirror.name .. " ... ")
        filesystem.remove(probe)
        if fetch(mirror.url(repo, branch, "version.lua"), probe) then
            filesystem.remove(probe)
            print("ok")
            return mirror
        end
        print("unreachable")
    end
    return nil
end

print("Installing EMON " .. repo .. "@" .. branch)

local mirror = selectMirror()
if not mirror then
    io.stderr:write("\nNo mirror could be reached.\n")
    io.stderr:write("If this says \"terminated the handshake\", the connection is being\n")
    io.stderr:write("cut at the TLS layer and no OpenComputers setting will help.\n")
    io.stderr:write("Copy the files into the computer's disk folder instead:\n")
    io.stderr:write("  saves/<world>/opencomputers/<disk-address>/\n")
    io.stderr:write("Run `components` in OpenOS to find the address.\n")
    return
end

io.write("Downloading " .. #FILES .. " files")
local failed = {}
for _, file in ipairs(FILES) do
    local target = INSTALL_DIR .. "/" .. file
    ensureDirectory(target)
    if fetch(mirror.url(repo, branch, file), target) then
        io.write(".")
    else
        io.write("!")
        table.insert(failed, file)
    end
end
io.write("\n")

if #failed > 0 then
    io.stderr:write("Failed to download " .. #failed .. " file(s) from " .. mirror.name .. ":\n")
    for _, file in ipairs(failed) do io.stderr:write("  " .. file .. "\n") end
    io.stderr:write("Re-run setup, or try another mirror: setup --mirror=raw\n")
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
print("Installed to " .. INSTALL_DIR .. " from " .. mirror.name)
print("Start it now with:  cd " .. INSTALL_DIR .. " && init")
print("Sensor diagnostics: cd " .. INSTALL_DIR .. " && tools/sensordump.lua")
