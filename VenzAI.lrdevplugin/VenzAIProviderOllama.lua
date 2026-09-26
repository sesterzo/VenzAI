--[[----------------------------------------------------------------------------

VenzAIProviderOllama.lua
The Ollama protocol: serialization, HTTP, extraction, classification.

A local server, so there is no credential: this driver declares NO secret field
at all, which is what proves the settings panel renders from declarations rather
than from a layout that assumes every provider has an API key.

/api/generate takes a single prompt string and a separate array of bare base64
images, so the contract's ordered parts collapse here - the texts are joined in
order, the images collected. That collapsing is this driver's business and
nothing outside it needs to know.

transportError and classifyStatus are this file's own copies. See the note in
VenzAIProviderOpenAI.lua: each driver reads its own service's failures, and the
mappings are allowed to diverge.

------------------------------------------------------------------------------]]

local LrHttp = import 'LrHttp'

local Json = require 'VenzAIJson'
local Contract = require 'VenzAIProviderContract'
local VenzAILog = require 'VenzAILog'
local log = VenzAILog.scoped("Ollama")

local LIST_TIMEOUT = 10

-- The analysis returns numbers, not prose: the same photograph should produce
-- the same develop settings twice running, and three refinement passes should
-- converge rather than argue. At 0.9 they disagreed with each other through
-- sampling alone, which reads as the model changing its mind. Low, not zero:
-- the task still carries judgement, and a flat 0 makes a model repeat a first
-- wrong guess across all three passes instead of reconsidering it.
local ANALYSIS_TEMPERATURE = 0.2

local M = {
    id = "ollama",
    displayName = "$$$/VenzAI/Provider/Ollama/Name=Ollama (local, offline)",
    -- A local model on CPU is slower than any cloud one, and there is no quota
    -- pushing back: minutes are normal here, not a symptom.
    defaultTimeout = 900,
    capabilities = { analyze = true, listModels = true },
    settingsFields = {
        { key = "baseUrl", role = "url", default = "http://localhost:11434",
          label = "$$$/VenzAI/Provider/Ollama/BaseUrl=Server URL" },
        { key = "model", role = "model", default = "qwen2.5vl:latest",
          label = "$$$/VenzAI/Provider/Ollama/Model=Model" },
    },
}

function M.validate(config)
    if type(config) ~= "table" then return false, "missing_config" end
    if config.baseUrl == nil or config.baseUrl == "" then return false, "missing_base_url" end
    if not config.baseUrl:match("^https?://") then return false, "invalid_base_url" end
    if config.model == nil or config.model == "" then return false, "missing_model" end
    return true
end

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

local function endpoint(baseUrl, path)
    return (baseUrl:gsub("/+$", "")) .. path
end

function M.analyze(request, config)
    local texts, images = {}, {}
    for _, part in ipairs(request.parts or {}) do
        if part.text then table.insert(texts, part.text) end
        if part.image then table.insert(images, Json.escape(part.image.data)) end
    end

    -- num_ctx and num_predict are set explicitly and generously. Ollama's
    -- default context window (often 4096 tokens) was observed to silently
    -- truncate the response mid-JSON once the prompt, plus a thinking model's
    -- full reasoning chain, plus the JSON answer no longer fit together - and a
    -- truncated response looks like "the model chose not to propose X" while
    -- actually being cut off. num_ctx was raised from 16384 to 32768 when the
    -- parameter vocabulary grew and the prompt with it. Note this costs local
    -- RAM/VRAM for the KV cache roughly in proportion: on a constrained machine,
    -- lowering it back is the first thing to try, watching for a Response whose
    -- truncated flag is set.
    local payload = string.format(
        '{ "model": %s, "prompt": %s, "images": [%s], %s "stream": false, ' ..
        '"options": { "temperature": ' .. ANALYSIS_TEMPERATURE ..
        ', "num_ctx": 32768, "num_predict": 4096 } }',
        Json.escape(config.model),
        Json.escape(table.concat(texts, "\n\n")),
        table.concat(images, ","),
        request.wantsJson and '"format": "json",' or '')

    local url = endpoint(config.baseUrl, "/api/generate")
    log("POST " .. url)
    local body, headers = LrHttp.post(url, payload,
        { { field = "Content-Type", value = "application/json" } },
        "POST", request.timeout or M.defaultTimeout)
    local status = headers and headers.status

    if not body then
        return Contract.failure("unreachable",
            transportError(headers) or "no response received", nil, status)
    end
    if status ~= 200 then
        return Contract.failure(classifyStatus(status), body:sub(1, 600), nil, status)
    end

    local answer = Json.stringValue(body, "response")
    if answer == nil or answer == "" then
        return Contract.failure("empty", body:sub(1, 600), nil, status)
    end

    return Contract.success({
        text = answer,
        -- Ollama reports why generation stopped. "length" instead of "stop"
        -- means the answer was cut off mid-JSON by the context limit, which
        -- looks exactly like the model choosing not to include something.
        truncated = (Json.stringValue(body, "done_reason") == "length"),
        httpStatus = status,
    })
end

function M.listModels(config)
    local body, headers = LrHttp.get(endpoint(config.baseUrl, "/api/tags"), nil, LIST_TIMEOUT)
    local status = headers and headers.status

    if not body then
        return nil, "unreachable", transportError(headers) or "no response received"
    end
    if status ~= 200 then
        return nil, classifyStatus(status), body:sub(1, 600)
    end

    -- A reachable server with nothing pulled is an EMPTY LIST, not a failure:
    -- the panel then says "no models installed", which is actionable, rather
    -- than "could not detect models", which sends the user looking for a network
    -- problem that is not there.
    return Json.stringValues(body, "name")
end

return M
