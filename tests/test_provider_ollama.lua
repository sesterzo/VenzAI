local Contract = require 'VenzAIProviderContract'

local CONFIG = { baseUrl = "http://localhost:11434", model = "qwen2.5vl:latest" }

return {
    { "the driver satisfies the contract", function()
        local ok, problem = Contract.validateDriver(require 'VenzAIProviderOllama')
        assert(ok, tostring(problem))
    end },

    { "the driver declares no secret field", function()
        local Ollama = require 'VenzAIProviderOllama'
        for _, field in ipairs(Ollama.settingsFields) do
            assert(field.role ~= "secret",
                "a local server needs no credential; field " .. field.key .. " is a secret")
        end
    end },

    { "an empty baseUrl is rejected before any request", function()
        harness.reset()
        local O = require 'VenzAIProviderOllama'
        local response = Contract.call(O, "analyze", { parts = {} },
            { baseUrl = "", model = "qwen2.5vl:latest" })
        assert(response.reasonKey == "missing_base_url", "got " .. tostring(response.reasonKey))
        assert(#harness.http.requests == 0)
    end },

    { "the image is sent in the images array, base64 and bare", function()
        harness.reset()
        local O = require 'VenzAIProviderOllama'
        harness.queueResponse('{"response":"{}","done_reason":"stop"}', { status = 200 })
        Contract.call(O, "analyze", { parts = {
            { text = "prompt" },
            { image = { mimeType = "image/jpeg", data = "QUJD" } },
        }, wantsJson = true }, { baseUrl = "http://localhost:11434", model = "m" })
        local body = harness.http.requests[1].body
        assert(body:find('"images"', 1, true), "the images array is missing")
        assert(body:find("QUJD", 1, true), "the image data is missing")
        assert(not body:find("data:image", 1, true),
            "Ollama takes bare base64, not a data URL")
    end },

    { "several text parts are joined into one prompt", function()
        -- Ollama takes a single prompt string, so the contract's ordered parts
        -- have to collapse. The order must survive.
        harness.reset()
        local O = require 'VenzAIProviderOllama'
        harness.queueResponse('{"response":"{}","done_reason":"stop"}', { status = 200 })
        Contract.call(O, "analyze", { parts = {
            { text = "FIRST" }, { text = "SECOND" },
        } }, { baseUrl = "http://localhost:11434", model = "m" })
        local body = harness.http.requests[1].body
        local firstAt = body:find("FIRST", 1, true)
        local secondAt = body:find("SECOND", 1, true)
        assert(firstAt and secondAt and firstAt < secondAt, "prompt order was lost")
    end },

    { "wantsJson maps to format json", function()
        harness.reset()
        local O = require 'VenzAIProviderOllama'
        harness.queueResponse('{"response":"{}","done_reason":"stop"}', { status = 200 })
        Contract.call(O, "analyze", { parts = { { text = "p" } }, wantsJson = true },
            { baseUrl = "http://localhost:11434", model = "m" })
        assert(harness.http.requests[1].body:find('"format"%s*:%s*"json"'),
            "format json is missing")
    end },

    { "done_reason length becomes truncated, replacing the grep in the engine", function()
        harness.reset()
        local O = require 'VenzAIProviderOllama'
        harness.queueResponse('{"response":"{\\"Exposure2012\\": 0.2","done_reason":"length"}',
            { status = 200 })
        local response = Contract.call(O, "analyze", { parts = {} },
            { baseUrl = "http://localhost:11434", model = "m" })
        assert(response.ok and response.truncated == true,
            "a cut-off answer must be reported as truncated, not as a deliberate omission")
    end },

    { "a 404 from a model that was never pulled is model_missing", function()
        harness.reset()
        local O = require 'VenzAIProviderOllama'
        harness.queueResponse('{"error":"model \'nope\' not found"}', { status = 404 })
        local response = Contract.call(O, "analyze", { parts = {} },
            { baseUrl = "http://localhost:11434", model = "nope" })
        assert(response.errorKind == "model_missing", "got " .. tostring(response.errorKind))
    end },

    { "a server that is not running is unreachable", function()
        harness.reset()
        local O = require 'VenzAIProviderOllama'
        harness.queueResponse(nil, { error = { name = "connection refused" } })
        local response = Contract.call(O, "analyze", { parts = {} },
            { baseUrl = "http://localhost:11434", model = "m" })
        assert(response.errorKind == "unreachable")
    end },

    { "200 with an empty response field yields empty", function()
        harness.reset()
        local O = require 'VenzAIProviderOllama'
        harness.queueResponse('{"response":"","done_reason":"stop"}', { status = 200 })
        local response = Contract.call(O, "analyze", { parts = {} },
            { baseUrl = "http://localhost:11434", model = "m" })
        assert(response.errorKind == "empty", "got " .. tostring(response.errorKind))
    end },

    -- Review Focus: reachable, but nothing installed. Not an error kind.
    { "listModels on a reachable but empty server returns an empty list, not an error", function()
        harness.reset()
        local O = require 'VenzAIProviderOllama'
        harness.queueResponse('{"models":[]}', { status = 200 })
        local names, errorKind = O.listModels({ baseUrl = "http://localhost:11434", model = "m" })
        assert(errorKind == nil, "reachable and empty is not a failure: got " .. tostring(errorKind))
        assert(type(names) == "table" and #names == 0, "expected an empty list")
    end },

    { "listModels reads the names from /api/tags", function()
        harness.reset()
        local O = require 'VenzAIProviderOllama'
        harness.queueResponse('{"models":[{"name":"qwen2.5vl:latest"},{"name":"llava:13b"}]}',
            { status = 200 })
        local names = O.listModels({ baseUrl = "http://localhost:11434", model = "m" })
        assert(#names == 2 and names[1] == "qwen2.5vl:latest")
        assert(harness.http.requests[1].url == "http://localhost:11434/api/tags",
            "got " .. harness.http.requests[1].url)
    end },
}
