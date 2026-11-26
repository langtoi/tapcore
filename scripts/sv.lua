----------------------------------------------------------------
-- TapCore automation HTTP server (port 3000)
-- The BAS client (X.xml / X2.xml) only uses:
--   RUNLUA, URL, TEXT                    -> processCommand
--   COLOR / findColor (+ script)         -> processColor
--   POINTS (base point + anchor points)  -> processPoints
--   text / image_path (check/click/clickN/hold) -> processSearch
--   header X-Action: SAVE_PHOTO          -> processSavePhoto
--   {"action": "STOP"}                   -> reply 200, then shut the server down (remote stop)
-- The client only reads the HTTP status (200 / 404 / 4xx / 500).
----------------------------------------------------------------
local socket = require("socket")
local json   = require("json")

local PORT        = 3000
local IDLE_EXIT_S = 1800   -- exit after 30 minutes without requests (0 = run forever)
local DEBUG_MODE  = false
local now         = socket.gettime or os.time

local function trim(s)
    return (s or ""):match("^%s*(.-)%s*$")
end

----------------------------------------------------------------
-- SCREEN TOUCH
-- TapCore dispatches touch events immediately; the short settle after touchUp only gives
-- the app time to handle the tap before the next request.
----------------------------------------------------------------
local TAP_HOLD_US     = 40000   -- finger-down time of a tap (a real tap lasts 40-120 ms)
local TOUCH_SETTLE_US = 50000
local POLL_INTERVAL_S = 0.03    -- pause between two color checks

-- Text search (Vision OCR). Measured on iPhone X: a Fast pass takes ~0.1 s, an Accurate pass
-- ~2-4 s whatever the region size. So text search runs Fast passes, and only when Fast keeps
-- missing does it spend one Accurate pass, if enough of the timeout is left for it.
local OCR_INTERVAL_S       = 0.08  -- pause between two Fast passes
local OCR_ACCURATE_AFTER_S = 1.5   -- Fast must have missed this long before an Accurate pass
local OCR_ACCURATE_GAP_S   = 6     -- at most one Accurate pass per this many seconds
local ocrAccurateCost      = 3.5   -- seconds; updated from the last Accurate pass
-- Fast OCR sees text as soon as it is drawn, often while the screen is still animating in and
-- the app ignores touches. Before tapping, the text must still be found at the same spot
-- (within OCR_SETTLE_PX) at least OCR_SETTLE_S after it was first seen.
local OCR_SETTLE_S         = 0.25
local OCR_SETTLE_PX        = 12

local function tap(x, y)
    touchDown(0, x, y)
    usleep(TAP_HOLD_US)
    touchUp(0, x, y)
    usleep(TOUCH_SETTLE_US)
end

-- "click" | "clickN" | "hold". Any other value (e.g. "check") does not touch.
-- Returns true if a touch was performed.
local function performAction(x, y, actionType)
    if actionType == "hold" then
        touchDown(0, x, y)
        usleep(1500000)
        touchUp(0, x, y)
        usleep(TOUCH_SETTLE_US)
        return true
    end
    local count = actionType == "click" and 1
        or tonumber(type(actionType) == "string" and actionType:match("^click(%d+)$") or "")
    if not count or count < 1 then return false end
    for i = 1, count do
        tap(x, y)
        if i < count then usleep(150000) end
    end
    return true
end

-- Call fn(deadline) until it returns non-nil or the timeout expires (at least once),
-- pausing `interval` seconds (default POLL_INTERVAL_S) between calls.
local function poll(timeout, fn, interval)
    local deadline = now() + timeout
    interval = interval or POLL_INTERVAL_S
    while true do
        local result = fn(deadline)
        if result ~= nil then return result end
        local remaining = deadline - now()
        if remaining <= 0 then return nil end
        usleep(math.floor(math.min(interval, remaining) * 1000000) + 1)
    end
end

----------------------------------------------------------------
-- HTTP
----------------------------------------------------------------
local REASONS = {[200] = "OK", [400] = "Bad Request", [404] = "Not Found",
    [411] = "Length Required", [500] = "Internal Server Error"}

local function sendAll(client, payload)
    local first = 1
    while first <= #payload do
        local sent, err, partial = client:send(payload, first)
        local last = sent or partial
        if not last or last < first then return nil, err or "Send made no progress" end
        first = last + 1
        if not sent and err ~= "timeout" then return nil, err end
    end
    return true
end

-- body: JSON string or table (encoded automatically)
local function respond(client, code, body)
    if type(body) == "table" then body = json.encode(body) end
    return sendAll(client, string.format(
        "HTTP/1.1 %d %s\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",
        code, REASONS[code] or "Error", #body, body))
end

local function fail(client, code, message)
    respond(client, code, {success = false, error = message})
end

local function receiveFullBody(client, length)
    local parts, total = {}, 0
    while total < length do
        local chunk, err, partial = client:receive(length - total)
        local data = chunk or partial
        if data and #data > 0 then
            parts[#parts + 1] = data
            total = total + #data
        end
        if total >= length then break end
        if err or not data or #data == 0 then
            return nil, err or "Incomplete body"
        end
    end
    return table.concat(parts)
end

-- Only used when json.decode fails: escape newlines/tabs inside strings
-- (multi-line pasted findColors scripts) and drop trailing commas before } or ].
local function fixJSON(s)
    local out, n = {}, 0
    local inStr, esc = false, false
    for i = 1, #s do
        local c = s:sub(i, i)
        if inStr then
            if esc then esc = false
            elseif c == "\\" then esc = true
            elseif c == '"' then inStr = false
            elseif c == "\n" then c = "\\n"
            elseif c == "\r" then c = "\\r"
            elseif c == "\t" then c = "\\t"
            end
        elseif c == '"' then
            inStr = true
        elseif c == "," and s:find("^%s*[}%]]", i + 1) then
            c = ""
        end
        n = n + 1
        out[n] = c
    end
    return table.concat(out)
end

----------------------------------------------------------------
-- VALUE VALIDATION
----------------------------------------------------------------
local SCRIPT_NULL = {}

local function isNull(v)
    return v == nil or v == SCRIPT_NULL or (json.null ~= nil and v == json.null)
end

local function toNumber(v)
    if type(v) ~= "number" and type(v) ~= "string" then return nil end
    local n = tonumber(v)
    if n and n == n and n ~= math.huge and n ~= -math.huge then return n end
    return nil
end

local function parseBool(v, defaultValue)
    if isNull(v) then return defaultValue end
    if type(v) == "boolean" then return v end
    if v == 1 or v == "1" or v == "true" then return true end
    if v == 0 or v == "0" or v == "false" then return false end
    return nil
end

local function normalizeRegion(region)
    if isNull(region) then return nil end
    if type(region) ~= "table" then return nil, "region must be an object or array" end
    local x = toNumber(region.x or region[1])
    local y = toNumber(region.y or region[2])
    local w = toNumber(region.width or region[3])
    local h = toNumber(region.height or region[4])
    if not x or not y or not w or not h or x < 0 or y < 0 or w <= 0 or h <= 0 then
        return nil, "region requires x/y >= 0 and width/height > 0"
    end
    return {x, y, w, h}
end

----------------------------------------------------------------
-- COLOR: read the literals of a findColors / findColor call exported by the
-- Function Helper. The script is NOT executed as Lua or JS. Accepts:
--   Lua: findColors({{0xFF0000,0,0},{0x00FF00,10,10}}, 0, {x,y,w,h})
--                             local colors = {...}; findColors(colors, 0, region)
--                             findColor(0xFFFFFF, 0, {x,y,w,h}) -- 0xFFFFFF, (992,489)
--   Legacy JS: findColors({colors: [{color: .., x: .., y: ..}], region: {...}})
----------------------------------------------------------------
local function parseFindColorsScript(raw)
    if type(raw) ~= "string" or trim(raw) == "" then return nil, "script is empty" end
    if #raw > 262144 then return nil, "script exceeds 256 KiB" end
    local ok, result = pcall(function()
        local pos, kind, value = 1, nil, nil
        local vars = {}   -- literals assigned before the call: local colors = {...}
        local function fail(message)
            error(message .. " at script byte " .. pos, 0)
        end
        local function nextToken()
            while pos <= #raw do
                local c, pair = raw:sub(pos, pos), raw:sub(pos, pos + 1)
                if c:match("%s") then
                    pos = pos + 1
                elseif pair == "--" then
                    -- Lua comment: --[[ ... ]] / --[==[ ... ]==] or -- to end of line
                    local eq = raw:match("^%-%-%[(=*)%[", pos)
                    if eq then
                        local close = "]" .. eq .. "]"
                        local ending = raw:find(close, pos + 4 + #eq, true)
                        if not ending then fail("Unclosed comment") end
                        pos = ending + #close
                    else
                        pos = raw:find("[\r\n]", pos + 2) or (#raw + 1)
                    end
                elseif pair == "//" then
                    pos = raw:find("[\r\n]", pos + 2) or (#raw + 1)
                elseif pair == "/*" then
                    local ending = raw:find("*/", pos + 2, true)
                    if not ending then fail("Unclosed comment") end
                    pos = ending + 2
                else
                    break
                end
            end
            if pos > #raw then kind, value = "eof", nil; return end
            local c = raw:sub(pos, pos)
            if c == '"' or c == "'" then
                local quote, parts = c, {}
                pos = pos + 1
                while pos <= #raw do
                    c = raw:sub(pos, pos)
                    pos = pos + 1
                    if c == quote then kind, value = "string", table.concat(parts); return end
                    if c == "\\" then
                        local escaped = raw:sub(pos, pos)
                        local escapes = {n = "\n", r = "\r", t = "\t", ['\\'] = '\\', ['"'] = '"', ["'"] = "'", ['/'] = '/'}
                        if not escapes[escaped] then fail("Unsupported string escape") end
                        c = escapes[escaped]
                        pos = pos + 1
                    end
                    parts[#parts + 1] = c
                end
                fail("Unclosed string")
            end
            local rest = raw:sub(pos)
            local identifier = rest:match("^[%a_$][%w_$]*")
            if identifier then
                pos = pos + #identifier
                kind, value = "identifier", identifier
                return
            end
            local number = rest:match("^[+-]?0[xX][%da-fA-F]+")
                or rest:match("^[+-]?%d+%.?%d*[eE][+-]?%d+")
                or rest:match("^[+-]?%.%d+[eE][+-]?%d+")
                or rest:match("^[+-]?%d+%.?%d*")
                or rest:match("^[+-]?%.%d+")
            if number then
                pos = pos + #number
                kind, value = "number", toNumber(number)
                if value == nil then fail("Invalid number") end
                return
            end
            pos = pos + 1
            kind, value = c, c
        end
        local function expect(token)
            if kind ~= token then fail("Expected '" .. token .. "'") end
            nextToken()
        end
        local parseValue
        parseValue = function(depth)
            if depth > 8 then fail("Options are nested too deeply") end
            if kind == "{" then
                nextToken()
                -- Lua uses {x, y, width, height}; JS uses {x: ..., y: ...}. Accept both.
                if kind == "number" or kind == "[" or kind == "{"
                    or (kind == "identifier" and
                        (value == "true" or value == "false" or value == "nil" or value == "null")) then
                    local array = {}
                    while kind ~= "}" do
                        array[#array + 1] = parseValue(depth + 1)
                        if kind ~= "," and kind ~= ";" then break end
                        nextToken()
                    end
                    expect("}")
                    return array
                end
                -- Object: JS {key: v} or Lua {key = v}
                local object, seen = {}, {}
                while kind ~= "}" do
                    if kind ~= "identifier" and kind ~= "string" then fail("Expected object key") end
                    local key = value
                    if seen[key] then fail("Duplicate key " .. key) end
                    seen[key] = true
                    nextToken()
                    if kind ~= ":" and kind ~= "=" then fail("Expected ':' or '='") end
                    nextToken()
                    object[key] = parseValue(depth + 1)
                    if kind ~= "," and kind ~= ";" then break end
                    nextToken()
                end
                expect("}")
                return object
            elseif kind == "[" then
                nextToken()
                local array = {}
                while kind ~= "]" do
                    array[#array + 1] = parseValue(depth + 1)
                    if kind ~= "," then break end
                    nextToken()
                end
                expect("]")
                return array
            elseif kind == "number" or kind == "string" then
                local literal = value
                nextToken()
                return literal
            elseif kind == "identifier" then
                local literal
                if value == "true" then literal = true
                elseif value == "false" then literal = false
                elseif value == "null" or value == "nil" then literal = SCRIPT_NULL
                elseif vars[value] ~= nil then literal = vars[value]
                else fail("Unknown variable '" .. value .. "' (use literal values)") end
                nextToken()
                return literal
            end
            fail("Expected a literal value")
        end
        local function attachSample(options)
            local sampleColor, sampleX, sampleY
            -- Sample from the Function Helper: "0xFFFFFF, (992,489)" (in a comment or plain text)
            for c, x, y in raw:gmatch(
                "([%+%-]?0[xX][%da-fA-F]+)%s*,%s*%(%s*([%+%-]?[%d%.]+)%s*,%s*([%+%-]?[%d%.]+)%s*%)") do
                sampleColor, sampleX, sampleY = c, x, y
            end
            if not sampleColor then
                for c, x, y in raw:gmatch(
                    "([%+%-]?%d+%.?%d*)%s*,%s*%(%s*([%+%-]?[%d%.]+)%s*,%s*([%+%-]?[%d%.]+)%s*%)") do
                    sampleColor, sampleX, sampleY = c, x, y
                end
            end
            if sampleColor then
                options.sample = {
                    color = toNumber(sampleColor),
                    x = toNumber(sampleX),
                    y = toNumber(sampleY)
                }
            end
            return options
        end
        -- Find the findColors( / findColor( call; remember literal assignments before it.
        nextToken()
        local functionName
        while kind ~= "eof" do
            if kind == "identifier" and (value == "findColors" or value == "findColor") then
                local name = value
                nextToken()
                if kind == "(" then functionName = name; break end
            elseif kind == "identifier" then
                local name = value
                nextToken()
                if kind == "=" then
                    nextToken()
                    if kind == "{" or kind == "[" or kind == "number" or kind == "string" then
                        local okLiteral, literal = pcall(parseValue, 0)
                        if okLiteral then vars[name] = literal end
                    end
                end
            else
                nextToken()
            end
        end
        if not functionName then
            fail("Missing findColors(...) or findColor(...) call")
        end
        nextToken()
        local args = {}
        while kind ~= ")" do
            args[#args + 1] = parseValue(0)
            if kind ~= "," then break end
            nextToken()
        end
        expect(")")

        if functionName == "findColors" then
            local first = args[1]
            -- JS: findColors({colors: [...], region: ...})
            if #args == 1 and type(first) == "table" and first.colors ~= nil then return first end
            -- Lua: findColors(colors, count, region, debug, rightToLeft, bottomToTop)
            return {colors = first, count = args[2], region = args[3], debug = args[4],
                rightToLeft = args[5], bottomToTop = args[6]}
        end

        -- findColor(color, count, region, debug, rightToLeft, bottomToTop)  (Lua)
        -- or findColor({color: ...})                                         (JS)
        if type(args[1]) == "table" and not isNull(args[1]) then
            local options = args[1]
            if isNull(options.color) then fail("findColor requires color") end
            options.colors = {{color = options.color, x = 0, y = 0}}
            options.color = nil
            return attachSample(options)
        end
        if isNull(args[1]) then fail("findColor requires color") end
        return attachSample({
            colors = {{color = args[1], x = 0, y = 0}},
            count = args[2], region = args[3], debug = args[4],
            rightToLeft = args[5], bottomToTop = args[6]
        })
    end)
    if not ok then return nil, tostring(result) end
    return result
end

local function normalizeColorsFromData(data)
    local parsed, err = parseFindColorsScript(data.script)
    if not parsed then return nil, nil, err end
    local input = parsed.colors
    if type(input) ~= "table" or #input == 0 then return nil, nil, "colors must be a nonempty array" end
    for key in pairs(input) do
        if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #input then
            return nil, nil, "colors must be a contiguous array"
        end
    end
    local colors = {}
    for i, item in ipairs(input) do
        if type(item) ~= "table" then return nil, nil, "Invalid colors[" .. i .. "]" end
        local c = toNumber(item.color or item[1])
        local x = toNumber(item.x or item[2])
        local y = toNumber(item.y or item[3])
        if not c or c % 1 ~= 0 or c < 0 or c > 0xFFFFFF or not x or not y then
            return nil, nil, "Invalid colors[" .. i .. "]: require RGB color, x and y"
        end
        colors[i] = {c, x, y}
    end
    if colors[1][2] ~= 0 or colors[1][3] ~= 0 then
        return nil, nil, "The first color must have x=0, y=0; other points use relative offsets"
    end
    -- Values in the outer JSON (when not null) override values in the script.
    local function option(key, defaultValue)
        if not isNull(data[key]) then return data[key] end
        if not isNull(parsed[key]) then return parsed[key] end
        return defaultValue
    end
    -- The server only uses the first match -> always scan with count = 1 (stop early),
    -- ignoring the script's count (count 0 = scan the whole screen, very slow on background colors).
    local options = {count = 1}
    local regionError
    options.region, regionError = normalizeRegion(option("region"))
    if regionError then return nil, nil, regionError end
    for _, key in ipairs({"debug", "rightToLeft", "bottomToTop"}) do
        options[key] = parseBool(option(key, false), false)
        if options[key] == nil then return nil, nil, key .. " must be a boolean" end
    end
    if parsed.sample then
        local sampleColor = toNumber(parsed.sample.color)
        local sampleX = toNumber(parsed.sample.x)
        local sampleY = toNumber(parsed.sample.y)
        if not sampleColor or sampleColor % 1 ~= 0 or sampleColor < 0 or sampleColor > 0xFFFFFF
            or not sampleX or not sampleY then
            return nil, nil, "Invalid sampled color coordinate"
        end
        if sampleColor ~= colors[1][1] then
            return nil, nil, "Sampled color does not match findColor color"
        end
        if options.region then
            local r = options.region
            if sampleX < r[1] or sampleY < r[2]
                or sampleX >= r[1] + r[3] or sampleY >= r[2] + r[4] then
                return nil, nil, "Sampled coordinate is outside region"
            end
        end
        options.sample = {color = sampleColor, x = sampleX, y = sampleY}
    end
    return colors, options
end

-- Call a native TapCore function; failure -> error() -> server replies 500.
local function nativeCall(name, fn, ...)
    local ok, res, nativeError = pcall(fn, ...)
    if not ok then error(name .. " failed: " .. tostring(res), 0) end
    if nativeError ~= nil and nativeError ~= false then
        error(name .. " failed: " .. tostring(nativeError), 0)
    end
    return res
end

local function processColor(client, data)
    local colors, opts, parseError = normalizeColorsFromData(data)
    if not colors then return fail(client, 400, parseError or "Invalid script") end
    local timeout = isNull(data.timeout) and 15 or toNumber(data.timeout)
    local offset  = isNull(data.offset)  and 0 or toNumber(data.offset)
    local offsetX = isNull(data.offsetX) and 0 or toNumber(data.offsetX)
    local offsetY = isNull(data.offsetY) and 0 or toNumber(data.offsetY)
    if not timeout or timeout < 0 then return fail(client, 400, "timeout must be a number >= 0") end
    if not offset or not offsetX or not offsetY then return fail(client, 400, "Offsets must be numbers") end
    local mode = isNull(data.mode) and "check" or tostring(data.mode):lower()
    if mode ~= "check" and mode ~= "click" and mode ~= "hold" and not mode:match("^click%d+$") then
        return fail(client, 400, "Invalid COLOR mode")
    end

    local sample, actualColor = opts.sample, nil
    local found = poll(timeout, function()
        if sample then
            -- Sample coordinate known -> read a single pixel (faster than scanning the region)
            actualColor = toNumber(nativeCall("getColor", getColor, sample.x, sample.y))
            if not actualColor then error("getColor returned an invalid result", 0) end
            if actualColor == sample.color then return {sample.x, sample.y} end
            return nil
        end
        local res = nativeCall("findColors", findColors, colors, opts.count, opts.region,
            opts.debug, opts.rightToLeft, opts.bottomToTop)
        if type(res) ~= "table" then error("findColors returned an invalid result", 0) end
        return res[1]
    end)

    if not found then
        if sample then
            return respond(client, 404, {success = false, error = "Not found",
                expectedColor = sample.color, actualColor = actualColor})
        end
        return fail(client, 404, "Not found")
    end
    local x, y = toNumber(found[1]), toNumber(found[2])
    if not x or not y then return fail(client, 500, "findColors returned invalid coordinates") end
    x, y = x + offsetX, y + offsetY + offset
    if performAction(x, y, mode) then usleep(120000) end
    respond(client, 200, {success = true, x = x, y = y})
end

----------------------------------------------------------------
-- POINTS: 1 base point + anchor points. Three input formats:
--   1) Paste the Function Helper export VERBATIM + "at": [x, y] = position of the first color:
--      "script": "const [result, error] = findColors({ colors: [ {color: 47740, x: 0, y: 0}, ... ] })",
--      "at": [930, 387]
--   2) Absolute coordinates: "script": "0x00BA7C, (930,387)\n0xFFFFFF, (1006,387)"
--   3) JSON: "points": [["0x00BA7C", 930, 387], {"color": 16777215, "x": 1006, "y": 387}]
-- The first point is the base (the point that gets tapped). By default colors are read
-- EXACTLY at the coordinates (getColors: fast, no false matches); "tolerance": max
-- difference per R/G/B channel. "search": N -> if nothing matches in place, search the
-- pattern shifted by up to N px with findColors (exact colors, tolerance not applied).
----------------------------------------------------------------
local function parsePoints(data)
    local list = {}
    if not isNull(data.points) then
        if type(data.points) ~= "table" then return nil, "points must be an array" end
        for i, p in ipairs(data.points) do
            if type(p) ~= "table" then return nil, "Invalid points[" .. i .. "]" end
            list[i] = {p.color or p[1], p.x or p[2], p.y or p[3]}
        end
    elseif type(data.script) == "string" and data.script:find("findColors?%s*%(") then
        -- Verbatim findColors/findColor export: anchors are offsets from "at"
        local at = data.at
        local ax = type(at) == "table" and toNumber(at.x or at[1])
        local ay = type(at) == "table" and toNumber(at.y or at[2])
        if not ax or not ay then
            return nil, 'Pasted findColors needs "at": [x, y] = screen position of the first color'
        end
        local parsed, parseError = parseFindColorsScript(data.script)
        if not parsed then return nil, parseError end
        if type(parsed.colors) ~= "table" then return nil, "colors must be a nonempty array" end
        for i, item in ipairs(parsed.colors) do
            if type(item) ~= "table" then return nil, "Invalid colors[" .. i .. "]" end
            local dx, dy = toNumber(item.x or item[2]), toNumber(item.y or item[3])
            if not dx or not dy then return nil, "Invalid colors[" .. i .. "]: need x and y" end
            list[i] = {item.color or item[1], ax + dx, ay + dy}
        end
    elseif type(data.script) == "string" then
        for c, x, y in data.script:gmatch(
            "(%w+)%s*,%s*%(%s*([%+%-]?[%d%.]+)%s*,%s*([%+%-]?[%d%.]+)%s*%)") do
            list[#list + 1] = {c, x, y}
        end
    end
    if #list < 2 then
        return nil, "Need a base point and at least 1 anchor: one 'color, (x,y)' per point"
    end
    local points, distinct = {}, false
    for i, p in ipairs(list) do
        local c, x, y = toNumber(p[1]), toNumber(p[2]), toNumber(p[3])
        if not c or c % 1 ~= 0 or c < 0 or c > 0xFFFFFF or not x or not y or x < 0 or y < 0 then
            return nil, "Invalid point " .. i .. ": need color 0x000000-0xFFFFFF and x, y >= 0"
        end
        points[i] = {color = c, x = x, y = y}
        if c ~= points[1].color then distinct = true end
    end
    if not distinct then
        return nil, "All points have the same color, so a plain background also matches: add a point of another color"
    end
    return points
end

-- Compare 2 colors with a per-channel R/G/B tolerance <= tol
local function colorClose(a, b, tol)
    if a == b then return true end
    if not a or tol <= 0 then return false end
    for _ = 1, 3 do
        if math.abs(a % 256 - b % 256) > tol then return false end
        a, b = math.floor(a / 256), math.floor(b / 256)
    end
    return true
end

local function hex(c)
    return c and string.format("0x%06X", c) or nil
end

local function processPoints(client, data)
    local points, pointsError = parsePoints(data)
    if not points then return fail(client, 400, pointsError) end
    local timeout   = isNull(data.timeout)   and 5 or toNumber(data.timeout)
    local tolerance = isNull(data.tolerance) and 0 or toNumber(data.tolerance)
    local search    = isNull(data.search)    and 0 or toNumber(data.search)
    local offsetX   = isNull(data.offsetX)   and 0 or toNumber(data.offsetX)
    local offsetY   = isNull(data.offsetY)   and 0 or toNumber(data.offsetY)
    if not timeout or timeout < 0 then return fail(client, 400, "timeout must be a number >= 0") end
    if not tolerance or tolerance < 0 or tolerance > 255 then return fail(client, 400, "tolerance must be 0-255") end
    if not search or search < 0 then return fail(client, 400, "search must be a number >= 0") end
    if not offsetX or not offsetY then return fail(client, 400, "Offsets must be numbers") end
    local mode = isNull(data.mode) and "check" or tostring(data.mode):lower()
    if mode ~= "check" and mode ~= "click" and mode ~= "hold" and not mode:match("^click%d+$") then
        return fail(client, 400, "Invalid mode")
    end

    local base = points[1]
    local locations, pattern = {}, {}
    local minX, minY, maxX, maxY = math.huge, math.huge, 0, 0
    for i, p in ipairs(points) do
        locations[i] = {p.x, p.y}
        pattern[i] = {p.color, p.x - base.x, p.y - base.y}
        minX, minY = math.min(minX, p.x), math.min(minY, p.y)
        maxX, maxY = math.max(maxX, p.x), math.max(maxY, p.y)
    end
    local region
    if search > 0 then
        local x0, y0 = math.max(0, minX - search), math.max(0, minY - search)
        region = {x0, y0, maxX + search - x0 + 1, maxY + search - y0 + 1}
    end

    local actual
    local found = poll(timeout, function()
        local colors = nativeCall("getColors", getColors, locations)
        if type(colors) ~= "table" then error("getColors returned an invalid result", 0) end
        actual = colors
        local match = true
        for i, p in ipairs(points) do
            if not colorClose(toNumber(colors[i]), p.color, tolerance) then match = false; break end
        end
        if match then return {base.x, base.y} end
        if region then
            local res = nativeCall("findColors", findColors, pattern, 1, region, false, false, false)
            if type(res) == "table" and res[1] then return res[1] end
        end
        return nil
    end)

    if not found then
        local report = {}
        for i, p in ipairs(points) do
            report[i] = {x = p.x, y = p.y, expected = hex(p.color), actual = hex(toNumber(actual and actual[i]))}
        end
        return respond(client, 404, {success = false, error = "Not found", points = report})
    end
    local x, y = toNumber(found[1]), toNumber(found[2])
    if not x or not y then return fail(client, 500, "findColors returned invalid coordinates") end
    local shiftX, shiftY = x - base.x, y - base.y
    x, y = x + offsetX, y + offsetY
    if performAction(x, y, mode) then usleep(120000) end
    respond(client, 200, {success = true, x = x, y = y, shiftX = shiftX, shiftY = shiftY})
end

----------------------------------------------------------------
-- RUNLUA / URL / TEXT
----------------------------------------------------------------
local function processCommand(client, data, action)
    local payload = data.data
    if not payload or isNull(payload) then return fail(client, 400, "Missing data payload") end

    local res = {}
    local ok, result
    if action == "URL" then
        ok = pcall(openURL, payload)
        res.message = ok and "URL opened" or "URL failed"
    elseif action == "TEXT" then
        local called, typed, how = pcall(inputText, payload)
        ok = called and typed ~= false
        res.message = ok and "Text input" or ("Text failed: " .. tostring(how or typed))
    else -- RUNLUA
        ok, result = pcall(function()
            local fn, compileError = load(payload)
            if not fn then error("Compile failed: " .. tostring(compileError), 0) end
            return fn()
        end)
        if not ok then
            res.error = tostring(result)
        elseif type(result) == "table" then
            res.data = result
        elseif type(result) == "string" then
            local trimmed = trim(result)
            local first = trimmed:sub(1, 1)
            local decoded, value = false, nil
            if first == "{" or first == "[" then decoded, value = pcall(json.decode, trimmed) end
            if decoded then res.data = value else res.message = trimmed end
        elseif result ~= nil then
            res.message = tostring(result)
        end
    end
    res.success = ok
    respond(client, ok and 200 or 500, res)
end

----------------------------------------------------------------
-- FIND TEXT (OCR) / IMAGE
----------------------------------------------------------------
local function processSearch(client, data)
    local timeout = toNumber(data.timeout) or 15
    local region, regionError = normalizeRegion(data.region)
    if regionError then return fail(client, 400, regionError) end
    local dx = toNumber(data.offsetX) or 0
    local dy = (toNumber(data.offsetY) or 0) + (toNumber(data.offset) or 0)

    if data.image_path then
        local dir = rootDir()
        if dir:sub(-1) ~= "/" then dir = dir .. "/" end
        local full = dir .. "Screenshots/" .. (data.image_path:match(".*/(.+)$") or data.image_path)
        local f = io.open(full, "rb")
        if not f then return fail(client, 404, "Image not found") end
        f:close()
        local threshold = toNumber(data.threshold) or 0.9

        local hit = poll(timeout, function()
            local ok, res = pcall(findImage, full, 1, threshold, region, DEBUG_MODE, 1)
            return ok and type(res) == "table" and res[1] or nil
        end)
        if not hit then return fail(client, 404, "Not found") end
        local x, y = hit[1] + dx, hit[2] + dy
        if performAction(x, y, data.action) then usleep(500000) end
        return respond(client, 200, {success = true, x = x, y = y})
    end

    if data.text then
        local word   = trim(tostring(data.text)):lower()
        local target = word:gsub("%s+", "")
        -- ex = true/omitted: OCR text equals or ENDS WITH target; ex = false: contains target
        local exact  = data.ex == nil or data.ex == true
        -- "level": "auto" (default) = Fast passes with an occasional Accurate fallback;
        -- "fast" / "accurate" force one level for every pass.
        local mode = type(data.level) == "string" and data.level:lower() or "auto"
        local started, lastAccurate = now(), -math.huge
        local willTouch = data.action == "hold" or
            (type(data.action) == "string" and data.action:match("^click%d*$") ~= nil)

        -- One OCR pass: returns {x, y} of the target or nil, plus the level used.
        local function locate(deadline)
            local level = mode
            if level ~= "fast" and level ~= "accurate" then
                local t = now()
                if t - started >= OCR_ACCURATE_AFTER_S and t - lastAccurate >= OCR_ACCURATE_GAP_S
                    and deadline - t >= ocrAccurateCost then
                    level, lastAccurate = "accurate", t
                else
                    level = "fast"
                end
            end
            local t0 = now()
            local ok, results = pcall(ocr, {level = level, languages = {"en-US"},
                correct = (level == "accurate"), region = region})
            if ok and level == "accurate" then ocrAccurateCost = math.max(1, now() - t0) end
            if not ok or type(results) ~= "table" then return nil, level end
            for _, item in ipairs(results) do
                local text = item.text or ""
                local candidate = trim(text):lower():gsub("%s+", "")
                local match
                if exact then
                    match = candidate:sub(-#target) == target
                else
                    match = candidate:find(target, 1, true) ~= nil
                end
                local r = item.rectangle
                if match and r and r.topLeft and r.topRight and r.bottomLeft then
                    -- Estimate the center of the target word inside the text line
                    local line = text:lower()
                    local s, e = line:find(word, 1, true)
                    local x
                    if s and #line > 0 then
                        x = r.topLeft.x + ((s + e) / 2 - 1) * (r.topRight.x - r.topLeft.x) / #line
                    else
                        x = (r.topLeft.x + r.topRight.x) / 2
                    end
                    return {x + dx, (r.topLeft.y + r.bottomLeft.y) / 2 + dy}, level
                end
            end
            return nil, level
        end

        local seen   -- {x, y, t}: where and when the text was first seen at its current spot
        local hit = poll(timeout, function(deadline)
            local pos, level = locate(deadline)
            if not pos then
                seen = nil
                return nil
            end
            -- "check" never touches; an Accurate pass already took seconds: no settle needed.
            if not willTouch or level == "accurate" then return pos end
            local t = now()
            if not seen or math.abs(pos[1] - seen[1]) > OCR_SETTLE_PX
                or math.abs(pos[2] - seen[2]) > OCR_SETTLE_PX then
                seen = {pos[1], pos[2], t}
                return nil
            end
            if t - seen[3] >= OCR_SETTLE_S or deadline - t <= OCR_INTERVAL_S then
                return pos
            end
            return nil
        end, OCR_INTERVAL_S)
        if not hit and seen then hit = {seen[1], seen[2]} end   -- found but timed out while settling
        if not hit then return fail(client, 404, "Not found") end
        performAction(hit[1], hit[2], data.action)
        return respond(client, 200, string.format('{"success":true,"x":%f,"y":%f}', hit[1], hit[2]))
    end

    fail(client, 400, "Missing params or text/image data")
end

----------------------------------------------------------------
-- SAVE_PHOTO (body = image bytes, header X-Action: SAVE_PHOTO)
----------------------------------------------------------------
local function processSavePhoto(client, headers)
    local len = tonumber(headers["content-length"]) or 0
    if len <= 0 then return respond(client, 400, '{"success":false,"error":"No content"}') end
    local imageData = receiveFullBody(client, len)
    if not imageData then return respond(client, 400, '{"success":false,"error":"Incomplete data"}') end

    local path = "/tmp/tmp_" .. os.time() .. ".jpg"
    local f = io.open(path, "wb")
    if not f then return respond(client, 500, '{"success":false,"error":"Write failed"}') end
    f:write(imageData)
    f:close()

    local saveFunc = saveToSystemAlbum or saveImageToAlbum or saveToAlbum
    local ok = saveFunc ~= nil and pcall(saveFunc, path)
    -- saveToSystemAlbum returns after Photos has imported the file, so it can go right away.
    os.remove(path)
    if not saveFunc then
        respond(client, 500, '{"success":false,"error":"No save function"}')
    elseif ok then
        respond(client, 200, '{"success":true,"message":"Saved to Album"}')
    else
        respond(client, 500, '{"success":false,"error":"Album failed"}')
    end
end

----------------------------------------------------------------
-- HANDLE ONE REQUEST
----------------------------------------------------------------
local function handleRequest(client)
    client:settimeout(5)
    local line = client:receive()
    if not line then return end

    local headers = {}
    while true do
        local l = client:receive()
        if not l or l == "" then break end
        local k, v = l:match("([^:]+):%s*(.+)")
        if k then headers[trim(k):lower()] = v end
    end

    if headers["x-action"] == "SAVE_PHOTO" then return processSavePhoto(client, headers) end
    if not line:match("^POST") then return end

    if headers["transfer-encoding"] then
        return fail(client, 400, "Send Content-Length; chunked requests are not supported")
    end
    local contentLength = tonumber(headers["content-length"])
    if not contentLength or contentLength <= 0 or contentLength % 1 ~= 0 or contentLength == math.huge then
        return fail(client, 411, "A positive Content-Length is required")
    end
    local body, receiveError = receiveFullBody(client, contentLength)
    if not body then return fail(client, 400, "Incomplete body: " .. tostring(receiveError)) end

    -- Try strict JSON first; on failure fix it (newlines in strings, trailing commas) and retry.
    local ok, data = pcall(json.decode, body)
    if not ok then ok, data = pcall(json.decode, fixJSON(body)) end
    if not ok or type(data) ~= "table" then return fail(client, 400, "Invalid JSON") end
    if type(data.action) ~= "string" then return fail(client, 400, "action must be a string") end

    local action = data.action:upper()
    if action == "STOP" then
        respond(client, 200, {success = true, message = "Server stopped"})
        return "STOP"
    end
    if action == "RUNLUA" or action == "URL" or action == "TEXT" then
        return processCommand(client, data, action)
    elseif action == "COLOR" or action == "FINDCOLOR" or action == "FINDCOLORS" then
        return processColor(client, data)
    elseif action == "POINTS" then
        return processPoints(client, data)
    end
    return processSearch(client, data)
end

----------------------------------------------------------------
-- SERVER LOOP
----------------------------------------------------------------
local function startServer()
    local server = socket.bind("0.0.0.0", PORT)
    if not server then return end
    -- accept() waits up to 0.5 s and returns the moment a request arrives (no idle polling).
    server:settimeout(0.5)

    local lastRequest = now()
    local dirty = false
    while true do
        local client = server:accept()
        if client then
            local handled, result = pcall(handleRequest, client)
            if not handled then
                pcall(respond, client, 500, {success = false, error = tostring(result)})
            end
            pcall(client.close, client)
            if handled and result == "STOP" then break end   -- {"action":"STOP"}
            lastRequest = now()
            dirty = true
        else
            if dirty then
                collectgarbage("collect")   -- collect garbage once after a burst of requests
                dirty = false
            end
            if IDLE_EXIT_S > 0 and now() - lastRequest > IDLE_EXIT_S then break end
        end
    end
    server:close()
end

pcall(startServer)
