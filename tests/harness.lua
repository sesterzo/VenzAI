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
        LrFileUtils = {
            -- postMultipart reads fileSize off a file part and does arithmetic
            -- on it, so a part without one raises inside the SDK. The stub
            -- answers like the real one: a table of attributes, or nothing at
            -- all for a path that is not there.
            fileAttributes = function(path)
                if H.files and H.files[path] == nil then return nil end
                return { fileSize = (H.files and H.files[path]) or 12345 }
            end,
            exists = function(path)
                if H.files and H.files[path] == nil then return false end
                return "file"
            end,
        },
        LrPathUtils = {
            child = function(a, b) return tostring(a) .. "/" .. tostring(b) end,
            getStandardFilePath = function(which) return "/tmp/" .. tostring(which) end,
            leafName = function(path)
                return tostring(path):match("[^/\]+$") or tostring(path)
            end,
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
            -- Image editing is the one call that is not JSON: OpenAI takes the
            -- photograph as a file part in a multipart form. Recorded the same
            -- way as post, with the parts kept so a test can check what was
            -- actually sent rather than only that something was.
            postMultipart = function(url, content, headers, timeout)
                table.insert(H.http.requests, {
                    verb = "POST_MULTIPART", url = url, parts = content,
                    headers = headers, timeout = timeout,
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
            -- Not a stub that just calls pcall: the whole point of the SDK's
            -- LrTasks.pcall is that the function it protects MAY yield, which
            -- Lua 5.1's pcall forbids ("attempt to yield across a C-call
            -- boundary" - Lightroom words it "Yielding is not allowed within a
            -- C or metamethod call"). Every LrHttp call yields, so a stub
            -- without this property would let the bug through green tests.
            -- It runs the function in its own coroutine and passes any yield
            -- outwards, which is what the real one does.
            pcall = function(fn, ...)
                local co = coroutine.create(fn)
                local passed = { ... }
                while true do
                    local returned = { coroutine.resume(co, unpack(passed)) }
                    local ok = table.remove(returned, 1)
                    if not ok then return false, returned[1] end
                    if coroutine.status(co) == "dead" then
                        return true, unpack(returned)
                    end
                    passed = { coroutine.yield(unpack(returned)) }
                end
            end,
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
-- Writes a real file and returns its path. Needed because a driver that
-- uploads a photograph opens it to measure it, and a stub cannot fake a file
-- the SDK is not involved in reading: io.open either finds bytes on disk or it
-- does not. Cleaned up by H.reset.
function H.tempFile(contents)
    local dir = os.getenv("TEMP") or os.getenv("TMPDIR") or "."
    H.tempCount = (H.tempCount or 0) + 1
    local path = dir .. "/venzai_test_" .. tostring(H.tempCount) .. ".jpg"

    local handle = io.open(path, "wb")
    if not handle then
        error("the test harness could not write a temporary file at " .. path)
    end
    handle:write(contents or "JPEGBYTES")
    handle:close()

    H.tempPaths = H.tempPaths or {}
    table.insert(H.tempPaths, path)
    return path
end

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
    -- path -> size. nil means "every path exists", which is what most
    -- suites want; a table makes only the listed paths exist.
    H.files = nil

    for _, path in ipairs(H.tempPaths or {}) do os.remove(path) end
    H.tempPaths = {}
    H.loaded = {}
    H.stubs = defaultStubs()
end

_G.harness = H
return H
