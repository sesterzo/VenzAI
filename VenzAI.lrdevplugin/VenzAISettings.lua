--[[----------------------------------------------------------------------------

VenzAISettings.lua
Single source of truth for VenzAI's configuration, shared by the settings
panel (PluginInfoProvider.lua) and the processing run (VenzAIProcess.lua).

Two things previously lived in each file separately and drifted apart:
the defaults and the "an empty string is not a value" rule. They are here now.

The Gemini API key is NOT kept in LrPrefs: LrPrefs is a plain-text file on
disk, so anyone who can read it can read the key. LrPasswords is the storage
Adobe documents for secrets and is backed by the platform keychain (Keychain
on macOS, the credential store on Windows) - the same API, the right backing
store on each platform, no conditional code.

------------------------------------------------------------------------------]]

local LrPrefs = import 'LrPrefs'
local LrPasswords = import 'LrPasswords'

local VenzAILog = require 'VenzAILog'
local log = VenzAILog.scoped("Settings")

local prefs = LrPrefs.prefsForPlugin()

-- Key under which the API key is stored in LrPasswords. The salt is left nil
-- so the plug-in ID is used, per the LrPasswords documentation.
local API_KEY_STORE_KEY = "geminiApiKey"

local M = {}

M.DEFAULTS = {
    engine = "gemini", -- "gemini" | "local"
    geminiAnalysisModel = "gemini-2.5-pro",
    geminiImageModel = "gemini-2.5-flash-image",
    ollamaBaseUrl = "http://localhost:11434",
    ollamaModel = "qwen2.5vl:latest",
    refinementPasses = 3,
}

M.MIN_PASSES = 1
M.MAX_PASSES = 5

-- In Lua "" is truthy, so `prefs.x or default` never falls back for a value
-- that was saved empty. Every read goes through here instead.
local function valueOr(value, default)
    if value == nil or value == "" then
        return default
    end
    return value
end

--------------------------------------------------------------------------------
-- API key (LrPasswords)
--------------------------------------------------------------------------------

function M.getApiKey()
    local ok, key = pcall(function()
        return LrPasswords.retrieve(API_KEY_STORE_KEY)
    end)
    if not ok then
        log("LrPasswords.retrieve failed: " .. tostring(key))
        return ""
    end
    return key or ""
end

function M.setApiKey(key)
    local ok, err = pcall(function()
        LrPasswords.store(API_KEY_STORE_KEY, key or "")
    end)
    if not ok then
        log("LrPasswords.store failed: " .. tostring(err))
        return false
    end
    return true
end

-- One-time move of a key written by an earlier version, which kept it in
-- prefs.geminiApiKey as plain text. Runs on every load but does nothing once
-- the pref is gone, so there is no "re-enter your key" step for the user.
-- The pref is cleared only after the store succeeded: a failed migration
-- leaves the old value in place rather than losing the key.
function M.migrateApiKeyFromPrefs()
    local legacy = prefs.geminiApiKey
    if legacy == nil or legacy == "" then
        if legacy == "" then prefs.geminiApiKey = nil end
        return false
    end

    if M.setApiKey(legacy) then
        prefs.geminiApiKey = nil
        log("Gemini API key migrated from LrPrefs to LrPasswords, plain-text copy removed.")
        return true
    end

    log("Could not migrate the API key to LrPasswords, leaving it in LrPrefs for now.")
    return false
end

--------------------------------------------------------------------------------
-- Everything else (LrPrefs)
--------------------------------------------------------------------------------

-- Writes any default that is missing or empty. Called both at load time and
-- every time the panel opens, so a value emptied by hand self-heals instead
-- of staying empty forever.
function M.applyDefaults()
    for key, default in pairs(M.DEFAULTS) do
        local before = prefs[key]
        if before == nil or before == "" then
            prefs[key] = default
        end
    end
end

function M.get(key)
    if key == "refinementPasses" then
        return M.getRefinementPasses()
    end
    return valueOr(prefs[key], M.DEFAULTS[key])
end

function M.set(key, value)
    prefs[key] = value
end

function M.getRefinementPasses()
    local passes = tonumber(prefs.refinementPasses) or M.DEFAULTS.refinementPasses
    if passes < M.MIN_PASSES then passes = M.MIN_PASSES end
    if passes > M.MAX_PASSES then passes = M.MAX_PASSES end
    return passes
end

-- Convenience snapshot for a processing run, so VenzAIProcess reads the
-- configuration once, in one place, instead of a dozen scattered lookups.
function M.snapshot()
    return {
        engine = M.get("engine"),
        geminiApiKey = M.getApiKey(),
        geminiAnalysisModel = M.get("geminiAnalysisModel"),
        geminiImageModel = M.get("geminiImageModel"),
        ollamaBaseUrl = M.get("ollamaBaseUrl"),
        ollamaModel = M.get("ollamaModel"),
        refinementPasses = M.getRefinementPasses(),
    }
end

return M
