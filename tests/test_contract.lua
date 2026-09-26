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
}
