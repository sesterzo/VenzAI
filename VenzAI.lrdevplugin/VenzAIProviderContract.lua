--[[----------------------------------------------------------------------------

VenzAIProviderContract.lua
The shapes every provider driver conforms to, and the funnel every call goes
through.

A driver owns the protocol: serialization, auth, HTTP, extracting text and
images, and classifying failures. It owns nothing else. Parsing, validation
and applying settings to the photo stay shared and downstream of every driver,
because they are the plug-in's only defence against a model answering
Temperature = 8, and two copies of them would eventually diverge.

The engine NEVER calls a driver method directly. It calls M.call, which
guarantees a well-formed Response whatever the driver does - including
raising. A buggy driver can fail; it cannot abort a run halfway and leave the
photo in an intermediate state.

Invariant: a driver returns CODES, never prose. Nothing in this file builds a
sentence for a human; VenzAIMessages turns a code into a localized message.
The one exception is validateDriver's `problem` string, which is a developer
diagnostic for a malformed driver - a programming error, reported to the log,
never shown as a user-facing message.

------------------------------------------------------------------------------]]

local VenzAILog = require 'VenzAILog'
local log = VenzAILog.scoped("Contract")

local M = {}

--------------------------------------------------------------------------------
-- The closed sets
--------------------------------------------------------------------------------

-- Closed on purpose, twice over: it is the set of conditions the engine knows
-- how to react to, and it is the list of messages to translate.
M.ERROR_KINDS = {
    config_invalid = true,  -- a required field is missing or malformed
    unreachable    = true,  -- DNS, connection refused, TLS, timeout
    auth           = true,  -- missing or rejected credentials
    rate_limited   = true,  -- quota exhausted or too many requests
    model_missing  = true,  -- the configured model does not exist there
    bad_request    = true,  -- malformed payload: our bug, not the user's
    server_error   = true,  -- provider 5xx
    empty          = true,  -- HTTP 200 with no usable text
    driver_fault   = true,  -- the driver raised, or returned a bad Response
    not_supported  = true,  -- a capability the driver does not declare
    unknown        = true,  -- anything else
}

M.CAPABILITIES = {
    analyze = true,
    generateReference = true,
    listModels = true,
}

-- 'secret' persists through LrPasswords and renders a password_field; every
-- other role persists through LrPrefs and renders an edit_field. 'model' also
-- gets the "Detect models" button when the driver declares listModels.
M.FIELD_ROLES = {
    secret = true,
    model  = true,
    url    = true,
    text   = true,
}

--------------------------------------------------------------------------------
-- Response constructors
--------------------------------------------------------------------------------

-- A Response always has the same shape, whatever happened.
function M.failure(errorKind, errorDetail, reasonKey, httpStatus)
    if not M.ERROR_KINDS[errorKind] then
        -- A driver naming a kind outside the closed set is itself a fault, but
        -- it must not become a Lua error at this depth: coerce it, and keep
        -- the original name where a human reading the log will find it.
        errorDetail = string.format("[errorKind '%s' is not in the closed set] %s",
            tostring(errorKind), tostring(errorDetail))
        errorKind = "unknown"
    end
    return {
        ok = false,
        text = nil,
        image = nil,
        truncated = false,
        httpStatus = httpStatus,
        errorKind = errorKind,
        errorDetail = errorDetail,
        reasonKey = reasonKey,
    }
end

function M.success(fields)
    return {
        ok = true,
        text = fields.text,
        image = fields.image,
        truncated = fields.truncated and true or false,
        httpStatus = fields.httpStatus,
        errorKind = nil,
        errorDetail = nil,
        reasonKey = nil,
    }
end

--------------------------------------------------------------------------------
-- Shape validation
--------------------------------------------------------------------------------

local function isNonEmptyString(value)
    return type(value) == "string" and value ~= ""
end

-- Checks what the engine is about to rely on. Returns ok, problem.
function M.validateResponse(response, method)
    if type(response) ~= "table" then
        return false, string.format("expected a table, got %s", type(response))
    end
    if type(response.ok) ~= "boolean" then
        return false, "field 'ok' must be a boolean"
    end

    if not response.ok then
        if not M.ERROR_KINDS[response.errorKind] then
            return false, string.format("errorKind '%s' is not in the closed set",
                tostring(response.errorKind))
        end
        return true
    end

    if method == "analyze" then
        if not isNonEmptyString(response.text) then
            return false, "a successful analyze must carry a non-empty text"
        end
    elseif method == "generateReference" then
        local image = response.image
        if type(image) ~= "table"
            or not isNonEmptyString(image.data)
            or not isNonEmptyString(image.mimeType) then
            return false, "a successful generateReference must carry image.data and image.mimeType"
        end
    end

    return true
end

-- Runs for every registered driver when the registry loads, so a malformed
-- driver is reported once and precisely instead of failing obscurely halfway
-- through a photograph. Returns ok, problem.
function M.validateDriver(driver)
    if type(driver) ~= "table" then
        return false, string.format("a driver must be a table, got %s", type(driver))
    end
    if not isNonEmptyString(driver.id) then
        return false, "missing 'id'"
    end
    if not isNonEmptyString(driver.displayName) then
        return false, string.format("driver '%s' is missing 'displayName'", driver.id)
    end
    if type(driver.validate) ~= "function" then
        return false, string.format("driver '%s' is missing the function 'validate'", driver.id)
    end
    if type(driver.defaultTimeout) ~= "number" or driver.defaultTimeout <= 0 then
        return false, string.format("driver '%s' needs a positive 'defaultTimeout'", driver.id)
    end

    if type(driver.capabilities) ~= "table" then
        return false, string.format("driver '%s' is missing 'capabilities'", driver.id)
    end
    for name, enabled in pairs(driver.capabilities) do
        if not M.CAPABILITIES[name] then
            return false, string.format("driver '%s' declares the unknown capability '%s'",
                driver.id, tostring(name))
        end
        if enabled and type(driver[name]) ~= "function" then
            return false, string.format("driver '%s' declares '%s' but has no such function",
                driver.id, name)
        end
    end
    if not driver.capabilities.analyze then
        return false, string.format("driver '%s' must declare the capability 'analyze'", driver.id)
    end

    if type(driver.settingsFields) ~= "table" then
        return false, string.format("driver '%s' is missing 'settingsFields'", driver.id)
    end
    for index, field in ipairs(driver.settingsFields) do
        if type(field) ~= "table" then
            return false, string.format("driver '%s': settingsFields[%d] is not a table",
                driver.id, index)
        end
        if not isNonEmptyString(field.key) then
            return false, string.format("driver '%s': settingsFields[%d] has no 'key'",
                driver.id, index)
        end
        if not M.FIELD_ROLES[field.role] then
            return false, string.format("driver '%s': field '%s' has the unknown role '%s'",
                driver.id, field.key, tostring(field.role))
        end
        if not isNonEmptyString(field.label) then
            return false, string.format("driver '%s': field '%s' has no 'label'",
                driver.id, field.key)
        end
        if field.default ~= nil and type(field.default) ~= "string" then
            return false, string.format("driver '%s': field '%s' has a non-string default",
                driver.id, field.key)
        end
        if field.role == "secret" and field.default ~= nil then
            return false, string.format("driver '%s': secret field '%s' must not have a default",
                driver.id, field.key)
        end
    end

    return true
end

--------------------------------------------------------------------------------
-- The call funnel
--------------------------------------------------------------------------------

-- The only way the engine reaches a driver. In order: the capability must be
-- declared, the config must validate, the method runs under pcall, and the
-- value it returns must match the Response shape. Anything else becomes a
-- Response the engine can handle, and the log names the driver and the method
-- rather than showing an anonymous stack trace.
function M.call(driver, method, request, config)
    local driverId = (type(driver) == "table" and tostring(driver.id)) or "<not a driver>"

    if type(driver) ~= "table"
        or type(driver.capabilities) ~= "table"
        or not driver.capabilities[method] then
        log(string.format("%s does not declare the capability '%s'.", driverId, tostring(method)))
        return M.failure("not_supported",
            string.format("driver '%s' does not declare '%s'", driverId, tostring(method)))
    end

    if type(driver.validate) ~= "function" then
        log(string.format("%s has no validate function.", driverId))
        return M.failure("driver_fault", string.format("driver '%s' has no validate function", driverId))
    end

    local validateOk, valid, reasonKey = pcall(driver.validate, config)
    if not validateOk then
        log(string.format("%s.validate raised: %s", driverId, tostring(valid)))
        return M.failure("driver_fault", tostring(valid))
    end
    if not valid then
        log(string.format("%s: configuration rejected (%s).", driverId, tostring(reasonKey)))
        return M.failure("config_invalid", nil, reasonKey or "config_unspecified")
    end

    local callOk, result = pcall(driver[method], request, config)
    if not callOk then
        log(string.format("%s.%s raised: %s", driverId, method, tostring(result)))
        return M.failure("driver_fault", tostring(result))
    end

    local shapeOk, problem = M.validateResponse(result, method)
    if not shapeOk then
        log(string.format("%s.%s returned a malformed Response: %s", driverId, method, problem))
        return M.failure("driver_fault", problem)
    end

    return result
end

-- The same funnel for listModels, which does not return a Response: it answers
-- a list of names, so it needs its own wrapper rather than being forced into a
-- shape it does not have.
--
-- It exists because the settings panel's Detect button used to call
-- driver.listModels directly, and so was the one place that skipped both
-- guarantees: an empty API key produced a round trip that came back `auth`
-- ("the key may have been revoked") instead of `config_invalid` ("the API key is
-- empty"), and a driver that raised on a nil field reached Lightroom as a raw
-- Lua error dialog.
--
-- Returns names, errorKind, errorDetail, reasonKey. An EMPTY list is success:
-- reachable with nothing installed is not a failure, and the caller says so
-- differently.
function M.listModels(driver, config)
    local driverId = (type(driver) == "table" and tostring(driver.id)) or "<not a driver>"

    if type(driver) ~= "table"
        or type(driver.capabilities) ~= "table"
        or not driver.capabilities.listModels then
        return nil, "not_supported",
            string.format("driver '%s' does not declare 'listModels'", driverId)
    end

    if type(driver.validate) ~= "function" then
        return nil, "driver_fault", string.format("driver '%s' has no validate function", driverId)
    end

    local validateOk, valid, reasonKey = pcall(driver.validate, config)
    if not validateOk then
        log(string.format("%s.validate raised during listModels: %s", driverId, tostring(valid)))
        return nil, "driver_fault", tostring(valid)
    end
    if not valid then
        log(string.format("%s: configuration rejected before listing models (%s).",
            driverId, tostring(reasonKey)))
        return nil, "config_invalid", nil, reasonKey or "config_unspecified"
    end

    local callOk, names, errorKind, errorDetail = pcall(driver.listModels, config)
    if not callOk then
        log(string.format("%s.listModels raised: %s", driverId, tostring(names)))
        return nil, "driver_fault", tostring(names)
    end

    if names == nil then
        return nil, errorKind or "unknown", errorDetail
    end
    if type(names) ~= "table" then
        log(string.format("%s.listModels returned a %s, expected a table.", driverId, type(names)))
        return nil, "driver_fault",
            string.format("listModels returned a %s, expected a table", type(names))
    end

    return names
end

return M
