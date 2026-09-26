-- Pins the behaviour VenzAISettings has before the provider rework, so that
-- Task 5 changes the shape of the configuration without changing these rules.

return {
    { "applyDefaults writes every default", function()
        -- After the provider rework DEFAULTS holds only the settings that
        -- belong to no provider; everything else is declared by a driver.
        harness.reset()
        local S = require 'VenzAISettings'
        S.applyDefaults()
        assert(harness.prefs.activeProvider == "gemini", "activeProvider default missing")
        assert(harness.prefs.refinementPasses == 3, "passes default missing")
        assert(harness.prefs.engine == nil,
            "engine is a driver's concern now and must not be written here")
    end },

    { "an empty string falls back to the default", function()
        -- In Lua "" is truthy, so `prefs.x or default` never falls back for a
        -- value saved empty. The rule is pinned here on a setting that survives
        -- the rework; the same rule for a driver's declared fields is pinned by
        -- "an empty stored value falls back to the declared default" below.
        harness.reset()
        local S = require 'VenzAISettings'
        harness.prefs.activeProvider = ""
        assert(S.getActiveProviderId() == "gemini",
            "empty string must not be treated as a value")
    end },

    { "refinement passes are clamped at both ends", function()
        harness.reset()
        local S = require 'VenzAISettings'
        harness.prefs.refinementPasses = 99
        assert(S.getRefinementPasses() == S.MAX_PASSES, "not clamped upwards")
        harness.prefs.refinementPasses = 0
        assert(S.getRefinementPasses() == S.MIN_PASSES, "not clamped downwards")
    end },

    { "the active provider defaults to gemini", function()
        harness.reset()
        local S = require 'VenzAISettings'
        S.applyDefaults()
        assert(S.getActiveProviderId() == "gemini", "got " .. tostring(S.getActiveProviderId()))
    end },

    { "a legacy plain-text API key is deleted, not migrated", function()
        harness.reset()
        local S = require 'VenzAISettings'
        harness.prefs.geminiApiKey = "legacy-key"
        assert(S.purgeLegacyPlainTextKey() == true, "did not report a purge")
        assert(harness.prefs.geminiApiKey == nil, "the plain-text key is still on disk")
        -- Deliberately NOT carried over: the spec rules out migration, and the
        -- key is re-entered once. What must not happen is it lingering in a
        -- plain-text file.
        assert(harness.passwords["provider.gemini.apiKey"] == nil,
            "the legacy key must not be migrated into LrPasswords")
    end },

    { "a provider config is built from the driver's declared fields", function()
        harness.reset()
        local S = require 'VenzAISettings'
        local fields = {
            { key = "apiKey", role = "secret", label = "$$$/x=Key" },
            { key = "model", role = "model", default = "m-1", label = "$$$/x=Model" },
            { key = "baseUrl", role = "url", default = "http://localhost", label = "$$$/x=URL" },
        }
        harness.passwords["provider.fake.apiKey"] = "stored-secret"
        harness.prefs["provider.fake.model"] = "m-2"
        local config = S.providerConfig("fake", fields)
        assert(config.apiKey == "stored-secret", "secret not read from LrPasswords")
        assert(config.model == "m-2", "pref value not read")
        assert(config.baseUrl == "http://localhost", "declared default not applied")
    end },

    { "an empty stored value falls back to the declared default", function()
        harness.reset()
        local S = require 'VenzAISettings'
        harness.prefs["provider.fake.model"] = ""
        local config = S.providerConfig("fake", {
            { key = "model", role = "model", default = "m-1", label = "$$$/x=Model" },
        })
        assert(config.model == "m-1", "empty string was treated as a value")
    end },

    { "a secret with nothing stored comes back as an empty string, not nil", function()
        -- validate() compares against "", and a nil here would make every
        -- driver's check have to handle two shapes of absence.
        harness.reset()
        local S = require 'VenzAISettings'
        local config = S.providerConfig("fake", {
            { key = "apiKey", role = "secret", label = "$$$/x=Key" },
        })
        assert(config.apiKey == "", "got " .. tostring(config.apiKey))
    end },

    { "a secret is written to LrPasswords and a normal field to prefs", function()
        harness.reset()
        local S = require 'VenzAISettings'
        S.setProviderField("fake", { key = "apiKey", role = "secret", label = "$$$/x=K" }, "s3cret")
        S.setProviderField("fake", { key = "model", role = "model", label = "$$$/x=M" }, "m-9")
        assert(harness.passwords["provider.fake.apiKey"] == "s3cret", "secret not in LrPasswords")
        assert(harness.prefs["provider.fake.apiKey"] == nil, "a secret must never reach prefs")
        assert(harness.prefs["provider.fake.model"] == "m-9", "field not in prefs")
    end },

    { "two providers with the same field name do not collide", function()
        harness.reset()
        local S = require 'VenzAISettings'
        local field = { key = "model", role = "model", label = "$$$/x=M" }
        S.setProviderField("alpha", field, "a-model")
        S.setProviderField("beta", field, "b-model")
        assert(S.providerConfig("alpha", { field }).model == "a-model")
        assert(S.providerConfig("beta", { field }).model == "b-model")
    end },
}
