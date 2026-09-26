local Contract = require 'VenzAIProviderContract'
local Messages = require 'VenzAIMessages'

return {
    { "every errorKind in the closed set has a message", function()
        -- The set is closed partly so that this list is finite and translatable.
        -- A new kind with no message would otherwise reach a user as a blank dialog.
        local missing = {}
        for kind in pairs(Contract.ERROR_KINDS) do
            local entry = Messages.ERROR_MESSAGES[kind]
            if not entry or not entry.title or not entry.body then
                table.insert(missing, kind)
            end
        end
        assert(#missing == 0, "no message for: " .. table.concat(missing, ", "))
    end },

    { "no message is defined for a kind outside the set", function()
        local extra = {}
        for kind in pairs(Messages.ERROR_MESSAGES) do
            if not Contract.ERROR_KINDS[kind] then table.insert(extra, kind) end
        end
        assert(#extra == 0, "message for unknown kind: " .. table.concat(extra, ", "))
    end },

    { "the provider name is substituted, not concatenated", function()
        local title, body = Messages.forError("rate_limited",
            "$$$/VenzAI/Provider/Gemini/Name=Gemini", "gemini-2.5-pro")
        assert(title ~= nil and title ~= "", "no title")
        assert(body:find("Gemini", 1, true), "the provider name is missing from the body")
        assert(not body:find("^1", 1, true), "an unsubstituted placeholder survived")
        assert(not body:find("$$$", 1, true), "a raw LOC key leaked into the body")
    end },

    { "the model name is substituted where a message uses it", function()
        local _, body = Messages.forError("model_missing",
            "$$$/VenzAI/Provider/Ollama/Name=Ollama", "qwen2.5vl:latest")
        assert(body:find("qwen2.5vl:latest", 1, true), "the model name is missing")
    end },

    { "config_invalid explains which field is wrong", function()
        local _, withReason = Messages.forError("config_invalid",
            "$$$/VenzAI/Provider/Gemini/Name=Gemini", "gemini-2.5-pro", "missing_api_key")
        local _, withoutReason = Messages.forError("config_invalid",
            "$$$/VenzAI/Provider/Gemini/Name=Gemini", "gemini-2.5-pro")
        assert(withReason ~= withoutReason,
            "the reasonKey must change the message, otherwise carrying it forward is pointless")
        assert(not withReason:find("$$$", 1, true), "a raw LOC key leaked")
    end },

    { "an unknown reasonKey degrades to a generic sentence rather than a blank", function()
        local _, body = Messages.forError("config_invalid",
            "$$$/VenzAI/Provider/Gemini/Name=Gemini", "m", "some_key_nobody_defined")
        assert(body ~= nil and body ~= "", "empty body")
        assert(not body:find("$$$", 1, true), "a raw LOC key leaked")
    end },

    { "the technical section is omitted when there is no detail", function()
        assert(Messages.technicalSection(nil) == "", "expected an empty string")
        local section = Messages.technicalSection("HTTP 429 quota exceeded for project 42")
        assert(section:find("HTTP 429", 1, true), "the raw detail must survive verbatim")
    end },
}
