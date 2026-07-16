-- GregTech getSensorInformation() helpers.
--
-- Sensor text is matched by LABEL, never by line index. NIDAS hardcoded
-- indices (stored = [2], capacity = [5], wireless = [23]) plus a "how many
-- lines came back" heuristic; that breaks whenever an addon inserts a line and
-- it silently produced garbage rather than failing. Labels degrade to nil.
--
-- Format notes for GTNH 2.8.3 (GT5U 5.09.51.482), which drive the parsing here:
--   * lines arrive already localised and contain § colour codes
--   * numbers use NumberFormat, so the group separator is locale-dependent
--   * several values appear twice: once with separators ("1,234,567") and once
--     in standard form ("1.234E18"). The scientific twin must not be parsed
--     for exact digits.
--   * averages carry a trailing qualifier: "Avg EU IN: 32,768 (last 20 seconds)".
--     Those parenthesised digits would corrupt a naive digits-only parse.

local parser = require("lib.utils.parser")
local util = require("core.util")

local sensor = {}

-- Read and normalise sensor lines. Returns an array of colour-stripped strings,
-- or nil if the component does not answer.
function sensor.lines(proxy)
    -- util.callable, not a "function" check: OpenComputers proxy methods are
    -- tables with a __call metamethod. See util.callable.
    if not proxy or not util.callable(proxy.getSensorInformation) then return nil end
    local ok, raw = pcall(proxy.getSensorInformation)
    if not ok or type(raw) ~= "table" then return nil end

    local lines = {}
    for i = 1, (raw.n or #raw) do
        local line = raw[i]
        lines[i] = (type(line) == "string") and parser.stripColors(line) or ""
    end
    return lines
end

-- First line matching a Lua pattern, or nil.
function sensor.find(lines, pattern)
    if not lines then return nil end
    for i = 1, #lines do
        if lines[i]:find(pattern) then return lines[i], i end
    end
    return nil
end

-- All lines matching a pattern.
function sensor.findAll(lines, pattern)
    local out = {}
    if not lines then return out end
    for i = 1, #lines do
        if lines[i]:find(pattern) then table.insert(out, lines[i]) end
    end
    return out
end

-- GTNH writes standard form as "2.64x10^11", not "2.64E11" — checking only for
-- an `E` exponent misses it entirely and the digit scrape yields the nonsense
-- 2641011. Both spellings are matched.
local function looksScientific(body)
    return body:match("%d%s*[eE]%s*%+?%s*%d") ~= nil
        or body:match("%d%s*[xX]%s*10%s*%^%s*%-?%d") ~= nil
end

-- Parse the numeric payload of a sensor line.
-- Returns: value (number), exact (decimal string or nil for scientific input).
--
-- The exact string matters because Lua numbers are doubles: past 2^53 (~9e15)
-- an LSC's stored EU can no longer be represented, and rendering the double
-- would show a wrong figure. Rates and percentages are fine as doubles.
function sensor.amount(line)
    if type(line) ~= "string" then return nil, nil end
    local body = parser.stripColors(line)

    -- Drop the label, keeping everything after the first colon.
    body = body:match(":%s*(.*)$") or body
    -- Drop qualifiers like "(last 5 minutes)" before any digit scraping.
    body = body:gsub("%b()", "")
    -- Drop units so "EU" / "EU/t" cannot contribute characters.
    body = body:gsub("[eE][uU]%s*/%s*[tT]", ""):gsub("[eE][uU]", "")

    -- ASCII hyphen only: Lua patterns match bytes, so putting a multi-byte
    -- minus sign in a character class would also match stray UTF-8 lead bytes.
    local negative = body:match("%-%s*[%d.]") ~= nil

    if looksScientific(body) then
        local mantissa, exponent = body:match("([%d.]+)%s*[eE]%s*%+?%s*(%d+)")
        if not mantissa then
            mantissa, exponent = body:match("([%d.]+)%s*[xX]%s*10%s*%^%s*(%-?%d+)")
        end
        if mantissa and exponent then
            local value = tonumber(mantissa) * 10 ^ tonumber(exponent)
            if negative then value = -value end
            return value, nil
        end
        -- Recognised as standard form but unparseable: better to admit that
        -- than to fall through and scrape the exponent's digits into the number.
        return nil, nil
    end

    local digits = body:gsub("%D", "")
    if digits == "" then return nil, nil end
    digits = digits:gsub("^0+(%d)", "%1")

    local value = tonumber(digits) or 0
    if negative then
        value = -value
        return value, "-" .. digits
    end
    return value, digits
end

-- Look up a label and parse it in one step.
-- Returns value, exact — or nil, nil when the label is absent.
function sensor.value(lines, pattern)
    local line = sensor.find(lines, pattern)
    if not line then return nil, nil end
    return sensor.amount(line)
end

-- Some values are printed twice, separator-formatted then scientific. Prefer
-- whichever carries exact digits; fall back to the scientific twin when the
-- figure has outgrown the separator-formatted variant.
function sensor.bestValue(lines, pattern)
    local candidates = sensor.findAll(lines, pattern)
    local bestValue, bestExact
    for i = 1, #candidates do
        local value, exact = sensor.amount(candidates[i])
        if value then
            if exact and not bestExact then
                bestValue, bestExact = value, exact
            elseif not bestValue then
                bestValue = value
            end
        end
    end
    return bestValue, bestExact
end

return sensor
