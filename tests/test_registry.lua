-- tests/test_registry.lua
local Registry = require 'VenzAIProviderRegistry'
local Settings = require 'VenzAISettings'

return {
    { "every registered driver satisfies the contract", function()
        local problems = Registry.problems()
        assert(#problems == 0, "rejected drivers: " .. table.concat(problems, " | "))
    end },

    { "the three designed drivers are registered, in order", function()
        local ids = {}
        for _, driver in ipairs(Registry.all()) do table.insert(ids, driver.id) end
        assert(table.concat(ids, ",") == "gemini,openai,ollama", "got " .. table.concat(ids, ","))
    end },

    { "byId finds a driver and returns nil for an unknown one", function()
        assert(Registry.byId("ollama").id == "ollama")
        assert(Registry.byId("nonesuch") == nil)
    end },

    { "the active driver follows the pref", function()
        harness.reset()
        local R = require 'VenzAIProviderRegistry'
        local S = require 'VenzAISettings'
        S.setActiveProviderId("ollama")
        assert(R.active().id == "ollama", "got " .. R.active().id)
    end },

    -- Review Focus: a pref naming a driver that no longer exists.
    { "an activeProvider naming an unknown driver falls back to the first", function()
        harness.reset()
        local R = require 'VenzAIProviderRegistry'
        local S = require 'VenzAISettings'
        S.setActiveProviderId("a-driver-that-was-removed")
        local active = R.active()
        assert(active ~= nil, "active() must never return nil")
        assert(active.id == R.all()[1].id, "expected the first driver, got " .. active.id)
    end },

    { "no two drivers share an id", function()
        local seen = {}
        for _, driver in ipairs(Registry.all()) do
            assert(not seen[driver.id], "duplicate id " .. driver.id)
            seen[driver.id] = true
        end
    end },
}
