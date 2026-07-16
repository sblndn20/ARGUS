-- Shared value formatting for both renderers.

local parser = require("lib.utils.parser")
local time = require("lib.utils.time")

local format = {}

format.UNIT = "EU"

-- Exact stored/capacity, grouped as 1,234,567.
-- Prefers the exact decimal string captured from the sensor: a Lua double
-- cannot represent an LSC's charge past 2^53, so formatting the number would
-- print a subtly wrong figure for any late-game buffer.
function format.exact(value, exactText)
    if exactText and exactText ~= "" then
        return parser.splitNumber(exactText) .. " " .. format.UNIT
    end
    if math.abs(value or 0) >= 2 ^ 53 then
        -- Beyond double precision and with no exact string to fall back on,
        -- grouped digits would imply accuracy we do not have.
        return string.format("%.4e", value) .. " " .. format.UNIT
    end
    return parser.splitNumber(value or 0) .. " " .. format.UNIT
end

-- Compact rendering for tight layouts: "1.2M EU".
function format.compact(value)
    return parser.metricNumber(value or 0) .. " " .. format.UNIT
end

-- Signed rate: "+1.2M EU/t".
function format.rate(value)
    if value == nil then return "--" end
    local sign = value > 0 and "+" or ""
    return sign .. parser.metricNumber(value) .. " " .. format.UNIT .. "/t"
end

-- Unsigned rate, for IN/OUT columns where the direction is already the label.
function format.magnitude(value)
    return parser.metricNumber(math.abs(value or 0)) .. " " .. format.UNIT .. "/t"
end

function format.percent(fraction)
    if fraction == nil then return "--" end
    -- Near-full and near-empty both round to a flat 100%/0% and hide the fact
    -- that the buffer is still moving, so keep more digits at the extremes.
    if fraction > 0.9999 then return "100%" end
    if fraction > 0 and fraction < 0.001 then
        return string.format("%.4f%%", fraction * 100)
    end
    return string.format("%.1f%%", fraction * 100)
end

-- A graph window as a short label: 30 -> "30 sec", 600 -> "10 min".
function format.window(seconds)
    seconds = math.floor(tonumber(seconds) or 0)
    if seconds < 60 then return seconds .. " sec" end
    if seconds < 3600 then return math.floor(seconds / 60) .. " min" end
    local hours = seconds / 3600
    -- Avoid "1.0 h" for the common exact case.
    if hours == math.floor(hours) then return math.floor(hours) .. " h" end
    return string.format("%.1f h", hours)
end

-- The graph's sample spacing, spelled out so the resolution is never a guess.
function format.step(seconds)
    if seconds < 1 then return string.format("%.2gs/pt", seconds) end
    if seconds < 60 then
        local whole = math.floor(seconds + 0.5)
        return whole .. "s/pt"
    end
    return math.floor(seconds / 60 + 0.5) .. "m/pt"
end

-- "Time to full 2d 4h 13m", or nil when nothing is projected.
function format.projection(seconds, direction)
    if not seconds or not direction then return nil end
    return (direction == "full" and "Time to full" or "Time to empty"), time.format(seconds)
end

return format
