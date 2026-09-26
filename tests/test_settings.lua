-- Pins the behaviour VenzAISettings has before the provider rework, so that
-- Task 5 changes the shape of the configuration without changing these rules.

return {
    { "applyDefaults writes every default", function()
        harness.reset()
        local S = require 'VenzAISettings'
        S.applyDefaults()
        assert(harness.prefs.engine == "gemini", "engine default missing")
        assert(harness.prefs.refinementPasses == 3, "passes default missing")
    end },

    { "an empty string falls back to the default", function()
        harness.reset()
        local S = require 'VenzAISettings'
        harness.prefs.geminiAnalysisModel = ""
        assert(S.get("geminiAnalysisModel") == "gemini-2.5-pro",
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

    { "the API key round-trips through LrPasswords, never through prefs", function()
        harness.reset()
        local S = require 'VenzAISettings'
        S.setApiKey("secret-value")
        assert(S.getApiKey() == "secret-value", "key did not round-trip")
        assert(harness.prefs.geminiApiKey == nil, "key must never land in prefs")
        assert(harness.passwords.geminiApiKey == "secret-value", "key not in LrPasswords")
    end },

    { "a legacy plain-text key is migrated out of prefs", function()
        harness.reset()
        local S = require 'VenzAISettings'
        harness.prefs.geminiApiKey = "legacy-key"
        assert(S.migrateApiKeyFromPrefs() == true, "migration did not report success")
        assert(harness.prefs.geminiApiKey == nil, "plain-text copy was left behind")
        assert(S.getApiKey() == "legacy-key", "key was lost in migration")
    end },
}
