local Contract = require 'VenzAIProviderContract'
local Gemini = require 'VenzAIProviderGemini'

local OK = { status = 200 }

local function analysisBody(answer)
    -- What Gemini really returns: the model's JSON, escaped, inside "text".
    local escaped = answer:gsub('\\', '\\\\'):gsub('"', '\\"')
    return '{"candidates":[{"content":{"parts":[{"text":"' .. escaped ..
           '"}]},"finishReason":"STOP"}]}'
end

local CONFIG = { apiKey = "k", model = "gemini-2.5-pro", imageModel = "gemini-2.5-flash-image" }

return {
    -- The analysis asks for numbers, not for ideas: the same photograph must
    -- produce the same develop settings twice running. A high temperature made
    -- consecutive refinement passes disagree with each other through sampling
    -- alone, which reads to the user as the model changing its mind.
    { "the analysis asks for a low temperature, so passes do not disagree by chance", function()
        harness.reset()
        local D = require 'VenzAIProviderGemini'
        harness.queueResponse(analysisBody('{"Exposure2012": 0.5}'), OK)
        Contract.call(D, "analyze", { parts = {}, wantsJson = true }, CONFIG)
        local sent = harness.http.requests[1].body:match('"temperature"%s*:%s*([%d%.]+)')
        assert(sent, "no temperature in the payload: " .. harness.http.requests[1].body)
        assert(tonumber(sent) <= 0.3, "temperature is " .. sent .. ", too high for a numeric answer")
    end },

    { "the driver satisfies the contract", function()
        local ok, problem = Contract.validateDriver(Gemini)
        assert(ok, tostring(problem))
    end },

    { "an empty API key is rejected before any request goes out", function()
        -- Review Focus: the user is told which field is wrong, not made to
        -- wait for a round trip that comes back auth.
        harness.reset()
        local G = require 'VenzAIProviderGemini'
        local response = Contract.call(G, "analyze", { parts = {} }, { apiKey = "", model = "m" })
        assert(response.errorKind == "config_invalid", "got " .. tostring(response.errorKind))
        assert(response.reasonKey == "missing_api_key", "got " .. tostring(response.reasonKey))
        assert(#harness.http.requests == 0, "a request went out on an invalid config")
    end },

    { "an empty model is rejected with its own reason", function()
        harness.reset()
        local G = require 'VenzAIProviderGemini'
        local response = Contract.call(G, "analyze", { parts = {} }, { apiKey = "k", model = "" })
        assert(response.reasonKey == "missing_model", "got " .. tostring(response.reasonKey))
    end },

    { "the key travels in a header, never in the URL", function()
        -- A URL is the part most likely to end up in a log line, a proxy
        -- access log or a bug report. The key value here is deliberately
        -- distinctive so that finding it in the URL cannot be a coincidence.
        harness.reset()
        local G = require 'VenzAIProviderGemini'
        harness.queueResponse(analysisBody('{"Exposure2012": 0.5}'), OK)
        Contract.call(G, "analyze", { parts = { { text = "hi" } }, wantsJson = true },
            { apiKey = "SENTINEL-KEY-9137", model = "gemini-2.5-pro" })
        local request = harness.http.requests[1]
        assert(not request.url:find("SENTINEL-KEY-9137", 1, true),
            "the key leaked into the URL: " .. request.url)
        assert(not request.body:find("SENTINEL-KEY-9137", 1, true),
            "the key leaked into the payload")
        local found = false
        for _, header in ipairs(request.headers) do
            if header.field == "x-goog-api-key" then
                found = true
                assert(header.value == "SENTINEL-KEY-9137", "got " .. tostring(header.value))
            end
        end
        assert(found, "the x-goog-api-key header is missing")
    end },

    { "the model name goes in the URL path and the response text comes back decoded", function()
        harness.reset()
        local G = require 'VenzAIProviderGemini'
        harness.queueResponse(analysisBody('{"Exposure2012": 0.5}'), OK)
        local response = Contract.call(G, "analyze",
            { parts = { { text = "prompt" } }, wantsJson = true }, CONFIG)
        assert(response.ok, tostring(response.errorKind) .. " " .. tostring(response.errorDetail))
        assert(harness.http.requests[1].url:find("gemini-2.5-pro", 1, true), "model not in the URL")
        assert(response.text == '{"Exposure2012": 0.5}',
            "text must arrive unescaped: got " .. tostring(response.text))
    end },

    { "wantsJson asks Gemini for a JSON-only answer", function()
        harness.reset()
        local G = require 'VenzAIProviderGemini'
        harness.queueResponse(analysisBody('{"Exposure2012": 0.5}'), OK)
        Contract.call(G, "analyze", { parts = { { text = "p" } }, wantsJson = true }, CONFIG)
        assert(harness.http.requests[1].body:find("response_mime_type", 1, true),
            "response_mime_type is missing from the payload")
    end },

    { "an image part is serialized as inline_data", function()
        harness.reset()
        local G = require 'VenzAIProviderGemini'
        harness.queueResponse(analysisBody('{"Exposure2012": 0.5}'), OK)
        Contract.call(G, "analyze", { parts = {
            { text = "IMAGE 1:" },
            { image = { mimeType = "image/jpeg", data = "QUJD" } },
        }, wantsJson = true }, CONFIG)
        local body = harness.http.requests[1].body
        assert(body:find("inline_data", 1, true), "inline_data missing")
        assert(body:find("QUJD", 1, true), "the image data did not reach the payload")
    end },

    { "MAX_TOKENS is reported as truncated, not as a deliberate answer", function()
        harness.reset()
        local G = require 'VenzAIProviderGemini'
        harness.queueResponse(
            '{"candidates":[{"content":{"parts":[{"text":"partial"}]},"finishReason":"MAX_TOKENS"}]}', OK)
        local response = Contract.call(G, "analyze", { parts = {} }, CONFIG)
        assert(response.ok and response.truncated == true, "truncation was not reported")
    end },

    -- Review Focus: HTTP 200 with no text at all.
    { "200 with no text yields empty rather than a Lua error", function()
        harness.reset()
        local G = require 'VenzAIProviderGemini'
        harness.queueResponse('{"candidates":[{"finishReason":"SAFETY"}]}', OK)
        local response = Contract.call(G, "analyze", { parts = {} }, CONFIG)
        assert(response.errorKind == "empty", "got " .. tostring(response.errorKind))
    end },

    { "no response at all is unreachable, and the transport reason survives", function()
        harness.reset()
        local G = require 'VenzAIProviderGemini'
        harness.queueResponse(nil, { error = { name = "connection refused" } })
        local response = Contract.call(G, "analyze", { parts = {} }, CONFIG)
        assert(response.errorKind == "unreachable", "got " .. tostring(response.errorKind))
        assert(tostring(response.errorDetail):find("connection refused", 1, true))
    end },

    { "each HTTP status maps to its own kind", function()
        local cases = {
            { 400, "bad_request" }, { 401, "auth" }, { 403, "auth" },
            { 404, "model_missing" }, { 429, "rate_limited" },
            { 500, "server_error" }, { 503, "server_error" }, { 418, "unknown" },
        }
        for _, case in ipairs(cases) do
            harness.reset()
            local G = require 'VenzAIProviderGemini'
            harness.queueResponse('{"error":{"message":"nope"}}', { status = case[1] })
            local response = Contract.call(G, "analyze", { parts = {} }, CONFIG)
            assert(response.errorKind == case[2],
                string.format("HTTP %d gave %s, expected %s", case[1], tostring(response.errorKind), case[2]))
            assert(response.httpStatus == case[1], "httpStatus must be carried forward")
        end
    end },

    { "a reference image comes back as data plus mimeType", function()
        harness.reset()
        local G = require 'VenzAIProviderGemini'
        harness.queueResponse(
            '{"candidates":[{"content":{"parts":[{"text":"here"},' ..
            '{"inlineData":{"mimeType":"image/png","data":"iVBORw0KGgo="}}]}}]}', OK)
        local response = Contract.call(G, "generateReference", { parts = { { text = "p" } } }, CONFIG)
        assert(response.ok, tostring(response.errorKind) .. " " .. tostring(response.errorDetail))
        assert(response.image.data == "iVBORw0KGgo=", "got " .. tostring(response.image.data))
        assert(response.image.mimeType == "image/png")
    end },

    { "a reference response with no image is empty, not a fault", function()
        harness.reset()
        local G = require 'VenzAIProviderGemini'
        harness.queueResponse('{"candidates":[{"content":{"parts":[{"text":"sorry"}]}}]}', OK)
        local response = Contract.call(G, "generateReference", { parts = {} }, CONFIG)
        assert(response.errorKind == "empty", "got " .. tostring(response.errorKind))
    end },

    { "listModels strips the models/ prefix", function()
        harness.reset()
        local G = require 'VenzAIProviderGemini'
        harness.queueResponse(
            '{"models":[{"name":"models/gemini-2.5-pro"},{"name":"models/gemini-2.5-flash"}]}', OK)
        local names, errorKind = G.listModels(CONFIG)
        assert(errorKind == nil, "got " .. tostring(errorKind))
        assert(#names == 2 and names[1] == "gemini-2.5-pro", "got " .. tostring(names[1]))
    end },

    { "listModels on a rejected key reports auth", function()
        harness.reset()
        local G = require 'VenzAIProviderGemini'
        harness.queueResponse('{"error":{}}', { status = 403 })
        local names, errorKind = G.listModels(CONFIG)
        assert(names == nil and errorKind == "auth", "got " .. tostring(errorKind))
    end },

    { "200 with an EMPTY text yields empty, not driver_fault", function()
        -- A safety block can come back as a present but empty text. Reporting
        -- driver_fault here tells the user "this is a fault in the plug-in rather
        -- than in your settings", when the truth is "a filter blocked it, try
        -- another model".
        harness.reset()
        local G = require 'VenzAIProviderGemini'
        harness.queueResponse(
            '{"candidates":[{"content":{"parts":[{"text":""}]},"finishReason":"SAFETY"}]}', OK)
        local response = Contract.call(G, "analyze", { parts = {} }, CONFIG)
        assert(response.errorKind == "empty", "got " .. tostring(response.errorKind))
    end },

    { "an answer split across parts where only one is empty still succeeds", function()
        harness.reset()
        local G = require 'VenzAIProviderGemini'
        harness.queueResponse(
            '{"candidates":[{"content":{"parts":[{"text":""},{"text":"{\\"Exposure2012\\": 0.5}"}]},"finishReason":"STOP"}]}', OK)
        local response = Contract.call(G, "analyze", { parts = {} }, CONFIG)
        assert(response.ok, "expected success, got " .. tostring(response.errorKind))
        assert(response.text == '{"Exposure2012": 0.5}', "got " .. tostring(response.text))
    end },
}
