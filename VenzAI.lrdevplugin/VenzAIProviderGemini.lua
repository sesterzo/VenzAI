--[[----------------------------------------------------------------------------

VenzAIProviderGemini.lua
The Gemini protocol: serialization, auth, HTTP, extraction, classification.

Nothing in this file knows about develop parameters, passes or photographs.
Nothing outside it knows that Gemini puts the model in the URL path, answers
with camelCase keys even when asked in snake_case, or calls truncation
MAX_TOKENS.

------------------------------------------------------------------------------]]

local LrHttp = import 'LrHttp'

local Json = require 'VenzAIJson'
local Contract = require 'VenzAIProviderContract'
local VenzAILog = require 'VenzAILog'
local log = VenzAILog.scoped("Gemini")

local BASE = "https://generativelanguage.googleapis.com/v1beta/models"
local LIST_TIMEOUT = 10

local M = {
    id = "gemini",
    displayName = "$$$/VenzAI/Provider/Gemini/Name=Gemini (Google, cloud)",
    -- A reasoning model spends a while before emitting a token, so this is
    -- minutes rather than seconds. Without a timeout a stalled connection
    -- leaves the progress bar spinning with no way out but restarting.
    defaultTimeout = 300,
    capabilities = { analyze = true, generateReference = true, listModels = true },
    settingsFields = {
        { key = "apiKey", role = "secret", required = true,
          label = "$$$/VenzAI/Provider/Gemini/ApiKey=API key" },
        { key = "model", role = "model", default = "gemini-2.5-pro",
          label = "$$$/VenzAI/Provider/Gemini/Model=Analysis model" },
        { key = "imageModel", role = "model", default = "gemini-2.5-flash-image",
          label = "$$$/VenzAI/Provider/Gemini/ImageModel=Reference image model" },
    },
}

function M.validate(config)
    if type(config) ~= "table" then return false, "missing_config" end
    if config.apiKey == nil or config.apiKey == "" then return false, "missing_api_key" end
    if config.model == nil or config.model == "" then return false, "missing_model" end
    return true
end

-- A connection that never got off the ground comes back with no body and no
-- status, which reads in the log exactly like a server that answered with
-- nothing. The SDK documents only the success shape of the headers table, but
-- in practice it carries an `error` entry here; reading it is guarded so that
-- if it ever stops being provided we fall back to the generic message.
local function transportError(headers)
    if headers and headers.error then
        local e = headers.error
        return tostring(e.name or e.errorCode or "connection failed")
    end
    return nil
end

local function classifyStatus(status)
    if status == 400 then return "bad_request" end
    if status == 401 or status == 403 then return "auth" end
    if status == 404 then return "model_missing" end
    if status == 429 then return "rate_limited" end
    if type(status) == "number" and status >= 500 then return "server_error" end
    return "unknown"
end

local function partsJson(parts)
    local out = {}
    for _, part in ipairs(parts or {}) do
        if part.text then
            table.insert(out, string.format('{ "text": %s }', Json.escape(part.text)))
        elseif part.image then
            table.insert(out, string.format(
                '{ "inline_data": { "mime_type": %s, "data": %s } }',
                Json.escape(part.image.mimeType), Json.escape(part.image.data)))
        end
    end
    return table.concat(out, ",")
end

-- The key travels in the x-goog-api-key header rather than the query string: a
-- URL is the part most likely to end up in a log line, a proxy access log or a
-- bug report.
local function post(url, payload, apiKey, timeout)
    local body, headers = LrHttp.post(url, payload, {
        { field = "Content-Type", value = "application/json" },
        { field = "x-goog-api-key", value = apiKey },
    }, "POST", timeout)
    return body, headers and headers.status, transportError(headers)
end

local function generateContent(model, payload, config, timeout)
    local url = string.format("%s/%s:generateContent", BASE, model)
    log("POST " .. url)
    local body, status, transport = post(url, payload, config.apiKey, timeout)

    if not body then
        return nil, Contract.failure("unreachable", transport or "no response received", nil, status)
    end
    if status ~= 200 then
        return nil, Contract.failure(classifyStatus(status), body:sub(1, 600), nil, status)
    end
    return body, nil, status
end

function M.analyze(request, config)
    local generationConfig = request.wantsJson
        and '{ "response_mime_type": "application/json", "temperature": 0.9 }'
        or '{ "temperature": 0.9 }'
    local payload = string.format('{ "contents": [{ "parts": [%s] }], "generationConfig": %s }',
        partsJson(request.parts), generationConfig)

    local body, failure, status = generateContent(config.model, payload, config,
        request.timeout or M.defaultTimeout)
    if failure then return failure end

    -- Several text parts are possible; the model's answer is their
    -- concatenation, already decoded by Json.
    local texts = Json.stringValues(body, "text")
    -- The key can be present and empty - a safety block arrives that way - so
    -- the concatenation is what decides, not the number of parts. Returning a
    -- Response with an empty text would fail the contract's shape check and
    -- reach the user as driver_fault ("a fault in the plug-in rather than in your
    -- settings") when the truth is "a filter blocked it, try another model".
    local answer = table.concat(texts)
    if answer == "" then
        return Contract.failure("empty", body:sub(1, 600), nil, status)
    end

    return Contract.success({
        text = answer,
        truncated = (Json.stringValue(body, "finishReason") == "MAX_TOKENS"),
        httpStatus = status,
    })
end

function M.generateReference(request, config)
    if config.imageModel == nil or config.imageModel == "" then
        return Contract.failure("config_invalid", nil, "missing_image_model")
    end

    local payload = string.format(
        '{ "contents": [{ "parts": [%s] }], "generationConfig": { "responseModalities": ["TEXT", "IMAGE"] } }',
        partsJson(request.parts))

    local body, failure, status = generateContent(config.imageModel, payload, config,
        request.timeout or M.defaultTimeout)
    if failure then return failure end

    -- The container is called inlineData in the answer even though the request
    -- said inline_data, so the data field is matched on its base64 alphabet
    -- rather than on the container's name.
    local data = body:match('"data"%s*:%s*"([A-Za-z0-9+/=]+)"')
    if not data then
        return Contract.failure("empty", body:sub(1, 600), nil, status)
    end

    return Contract.success({
        image = {
            data = data,
            mimeType = body:match('"mime[Tt]ype"%s*:%s*"([^"]+)"') or "image/png",
        },
        httpStatus = status,
    })
end

function M.listModels(config)
    local body, headers = LrHttp.get(BASE,
        { { field = "x-goog-api-key", value = config.apiKey } }, LIST_TIMEOUT)
    local status = headers and headers.status

    if not body then
        return nil, "unreachable", transportError(headers) or "no response received"
    end
    if status ~= 200 then
        return nil, classifyStatus(status), body:sub(1, 600)
    end

    local names = {}
    for _, name in ipairs(Json.stringValues(body, "name")) do
        table.insert(names, (name:gsub("^models/", "")))
    end
    return names
end

return M
