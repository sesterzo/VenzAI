local Contract = require 'VenzAIProviderContract'

-- Sentinel meaning "remove this field". Needed because `{ id = nil }` does not
-- create the key at all, so pairs() never sees it and the override silently
-- does nothing - which would make a test claiming to check a missing field
-- actually check a well-formed driver, and pass for the wrong reason.
local REMOVE = {}

-- A minimal driver that satisfies validateDriver, used as the base for the
-- deliberately broken variants below.
local function goodDriver(overrides)
    local driver = {
        id = "fake",
        displayName = "$$$/VenzAI/Provider/Fake/Name=Fake",
        defaultTimeout = 30,
        capabilities = { analyze = true },
        settingsFields = {
            { key = "apiKey", role = "secret", required = true,
              label = "$$$/VenzAI/Provider/Fake/ApiKey=API key" },
            { key = "model", role = "model", default = "fake-1",
              label = "$$$/VenzAI/Provider/Fake/Model=Analysis model" },
        },
        validate = function(config)
            if config == nil or config.apiKey == nil or config.apiKey == "" then
                return false, "missing_api_key"
            end
            return true
        end,
        analyze = function(request, config)
            return Contract.success({ text = "an answer" })
        end,
    }
    for key, value in pairs(overrides or {}) do
        if value == REMOVE then driver[key] = nil else driver[key] = value end
    end
    return driver
end

local VALID_CONFIG = { apiKey = "k", model = "fake-1" }

return {
    -- Regression, found in Lightroom: every driver field rendered empty and
    -- nothing the user typed was ever saved, because the panel's property-table
    -- keys were "provider.<id>.<field>". LrView reads a dot in a bound key as a
    -- KEY PATH - it looked for propertyTable.provider.gemini.apiKey, found no
    -- table called `provider`, and bound the control to nothing. So the binding
    -- key is built here, and it may not contain a dot.
    { "a binding key contains no dot, because LrView reads one as a key path", function()
        local key = Contract.bindingKey("gemini", "apiKey")
        assert(not key:find("%."), "the key must be flat, got " .. key)
    end },

    { "binding keys do not collide across drivers or fields", function()
        local seen = {}
        local pairsToCheck = {
            { "gemini", "model" }, { "gemini", "imageModel" },
            { "openai", "model" }, { "ollama", "model" },
        }
        for _, pair in ipairs(pairsToCheck) do
            local key = Contract.bindingKey(pair[1], pair[2])
            assert(not seen[key], "two fields share the binding key " .. key)
            seen[key] = true
        end
    end },

    -- The flat key is only unambiguous while the parts it joins are plain
    -- identifiers: a driver id "a_b" with field "c" and a driver "a" with field
    -- "b_c" would otherwise produce the same key, and a dot would bring back
    -- the key-path bug through the driver rather than through the panel.
    { "a driver id that is not a plain identifier is rejected", function()
        local ok, problem = Contract.validateDriver(goodDriver({ id = "ge.mini" }))
        assert(not ok, "a dotted id was accepted")
        assert(problem:find("id"), "the problem must name the id, got " .. tostring(problem))

        assert(not Contract.validateDriver(goodDriver({ id = "ge_mini" })),
            "an id with an underscore was accepted")
        assert(Contract.validateDriver(goodDriver({ id = "gemini2" })),
            "a plain identifier with a digit must stay valid")
    end },

    { "a field key that is not a plain identifier is rejected", function()
        local ok, problem = Contract.validateDriver(goodDriver({
            settingsFields = {
                { key = "api.key", role = "secret",
                  label = "$$$/VenzAI/Provider/Fake/ApiKey=API key" },
            },
        }))
        assert(not ok, "a dotted field key was accepted")
        assert(problem:find("api%.key"), "the problem must name the field, got " .. tostring(problem))
    end },

    --------------------------------------------------------------------------
    -- validateDriver
    --------------------------------------------------------------------------
    { "a well-formed driver validates", function()
        local ok, problem = Contract.validateDriver(goodDriver())
        assert(ok, "rejected a good driver: " .. tostring(problem))
    end },

    { "a driver with no id is rejected", function()
        local ok, problem = Contract.validateDriver(goodDriver({ id = REMOVE }))
        assert(not ok and problem:find("id"), "problem was " .. tostring(problem))
    end },

    { "a driver with no displayName is rejected", function()
        local ok, problem = Contract.validateDriver(goodDriver({ displayName = REMOVE }))
        assert(not ok and problem:find("displayName"), "problem was " .. tostring(problem))
    end },

    { "a capability with no matching function is rejected, and the message names it", function()
        local ok, problem = Contract.validateDriver(goodDriver({
            capabilities = { analyze = true, listModels = true },
        }))
        assert(not ok, "a driver declaring listModels without the function passed")
        assert(problem:find("listModels"), "the message must name the capability: " .. problem)
    end },

    { "an unknown capability is rejected", function()
        local ok, problem = Contract.validateDriver(goodDriver({
            capabilities = { analyze = true, telepathy = true },
        }))
        assert(not ok and problem:find("telepathy"), "problem was " .. tostring(problem))
    end },

    { "a driver that does not declare analyze is rejected", function()
        local ok = Contract.validateDriver(goodDriver({ capabilities = { listModels = true } }))
        assert(not ok)
    end },

    { "a settings field with an unknown role is rejected, and the message names the field", function()
        local ok, problem = Contract.validateDriver(goodDriver({
            settingsFields = {
                { key = "weird", role = "telepathic", label = "$$$/x=Weird" },
            },
        }))
        assert(not ok, "an unknown role passed")
        assert(problem:find("weird") and problem:find("telepathic"), "problem was " .. problem)
    end },

    { "a settings field with no label is rejected", function()
        local ok, problem = Contract.validateDriver(goodDriver({
            settingsFields = { { key = "model", role = "model" } },
        }))
        assert(not ok and problem:find("label"), "problem was " .. tostring(problem))
    end },

    { "a secret field with a default is rejected", function()
        -- A default for a secret would mean shipping a credential in the source.
        local ok, problem = Contract.validateDriver(goodDriver({
            settingsFields = {
                { key = "apiKey", role = "secret", default = "sk-oops",
                  label = "$$$/x=API key" },
            },
        }))
        assert(not ok and problem:find("default"), "problem was " .. tostring(problem))
    end },

    { "a missing defaultTimeout is rejected", function()
        local ok = Contract.validateDriver(goodDriver({ defaultTimeout = REMOVE }))
        assert(not ok)
    end },

    --------------------------------------------------------------------------
    -- The call funnel
    --------------------------------------------------------------------------
    { "a well-formed call passes the Response through unchanged", function()
        local response = Contract.call(goodDriver(), "analyze", {}, VALID_CONFIG)
        assert(response.ok == true, "call failed")
        assert(response.text == "an answer")
        assert(response.truncated == false, "truncated must be normalized to false")
    end },

    { "an undeclared capability yields not_supported without touching the driver", function()
        local reached = false
        local driver = goodDriver({
            generateReference = function() reached = true end,
        })
        local response = Contract.call(driver, "generateReference", {}, VALID_CONFIG)
        assert(response.ok == false)
        assert(response.errorKind == "not_supported", "got " .. tostring(response.errorKind))
        assert(not reached, "the method must not run when the capability is not declared")
    end },

    { "a rejected config yields config_invalid and carries the reasonKey forward", function()
        -- Review Focus: a required secret left empty must be told to the user as
        -- WHICH field is wrong, before any request goes out.
        local reached = false
        local driver = goodDriver({
            analyze = function() reached = true; return Contract.success({ text = "x" }) end,
        })
        local response = Contract.call(driver, "analyze", {}, { apiKey = "", model = "fake-1" })
        assert(response.ok == false)
        assert(response.errorKind == "config_invalid", "got " .. tostring(response.errorKind))
        assert(response.reasonKey == "missing_api_key",
            "the reasonKey must survive: got " .. tostring(response.reasonKey))
        assert(not reached, "analyze must not run on an invalid config")
    end },

    { "a nil config is rejected rather than crashing the driver", function()
        local response = Contract.call(goodDriver(), "analyze", {}, nil)
        assert(response.ok == false and response.errorKind == "config_invalid")
    end },

    { "a method that raises becomes driver_fault carrying the message", function()
        local driver = goodDriver({
            analyze = function() error("something snapped", 0) end,
        })
        local response = Contract.call(driver, "analyze", {}, VALID_CONFIG)
        assert(response.ok == false)
        assert(response.errorKind == "driver_fault", "got " .. tostring(response.errorKind))
        assert(tostring(response.errorDetail):find("something snapped"),
            "the raised message must reach errorDetail: " .. tostring(response.errorDetail))
    end },

    { "a validate that raises becomes driver_fault, not config_invalid", function()
        local driver = goodDriver({ validate = function() error("validate broke", 0) end })
        local response = Contract.call(driver, "analyze", {}, VALID_CONFIG)
        assert(response.ok == false and response.errorKind == "driver_fault",
            "got " .. tostring(response.errorKind))
    end },

    { "a method returning nil becomes driver_fault", function()
        local driver = goodDriver({ analyze = function() return nil end })
        local response = Contract.call(driver, "analyze", {}, VALID_CONFIG)
        assert(response.ok == false and response.errorKind == "driver_fault")
    end },

    { "a method returning a string becomes driver_fault", function()
        local driver = goodDriver({ analyze = function() return "oops" end })
        local response = Contract.call(driver, "analyze", {}, VALID_CONFIG)
        assert(response.ok == false and response.errorKind == "driver_fault")
    end },

    { "a table with no ok field becomes driver_fault", function()
        local driver = goodDriver({ analyze = function() return { text = "hi" } end })
        local response = Contract.call(driver, "analyze", {}, VALID_CONFIG)
        assert(response.ok == false and response.errorKind == "driver_fault")
    end },

    { "a successful analyze with no text becomes driver_fault", function()
        local driver = goodDriver({ analyze = function() return { ok = true } end })
        local response = Contract.call(driver, "analyze", {}, VALID_CONFIG)
        assert(response.ok == false and response.errorKind == "driver_fault",
            "got " .. tostring(response.errorKind))
    end },

    { "a failure naming an errorKind outside the closed set is coerced to unknown", function()
        local driver = goodDriver({
            analyze = function() return { ok = false, errorKind = "teapot" } end,
        })
        local response = Contract.call(driver, "analyze", {}, VALID_CONFIG)
        assert(response.ok == false)
        assert(response.errorKind == "driver_fault", "got " .. tostring(response.errorKind))
    end },

    { "failure() itself coerces an unknown kind and keeps the original name in the detail", function()
        local response = Contract.failure("teapot", "the original detail")
        assert(response.errorKind == "unknown", "got " .. tostring(response.errorKind))
        assert(response.errorDetail:find("teapot"), "the original name must survive in the detail")
        assert(response.errorDetail:find("the original detail"))
    end },

    { "a successful generateReference needs both image fields", function()
        local driver = goodDriver({
            capabilities = { analyze = true, generateReference = true },
            generateReference = function()
                return { ok = true, image = { data = "abc" } }  -- no mimeType
            end,
        })
        local response = Contract.call(driver, "generateReference", {}, VALID_CONFIG)
        assert(response.ok == false and response.errorKind == "driver_fault")
    end },

    { "a well-formed generateReference passes through", function()
        local driver = goodDriver({
            capabilities = { analyze = true, generateReference = true },
            generateReference = function()
                return Contract.success({ image = { data = "abc", mimeType = "image/png" } })
            end,
        })
        local response = Contract.call(driver, "generateReference", {}, VALID_CONFIG)
        assert(response.ok == true and response.image.mimeType == "image/png")
    end },

    { "every errorKind a driver may return is in the closed set", function()
        -- Guards against the set being widened by accident in one place only.
        local expected = {
            "config_invalid", "unreachable", "auth", "rate_limited",
            "model_missing", "bad_request", "server_error", "empty",
            "driver_fault", "not_supported", "unknown",
        }
        local count = 0
        for _ in pairs(Contract.ERROR_KINDS) do count = count + 1 end
        assert(count == #expected, "the set has " .. count .. " kinds, expected " .. #expected)
        for _, kind in ipairs(expected) do
            assert(Contract.ERROR_KINDS[kind], "missing kind " .. kind)
        end
    end },

    --------------------------------------------------------------------------
    -- The listModels funnel
    --------------------------------------------------------------------------
    { "listModels through the funnel rejects a bad config before calling out", function()
        -- The panel's Detect button used to call driver.listModels directly, so
        -- an empty API key produced a round trip that came back auth - "the key
        -- may have been revoked" - instead of "the API key is empty".
        local reached = false
        local driver = goodDriver({
            capabilities = { analyze = true, listModels = true },
            listModels = function() reached = true; return { "m-1" } end,
        })
        local names, errorKind, detail, reasonKey =
            Contract.listModels(driver, { apiKey = "", model = "fake-1" })
        assert(names == nil, "no list should come back")
        assert(errorKind == "config_invalid", "got " .. tostring(errorKind))
        assert(reasonKey == "missing_api_key", "got " .. tostring(reasonKey))
        assert(not reached, "listModels must not run on an invalid config")
    end },

    { "listModels through the funnel passes a good call through", function()
        local driver = goodDriver({
            capabilities = { analyze = true, listModels = true },
            listModels = function(config) return { "m-1", "m-2" } end,
        })
        local names, errorKind = Contract.listModels(driver, VALID_CONFIG)
        assert(errorKind == nil, "got " .. tostring(errorKind))
        assert(#names == 2 and names[1] == "m-1")
    end },

    { "listModels through the funnel preserves an empty list as success", function()
        -- Reachable but nothing installed is not a failure.
        local driver = goodDriver({
            capabilities = { analyze = true, listModels = true },
            listModels = function() return {} end,
        })
        local names, errorKind = Contract.listModels(driver, VALID_CONFIG)
        assert(errorKind == nil, "an empty list is not an error")
        assert(type(names) == "table" and #names == 0)
    end },

    { "listModels through the funnel turns a raise into driver_fault", function()
        -- A field arriving nil rather than "" made a driver concatenate nil and
        -- raise, which reached Lightroom as a raw Lua error dialog.
        local driver = goodDriver({
            capabilities = { analyze = true, listModels = true },
            listModels = function() error("attempt to concatenate a nil value", 0) end,
        })
        local names, errorKind, detail = Contract.listModels(driver, VALID_CONFIG)
        assert(names == nil)
        assert(errorKind == "driver_fault", "got " .. tostring(errorKind))
        assert(tostring(detail):find("concatenate", 1, true), "the raise must reach the detail")
    end },

    { "listModels on a driver that does not declare it is not_supported", function()
        local names, errorKind = Contract.listModels(goodDriver(), VALID_CONFIG)
        assert(names == nil and errorKind == "not_supported", "got " .. tostring(errorKind))
    end },

    { "listModels returning something that is not a table is driver_fault", function()
        local driver = goodDriver({
            capabilities = { analyze = true, listModels = true },
            listModels = function() return "oops" end,
        })
        local names, errorKind = Contract.listModels(driver, VALID_CONFIG)
        assert(names == nil and errorKind == "driver_fault", "got " .. tostring(errorKind))
    end },
}
