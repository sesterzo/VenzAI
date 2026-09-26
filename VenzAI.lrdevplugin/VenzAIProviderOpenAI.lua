--[[----------------------------------------------------------------------------

VenzAIProviderOpenAI.lua
The OpenAI protocol: serialization, auth, HTTP, extraction, classification.

Written SECOND on purpose. The driver contract was defined from two examples,
Gemini and Ollama, and risked being Gemini-shaped; OpenAI is where that leaks,
so it comes before Ollama rather than last.

It differs from Gemini in every place the contract abstracts: the model is a
field in the body rather than a path segment, auth is a Bearer header, an image
is a data URL inside a content array, JSON mode is response_format, truncation
is finish_reason == "length", and the answer lives at
choices[].message.content.

transportError and classifyStatus are this file's own copies rather than shared
with the other drivers. They are each a driver's reading of ITS service's
failures, and the two mappings will diverge the first time one provider uses a
status the other does not. Two eight-line functions allowed to differ beat one
shared function with a provider flag.

------------------------------------------------------------------------------]]

local LrHttp = import 'LrHttp'

local Json = require 'VenzAIJson'
local Contract = require 'VenzAIProviderContract'
local VenzAILog = require 'VenzAILog'
local log = VenzAILog.scoped("OpenAI")

local LIST_TIMEOUT = 10

-- The analysis returns numbers, not prose: the same photograph should produce
-- the same develop settings twice running, and three refinement passes should
-- converge rather than argue. At 0.9 they disagreed with each other through
-- sampling alone, which reads as the model changing its mind. Low, not zero:
-- the task still carries judgement, and a flat 0 makes a model repeat a first
-- wrong guess across all three passes instead of reconsidering it.
local ANALYSIS_TEMPERATURE = 0.2

local M = {
    id = "openai",
    displayName = "$$$/VenzAI/Provider/OpenAI/Name=OpenAI (cloud)",
    defaultTimeout = 300,
    -- No generateReference: OpenAI's image models are a different endpoint with
    -- a different shape, and the design forbids mixing roles. The engine asks
    -- for the capability and proceeds without a reference, which is already the
    -- path a local model takes.
    capabilities = { analyze = true, listModels = true },
    settingsFields = {
        { key = "apiKey", role = "secret", required = true,
          label = "$$$/VenzAI/Provider/OpenAI/ApiKey=API key" },
        { key = "model", role = "model", default = "gpt-5",
          label = "$$$/VenzAI/Provider/OpenAI/Model=Analysis model" },
        { key = "baseUrl", role = "url", default = "https://api.openai.com/v1",
          label = "$$$/VenzAI/Provider/OpenAI/BaseUrl=API base URL" },
    },
}

function M.validate(config)
    if type(config) ~= "table" then return false, "missing_config" end
    if config.apiKey == nil or config.apiKey == "" then return false, "missing_api_key" end
    if config.model == nil or config.model == "" then return false, "missing_model" end
    if config.baseUrl == nil or config.baseUrl == "" then return false, "missing_base_url" end
    if not config.baseUrl:match("^https?://") then return false, "invalid_base_url" end
    return true
end

-- A connection that never got off the ground comes back with no body and no
-- status, which reads in the log exactly like a server that answered with
-- nothing. The SDK documents only the success shape of the headers table, but in
-- practice it carries an `error` entry here; reading it is guarded so that if it
-- ever stops being provided we fall back to the generic message.
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

-- Trims a trailing slash so that a base URL entered either way produces one
-- correct endpoint rather than a doubled slash some proxies reject.
local function endpoint(baseUrl, path)
    return (baseUrl:gsub("/+$", "")) .. path
end

-- OpenAI takes one message whose content is an array of typed parts, and an
-- image is a data URL rather than a separate field.
local function contentJson(parts)
    local out = {}
    for _, part in ipairs(parts or {}) do
        if part.text then
            table.insert(out, string.format('{ "type": "text", "text": %s }',
                Json.escape(part.text)))
        elseif part.image then
            table.insert(out, string.format(
                '{ "type": "image_url", "image_url": { "url": %s } }',
                Json.escape(string.format("data:%s;base64,%s",
                    part.image.mimeType, part.image.data))))
        end
    end
    return table.concat(out, ",")
end

-- Some models fix their own sampling and reject the parameter outright:
--
--   "Unsupported value: 'temperature' does not support 0.2 with this model.
--    Only the default (1) value is supported."
--
-- That is a 400, so the whole pass died telling the user the plug-in had built
-- a malformed request. It had not: the request is fine, the parameter is just
-- not ours to set on that model. Detected on the service's own words rather
-- than on a list of model names, which would be out of date by the time it
-- shipped.
local function refusesTemperature(body)
    if not body then return false end
    return body:find("unsupported_value", 1, true) ~= nil
        and body:find("temperature", 1, true) ~= nil
end

function M.analyze(request, config)
    local responseFormat = request.wantsJson
        and ', "response_format": { "type": "json_object" }' or ''

    local function buildPayload(withTemperature)
        local temperature = withTemperature
            and (', "temperature": ' .. ANALYSIS_TEMPERATURE) or ''
        return string.format(
            '{ "model": %s, "messages": [{ "role": "user", "content": [%s] }]%s%s }',
            Json.escape(config.model), contentJson(request.parts), temperature, responseFormat)
    end

    local url = endpoint(config.baseUrl, "/chat/completions")

    local function send(payload)
        log("POST " .. url)
        return LrHttp.post(url, payload, {
            { field = "Content-Type", value = "application/json" },
            { field = "Authorization", value = "Bearer " .. config.apiKey },
        }, "POST", request.timeout or M.defaultTimeout)
    end

    local body, headers = send(buildPayload(true))
    local status = headers and headers.status

    if body and status == 400 and refusesTemperature(body) then
        log("This model sets its own temperature; retrying once without it.")
        body, headers = send(buildPayload(false))
        status = headers and headers.status
    end

    if not body then
        return Contract.failure("unreachable",
            transportError(headers) or "no response received", nil, status)
    end
    if status ~= 200 then
        return Contract.failure(classifyStatus(status), body:sub(1, 600), nil, status)
    end

    -- "content" is the assistant's answer. A refusal also arrives under
    -- "content", so an empty one is genuinely empty rather than a fault.
    local contents = Json.stringValues(body, "content")
    if #contents == 0 or contents[1] == "" then
        return Contract.failure("empty", body:sub(1, 600), nil, status)
    end

    return Contract.success({
        text = table.concat(contents),
        truncated = (Json.stringValue(body, "finish_reason") == "length"),
        httpStatus = status,
    })
end

-- /v1/models returns everything the account can reach: embeddings, speech,
-- transcription, image generation, moderation, realtime sessions, and the old
-- completion models. Hundreds of entries, of which a handful can look at a
-- photograph and answer with JSON, and the settings panel offered all of them.
--
-- Filtered by EXCLUSION, never by a list of approved names. A whitelist would
-- be out of date the day OpenAI ships its next model, and the user would have
-- no way to reach it; an exclusion list only goes stale by showing one entry
-- too many, which costs a moment rather than a capability.
local CANNOT_READ_A_PHOTOGRAPH = {
    "embedding", "whisper", "tts", "audio", "realtime", "transcribe", "speech",
    "dall%-e", "image", "sora", "moderation", "search", "davinci", "babbage",
    "computer%-use",
}

local function cannotReadAPhotograph(id)
    local name = id:lower()
    for _, pattern in ipairs(CANNOT_READ_A_PHOTOGRAPH) do
        if name:find(pattern) then return true end
    end
    return false
end

function M.listModels(config)
    local body, headers = LrHttp.get(endpoint(config.baseUrl, "/models"),
        { { field = "Authorization", value = "Bearer " .. config.apiKey } }, LIST_TIMEOUT)
    local status = headers and headers.status

    if not body then
        return nil, "unreachable", transportError(headers) or "no response received"
    end
    if status ~= 200 then
        return nil, classifyStatus(status), body:sub(1, 600)
    end
    local everything = Json.stringValues(body, "id")
    local usable = {}
    for _, id in ipairs(everything) do
        if not cannotReadAPhotograph(id) then
            table.insert(usable, id)
        end
    end

    log(string.format("%d model(s) offered, %d can plausibly do this job.",
        #everything, #usable))
    return usable
end

return M
