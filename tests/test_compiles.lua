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
    "VenzAIDelta",
    "VenzAIParse",
    "VenzAIPrompts",
    "VenzAIProcess",
    "VenzAIProviderContract",
    "VenzAIProviderGemini",
    "VenzAIProviderOllama",
    "VenzAIProviderOpenAI",
    "VenzAIProviderRegistry",
    "VenzAISelfTest",
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
-- would leave it unchecked. The list of what is actually in the bundle is
-- injected by tests/run.py: the first version of this shelled out to `ls`, which
-- does not exist in cmd.exe, so it silently found zero files and the assertion
-- could never fail - a guard that guarded nothing.
table.insert(cases, { "the bundle contains exactly the files listed here", function()
    assert(VENZAI_BUNDLE_FILES and VENZAI_BUNDLE_FILES ~= "",
        "tests/run.py did not inject the bundle file list")

    local found, count = {}, 0
    for name in tostring(VENZAI_BUNDLE_FILES):gmatch("[^,]+") do
        found[name] = true
        count = count + 1
    end
    assert(count >= #FILES,
        string.format("the bundle has %d .lua files but this test lists %d", count, #FILES))

    local listed = {}
    local missing = {}
    for _, name in ipairs(FILES) do
        listed[name] = true
        if not found[name] then table.insert(missing, name) end
    end
    assert(#missing == 0, "listed here but not in the bundle: " .. table.concat(missing, ", "))

    local unlisted = {}
    for name in pairs(found) do
        if not listed[name] then table.insert(unlisted, name) end
    end
    table.sort(unlisted)
    assert(#unlisted == 0, "in the bundle but not listed in this test: " .. table.concat(unlisted, ", "))
end })

return cases
