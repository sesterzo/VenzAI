--[[----------------------------------------------------------------------------

harness.lua
Development-only test harness. NOT part of the plug-in bundle.

Lets a bundle file be loaded outside Lightroom by supplying the three globals
the SDK normally provides - import, require and LOC - backed by in-memory
stores a test can read and write. The interpreter underneath is real Lua 5.1,
the dialect Lightroom runs, so a difference between dialects cannot hide here
and then surface in the application.

tests/run.py creates a fresh runtime per suite file, so state is shared
between the tests of one file and never across files. A test that cares calls
harness.reset() first.

------------------------------------------------------------------------------]]

local BUNDLE = VENZAI_BUNDLE or "VenzAI.lrdevplugin"

local H = {
    prefs = {},
    passwords = {},
    logLines = {},
    http = { requests = {}, responses = {} },
    stubs = {},
    loaded = {},
}

-- Mirrors LOC: the default text is whatever follows the first '=' in the key,
-- and ^1..^9 are replaced positionally. Tests therefore assert on real
-- English output, and a key with no default text shows up as the bare key.
function _G.LOC(key, ...)
    local text = tostring(key):match("^%$%$%$/[^=]*=(.*)$") or tostring(key)
    local args = { ... }
    return (text:gsub("%^(%d)", function(n)
        local value = args[tonumber(n)]
        return value == nil and "" or tostring(value)
    end))
end

_G.MAC_ENV, _G.WIN_ENV = false, true

local function defaultStubs()
    return {
        LrPrefs = {
            prefsForPlugin = function() return H.prefs end,
        },
        LrPasswords = {
            store = function(key, value) H.passwords[key] = value end,
            retrieve = function(key) return H.passwords[key] end,
        },
        -- LrLogger is called as a function, and the object it returns is used
        -- with method syntax, so info receives the logger as its first
        -- argument.
        LrLogger = function()
            return {
                enable = function() end,
                info = function(_, message) table.insert(H.logLines, tostring(message)) end,
            }
        end,
        LrPathUtils = {
            child = function(a, b) return tostring(a) .. "/" .. tostring(b) end,
            getStandardFilePath = function(which) return "/tmp/" .. tostring(which) end,
        },
        LrStringUtils = {
            encodeBase64 = function(s) return "BASE64(" .. tostring(s) .. ")" end,
            decodeBase64 = function(s) return tostring(s):match("^BASE64%((.*)%)$") or s end,
            trimWhitespace = function(s) return (tostring(s):gsub("^%s+", ""):gsub("%s+$", "")) end,
        },
        -- Records every request and answers from a queue, so a test drives a
        -- driver's whole request/response cycle with no network.
        LrHttp = {
            post = function(url, body, headers, method, timeout)
                table.insert(H.http.requests, {
                    verb = "POST", url = url, body = body,
                    headers = headers, method = method, timeout = timeout,
                })
                local queued = table.remove(H.http.responses, 1)
                if not queued then return nil, { error = { name = "no response queued" } } end
                return queued.body, queued.headers
            end,
            get = function(url, headers, timeout)
                table.insert(H.http.requests, {
                    verb = "GET", url = url, headers = headers, timeout = timeout,
                })
                local queued = table.remove(H.http.responses, 1)
                if not queued then return nil, { error = { name = "no response queued" } } end
                return queued.body, queued.headers
            end,
        },
        LrDialogs = {
            message = function(title, detail, kind)
                table.insert(H.logLines, string.format("DIALOG[%s] %s | %s",
                    tostring(kind), tostring(title), tostring(detail)))
            end,
        },
        LrErrors = { throwUserError = function(m) error(m, 2) end },
        -- Empty on purpose: VenzAIMasks imports both at load time, and every
        -- test that exercises masking supplies its own LrDevelopController
        -- through harness.stub. An empty table here is what lets the module
        -- load at all.
        LrDevelopController = {},
        LrApplicationView = { switchToModule = function() end },
        LrTasks = {
            startAsyncTask = function(fn) fn() end,
            sleep = function() end,
            yield = function() end,
        },
    }
end

H.stubs = defaultStubs()

function _G.import(name)
    local stub = H.stubs[name]
    if stub == nil then
        error("test harness has no stub for " .. tostring(name), 2)
    end
    return stub
end

function _G.require(name)
    if H.loaded[name] ~= nil then return H.loaded[name] end
    local path = BUNDLE .. "/" .. name .. ".lua"
    local chunk, err = loadfile(path)
    if not chunk then error("could not load " .. path .. ": " .. tostring(err), 2) end
    local module = chunk()
    H.loaded[name] = module
    return module
end

-- Replaces one stub. Call BEFORE the module under test is required, since a
-- module captures its imports at load time.
function H.stub(name, value)
    H.stubs[name] = value
end

function H.queueResponse(body, headers)
    table.insert(H.http.responses, { body = body, headers = headers })
end

-- Clears every store AND the module cache, so the next require re-runs the
-- module's top-level code against fresh stores.
function H.reset()
    H.prefs = {}
    H.passwords = {}
    H.logLines = {}
    H.http = { requests = {}, responses = {} }
    H.loaded = {}
    H.stubs = defaultStubs()
end

_G.harness = H
return H
