--[[----------------------------------------------------------------------------

VenzAISettings.lua
Single source of truth for VenzAI's configuration, shared by the settings
panel (PluginInfoProvider.lua) and the processing run (VenzAIProcess.lua).

Two things previously lived in each file separately and drifted apart:
the defaults and the "an empty string is not a value" rule. They are here now.

Settings that belong to no provider - which provider is active, and how many
refinement passes to run - live in M.DEFAULTS. Everything else is declared by
a driver in its settingsFields and read through M.providerConfig, so adding a
provider, or a field to one, is a change in that driver and nowhere else.

A field whose role is "secret" is NOT kept in LrPrefs: LrPrefs is a plain-text
file on disk, so anyone who can read it can read the secret. LrPasswords is the
storage Adobe documents for secrets and is backed by the platform keychain
(Keychain on macOS, the credential store on Windows) - the same API, the right
backing store on each platform, no conditional code.

------------------------------------------------------------------------------]]

local LrPrefs = import 'LrPrefs'
local LrPasswords = import 'LrPasswords'

local VenzAILog = require 'VenzAILog'
local log = VenzAILog.scoped("Settings")

local prefs = LrPrefs.prefsForPlugin()

local M = {}

M.DEFAULTS = {
    activeProvider = "gemini",
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
-- Settings that belong to no provider
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

function M.getActiveProviderId()
    return valueOr(prefs.activeProvider, M.DEFAULTS.activeProvider)
end

function M.setActiveProviderId(id)
    prefs.activeProvider = id
end

--------------------------------------------------------------------------------
-- Per-provider settings
--------------------------------------------------------------------------------

-- Namespaced by driver id, so two providers can both declare a field called
-- "model" without colliding, and removing a driver leaves an inert island of
-- preferences rather than a conflict.
local function prefKey(driverId, fieldKey)
    return string.format("provider.%s.%s", tostring(driverId), tostring(fieldKey))
end

-- Reads one declared field. A secret comes from LrPasswords, everything else
-- from LrPrefs. A secret never falls back to a default - the driver contract
-- forbids one, since a default secret would mean shipping a credential in the
-- source - and comes back as "" when unset, so every driver's validate() has a
-- single shape of absence to check.
function M.getProviderField(driverId, field)
    if field.role == "secret" then
        local ok, value = pcall(function()
            return LrPasswords.retrieve(prefKey(driverId, field.key))
        end)
        if not ok then
            log("LrPasswords.retrieve failed for " .. prefKey(driverId, field.key) ..
                ": " .. tostring(value))
            return ""
        end
        return value or ""
    end
    return valueOr(prefs[prefKey(driverId, field.key)], field.default or "")
end

function M.setProviderField(driverId, field, value)
    if field.role == "secret" then
        local ok, err = pcall(function()
            LrPasswords.store(prefKey(driverId, field.key), value or "")
        end)
        if not ok then
            log("LrPasswords.store failed for " .. prefKey(driverId, field.key) ..
                ": " .. tostring(err))
            return false
        end
        return true
    end
    prefs[prefKey(driverId, field.key)] = value
    return true
end

-- The `config` of the driver contract: one flat table keyed by each declared
-- field's own key. Built from the declaration, so adding a field to a driver is
-- a change in that driver and nowhere else.
function M.providerConfig(driverId, settingsFields)
    local config = {}
    for _, field in ipairs(settingsFields or {}) do
        config[field.key] = M.getProviderField(driverId, field)
    end
    return config
end

--------------------------------------------------------------------------------
-- Leftovers from before the driver layer
--------------------------------------------------------------------------------

-- Deletes the plain-text API key an earlier version kept in prefs.geminiApiKey.
-- This is NOT a migration - the value is never read anywhere, and the key is
-- re-entered once, as the design states. It is deleted rather than ignored
-- because a credential sitting in a plain-text preferences file is the exact
-- problem LrPasswords was adopted to solve, and ignoring it would leave it
-- there forever.
function M.purgeLegacyPlainTextKey()
    if prefs.geminiApiKey == nil then return false end
    prefs.geminiApiKey = nil
    log("Removed the plain-text Gemini API key left in LrPrefs by an earlier version. " ..
        "Re-enter the key in the plug-in settings.")
    return true
end

return M
