-- Pins the behaviour VenzAISettings has before the provider rework, so that
-- Task 5 changes the shape of the configuration without changing these rules.

return {
    { "showing the reference image is off unless asked for", function()
        -- A debugging aid: it stops the run with a dialog, so it must never be
        -- on by default. `false` is a value, not an absence - the same trap the
        -- toggle fields have, one level up.
        harness.reset()
        local S = require 'VenzAISettings'
        S.applyDefaults()
        assert(S.get("showReference") == false, "got " .. tostring(S.get("showReference")))
        harness.prefs.showReference = true
        assert(S.get("showReference") == true, "the setting cannot be turned on")
        harness.prefs.showReference = false
        assert(S.get("showReference") == false, "turning it back off did not stick")
    end },

    --------------------------------------------------------------------------
    -- Toggles are booleans, not strings
    --------------------------------------------------------------------------
    { "a toggle comes back as a boolean, not the string it was stored as", function()
        harness.reset()
        local S = require 'VenzAISettings'
        local field = { key = "useReference", role = "toggle", default = true }
        S.setProviderField("gemini", field, false)
        local back = S.getProviderField("gemini", field)
        assert(back == false, "got " .. type(back) .. " " .. tostring(back))
    end },

    { "a toggle never set takes its declared default", function()
        harness.reset()
        local S = require 'VenzAISettings'
        assert(S.getProviderField("gemini",
            { key = "useReference", role = "toggle", default = true }) == true)
        assert(S.getProviderField("gemini",
            { key = "useImages", role = "toggle", default = false }) == false)
    end },

    { "a toggle switched off survives the round trip", function()
        -- The bug this guards: `value or default` treats false as absent, so a
        -- switch the user turned off comes back on at the next read.
        harness.reset()
        local S = require 'VenzAISettings'
        local field = { key = "useReference", role = "toggle", default = true }
        S.setProviderField("gemini", field, false)
        assert(S.getProviderField("gemini", field) == false, "the switch turned itself back on")
        local config = S.providerConfig("gemini", { field })
        assert(config.useReference == false, "and it came back on through providerConfig")
    end },

    { "applyDefaults writes every default", function()
        -- After the provider rework DEFAULTS holds only the settings that
        -- belong to no provider; everything else is declared by a driver.
        harness.reset()
        local S = require 'VenzAISettings'
        S.applyDefaults()
        assert(harness.prefs.refinementPasses == 3, "passes default missing")
        assert(harness.prefs.activeProvider == nil,
            "which provider is default belongs to the registry's first line, "
            .. "and naming one here would put a provider's name in this file")
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
        assert(S.getActiveProviderId() == nil,
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

    { "an unset active provider is nil, not a provider's name", function()
        -- The registry decides which driver runs when nothing is chosen; this
        -- module must not name one. Pinned here because a default id put back
        -- in DEFAULTS would silently re-couple every provider to one of them.
        harness.reset()
        local S = require 'VenzAISettings'
        S.applyDefaults()
        assert(S.getActiveProviderId() == nil, "got " .. tostring(S.getActiveProviderId()))
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
