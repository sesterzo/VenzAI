local Contract = require 'VenzAIProviderContract'

local CONFIG = { apiKey = "sk-x", model = "gpt-5", baseUrl = "https://api.openai.com/v1" }

-- Was never defined in this file, so every queueResponse(body, OK) passed a nil
-- global as the headers and the driver saw no status at all.
local OK = { status = 200 }

local function chatBody(answer, finishReason)
    local escaped = answer:gsub('\\', '\\\\'):gsub('"', '\\"')
    return '{"choices":[{"message":{"role":"assistant","content":"' .. escaped ..
           '"},"finish_reason":"' .. (finishReason or "stop") .. '"}]}'
end

return {
    -- /v1/models returns every model on the account - embeddings, speech,
    -- transcription, image generation, moderation, realtime - so the picker
    -- offered hundreds of entries of which a handful can read a photograph and
    -- answer with JSON. Filtered by EXCLUDING the families that cannot do this
    -- job, never by a list of approved names: a whitelist would hide every
    -- model released after this file was written.
    { "the model list drops the families that cannot read a photograph", function()
        harness.reset()
        local D = require 'VenzAIProviderOpenAI'
        harness.queueResponse([==[{"data":[
            {"id":"gpt-5"},
            {"id":"gpt-5-mini"},
            {"id":"text-embedding-3-large"},
            {"id":"whisper-1"},
            {"id":"tts-1-hd"},
            {"id":"dall-e-3"},
            {"id":"gpt-image-1"},
            {"id":"omni-moderation-latest"},
            {"id":"gpt-4o-realtime-preview"},
            {"id":"gpt-4o-audio-preview"},
            {"id":"gpt-4o-transcribe"},
            {"id":"davinci-002"},
            {"id":"sora-2"},
            {"id":"gpt-4.1"}
        ]}]==], OK)

        local names = Contract.listModels(D, CONFIG)
        local kept = {}
        for _, name in ipairs(names) do kept[name] = true end

        for _, wanted in ipairs({ "gpt-5", "gpt-5-mini", "gpt-4.1" }) do
            assert(kept[wanted], wanted .. " was filtered out and it should not be")
        end
        for _, unwanted in ipairs({ "text-embedding-3-large", "whisper-1", "tts-1-hd",
                                    "dall-e-3", "gpt-image-1", "omni-moderation-latest",
                                    "gpt-4o-realtime-preview", "gpt-4o-audio-preview",
                                    "gpt-4o-transcribe", "davinci-002", "sora-2" }) do
            assert(not kept[unwanted], unwanted .. " survived the filter")
        end
    end },

    { "a model this file has never heard of is kept", function()
        harness.reset()
        local D = require 'VenzAIProviderOpenAI'
        harness.queueResponse([==[{"data":[{"id":"gpt-7-ultra-2027"},{"id":"whisper-9"}]}]==], OK)
        local names = Contract.listModels(D, CONFIG)
        assert(#names == 1 and names[1] == "gpt-7-ultra-2027",
            "an unknown model must survive; got " .. table.concat(names, ","))
    end },

    { "an empty list after filtering is still not an error", function()
        harness.reset()
        local D = require 'VenzAIProviderOpenAI'
        harness.queueResponse([==[{"data":[{"id":"whisper-1"},{"id":"tts-1"}]}]==], OK)
        local names, errorKind = Contract.listModels(D, CONFIG)
        assert(errorKind == nil, "got " .. tostring(errorKind))
        assert(type(names) == "table" and #names == 0, "expected an empty list")
    end },

    -- Reported from Lightroom: gpt-5 answers 400 with
    --   "Unsupported value: 'temperature' does not support 0.2 with this
    --    model. Only the default (1) value is supported."
    -- and the whole pass died with a "malformed request" dialog. Newer
    -- reasoning models fix their own sampling; the parameter is not refused
    -- because its value is wrong, but because it is not ours to set.
    { "a model that refuses the temperature is retried without it", function()
        harness.reset()
        local D = require 'VenzAIProviderOpenAI'
        harness.queueResponse([==[{"error":{"message":"Unsupported value: 'temperature' does not support 0.2 with this model. Only the default (1) value is supported.","type":"invalid_request_error","param":"temperature","code":"unsupported_value"}}]==],
            { status = 400 })
        harness.queueResponse(chatBody([==[{"Exposure2012": 0.2}]==]), OK)

        local response = Contract.call(D, "analyze", { parts = {}, wantsJson = true }, CONFIG)
        assert(response.ok, "the retry never happened: " ..
            tostring(response.errorKind) .. " / " .. tostring(response.errorDetail))
        assert(#harness.http.requests == 2, "expected two requests, got " .. #harness.http.requests)
        assert(harness.http.requests[1].body:find("temperature", 1, true),
            "the first request should carry the temperature")
        assert(not harness.http.requests[2].body:find("temperature", 1, true),
            "the retry must drop the temperature")
    end },

    { "a 400 about anything else is still a bad_request", function()
        harness.reset()
        local D = require 'VenzAIProviderOpenAI'
        harness.queueResponse([==[{"error":{"message":"Invalid image","code":"invalid_image"}}]==],
            { status = 400 })
        local response = Contract.call(D, "analyze", { parts = {}, wantsJson = true }, CONFIG)
        assert(not response.ok, "a real bad request must not be retried into success")
        assert(#harness.http.requests == 1, "it must not retry, got " .. #harness.http.requests)
    end },

    -- The analysis asks for numbers, not for ideas: the same photograph must
    -- produce the same develop settings twice running. A high temperature made
    -- consecutive refinement passes disagree with each other through sampling
    -- alone, which reads to the user as the model changing its mind.
    { "the analysis asks for a low temperature, so passes do not disagree by chance", function()
        harness.reset()
        local D = require 'VenzAIProviderOpenAI'
        harness.queueResponse(chatBody('{"Exposure2012": 0.5}'), OK)
        Contract.call(D, "analyze", { parts = {}, wantsJson = true }, CONFIG)
        local sent = harness.http.requests[1].body:match('"temperature"%s*:%s*([%d%.]+)')
        assert(sent, "no temperature in the payload: " .. harness.http.requests[1].body)
        assert(tonumber(sent) <= 0.3, "temperature is " .. sent .. ", too high for a numeric answer")
    end },

    { "the driver satisfies the contract", function()
        local ok, problem = Contract.validateDriver(require 'VenzAIProviderOpenAI')
        assert(ok, tostring(problem))
    end },

    { "generateReference is not declared, and asking for it is not_supported", function()
        -- The engine must degrade to analysis without a reference, exactly as
        -- it already does for a local model, with no branch on provider name.
        harness.reset()
        local O = require 'VenzAIProviderOpenAI'
        assert(O.capabilities.generateReference ~= true, "OpenAI must not declare it")
        local response = Contract.call(O, "generateReference", { parts = {} }, CONFIG)
        assert(response.errorKind == "not_supported", "got " .. tostring(response.errorKind))
        assert(#harness.http.requests == 0, "nothing should have been sent")
    end },

    { "the model is a body field, not a URL path segment", function()
        harness.reset()
        local O = require 'VenzAIProviderOpenAI'
        harness.queueResponse(chatBody('{"Exposure2012": 0.5}'), { status = 200 })
        Contract.call(O, "analyze", { parts = { { text = "p" } }, wantsJson = true }, CONFIG)
        local request = harness.http.requests[1]
        assert(not request.url:find("gpt-5", 1, true), "the model must not be in the URL")
        assert(request.body:find('"model"', 1, true), "the model must be in the body")
        assert(request.url == "https://api.openai.com/v1/chat/completions",
            "got " .. request.url)
    end },

    { "auth is a Bearer header", function()
        harness.reset()
        local O = require 'VenzAIProviderOpenAI'
        harness.queueResponse(chatBody("{}"), { status = 200 })
        Contract.call(O, "analyze", { parts = { { text = "p" } } }, CONFIG)
        local found = false
        for _, header in ipairs(harness.http.requests[1].headers) do
            if header.field == "Authorization" then
                found = true
                assert(header.value == "Bearer sk-x", "got " .. header.value)
            end
        end
        assert(found, "no Authorization header")
    end },

    { "an image part becomes a data URL", function()
        harness.reset()
        local O = require 'VenzAIProviderOpenAI'
        harness.queueResponse(chatBody("{}"), { status = 200 })
        Contract.call(O, "analyze", { parts = {
            { text = "IMAGE 1:" },
            { image = { mimeType = "image/jpeg", data = "QUJD" } },
        } }, CONFIG)
        local body = harness.http.requests[1].body
        assert(body:find("data:image/jpeg;base64,QUJD", 1, true),
            "the image must be a data URL: " .. body:sub(1, 300))
        assert(body:find("image_url", 1, true), "image_url is missing")
    end },

    { "wantsJson maps to response_format", function()
        harness.reset()
        local O = require 'VenzAIProviderOpenAI'
        harness.queueResponse(chatBody("{}"), { status = 200 })
        Contract.call(O, "analyze", { parts = { { text = "p" } }, wantsJson = true }, CONFIG)
        assert(harness.http.requests[1].body:find("json_object", 1, true),
            "response_format is missing")
    end },

    { "finish_reason length is reported as truncated", function()
        harness.reset()
        local O = require 'VenzAIProviderOpenAI'
        harness.queueResponse(chatBody("partial", "length"), { status = 200 })
        local response = Contract.call(O, "analyze", { parts = {} }, CONFIG)
        assert(response.ok and response.truncated == true)
    end },

    { "200 with no content yields empty", function()
        harness.reset()
        local O = require 'VenzAIProviderOpenAI'
        harness.queueResponse('{"choices":[]}', { status = 200 })
        local response = Contract.call(O, "analyze", { parts = {} }, CONFIG)
        assert(response.errorKind == "empty", "got " .. tostring(response.errorKind))
    end },

    { "an empty baseUrl is rejected with its own reason", function()
        harness.reset()
        local O = require 'VenzAIProviderOpenAI'
        local response = Contract.call(O, "analyze", { parts = {} },
            { apiKey = "sk-x", model = "gpt-5", baseUrl = "" })
        assert(response.reasonKey == "missing_base_url", "got " .. tostring(response.reasonKey))
    end },

    { "a baseUrl with no scheme is rejected", function()
        harness.reset()
        local O = require 'VenzAIProviderOpenAI'
        local response = Contract.call(O, "analyze", { parts = {} },
            { apiKey = "sk-x", model = "gpt-5", baseUrl = "api.openai.com" })
        assert(response.reasonKey == "invalid_base_url", "got " .. tostring(response.reasonKey))
    end },

    { "a trailing slash on baseUrl does not produce a doubled slash", function()
        harness.reset()
        local O = require 'VenzAIProviderOpenAI'
        harness.queueResponse(chatBody("{}"), { status = 200 })
        Contract.call(O, "analyze", { parts = { { text = "p" } } },
            { apiKey = "sk-x", model = "gpt-5", baseUrl = "https://api.openai.com/v1/" })
        assert(harness.http.requests[1].url == "https://api.openai.com/v1/chat/completions",
            "got " .. harness.http.requests[1].url)
    end },
}
