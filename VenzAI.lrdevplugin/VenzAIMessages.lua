--[[----------------------------------------------------------------------------

VenzAIMessages.lua
The single catalog mapping a code to a localized title and body.

Drivers return codes; this is the only file that turns one into a sentence.
Nothing here concatenates: word order differs between languages, so
"error on " .. provider .. ": " .. reason is untranslatable by construction.
Every sentence is one LOC key with ^1..^3 placeholders.

^1 is the provider's display name, itself a LOC key so that it is localized
too. ^2 is the model name. ^3, where a message uses it, is the explanation of
which setting is wrong.

errorDetail is NOT translated and NOT part of these sentences. It is the
provider's own raw text, shown below the message in a clearly marked technical
section. The localized message must be sufficient on its own: if the user has
to read Google's JSON to know what to do, the message is wrong.

------------------------------------------------------------------------------]]

local M = {}

-- One entry per errorKind of the closed set in VenzAIProviderContract. A kind
-- with no entry here would reach the user as a blank dialog, which is what
-- tests/test_messages.lua exists to prevent.
M.ERROR_MESSAGES = {
    config_invalid = {
        title = "$$$/VenzAI/Error/Kind/ConfigInvalid/Title=VenzAI is not ready to run",
        body = "$$$/VenzAI/Error/Kind/ConfigInvalid/Body=^1 cannot be used with the current settings.\n\n^3\n\nOpen File > Plug-in Manager > VenzAI to correct it.",
    },
    unreachable = {
        title = "$$$/VenzAI/Error/Kind/Unreachable/Title=VenzAI could not reach ^1",
        body = "$$$/VenzAI/Error/Kind/Unreachable/Body=No answer came back from ^1.\n\nCheck your network connection, and that the address in the plug-in settings is correct and the service is running.",
    },
    auth = {
        title = "$$$/VenzAI/Error/Kind/Auth/Title=^1 rejected the credentials",
        body = "$$$/VenzAI/Error/Kind/Auth/Body=^1 did not accept the API key.\n\nCheck the key in File > Plug-in Manager > VenzAI. A key that was working may have been revoked, or may not be enabled for the model '^2'.",
    },
    rate_limited = {
        title = "$$$/VenzAI/Error/Kind/RateLimited/Title=^1 is rate limiting VenzAI",
        body = "$$$/VenzAI/Error/Kind/RateLimited/Body=^1 refused the request because the quota is exhausted or too many requests arrived too quickly.\n\nWait and run VenzAI again. Nothing was applied to the photo by this pass.",
    },
    model_missing = {
        title = "$$$/VenzAI/Error/Kind/ModelMissing/Title=The model '^2' does not exist on ^1",
        body = "$$$/VenzAI/Error/Kind/ModelMissing/Body=^1 does not know a model called '^2'.\n\nCorrect the model name in File > Plug-in Manager > VenzAI. The 'Detect models' button next to the field lists the names that service currently offers.",
    },
    bad_request = {
        title = "$$$/VenzAI/Error/Kind/BadRequest/Title=^1 rejected the request as malformed",
        body = "$$$/VenzAI/Error/Kind/BadRequest/Body=^1 answered that the request VenzAI built is not valid.\n\nThis is a fault in the plug-in rather than in your settings. The technical detail below is what the service reported.",
    },
    server_error = {
        title = "$$$/VenzAI/Error/Kind/ServerError/Title=^1 reported an internal error",
        body = "$$$/VenzAI/Error/Kind/ServerError/Body=^1 failed on its own side.\n\nThis is usually temporary; running VenzAI again later is the remedy.",
    },
    empty = {
        title = "$$$/VenzAI/Error/Kind/Empty/Title=^1 answered without any content",
        body = "$$$/VenzAI/Error/Kind/Empty/Body=^1 accepted the request but returned no usable answer.\n\nThis happens when a safety filter blocks the response, or when the model '^2' cannot see images. Try another model.",
    },
    driver_fault = {
        title = "$$$/VenzAI/Error/Kind/DriverFault/Title=VenzAI failed while talking to ^1",
        body = "$$$/VenzAI/Error/Kind/DriverFault/Body=The part of VenzAI that speaks to ^1 failed.\n\nThis is a fault in the plug-in rather than in your settings, and the photo keeps whatever earlier passes applied. The technical detail below identifies where.",
    },
    not_supported = {
        title = "$$$/VenzAI/Error/Kind/NotSupported/Title=^1 does not support that step",
        body = "$$$/VenzAI/Error/Kind/NotSupported/Body=^1 does not offer the capability VenzAI asked for.\n\nThis is a fault in the plug-in: a step was requested that this provider never declared.",
    },
    unknown = {
        title = "$$$/VenzAI/Error/Kind/Unknown/Title=^1 failed for an unrecognized reason",
        body = "$$$/VenzAI/Error/Kind/Unknown/Body=^1 failed in a way VenzAI does not recognize.\n\nThe technical detail below is the raw report from the service.",
    },
}

-- Explanations for the reasonKey a driver's validate() returns. These are the
-- ^3 of config_invalid: the user is told WHICH field is wrong, not merely that
-- the configuration is invalid.
local CONFIG_REASONS = {
    missing_config = "$$$/VenzAI/Error/Reason/MissingConfig=No settings were found for this provider.",
    missing_api_key = "$$$/VenzAI/Error/Reason/MissingApiKey=The API key is empty.",
    missing_model = "$$$/VenzAI/Error/Reason/MissingModel=No analysis model is set.",
    missing_image_model = "$$$/VenzAI/Error/Reason/MissingImageModel=No reference image model is set.",
    missing_base_url = "$$$/VenzAI/Error/Reason/MissingBaseUrl=The server address is empty.",
    invalid_base_url = "$$$/VenzAI/Error/Reason/InvalidBaseUrl=The server address must start with http:// or https://.",
    config_unspecified = "$$$/VenzAI/Error/Reason/Unspecified=A required setting is missing or malformed.",
}

-- Returns title, body. `providerNameKey` is the driver's displayName, still a
-- LOC key; `reasonKey` is used only by the messages that carry a ^3.
function M.forError(errorKind, providerNameKey, modelName, reasonKey)
    local entry = M.ERROR_MESSAGES[errorKind] or M.ERROR_MESSAGES.unknown
    local providerName = LOC(providerNameKey or "$$$/VenzAI/Provider/Unknown/Name=the AI service")
    local model = modelName or ""
    -- An unrecognized reasonKey degrades to the generic sentence rather than
    -- leaving a hole in the middle of the message.
    local reason = LOC(CONFIG_REASONS[reasonKey] or CONFIG_REASONS.config_unspecified)

    return LOC(entry.title, providerName, model, reason),
           LOC(entry.body, providerName, model, reason)
end

-- A malformed driver is a programming error, not a user's mistake, so it gets
-- one message and the developer diagnostic goes in the technical section.
function M.forDriverProblem(problem)
    return LOC "$$$/VenzAI/Error/DriverProblem/Title=A VenzAI provider is misconfigured",
           LOC("$$$/VenzAI/Error/DriverProblem/Body=One of VenzAI's providers does not match the interface the plug-in expects, so it was not loaded.\n\n^1",
               tostring(problem))
end

-- The provider's own raw text, under a localized heading, kept separate from
-- the translated message above it. Empty when there is nothing to show, so a
-- caller can always append it unconditionally.
function M.technicalSection(errorDetail)
    if errorDetail == nil or errorDetail == "" then return "" end
    return LOC("$$$/VenzAI/Error/TechnicalSection=\n\nTechnical detail reported by the service:\n^1",
        tostring(errorDetail))
end

return M
