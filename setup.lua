-- ARGUS installer.
--
--   wget -f https://cdn.jsdelivr.net/gh/sblndn20/ARGUS@v2.2.0/setup.lua && setup
--
-- Note the `&&`: without it, a failed wget leaves the PREVIOUS setup.lua in
-- place and `setup` cheerfully runs that instead, installing whatever ref that
-- old copy defaults to. The failure then looks like "the update did nothing".
--
-- Files are fetched individually rather than as a release tarball. NIDAS pulls
-- a third-party tar binary into /bin first because OpenOS has no archiver; with
-- ~30 files that dependency is not worth it, and this way the installer works
-- straight from a tag with no release pipeline behind it.
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
--
-- The default is a TAG, not a branch. jsDelivr caches a branch ref for hours
-- and does so per file, so `@main` can serve a different commit for each file
-- and every request still reports success. A tag is immutable, so every file is
-- guaranteed to come from one commit.
--
-- Use --branch=<commit-sha> to install an exact revision (also immutable).
-- Use --branch=main only to test unreleased code.
local REPO = "sblndn20/ARGUS"
local BRANCH = "v2.2.0"

-- What this installer expects to find on disk afterwards. Checked at the end so
-- a stale mirror is reported instead of passing as a clean install.
local EXPECTED_VERSION = "2.2.0"

local INSTALL_DIR = "/home/ARGUS"

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
    "net/init.lua",
    "net/server.lua",
    "net/client.lua",
    "tools/sensordump.lua",
}

local args, options = shell.parse(...)
local repo = options.repo or REPO
local branch = options.branch or args[1] or BRANCH

if not component.isAvailable("internet") then
    io.stderr:write("An Internet Card is required to install ARGUS.\n")
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

    local probe = "/tmp/argus-probe"
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

print("ARGUS installer — " .. repo .. "@" .. branch)

local SETTINGS_DIR = INSTALL_DIR .. "/settings"
local CONFIG_FILE = SETTINGS_DIR .. "/config"
local CONFIG_BACKUP = "/tmp/argus-config"

-- filesystem.copy handles FILES ONLY. OpenOS implements it as
--     local input = filesystem.open(fromPath, "rb")
-- which fails on a directory, so copy returns false and copies nothing —
-- without raising. Passing it `settings/` therefore did nothing at all, and the
-- wipe that followed took the settings with it. Copy the config file itself.
local function stashConfig(from)
    if not filesystem.exists(from) then return false end
    filesystem.remove(CONFIG_BACKUP)
    return filesystem.copy(from, CONFIG_BACKUP) and true or false
end

local function restoreConfig()
    if not filesystem.exists(CONFIG_BACKUP) then return false end
    filesystem.makeDirectory(SETTINGS_DIR)
    local ok = filesystem.copy(CONFIG_BACKUP, CONFIG_FILE)
    filesystem.remove(CONFIG_BACKUP)
    return ok and true or false
end

-- Move an install made under the app's previous name. Left alone, the old tree
-- keeps its settings hostage and its autostart line points at a directory that
-- is about to stop existing.
local LEGACY_DIR = "/home/EMON"
if filesystem.exists(LEGACY_DIR) and LEGACY_DIR ~= INSTALL_DIR then
    print("Found a previous install at " .. LEGACY_DIR)
    if not filesystem.exists(CONFIG_FILE) and stashConfig(LEGACY_DIR .. "/settings/config") then
        if restoreConfig() then print("  settings carried over") end
    end
    filesystem.remove(LEGACY_DIR)
    print("  removed " .. LEGACY_DIR)

    -- Autostart still names the old directory; booting would land in nothing.
    local shrc = io.open("/home/.shrc", "r")
    if shrc then
        local body = shrc:read("*a") or ""
        shrc:close()
        if body:find(LEGACY_DIR, 1, true) then
            local rewritten = io.open("/home/.shrc", "w")
            if rewritten then
                rewritten:write("cd " .. INSTALL_DIR .. "\ninit\ncd\n")
                rewritten:close()
                print("  autostart repointed at " .. INSTALL_DIR)
            end
        end
    end
end

-- Wipe first when asked. A file that a newer layout no longer downloads would
-- otherwise sit there forever, and a half-updated tree fails in confusing ways
-- (a function that exists in the repo reported as nil).
if options.clean then
    local kept = stashConfig(CONFIG_FILE)
    print("Removing " .. INSTALL_DIR .. (kept and " (settings kept)" or ""))
    filesystem.remove(INSTALL_DIR)
    filesystem.makeDirectory(INSTALL_DIR)
    restoreConfig()
end

-- A branch ref is cached per file by the CDN, so files can arrive from
-- different commits and leave a mix that crashes on a missing function. Only
-- tags and commit SHAs are immutable.
if branch == "main" or branch == "master" then
    print("WARNING: '" .. branch .. "' is a branch. Mirrors cache branch refs per")
    print("file, so files may arrive from different commits. Prefer a tag or a")
    print("commit SHA: setup --branch=v2.2.0")
end

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
if not filesystem.exists(SETTINGS_DIR) then
    filesystem.makeDirectory(SETTINGS_DIR)
end

-- Record what was installed. Without this there is no way to tell a stale
-- install from a fresh one — every build reports the same version string, and
-- a mirror can serve a cached copy of a branch for hours without saying so.
local stamp = io.open(SETTINGS_DIR .. "/installed", "w")
if stamp then
    stamp:write(branch .. "\n" .. mirror.name .. "\n")
    stamp:close()
end

-- Autostart via /home/.shrc, which /etc/profile.lua sources on every shell
-- login. `cd` first: OpenOS resolves program names against the working dir.
io.write("Run ARGUS automatically on boot? [Y/n] ")
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

-- Read back what actually landed on disk. Downloading successfully is not the
-- same as installing what was asked for: a CDN can serve a cached copy of an
-- older commit and every request still reports success.
local installed = "?"
local versionFile = io.open(INSTALL_DIR .. "/version.lua", "r")
if versionFile then
    installed = (versionFile:read("*a") or ""):match('"([^"]+)"') or "?"
    versionFile:close()
end

print("")
print("Installed " .. #FILES .. " files to " .. INSTALL_DIR)
print("  version : " .. installed)
print("  ref     : " .. branch)
print("  mirror  : " .. mirror.name)
if installed ~= EXPECTED_VERSION then
    print("")
    print("WARNING: expected version " .. EXPECTED_VERSION .. " but " .. installed
        .. " landed on disk.")
    print("The mirror served a stale copy. Retry with:  setup --clean --mirror=raw")
end
print("")
print("Start it now with:  cd " .. INSTALL_DIR .. " && init")
print("Sensor diagnostics: cd " .. INSTALL_DIR .. " && tools/sensordump.lua")
