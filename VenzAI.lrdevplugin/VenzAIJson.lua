--[[----------------------------------------------------------------------------

VenzAIJson.lua
JSON string escaping and unescaping, in both directions.

Every driver puts a string into a request payload and takes one back out of a
response, so both halves live here rather than once per driver.

Lua's string.format("%q", ...) does NOT produce a valid JSON escape: it turns
a newline into a backslash followed by a REAL line break, not into the
two-character sequence \n that JSON requires. Google tolerates it; Ollama's Go
parser answers 400. Hence the hand-written escaper, which was already in
VenzAIProcess before the drivers existed and is unchanged here.

Reading is the half that is new. The old code never extracted the model's
answer: it handed the whole HTTP body to the parser, which ran
gsub('\\"', '"') over it to neutralize the escaping of JSON nested inside
JSON. That is a guess, not a decoder - it turns \\" into a real quote too, and
leaves \n as two characters. readStringAt honours escapes properly, which is
what lets the driver contract promise a response.text that is already decoded.

------------------------------------------------------------------------------]]

local M = {}

--------------------------------------------------------------------------------
-- Writing
--------------------------------------------------------------------------------

-- Returns `s` as a complete, quoted JSON string literal.
function M.escape(s)
    local escaped = tostring(s):gsub('[%z\1-\31\\"]', function(c)
        if c == '\\' then return '\\\\'
        elseif c == '"' then return '\\"'
        elseif c == '\n' then return '\\n'
        elseif c == '\r' then return '\\r'
        elseif c == '\t' then return '\\t'
        else return string.format('\\u%04x', c:byte())
        end
    end)
    return '"' .. escaped .. '"'
end

--------------------------------------------------------------------------------
-- Reading
--------------------------------------------------------------------------------

local SIMPLE_ESCAPES = {
    ['"'] = '"', ['\\'] = '\\', ['/'] = '/',
    b = '\b', f = '\f', n = '\n', r = '\r', t = '\t',
}

-- UTF-8 encoding of one code point, for \uXXXX. Lightroom's strings are UTF-8.
-- Surrogate halves (D800..DFFF) are dropped rather than encoded: on their own
-- they are not a character, and a develop-parameter answer has no reason to
-- contain one. A model that emits an astral character loses it instead of
-- producing invalid UTF-8 that Lightroom would then have to survive.
local function utf8FromCodepoint(code)
    if code >= 0xD800 and code <= 0xDFFF then
        return ""
    elseif code < 0x80 then
        return string.char(code)
    elseif code < 0x800 then
        return string.char(0xC0 + math.floor(code / 0x40),
                           0x80 + (code % 0x40))
    else
        return string.char(0xE0 + math.floor(code / 0x1000),
                           0x80 + (math.floor(code / 0x40) % 0x40),
                           0x80 + (code % 0x40))
    end
end

-- Decodes the CONTENT of a JSON string literal, without its surrounding
-- quotes: the inverse of escape().
function M.decode(s)
    if not s:find('\\', 1, true) then return s end

    local out = {}
    local i, n = 1, #s
    while i <= n do
        local c = s:sub(i, i)
        if c ~= '\\' then
            table.insert(out, c)
            i = i + 1
        else
            local nextChar = s:sub(i + 1, i + 1)
            if nextChar == 'u' then
                local code = tonumber(s:sub(i + 2, i + 5), 16)
                if code then
                    table.insert(out, utf8FromCodepoint(code))
                    i = i + 6
                else
                    -- Malformed \u with no four hex digits: keep it literally
                    -- rather than swallowing the rest of the string.
                    table.insert(out, nextChar)
                    i = i + 2
                end
            elseif nextChar == '' then
                -- A trailing lone backslash, i.e. a truncated body.
                table.insert(out, '\\')
                i = i + 1
            else
                table.insert(out, SIMPLE_ESCAPES[nextChar] or nextChar)
                i = i + 2
            end
        end
    end
    return table.concat(out)
end

-- Reads the JSON string literal starting at `openQuotePos`, which must be the
-- index of its opening quote. Honours escapes, so an escaped quote inside the
-- value does not end it early. Returns the decoded value and the index just
-- past the closing quote, or nil if the literal is unterminated.
function M.readStringAt(body, openQuotePos)
    if body:sub(openQuotePos, openQuotePos) ~= '"' then return nil end
    local i, n = openQuotePos + 1, #body
    local startPos = i
    while i <= n do
        local c = body:sub(i, i)
        if c == '\\' then
            i = i + 2
        elseif c == '"' then
            return M.decode(body:sub(startPos, i - 1)), i + 1
        else
            i = i + 1
        end
    end
    return nil
end

-- Every value of `"<key>": "<string>"` in `body`, decoded, in order of
-- appearance. This is how a driver pulls the model's answer out of a response
-- without a full JSON parser: the key is unambiguous in each provider's
-- response shape, and reading the literal properly is what makes the old
-- gsub('\\"', '"') hack unnecessary.
--
-- `key` is interpolated into a Lua pattern, so it must be a plain word. Every
-- caller passes a fixed literal ("text", "data", "content", "mimeType").
function M.stringValues(body, key)
    local values = {}
    local pattern = '"' .. key .. '"%s*:%s*'
    local searchFrom = 1
    while true do
        local _, matchEnd = body:find(pattern, searchFrom)
        if not matchEnd then break end
        local value, nextPos = M.readStringAt(body, matchEnd + 1)
        if value then
            table.insert(values, value)
            searchFrom = nextPos
        else
            searchFrom = matchEnd + 1
        end
    end
    return values
end

-- The first value of `"<key>": "<string>"`, or nil. Convenience for the
-- common case of a key that appears once.
function M.stringValue(body, key)
    local values = M.stringValues(body, key)
    return values[1]
end

return M
