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

local LrPathUtils = import 'LrPathUtils'

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
    -- generateReference is declared, and switched OFF by default through the
    -- useReference toggle below. Its request format still comes from
    -- documentation rather than from a call that has ever been made - but the
    -- engine asks Contract.capabilityEnabled, which reads the switch, so the
    -- unverified path cannot run until someone deliberately turns it on. That
    -- is what the toggle is for: it makes an untried capability safe to ship
    -- instead of hiding it from the person willing to try it.
    capabilities = { analyze = true, generateReference = true, listModels = true },
    settingsFields = {
        { key = "apiKey", role = "secret", required = true,
          label = "$$$/VenzAI/Provider/OpenAI/ApiKey=API key" },
        { key = "model", role = "model", default = "gpt-5",
          label = "$$$/VenzAI/Provider/OpenAI/Model=Analysis model" },
        { key = "imageModel", role = "model", default = "gpt-image-2",
          label = "$$$/VenzAI/Provider/OpenAI/ImageModel=Reference image model" },
        { key = "useReference", role = "toggle", default = false,
          enables = "generateReference",
          label = "$$$/VenzAI/Provider/OpenAI/UseReference=Generate a reference image first (untested)" },
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
-- Which parameter the image endpoint refused, or nil.
--
-- Read from the error's own "param" field rather than from its prose. Matching
-- the wording is what broke the previous version: it looked for "not supported"
-- and the API answered "The model 'gpt-image-2' does not support the
-- 'input_fidelity' parameter." - so the retry never fired and a whole reference
-- was lost over one optional field. The structured field cannot drift like that.
local function refusedParameter(body)
    if not body then return nil end
    return body:match('"param"%s*:%s*"([%w_]+)"')
end

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

-- The other half of the same problem. The image field needs the models the
-- analysis field must not see, so this one is an INCLUSION list: only a family
-- that draws pictures belongs here, and a chat model offered for the reference
-- image would fail on the first call.
local DRAWS_PICTURES = { "image", "dall%-e" }

local function cannotDrawAPicture(id)
    local name = id:lower()
    for _, pattern in ipairs(DRAWS_PICTURES) do
        if name:find(pattern) then return false end
    end
    return true
end

-- Generates the reference image: the SAME photograph, finished, which the
-- analysis then reverse-engineers into develop settings.
--
-- This is the one call in the plug-in that is not JSON. OpenAI's image editing
-- takes the photograph as a file in a multipart form, because it is an upload
-- rather than a field, so it goes through LrHttp.postMultipart instead of the
-- LrHttp.post every other call here uses.
--
-- The photograph travels BY PATH, not as the base64 the analysis uses. Two
-- details cost six rejected calls, both answered with the same unhelpful
-- "Invalid image file or mode for image 1":
--
--   * the part is called "image[]", not "image" - the endpoint takes a list
--     even when there is one image in it;
--   * the part carries the file, not the base64 text of the file. A string
--     describing a JPEG is not a JPEG.
--
-- The engine already exported that JPEG to disk to encode it, so it passes the
-- path beside the base64 and each driver takes the form its protocol wants.
function M.generateReference(request, config)
    if config.imageModel == nil or config.imageModel == "" then
        return Contract.failure("config_invalid", nil, "missing_image_model")
    end

    -- The photograph and the instruction arrive in the same `parts` list the
    -- analysis uses, so the driver picks them apart rather than the engine
    -- knowing which provider wants what.
    local prompt, photo
    for _, part in ipairs(request.parts or {}) do
        if part.text and not prompt then
            prompt = part.text
        elseif part.image and not photo then
            photo = part.image
        end
    end

    if not photo then
        return Contract.failure("driver_fault",
            "generateReference was called without an image part")
    end

    if not request.imagePath then
        return Contract.failure("driver_fault",
            "this endpoint uploads the photograph as a file and the request carried no path")
    end

    -- postMultipart does arithmetic on the part's fileSize while building the
    -- body, so a file part without one raises inside the SDK rather than
    -- returning an error.
    --
    -- Measured with plain Lua rather than LrFileUtils.fileAttributes, which
    -- answered without a fileSize for a file that had just been written and
    -- read back successfully two lines earlier. Seeking to the end of the file
    -- is the same answer with nothing to get wrong, and it proves the file is
    -- readable in the same motion.
    local handle = io.open(request.imagePath, "rb")
    local fileSize
    if handle then
        fileSize = handle:seek("end")
        handle:close()
    end

    if not handle then
        return Contract.failure("driver_fault",
            "could not open the exported photograph at " .. tostring(request.imagePath))
    end
    if not fileSize or fileSize == 0 then
        return Contract.failure("driver_fault",
            "the exported photograph is empty at " .. tostring(request.imagePath))
    end

    local url = endpoint(config.baseUrl, "/images/edits")
    -- Which model drew the reference is the first thing anyone asks when the
    -- reference is wrong, and until now the log could not answer it.
    log("Reference image model: " .. tostring(config.imageModel))

    -- The reference is a TARGET, and a target that invents the material it is
    -- made of is a worse target. Left at their defaults this endpoint returns
    -- a medium-quality render that re-draws faces, hands and fabric freely;
    -- asking for high quality and high fidelity to the input costs one field
    -- each and keeps the picture recognisably the same photograph.
    --
    -- Size is deliberately left alone: "auto" already answers 1536x1024 for a
    -- landscape frame and 1024x1536 for an upright one, and naming a size
    -- ourselves would only be a chance to name the wrong one.
    -- Asked for one at a time, and dropped one at a time. The models behind
    -- this endpoint do not take the same set - gpt-image-2 accepts quality and
    -- refuses input_fidelity - and giving up both over one refusal would throw
    -- away a field that was never the problem.
    local refinements = { quality = "high", input_fidelity = "high" }

    local function parts()
        local list = {
            { name = "model", value = config.imageModel },
            { name = "prompt", value = prompt or "" },
            {
                name = "image[]",
                fileName = LrPathUtils.leafName(request.imagePath),
                filePath = request.imagePath,
                fileSize = fileSize,
                contentType = photo.mimeType or "image/jpeg",
            },
            { name = "n", value = "1" },
        }
        for name, value in pairs(refinements) do
            table.insert(list, { name = name, value = value })
        end
        return list
    end

    local function asked()
        local names = {}
        for name in pairs(refinements) do table.insert(names, name) end
        table.sort(names)
        return #names > 0 and (" [" .. table.concat(names, ", ") .. "]") or ""
    end

    local function send()
        log("POST (multipart) " .. url .. asked())
        return LrHttp.postMultipart(url, parts(), {
            { field = "Authorization", value = "Bearer " .. config.apiKey },
        }, request.timeout or M.defaultTimeout)
    end

    local body, headers = send()
    local status = headers and headers.status

    -- One attempt per optional field and no more: a loop that keeps retrying a
    -- 400 it does not understand is how a run hangs on a bad request.
    for _ = 1, 2 do
        if not (body and status == 400) then break end

        -- The body of a 400 is the only place that says WHY, and a fallback
        -- that hides its own reason is a fallback nobody can check.
        log("The image endpoint refused the request: " .. tostring(body):sub(1, 500))

        local refused = refusedParameter(body)
        if not refused or refinements[refused] == nil then break end

        log(string.format("This image model does not take '%s'; dropping it and asking again.", refused))
        refinements[refused] = nil
        body, headers = send()
        status = headers and headers.status
    end
    if not body then
        return Contract.failure("unreachable",
            transportError(headers) or "no response received", nil, status)
    end
    if status ~= 200 then
        return Contract.failure(classifyStatus(status), body:sub(1, 600), nil, status)
    end

    local data = body:match('"b64_json"%s*:%s*"([A-Za-z0-9+/=]+)"')
    if not data then
        return Contract.failure("empty", body:sub(1, 600), nil, status)
    end

    return Contract.success({
        image = {
            data = data,
            -- The endpoint answers PNG unless asked otherwise, and the
            -- analysis only ever re-sends this as a data URL, so the type is
            -- stated rather than guessed from the bytes.
            mimeType = "image/png",
        },
        httpStatus = status,
    })
end

function M.listModels(config, field)
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

    -- Which list to offer depends on the field being filled. The driver knows
    -- its own field keys; nothing outside it needs to.
    local reject = cannotReadAPhotograph
    if field and field.key == "imageModel" then
        reject = cannotDrawAPicture
    end

    local usable = {}
    for _, id in ipairs(everything) do
        if not reject(id) then
            table.insert(usable, id)
        end
    end

    log(string.format("%d model(s) offered, %d can plausibly do this job.",
        #everything, #usable))
    return usable
end

return M
