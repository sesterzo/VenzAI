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
    { "a path whose file is gone says so, and says which path", function()
        -- The real failure this cost five attempts to find: the engine deleted
        -- the exported JPEG one line after encoding it, so by the time the
        -- driver opened the path the file was gone. The message has to name the
        -- path, or the next person reads "could not open" and goes looking at
        -- permissions.
        harness.reset()
        local D = require 'VenzAIProviderOpenAI'
        local gone = (os.getenv("TEMP") or ".") .. "/venzai_definitely_not_here.jpg"
        local response = D.generateReference({
            imagePath = gone,
            parts = { { text = "p" }, { image = { mimeType = "image/jpeg", data = "SU1H" } } },
        }, { apiKey = "sk-x", imageModel = "gpt-image-2",
             baseUrl = "https://api.openai.com/v1" })
        assert(not response.ok)
        assert(tostring(response.errorDetail):find(gone, 1, true),
            "the message must name the path: " .. tostring(response.errorDetail))
        assert(#harness.http.requests == 0)
    end },

    --------------------------------------------------------------------------
    -- The reference image
    --------------------------------------------------------------------------
    -- The capability is NOT declared yet on purpose: the wire format below is
    -- written from documentation, not from a call that has ever been made, and
    -- a declared capability is a promise the engine will act on mid-photograph.
    -- The function is tested here in isolation until a real run confirms it.
    { "the reference capability is declared but switched off by default", function()
        -- The protocol is still unverified. What keeps it from running is no
        -- longer a missing declaration but the toggle's default: the engine
        -- asks Contract.capabilityEnabled, which reads the switch. That is the
        -- whole point of the switch - it makes an unverified path safe to ship
        -- without hiding it from someone willing to try it.
        local D = require 'VenzAIProviderOpenAI'
        assert(type(D.generateReference) == "function", "the method is missing")
        assert(D.capabilities.generateReference, "the capability must be declared")

        local toggle
        for _, field in ipairs(D.settingsFields) do
            if field.key == "useReference" then toggle = field end
        end
        assert(toggle, "there is no toggle for it")
        assert(toggle.role == "toggle" and toggle.enables == "generateReference",
            "the toggle must be wired to the capability")
        assert(toggle.default == false, "it must be OFF until a real run confirms the protocol")

        assert(not Contract.capabilityEnabled(D, "generateReference", {}),
            "with nothing configured, the engine must not ask for a reference")
        assert(Contract.capabilityEnabled(D, "generateReference", { useReference = true }),
            "ticking the box must enable it")
    end },

    { "the driver declares a model field for the reference image", function()
        local D = require 'VenzAIProviderOpenAI'
        local field
        for _, f in ipairs(D.settingsFields) do
            if f.key == "imageModel" then field = f end
        end
        assert(field, "generateReference reads config.imageModel and nothing declares it")
        assert(field.role == "model", "it needs the Detect models button")
        assert(type(field.default) == "string" and field.default ~= "")
    end },

    --------------------------------------------------------------------------
    -- Detect models knows which field it is filling
    --------------------------------------------------------------------------
    -- The filter that hides speech, embedding and image models from the
    -- analysis field would hide exactly what the image field needs. The panel
    -- already has the field in hand; it passes it, and the driver decides.
    { "the image field is offered image models", function()
        harness.reset()
        local D = require 'VenzAIProviderOpenAI'
        harness.queueResponse([==[{"data":[
            {"id":"gpt-5"},{"id":"gpt-image-2"},{"id":"dall-e-3"},{"id":"whisper-1"}
        ]}]==], OK)
        local names = Contract.listModels(D, CONFIG, { key = "imageModel", role = "model" })
        local kept = {}
        for _, n in ipairs(names) do kept[n] = true end
        assert(kept["gpt-image-2"], "the image model was hidden from the image field")
        assert(kept["dall-e-3"], "an image family must be offered here")
        assert(not kept["whisper-1"], "speech is not an image model")
        assert(not kept["gpt-5"], "a chat model cannot generate an image")
    end },

    { "the analysis field is offered chat models and nothing else", function()
        harness.reset()
        local D = require 'VenzAIProviderOpenAI'
        harness.queueResponse([==[{"data":[
            {"id":"gpt-5"},{"id":"gpt-image-2"},{"id":"dall-e-3"},{"id":"whisper-1"}
        ]}]==], OK)
        local names = Contract.listModels(D, CONFIG, { key = "model", role = "model" })
        local kept = {}
        for _, n in ipairs(names) do kept[n] = true end
        assert(kept["gpt-5"], "the analysis model was hidden")
        assert(not kept["gpt-image-2"] and not kept["dall-e-3"],
            "an image generator cannot read a photograph and answer with JSON")
    end },

    { "with no field named, the old behaviour stands", function()
        -- The self-test calls listModels to see whether the service answers at
        -- all, and has no field in mind.
        harness.reset()
        local D = require 'VenzAIProviderOpenAI'
        harness.queueResponse([==[{"data":[{"id":"gpt-5"},{"id":"whisper-1"}]}]==], OK)
        local names = Contract.listModels(D, CONFIG)
        assert(#names == 1 and names[1] == "gpt-5", "got " .. table.concat(names, ","))
    end },

    { "an empty image model is rejected before any request goes out", function()
        harness.reset()
        local D = require 'VenzAIProviderOpenAI'
        local response = D.generateReference({ parts = {} },
            { apiKey = "sk-x", model = "gpt-5", baseUrl = "https://api.openai.com/v1" })
        assert(response.errorKind == "config_invalid", "got " .. tostring(response.errorKind))
        assert(response.reasonKey == "missing_image_model", "got " .. tostring(response.reasonKey))
        assert(#harness.http.requests == 0, "a request went out with no model")
    end },

    { "a request with no photograph in it is a driver fault, not a round trip", function()
        harness.reset()
        local D = require 'VenzAIProviderOpenAI'
        local response = D.generateReference({ parts = { { text = "retouch this" } } },
            { apiKey = "sk-x", imageModel = "gpt-image-2",
              baseUrl = "https://api.openai.com/v1" })
        assert(not response.ok)
        assert(#harness.http.requests == 0, "nothing should be sent without an image")
    end },

    { "the photograph travels as a file part and the prompt as a field", function()
        harness.reset()
        local photoPath = harness.tempFile()
        local D = require 'VenzAIProviderOpenAI'
        harness.queueResponse([==[{"data":[{"b64_json":"UkVGRVJFTkNF"}]}]==], OK)

        local response = D.generateReference({
            imagePath = photoPath,
            parts = {
                { text = "make this the finished version" },
                { image = { mimeType = "image/jpeg", data = "SU1BR0U=" } },
            },
        }, { apiKey = "sk-x", imageModel = "gpt-image-2",
             baseUrl = "https://api.openai.com/v1" })

        assert(response.ok, tostring(response.errorKind) .. " " .. tostring(response.errorDetail))
        assert(response.image.data == "UkVGRVJFTkNF", "got " .. tostring(response.image.data))

        local sent = harness.http.requests[1]
        assert(sent.verb == "POST_MULTIPART", "it must not be sent as JSON")
        assert(sent.url:find("/images/edits", 1, true), "wrong endpoint: " .. sent.url)

        local named = {}
        for _, part in ipairs(sent.parts) do named[part.name] = part end
        assert(named.model and named.model.value == "gpt-image-2",
            "the model must travel as its own field")
        assert(named.prompt and named.prompt.value:find("finished version", 1, true),
            "the prompt must travel as its own field")

        -- The name is "image[]", not "image": the endpoint takes a list of
        -- images even when there is one. With the wrong name OpenAI answered
        -- "Invalid image file or mode for image 1", six times out of six.
        local photo = named["image[]"]
        assert(photo, "the photograph must travel as a part called image[]")

        -- And it travels as a FILE, by path. Handing the endpoint the base64
        -- text as the part's value is what it was rejecting: that is a string
        -- describing a JPEG, not a JPEG.
        assert(photo.filePath == photoPath,
            "the part must carry the exported file's path, got " .. tostring(photo.filePath))
        assert(photo.value == nil, "the base64 must not be sent as the part's value")
        assert(photo.contentType == "image/jpeg", "the image part needs its type")
        assert(photo.fileName, "the image part needs a file name")

        -- LrHttp.postMultipart does arithmetic on fileSize while building the
        -- body, so a file part without one raises inside the SDK - not a
        -- rejected request, a Lua error with no useful line number.
        assert(type(photo.fileSize) == "number" and photo.fileSize > 0,
            "the image part needs its size, got " .. tostring(photo.fileSize))
    end },

    { "a path that is not on disk is reported, not sent", function()
        harness.reset()
        harness.files = {}   -- nothing exists
        local D = require 'VenzAIProviderOpenAI'
        local response = D.generateReference({
            imagePath = "C:/temp/VenzAI/gone.jpg",
            parts = { { text = "p" }, { image = { mimeType = "image/jpeg", data = "SU1H" } } },
        }, { apiKey = "sk-x", imageModel = "gpt-image-2",
             baseUrl = "https://api.openai.com/v1" })
        assert(not response.ok, "it should not have tried")
        assert(#harness.http.requests == 0, "nothing should have been sent")
    end },

    { "with no file on disk the driver says so instead of sending base64", function()
        -- The engine passes the path beside the base64. A driver reached
        -- without one cannot build this request at all, and saying so beats
        -- sending something the endpoint will reject.
        harness.reset()
        local D = require 'VenzAIProviderOpenAI'
        local response = D.generateReference({
            parts = {
                { text = "p" },
                { image = { mimeType = "image/jpeg", data = "SU1BR0U=" } },
            },
        }, { apiKey = "sk-x", imageModel = "gpt-image-2",
             baseUrl = "https://api.openai.com/v1" })
        assert(not response.ok, "it should not have tried")
        assert(#harness.http.requests == 0, "nothing should have been sent")
    end },

    { "the key travels in a header, never in the form", function()
        harness.reset()
        local photoPath = harness.tempFile()
        local D = require 'VenzAIProviderOpenAI'
        harness.queueResponse([==[{"data":[{"b64_json":"UkVG"}]}]==], OK)
        D.generateReference({
            imagePath = photoPath,
            parts = { { text = "p" }, { image = { mimeType = "image/jpeg", data = "SU1H" } } },
        }, { apiKey = "SENTINEL-KEY-4471", imageModel = "gpt-image-2",
             baseUrl = "https://api.openai.com/v1" })

        local sent = harness.http.requests[1]
        assert(not sent.url:find("SENTINEL-KEY-4471", 1, true), "the key leaked into the URL")
        for _, part in ipairs(sent.parts) do
            assert(not tostring(part.value or ""):find("SENTINEL-KEY-4471", 1, true),
                "the key leaked into the form")
        end
        local found = false
        for _, header in ipairs(sent.headers) do
            if header.field == "Authorization" then
                found = true
                assert(header.value == "Bearer SENTINEL-KEY-4471", "got " .. header.value)
            end
        end
        assert(found, "the Authorization header is missing")
    end },

    { "a 400 from the image endpoint is classified, not passed through raw", function()
        harness.reset()
        local photoPath = harness.tempFile()
        local D = require 'VenzAIProviderOpenAI'
        harness.queueResponse([==[{"error":{"message":"Unknown model"}}]==], { status = 400 })
        local response = D.generateReference({
            imagePath = photoPath,
            parts = { { text = "p" }, { image = { mimeType = "image/jpeg", data = "SU1H" } } },
        }, { apiKey = "sk-x", imageModel = "nope", baseUrl = "https://api.openai.com/v1" })
        assert(response.errorKind == "bad_request", "got " .. tostring(response.errorKind))
        assert(response.httpStatus == 400)
    end },

    { "a 200 carrying no image is empty, not a success", function()
        harness.reset()
        local photoPath = harness.tempFile()
        local D = require 'VenzAIProviderOpenAI'
        harness.queueResponse([==[{"data":[]}]==], OK)
        local response = D.generateReference({
            imagePath = photoPath,
            parts = { { text = "p" }, { image = { mimeType = "image/jpeg", data = "SU1H" } } },
        }, { apiKey = "sk-x", imageModel = "gpt-image-2", baseUrl = "https://api.openai.com/v1" })
        assert(response.errorKind == "empty", "got " .. tostring(response.errorKind))
    end },

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

    { "the engine degrades to analysis alone when the switch is off", function()
        -- Written when OpenAI could not generate an image at all, and asserted
        -- the capability was absent. It can now, and what keeps the engine from
        -- asking is the switch rather than the missing declaration - so the
        -- assertion moves to the behaviour that actually matters: with the
        -- switch off, nothing is asked for and nothing is sent.
        harness.reset()
        local O = require 'VenzAIProviderOpenAI'
        assert(not Contract.capabilityEnabled(O, "generateReference", { useReference = false }),
            "the engine would still ask for a reference")
        assert(not Contract.capabilityEnabled(O, "generateReference", {}),
            "with nothing configured the default must keep it off")
        assert(#harness.http.requests == 0, "nothing should have been sent")
    end },

    { "a driver that declares no reference at all is still not_supported", function()
        -- Ollama's case, and the guarantee the engine relies on: asking a
        -- driver for something it never claimed returns a Response, not a
        -- crash, and sends nothing.
        harness.reset()
        local Ollama = require 'VenzAIProviderOllama'
        local response = Contract.call(Ollama, "generateReference", { parts = {} },
            { baseUrl = "http://localhost:11434", model = "qwen2.5vl:latest" })
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
