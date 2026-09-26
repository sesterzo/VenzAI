local Contract = require 'VenzAIProviderContract'

local CONFIG = { apiKey = "sk-x", model = "gpt-5", baseUrl = "https://api.openai.com/v1" }

local function chatBody(answer, finishReason)
    local escaped = answer:gsub('\\', '\\\\'):gsub('"', '\\"')
    return '{"choices":[{"message":{"role":"assistant","content":"' .. escaped ..
           '"},"finish_reason":"' .. (finishReason or "stop") .. '"}]}'
end

return {
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
