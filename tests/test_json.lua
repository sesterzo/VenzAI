local J = require 'VenzAIJson'

local BACKSLASH = string.char(92)
local QUOTE = string.char(34)

return {
    { "escape leaves a plain string alone", function()
        assert(J.escape("hello") == QUOTE .. "hello" .. QUOTE)
    end },

    { "escape turns a quote into backslash-quote", function()
        -- say "hi"  ->  "say \"hi\""
        local got = J.escape('say ' .. QUOTE .. 'hi' .. QUOTE)
        local want = QUOTE .. 'say ' .. BACKSLASH .. QUOTE .. 'hi' .. BACKSLASH .. QUOTE .. QUOTE
        assert(got == want, "got " .. got)
    end },

    { "escape turns a newline into the two characters backslash n", function()
        -- This is the bug string.format("%q") has: it emits a real line break.
        local got = J.escape("a\nb")
        local want = QUOTE .. "a" .. BACKSLASH .. "n" .. "b" .. QUOTE
        assert(got == want, "got " .. got .. " (len " .. #got .. ")")
        assert(#got == 6, "expected 6 characters, got " .. #got)
        assert(not got:find("\n", 1, true), "a real line break survived")
    end },

    { "escape doubles a backslash", function()
        local got = J.escape("a" .. BACKSLASH .. "b")
        local want = QUOTE .. "a" .. BACKSLASH .. BACKSLASH .. "b" .. QUOTE
        assert(got == want, "got " .. got)
    end },

    { "escape turns an other control character into \\u00xx", function()
        local got = J.escape("a" .. string.char(1) .. "b")
        local want = QUOTE .. "a" .. BACKSLASH .. "u0001" .. "b" .. QUOTE
        assert(got == want, "got " .. got)
    end },

    -- Reading. These are the cases the old gsub('\\"', '"') hack got wrong.
    { "nested JSON comes out intact", function()
        -- {"text": "{\"Exposure2012\": -0.25}"}
        local body = '{"text": ' .. QUOTE .. '{' .. BACKSLASH .. QUOTE
            .. 'Exposure2012' .. BACKSLASH .. QUOTE .. ': -0.25}' .. QUOTE .. '}'
        assert(J.stringValue(body, "text") == '{"Exposure2012": -0.25}',
            "got " .. tostring(J.stringValue(body, "text")))
    end },

    { "an escaped backslash stays a backslash and does not become a quote", function()
        -- The old hack turned \\" into a bare quote here and corrupted the value.
        local inner = 'C:' .. BACKSLASH .. BACKSLASH .. 'temp'
        local body = '{"text": ' .. QUOTE .. inner .. QUOTE .. '}'
        assert(J.stringValue(body, "text") == 'C:' .. BACKSLASH .. 'temp',
            "got " .. tostring(J.stringValue(body, "text")))
    end },

    { "backslash-n decodes to a real newline", function()
        local body = '{"text":' .. QUOTE .. 'a' .. BACKSLASH .. 'nb' .. QUOTE .. '}'
        assert(J.stringValue(body, "text") == "a\nb")
    end },

    { "several values come back in order", function()
        local body = '{"parts":[{"text":"first"},{"text":"second"}]}'
        local values = J.stringValues(body, "text")
        assert(#values == 2, "expected 2, got " .. #values)
        assert(values[1] == "first" and values[2] == "second")
    end },

    { "a missing key is nil, not an error", function()
        assert(J.stringValue('{"a":1}', "text") == nil)
    end },

    { "an unterminated literal yields nothing and does not hang", function()
        -- A body truncated mid-string, which is what a cut-off response is.
        local body = '{"text": ' .. QUOTE .. 'cut off here'
        assert(#J.stringValues(body, "text") == 0)
    end },

    { "escape and decode round-trip", function()
        local original = 'tab\there ' .. QUOTE .. 'q' .. QUOTE .. ' ' .. BACKSLASH .. ' back\nnew'
        local literal = J.escape(original)
        assert(J.decode(literal:sub(2, -2)) == original)
    end },

    { "a unicode escape decodes to UTF-8", function()
        local body = '{"text":' .. QUOTE .. 'caff' .. BACKSLASH .. 'u00e8' .. QUOTE .. '}'
        -- U+00E8 is 0xC3 0xA8 in UTF-8.
        assert(J.stringValue(body, "text") == "caff" .. string.char(195, 168),
            "got " .. tostring(J.stringValue(body, "text")))
    end },

    { "a lone surrogate half is dropped rather than emitted", function()
        local body = '{"text":' .. QUOTE .. 'a' .. BACKSLASH .. 'ud800b' .. QUOTE .. '}'
        assert(J.stringValue(body, "text") == "ab",
            "got " .. tostring(J.stringValue(body, "text")))
    end },
}
