-- Every file in the bundle must compile under Lua 5.1, the dialect Lightroom
-- runs. This is the check section 12 of the spec wanted from Adobe's luac -p,
-- done with the interpreter we have instead.
--
-- loadfile compiles without executing, so this needs no Lr* stub and covers the
-- files that have no behavioural test of their own - PluginInfoProvider,
-- VenzAIProcess and VenzAISelfTest - where a syntax error or a stray edit would
-- otherwise only surface when Lightroom refuses to load the plug-in.

local BUNDLE = VENZAI_BUNDLE or "VenzAI.lrdevplugin"

local FILES = {
    "Info",
    "PluginInfoProvider",
    "VenzAIJson",
    "VenzAILog",
    "VenzAIMasks",
    "VenzAIMessages",
    "VenzAIParse",
    "VenzAIPrompts",
    "VenzAIProcess",
    "VenzAIProviderContract",
    "VenzAIProviderGemini",
    "VenzAIProviderOllama",
    "VenzAIProviderOpenAI",
    "VenzAIProviderRegistry",
    "VenzAISettings",
}

local cases = {}

for _, name in ipairs(FILES) do
    table.insert(cases, { name .. ".lua compiles", function()
        local path = BUNDLE .. "/" .. name .. ".lua"
        local chunk, err = loadfile(path)
        assert(chunk, "does not compile: " .. tostring(err))
    end })
end

-- Guards against a file being added to the bundle and never listed above, which
-- would leave it unchecked.
table.insert(cases, { "every listed file exists and nothing in the bundle is unlisted", function()
    local listed = {}
    for _, name in ipairs(FILES) do listed[name] = true end

    -- io.popen is unavailable in Lightroom but fine here: this is a test, and it
    -- runs on a desktop interpreter.
    local pipe = io.popen('ls "' .. BUNDLE .. '"/*.lua 2>/dev/null')
    assert(pipe, "could not list the bundle")
    local unlisted = {}
    for line in pipe:lines() do
        local base = line:match("([^/\\]+)%.lua%s*$")
        if base and not listed[base] then table.insert(unlisted, base) end
    end
    pipe:close()
    assert(#unlisted == 0, "not listed in this test: " .. table.concat(unlisted, ", "))
end })

return cases
