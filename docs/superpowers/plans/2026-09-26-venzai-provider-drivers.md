# VenzAI Provider Drivers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace VenzAI's two hardcoded engines with a driver layer, so the processing engine never names a provider and adding one is a new file plus one registry line.

**Architecture:** A driver is a data table declaring `capabilities` and `settingsFields` plus the functions `validate`, `analyze`, `generateReference` and `listModels`. The engine never calls a driver directly: every call goes through `Contract.call`, which checks the capability, validates the config, runs the method under `pcall` and guarantees a well-formed Response back. Parsing, validation and Lightroom application stay shared and downstream of every driver. Errors are a closed set of `errorKind` codes; drivers return codes, never prose, and one catalog turns a code into a localized message.

**Tech Stack:** Lua 5.1 (Lightroom Classic SDK 15.3, minimum 11.0), Lightroom SDK namespaces (`LrHttp`, `LrPrefs`, `LrPasswords`, `LrView`, `LrDevelopController`). Tests run outside Lightroom on the `lua51` runtime embedded in the Python package `lupa` (already installed), driven by a Python runner.

**Spec:** [docs/superpowers/specs/2026-09-26-venzai-provider-drivers-design.md](../specs/2026-09-26-venzai-provider-drivers-design.md)

## Global Constraints

- `LrSdkVersion = 15.3`, `LrSdkMinimumVersion = 11.0`. Do not change either.
- `LrToolkitIdentifier = 'com.user.geminiautoedit'`. Never change it: `LrPrefs` and `LrPasswords` are both keyed on it.
- Flat files in the bundle root. No Lua subfolders — there is no evidence Lightroom's loader searches them.
- **Drivers return codes, never prose.** No driver builds a sentence intended for a human.
- No string concatenation to build a user-facing sentence. Everything goes through `LOC` with `^1 ^2 ^3` placeholders, including provider names, which are LOC keys.
- English lives in the source as the `LOC` default; Italian lives in `TranslatedStrings_it.txt`. An incomplete language degrades to English phrase by phrase.
- The `errorKind` set is closed: `config_invalid`, `unreachable`, `auth`, `rate_limited`, `model_missing`, `bad_request`, `server_error`, `empty`, `driver_fault`, `not_supported`, `unknown`.
- No fallback chains, no parallel runs, no mixed roles, no dynamic driver discovery, no settings migration, no retries.
- One active provider at a time, chosen in the settings panel.
- Prompt text sent to a model stays in English.
- Adding provider #4 must touch exactly: one new driver file, one line in the registry, and translation labels. Nothing else.
- Tests and the harness live in `tests/` at the repo root, never inside the bundle. The bundle contains only what Lightroom loads.
- Run the suite with `python tests/run.py` from the repo root.

## Review Focus

Five conditions the spec implies but does not give a task of their own. Each one's test is added to the task that owns the code.

- **A provider answers HTTP 200 with a body containing no text at all** (safety block, empty `candidates`, a truncated body cut before the text field). The user expects `empty`, not a Lua error inside the driver. — Tasks 9, 10, 11.
- **A required secret is empty.** The user expects to be told which field is wrong before any network call, not to watch a request go out and come back `auth`. — Tasks 3, 9.
- **`listModels` reaches the server and it has no models.** The user expects "reachable, but nothing is installed", which is not an error kind — it is an empty list, and the panel must not present it as a failure. — Task 11.
- **The model's answer contains JSON-escaped quotes.** Removing the `gsub('\\"', '"')` hack must not regress mask parsing, which reads nested objects. `response.text` must arrive already unescaped. — Tasks 2, 7.
- **`activeProvider` names a driver that no longer exists** (a pref left over from a renamed or removed driver). The user expects the plug-in to fall back to the first registered driver and keep working, not to fail at load. — Task 12.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `tests/harness.lua` | stubs `import`, `require`, `LOC`; holds the fake prefs/passwords/HTTP stores | 1 |
| `tests/run.py` | runs every `tests/test_*.lua` on a fresh Lua 5.1 runtime | 1 |
| `VenzAI.lrdevplugin/VenzAIJson.lua` | JSON string escaping and unescaping, both directions | 2 |
| `VenzAI.lrdevplugin/VenzAIProviderContract.lua` | Response/driver shapes, the closed `errorKind` set, `validateDriver`, the `call` funnel | 3 |
| `VenzAI.lrdevplugin/VenzAIMessages.lua` | the only mapping from a code to a localized title/body | 4 |
| `VenzAI.lrdevplugin/VenzAISettings.lua` | *modified*: `providerConfig`, `activeProvider`; `snapshot` removed | 5 |
| `VenzAI.lrdevplugin/VenzAIPrompts.lua` | building the analysis and reference prompts | 6 |
| `VenzAI.lrdevplugin/VenzAIParse.lua` | whitelist, ranges, crop coherence, mask extraction | 7 |
| `VenzAI.lrdevplugin/VenzAIMasks.lua` | applying local corrections through `LrDevelopController` | 8 |
| `VenzAI.lrdevplugin/VenzAIProviderGemini.lua` | Gemini protocol | 9 |
| `VenzAI.lrdevplugin/VenzAIProviderOpenAI.lua` | OpenAI protocol — implemented second on purpose | 10 |
| `VenzAI.lrdevplugin/VenzAIProviderOllama.lua` | Ollama protocol | 11 |
| `VenzAI.lrdevplugin/VenzAIProviderRegistry.lua` | the hand-written driver list | 12 |
| `VenzAI.lrdevplugin/PluginInfoProvider.lua` | *rewritten*: renders the panel from declarations | 13 |
| `VenzAI.lrdevplugin/VenzAIProcess.lua` | *slimmed*: the pass loop only | 14 |
| `VenzAI.lrdevplugin/VenzAISelfTest.lua` | the "test providers" menu item | 15 |
| `VenzAI.lrdevplugin/Info.lua` | *modified*: one new menu entry | 15 |
| `tests/check_translations.py` | translation key completeness | 16 |

**One deviation from the spec's file list (§4.3):** `VenzAIJson.lua` is not in it. Three drivers each need to escape a JSON string on the way out and unescape one on the way in. The escaper is subtle — the comment at `VenzAIProcess.lua:1012` records that `string.format("%q")` produces output Ollama's Go parser rejects — and three copies of it would be three places to fix the next such bug. One 60-line module with a single responsibility is the alternative.

**Extraction tasks (6, 7, 8) move existing code verbatim.** For those, this plan gives exact source line ranges and the exact module wrapper rather than reprinting 900 unchanged lines. Moving `VenzAIProcess.lua:217-478` into a module is a complete instruction; retyping it here would add only the chance of a transcription error.

---

### Task 1: Test harness

The plug-in only ever runs inside Lightroom, so nothing here is testable until there is a way to load a bundle file outside it. This task builds that, and proves it on code that already exists and already works.

**Files:**
- Create: `tests/harness.lua`
- Create: `tests/run.py`
- Create: `tests/test_settings.lua`
- Create: `tests/requirements.txt`

**Interfaces:**
- Consumes: nothing.
- Produces: the global `harness` table inside every test runtime, with fields `prefs` (table), `passwords` (table), `logLines` (array of strings), `http` (table with `requests` array and `responses` queue) and the functions `harness.stub(name, value)`, `harness.queueResponse(body, headers)` and `harness.reset()`. Every `tests/test_*.lua` file returns an array of `{ "<test name>", function() ... end }` pairs.

- [ ] **Step 1: Write the failing test**

Create `tests/test_settings.lua`. It pins behaviour `VenzAISettings.lua` has today, so a later task cannot break it silently:

```lua
-- Pins the behaviour VenzAISettings has before the provider rework, so that
-- Task 5 changes the shape of the configuration without changing these rules.

return {
    { "applyDefaults writes every default", function()
        harness.reset()
        local S = require 'VenzAISettings'
        S.applyDefaults()
        assert(harness.prefs.engine == "gemini", "engine default missing")
        assert(harness.prefs.refinementPasses == 3, "passes default missing")
    end },

    { "an empty string falls back to the default", function()
        harness.reset()
        local S = require 'VenzAISettings'
        harness.prefs.geminiAnalysisModel = ""
        assert(S.get("geminiAnalysisModel") == "gemini-2.5-pro",
            "empty string must not be treated as a value")
    end },

    { "refinement passes are clamped at both ends", function()
        harness.reset()
        local S = require 'VenzAISettings'
        harness.prefs.refinementPasses = 99
        assert(S.getRefinementPasses() == S.MAX_PASSES, "not clamped upwards")
        harness.prefs.refinementPasses = 0
        assert(S.getRefinementPasses() == S.MIN_PASSES, "not clamped downwards")
    end },

    { "the API key round-trips through LrPasswords, never through prefs", function()
        harness.reset()
        local S = require 'VenzAISettings'
        S.setApiKey("secret-value")
        assert(S.getApiKey() == "secret-value", "key did not round-trip")
        assert(harness.prefs.geminiApiKey == nil, "key must never land in prefs")
        assert(harness.passwords.geminiApiKey == "secret-value", "key not in LrPasswords")
    end },

    { "a legacy plain-text key is migrated out of prefs", function()
        harness.reset()
        local S = require 'VenzAISettings'
        harness.prefs.geminiApiKey = "legacy-key"
        assert(S.migrateApiKeyFromPrefs() == true, "migration did not report success")
        assert(harness.prefs.geminiApiKey == nil, "plain-text copy was left behind")
        assert(S.getApiKey() == "legacy-key", "key was lost in migration")
    end },
}
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `python tests/run.py`
Expected: FAIL — python cannot open `tests/run.py`. Nothing exists yet.

- [ ] **Step 3: Write the harness**

Create `tests/harness.lua`:

```lua
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
```

- [ ] **Step 4: Write the runner**

Create `tests/run.py`:

```python
"""Runs the VenzAI Lua test suites on a real Lua 5.1 interpreter.

Lightroom runs Lua 5.1 and ships no interpreter we can drive, and Adobe's
luac.exe is not installed here - it comes with the downloadable SDK, not with
the application. lupa embeds several Lua runtimes; lua51 is the one whose
dialect matches Lightroom, so a test that passes here is a test written in
the language the plug-in actually runs.

Usage:
    python tests/run.py                # every suite
    python tests/run.py contract json  # only suites whose name matches
"""

import glob
import sys
from pathlib import Path

from lupa import lua51

ROOT = Path(__file__).resolve().parent.parent
BUNDLE = ROOT / "VenzAI.lrdevplugin"
HARNESS = ROOT / "tests" / "harness.lua"


def run_suite(path):
    """Runs one suite file in its own runtime. Returns (passed, failed)."""
    runtime = lua51.LuaRuntime(unpack_returned_tuples=True)
    runtime.globals()["VENZAI_BUNDLE"] = BUNDLE.as_posix()
    runtime.execute(HARNESS.read_text(encoding="utf-8"))

    suite = runtime.execute(path.read_text(encoding="utf-8"))
    if suite is None:
        print("  ERROR  %s returned nothing; a suite must return an array of cases"
              % path.name)
        return 0, 1

    passed = failed = 0
    for index in range(1, len(suite) + 1):
        case = suite[index]
        name, body = case[1], case[2]
        try:
            body()
        except Exception as exc:  # a Lua assert arrives as a LuaError
            print("  FAIL  %s" % name)
            for line in str(exc).strip().splitlines():
                print("          %s" % line)
            failed += 1
        else:
            print("  PASS  %s" % name)
            passed += 1
    return passed, failed


def main():
    files = sorted(Path(p) for p in glob.glob(str(ROOT / "tests" / "test_*.lua")))
    if len(sys.argv) > 1:
        wanted = sys.argv[1:]
        files = [f for f in files if any(w in f.name for w in wanted)]
    if not files:
        print("no suites matched")
        return 1

    total_passed = total_failed = 0
    for path in files:
        print(path.name)
        passed, failed = run_suite(path)
        total_passed += passed
        total_failed += failed

    print("\n%d passed, %d failed" % (total_passed, total_failed))
    return 1 if total_failed else 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 5: Record the dependency**

`lupa` is already installed in this machine's Python, but a fresh clone needs
it. Create `tests/requirements.txt`:

```
# The Lua 5.1 interpreter the test harness runs on. Lightroom runs Lua 5.1 and
# ships no interpreter we can drive; Adobe's luac.exe comes with the
# downloadable SDK, not with the application. lupa embeds several runtimes and
# lua51 is the one whose dialect matches.
# Install with: python -m pip install -r tests/requirements.txt
lupa>=2.8
```

This is a development dependency of the repository. Nothing is added to the
plug-in bundle, which Lightroom loads on its own terms.

- [ ] **Step 6: Run the tests and make sure they pass**

Run: `python tests/run.py`
Expected: `test_settings.lua` with 5 PASS lines, then `5 passed, 0 failed`.

If `test harness has no stub for X` appears, add that namespace to `defaultStubs()` — the message naming the missing namespace is the harness working as intended.

- [ ] **Step 7: Commit**

```bash
git add tests/harness.lua tests/run.py tests/test_settings.lua tests/requirements.txt
git commit -m "test: run bundle modules outside Lightroom on real Lua 5.1"
```

---

### Task 2: VenzAIJson — JSON string escaping and unescaping

Three drivers each need to put a string into a payload and take one back out. The writing half already exists as `jsonEscape` at `VenzAIProcess.lua:1012` and moves here unchanged. The reading half is new, and it is what lets the contract promise a `response.text` that is already decoded — the promise that deletes the `gsub('\\"', '"')` hack.

**Files:**
- Create: `VenzAI.lrdevplugin/VenzAIJson.lua`
- Create: `tests/test_json.lua`
- Source of the escaper, to be deleted in Task 14: `VenzAIProcess.lua:1012-1029`

**Interfaces:**
- Consumes: nothing. This module imports no `Lr*` namespace, which is why it is fully testable.
- Produces: `Json.escape(s) -> '"<escaped>"'` (a complete quoted literal, quotes included); `Json.decode(content) -> string` (inverse of escape, on the content *without* surrounding quotes); `Json.readStringAt(body, openQuotePos) -> value, nextPos` or `nil`; `Json.stringValues(body, key) -> array of decoded strings` in order of appearance; `Json.stringValue(body, key) -> string` or `nil`.

> The code in Steps 3 and 1 below has been executed against the `lua51` runtime: all 14 cases pass. Use it as given.

- [ ] **Step 1: Write the failing test**

Create `tests/test_json.lua`:

```lua
local J = require 'VenzAIJson'

local BACKSLASH = string.char(92)
local QUOTE = string.char(34)

return {
    { "escape leaves a plain string alone", function()
        assert(J.escape("hello") == QUOTE .. "hello" .. QUOTE)
    end },

    { "escape turns a quote into backslash-quote", function()
        -- say "hi"  ->  "say \"hi\""
        local got = J.escape('say ' .. QUOTE .. 'hi' .. QUOTE)
        local want = QUOTE .. 'say ' .. BACKSLASH .. QUOTE .. 'hi' .. BACKSLASH .. QUOTE .. QUOTE
        assert(got == want, "got " .. got)
    end },

    { "escape turns a newline into the two characters backslash n", function()
        -- This is the bug string.format("%q") has: it emits a real line break.
        local got = J.escape("a\nb")
        local want = QUOTE .. "a" .. BACKSLASH .. "n" .. "b" .. QUOTE
        assert(got == want, "got " .. got .. " (len " .. #got .. ")")
        assert(#got == 6, "expected 6 characters, got " .. #got)
        assert(not got:find("\n", 1, true), "a real line break survived")
    end },

    { "escape doubles a backslash", function()
        local got = J.escape("a" .. BACKSLASH .. "b")
        local want = QUOTE .. "a" .. BACKSLASH .. BACKSLASH .. "b" .. QUOTE
        assert(got == want, "got " .. got)
    end },

    { "escape turns an other control character into \\u00xx", function()
        local got = J.escape("a" .. string.char(1) .. "b")
        local want = QUOTE .. "a" .. BACKSLASH .. "u0001" .. "b" .. QUOTE
        assert(got == want, "got " .. got)
    end },

    -- Reading. These are the cases the old gsub('\\"', '"') hack got wrong.
    { "nested JSON comes out intact", function()
        -- {"text": "{\"Exposure2012\": -0.25}"}
        local body = '{"text": ' .. QUOTE .. '{' .. BACKSLASH .. QUOTE
            .. 'Exposure2012' .. BACKSLASH .. QUOTE .. ': -0.25}' .. QUOTE .. '}'
        assert(J.stringValue(body, "text") == '{"Exposure2012": -0.25}',
            "got " .. tostring(J.stringValue(body, "text")))
    end },

    { "an escaped backslash stays a backslash and does not become a quote", function()
        -- The old hack turned \\" into a bare quote here and corrupted the value.
        local inner = 'C:' .. BACKSLASH .. BACKSLASH .. 'temp'
        local body = '{"text": ' .. QUOTE .. inner .. QUOTE .. '}'
        assert(J.stringValue(body, "text") == 'C:' .. BACKSLASH .. 'temp',
            "got " .. tostring(J.stringValue(body, "text")))
    end },

    { "backslash-n decodes to a real newline", function()
        local body = '{"text":' .. QUOTE .. 'a' .. BACKSLASH .. 'nb' .. QUOTE .. '}'
        assert(J.stringValue(body, "text") == "a\nb")
    end },

    { "several values come back in order", function()
        local body = '{"parts":[{"text":"first"},{"text":"second"}]}'
        local values = J.stringValues(body, "text")
        assert(#values == 2, "expected 2, got " .. #values)
        assert(values[1] == "first" and values[2] == "second")
    end },

    { "a missing key is nil, not an error", function()
        assert(J.stringValue('{"a":1}', "text") == nil)
    end },

    { "an unterminated literal yields nothing and does not hang", function()
        -- A body truncated mid-string, which is what a cut-off response is.
        local body = '{"text": ' .. QUOTE .. 'cut off here'
        assert(#J.stringValues(body, "text") == 0)
    end },

    { "escape and decode round-trip", function()
        local original = 'tab\there ' .. QUOTE .. 'q' .. QUOTE .. ' ' .. BACKSLASH .. ' back\nnew'
        local literal = J.escape(original)
        assert(J.decode(literal:sub(2, -2)) == original)
    end },

    { "a unicode escape decodes to UTF-8", function()
        local body = '{"text":' .. QUOTE .. 'caff' .. BACKSLASH .. 'u00e8' .. QUOTE .. '}'
        -- U+00E8 is 0xC3 0xA8 in UTF-8.
        assert(J.stringValue(body, "text") == "caff" .. string.char(195, 168),
            "got " .. tostring(J.stringValue(body, "text")))
    end },

    { "a lone surrogate half is dropped rather than emitted", function()
        local body = '{"text":' .. QUOTE .. 'a' .. BACKSLASH .. 'ud800b' .. QUOTE .. '}'
        assert(J.stringValue(body, "text") == "ab",
            "got " .. tostring(J.stringValue(body, "text")))
    end },
}
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `python tests/run.py json`
Expected: FAIL — `could not load VenzAI.lrdevplugin/VenzAIJson.lua`.

- [ ] **Step 3: Write the module**

Create `VenzAI.lrdevplugin/VenzAIJson.lua`:

```lua
--[[----------------------------------------------------------------------------

VenzAIJson.lua
JSON string escaping and unescaping, in both directions.

Every driver puts a string into a request payload and takes one back out of a
response, so both halves live here rather than once per driver.

Lua's string.format("%q", ...) does NOT produce a valid JSON escape: it turns
a newline into a backslash followed by a REAL line break, not into the
two-character sequence \n that JSON requires. Google tolerates it; Ollama's Go
parser answers 400. Hence the hand-written escaper, which was already in
VenzAIProcess before the drivers existed and is unchanged here.

Reading is the half that is new. The old code never extracted the model's
answer: it handed the whole HTTP body to the parser, which ran
gsub('\\"', '"') over it to neutralize the escaping of JSON nested inside
JSON. That is a guess, not a decoder - it turns \\" into a real quote too, and
leaves \n as two characters. readStringAt honours escapes properly, which is
what lets the driver contract promise a response.text that is already decoded.

------------------------------------------------------------------------------]]

local M = {}

--------------------------------------------------------------------------------
-- Writing
--------------------------------------------------------------------------------

-- Returns `s` as a complete, quoted JSON string literal.
function M.escape(s)
    local escaped = tostring(s):gsub('[%z\1-\31\\"]', function(c)
        if c == '\\' then return '\\\\'
        elseif c == '"' then return '\\"'
        elseif c == '\n' then return '\\n'
        elseif c == '\r' then return '\\r'
        elseif c == '\t' then return '\\t'
        else return string.format('\\u%04x', c:byte())
        end
    end)
    return '"' .. escaped .. '"'
end

--------------------------------------------------------------------------------
-- Reading
--------------------------------------------------------------------------------

local SIMPLE_ESCAPES = {
    ['"'] = '"', ['\\'] = '\\', ['/'] = '/',
    b = '\b', f = '\f', n = '\n', r = '\r', t = '\t',
}

-- UTF-8 encoding of one code point, for \uXXXX. Lightroom's strings are UTF-8.
-- Surrogate halves (D800..DFFF) are dropped rather than encoded: on their own
-- they are not a character, and a develop-parameter answer has no reason to
-- contain one. A model that emits an astral character loses it instead of
-- producing invalid UTF-8 that Lightroom would then have to survive.
local function utf8FromCodepoint(code)
    if code >= 0xD800 and code <= 0xDFFF then
        return ""
    elseif code < 0x80 then
        return string.char(code)
    elseif code < 0x800 then
        return string.char(0xC0 + math.floor(code / 0x40),
                           0x80 + (code % 0x40))
    else
        return string.char(0xE0 + math.floor(code / 0x1000),
                           0x80 + (math.floor(code / 0x40) % 0x40),
                           0x80 + (code % 0x40))
    end
end

-- Decodes the CONTENT of a JSON string literal, without its surrounding
-- quotes: the inverse of escape().
function M.decode(s)
    if not s:find('\\', 1, true) then return s end

    local out = {}
    local i, n = 1, #s
    while i <= n do
        local c = s:sub(i, i)
        if c ~= '\\' then
            table.insert(out, c)
            i = i + 1
        else
            local nextChar = s:sub(i + 1, i + 1)
            if nextChar == 'u' then
                local code = tonumber(s:sub(i + 2, i + 5), 16)
                if code then
                    table.insert(out, utf8FromCodepoint(code))
                    i = i + 6
                else
                    -- Malformed \u with no four hex digits: keep it literally
                    -- rather than swallowing the rest of the string.
                    table.insert(out, nextChar)
                    i = i + 2
                end
            elseif nextChar == '' then
                -- A trailing lone backslash, i.e. a truncated body.
                table.insert(out, '\\')
                i = i + 1
            else
                table.insert(out, SIMPLE_ESCAPES[nextChar] or nextChar)
                i = i + 2
            end
        end
    end
    return table.concat(out)
end

-- Reads the JSON string literal starting at `openQuotePos`, which must be the
-- index of its opening quote. Honours escapes, so an escaped quote inside the
-- value does not end it early. Returns the decoded value and the index just
-- past the closing quote, or nil if the literal is unterminated.
function M.readStringAt(body, openQuotePos)
    if body:sub(openQuotePos, openQuotePos) ~= '"' then return nil end
    local i, n = openQuotePos + 1, #body
    local startPos = i
    while i <= n do
        local c = body:sub(i, i)
        if c == '\\' then
            i = i + 2
        elseif c == '"' then
            return M.decode(body:sub(startPos, i - 1)), i + 1
        else
            i = i + 1
        end
    end
    return nil
end

-- Every value of `"<key>": "<string>"` in `body`, decoded, in order of
-- appearance. This is how a driver pulls the model's answer out of a response
-- without a full JSON parser: the key is unambiguous in each provider's
-- response shape, and reading the literal properly is what makes the old
-- gsub('\\"', '"') hack unnecessary.
--
-- `key` is interpolated into a Lua pattern, so it must be a plain word. Every
-- caller passes a fixed literal ("text", "data", "content", "mimeType").
function M.stringValues(body, key)
    local values = {}
    local pattern = '"' .. key .. '"%s*:%s*'
    local searchFrom = 1
    while true do
        local _, matchEnd = body:find(pattern, searchFrom)
        if not matchEnd then break end
        local value, nextPos = M.readStringAt(body, matchEnd + 1)
        if value then
            table.insert(values, value)
            searchFrom = nextPos
        else
            searchFrom = matchEnd + 1
        end
    end
    return values
end

-- The first value of `"<key>": "<string>"`, or nil. Convenience for the
-- common case of a key that appears once.
function M.stringValue(body, key)
    local values = M.stringValues(body, key)
    return values[1]
end

return M
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `python tests/run.py json`
Expected: 14 PASS, `14 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add VenzAI.lrdevplugin/VenzAIJson.lua tests/test_json.lua
git commit -m "feat: JSON string escaping and unescaping in one module

The escaper moves out of VenzAIProcess unchanged; the decoder is new and is
what lets a driver return an already-unescaped text, replacing the
gsub('\\\\\"', '\"') guess that also collapsed an escaped backslash."
```

---

### Task 3: VenzAIProviderContract — shapes, the closed error set, and the call funnel

This is the file the whole design rests on. It defines what a driver is, checks one at load time, and guarantees the engine a well-formed Response no matter how a driver misbehaves.

**Files:**
- Create: `VenzAI.lrdevplugin/VenzAIProviderContract.lua`
- Create: `tests/test_contract.lua`

**Interfaces:**
- Consumes: `VenzAILog.scoped(prefix)` from `VenzAILog.lua`.
- Produces:
  - `Contract.ERROR_KINDS` — the closed set, as a set-shaped table.
  - `Contract.CAPABILITIES` — `{ analyze, generateReference, listModels }`.
  - `Contract.FIELD_ROLES` — `{ secret, model, url, text }`.
  - `Contract.failure(errorKind, errorDetail, reasonKey, httpStatus) -> Response`.
  - `Contract.success({ text, image, truncated, httpStatus }) -> Response`.
  - `Contract.validateResponse(response, method) -> ok, problem`.
  - `Contract.validateDriver(driver) -> ok, problem`.
  - `Contract.call(driver, method, request, config) -> Response`.

A Response is always `{ ok, text, image, truncated, httpStatus, errorKind, errorDetail, reasonKey }`. `text` is already unescaped. Every driver in Tasks 9–11 builds its Responses through `Contract.success` and `Contract.failure` and never assembles the table by hand.

> The code in Steps 3 and 1 below has been executed against the `lua51` runtime: all 25 cases pass. Use it as given.

- [ ] **Step 1: Write the failing test**

Create `tests/test_contract.lua`:

```lua
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
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `python tests/run.py contract`
Expected: FAIL — `could not load VenzAI.lrdevplugin/VenzAIProviderContract.lua`.

- [ ] **Step 3: Write the module**

Create `VenzAI.lrdevplugin/VenzAIProviderContract.lua`:

```lua
--[[----------------------------------------------------------------------------

VenzAIProviderContract.lua
The shapes every provider driver conforms to, and the funnel every call goes
through.

A driver owns the protocol: serialization, auth, HTTP, extracting text and
images, and classifying failures. It owns nothing else. Parsing, validation
and applying settings to the photo stay shared and downstream of every driver,
because they are the plug-in's only defence against a model answering
Temperature = 8, and two copies of them would eventually diverge.

The engine NEVER calls a driver method directly. It calls M.call, which
guarantees a well-formed Response whatever the driver does - including
raising. A buggy driver can fail; it cannot abort a run halfway and leave the
photo in an intermediate state.

Invariant: a driver returns CODES, never prose. Nothing in this file builds a
sentence for a human; VenzAIMessages turns a code into a localized message.
The one exception is validateDriver's `problem` string, which is a developer
diagnostic for a malformed driver - a programming error, reported to the log,
never shown as a user-facing message.

------------------------------------------------------------------------------]]

local VenzAILog = require 'VenzAILog'
local log = VenzAILog.scoped("Contract")

local M = {}

--------------------------------------------------------------------------------
-- The closed sets
--------------------------------------------------------------------------------

-- Closed on purpose, twice over: it is the set of conditions the engine knows
-- how to react to, and it is the list of messages to translate.
M.ERROR_KINDS = {
    config_invalid = true,  -- a required field is missing or malformed
    unreachable    = true,  -- DNS, connection refused, TLS, timeout
    auth           = true,  -- missing or rejected credentials
    rate_limited   = true,  -- quota exhausted or too many requests
    model_missing  = true,  -- the configured model does not exist there
    bad_request    = true,  -- malformed payload: our bug, not the user's
    server_error   = true,  -- provider 5xx
    empty          = true,  -- HTTP 200 with no usable text
    driver_fault   = true,  -- the driver raised, or returned a bad Response
    not_supported  = true,  -- a capability the driver does not declare
    unknown        = true,  -- anything else
}

M.CAPABILITIES = {
    analyze = true,
    generateReference = true,
    listModels = true,
}

-- 'secret' persists through LrPasswords and renders a password_field; every
-- other role persists through LrPrefs and renders an edit_field. 'model' also
-- gets the "Detect models" button when the driver declares listModels.
M.FIELD_ROLES = {
    secret = true,
    model  = true,
    url    = true,
    text   = true,
}

--------------------------------------------------------------------------------
-- Response constructors
--------------------------------------------------------------------------------

-- A Response always has the same shape, whatever happened.
function M.failure(errorKind, errorDetail, reasonKey, httpStatus)
    if not M.ERROR_KINDS[errorKind] then
        -- A driver naming a kind outside the closed set is itself a fault, but
        -- it must not become a Lua error at this depth: coerce it, and keep
        -- the original name where a human reading the log will find it.
        errorDetail = string.format("[errorKind '%s' is not in the closed set] %s",
            tostring(errorKind), tostring(errorDetail))
        errorKind = "unknown"
    end
    return {
        ok = false,
        text = nil,
        image = nil,
        truncated = false,
        httpStatus = httpStatus,
        errorKind = errorKind,
        errorDetail = errorDetail,
        reasonKey = reasonKey,
    }
end

function M.success(fields)
    return {
        ok = true,
        text = fields.text,
        image = fields.image,
        truncated = fields.truncated and true or false,
        httpStatus = fields.httpStatus,
        errorKind = nil,
        errorDetail = nil,
        reasonKey = nil,
    }
end

--------------------------------------------------------------------------------
-- Shape validation
--------------------------------------------------------------------------------

local function isNonEmptyString(value)
    return type(value) == "string" and value ~= ""
end

-- Checks what the engine is about to rely on. Returns ok, problem.
function M.validateResponse(response, method)
    if type(response) ~= "table" then
        return false, string.format("expected a table, got %s", type(response))
    end
    if type(response.ok) ~= "boolean" then
        return false, "field 'ok' must be a boolean"
    end

    if not response.ok then
        if not M.ERROR_KINDS[response.errorKind] then
            return false, string.format("errorKind '%s' is not in the closed set",
                tostring(response.errorKind))
        end
        return true
    end

    if method == "analyze" then
        if not isNonEmptyString(response.text) then
            return false, "a successful analyze must carry a non-empty text"
        end
    elseif method == "generateReference" then
        local image = response.image
        if type(image) ~= "table"
            or not isNonEmptyString(image.data)
            or not isNonEmptyString(image.mimeType) then
            return false, "a successful generateReference must carry image.data and image.mimeType"
        end
    end

    return true
end

-- Runs for every registered driver when the registry loads, so a malformed
-- driver is reported once and precisely instead of failing obscurely halfway
-- through a photograph. Returns ok, problem.
function M.validateDriver(driver)
    if type(driver) ~= "table" then
        return false, string.format("a driver must be a table, got %s", type(driver))
    end
    if not isNonEmptyString(driver.id) then
        return false, "missing 'id'"
    end
    if not isNonEmptyString(driver.displayName) then
        return false, string.format("driver '%s' is missing 'displayName'", driver.id)
    end
    if type(driver.validate) ~= "function" then
        return false, string.format("driver '%s' is missing the function 'validate'", driver.id)
    end
    if type(driver.defaultTimeout) ~= "number" or driver.defaultTimeout <= 0 then
        return false, string.format("driver '%s' needs a positive 'defaultTimeout'", driver.id)
    end

    if type(driver.capabilities) ~= "table" then
        return false, string.format("driver '%s' is missing 'capabilities'", driver.id)
    end
    for name, enabled in pairs(driver.capabilities) do
        if not M.CAPABILITIES[name] then
            return false, string.format("driver '%s' declares the unknown capability '%s'",
                driver.id, tostring(name))
        end
        if enabled and type(driver[name]) ~= "function" then
            return false, string.format("driver '%s' declares '%s' but has no such function",
                driver.id, name)
        end
    end
    if not driver.capabilities.analyze then
        return false, string.format("driver '%s' must declare the capability 'analyze'", driver.id)
    end

    if type(driver.settingsFields) ~= "table" then
        return false, string.format("driver '%s' is missing 'settingsFields'", driver.id)
    end
    for index, field in ipairs(driver.settingsFields) do
        if type(field) ~= "table" then
            return false, string.format("driver '%s': settingsFields[%d] is not a table",
                driver.id, index)
        end
        if not isNonEmptyString(field.key) then
            return false, string.format("driver '%s': settingsFields[%d] has no 'key'",
                driver.id, index)
        end
        if not M.FIELD_ROLES[field.role] then
            return false, string.format("driver '%s': field '%s' has the unknown role '%s'",
                driver.id, field.key, tostring(field.role))
        end
        if not isNonEmptyString(field.label) then
            return false, string.format("driver '%s': field '%s' has no 'label'",
                driver.id, field.key)
        end
        if field.default ~= nil and type(field.default) ~= "string" then
            return false, string.format("driver '%s': field '%s' has a non-string default",
                driver.id, field.key)
        end
        if field.role == "secret" and field.default ~= nil then
            return false, string.format("driver '%s': secret field '%s' must not have a default",
                driver.id, field.key)
        end
    end

    return true
end

--------------------------------------------------------------------------------
-- The call funnel
--------------------------------------------------------------------------------

-- The only way the engine reaches a driver. In order: the capability must be
-- declared, the config must validate, the method runs under pcall, and the
-- value it returns must match the Response shape. Anything else becomes a
-- Response the engine can handle, and the log names the driver and the method
-- rather than showing an anonymous stack trace.
function M.call(driver, method, request, config)
    local driverId = (type(driver) == "table" and tostring(driver.id)) or "<not a driver>"

    if type(driver) ~= "table"
        or type(driver.capabilities) ~= "table"
        or not driver.capabilities[method] then
        log(string.format("%s does not declare the capability '%s'.", driverId, tostring(method)))
        return M.failure("not_supported",
            string.format("driver '%s' does not declare '%s'", driverId, tostring(method)))
    end

    if type(driver.validate) ~= "function" then
        log(string.format("%s has no validate function.", driverId))
        return M.failure("driver_fault", string.format("driver '%s' has no validate function", driverId))
    end

    local validateOk, valid, reasonKey = pcall(driver.validate, config)
    if not validateOk then
        log(string.format("%s.validate raised: %s", driverId, tostring(valid)))
        return M.failure("driver_fault", tostring(valid))
    end
    if not valid then
        log(string.format("%s: configuration rejected (%s).", driverId, tostring(reasonKey)))
        return M.failure("config_invalid", nil, reasonKey or "config_unspecified")
    end

    local callOk, result = pcall(driver[method], request, config)
    if not callOk then
        log(string.format("%s.%s raised: %s", driverId, method, tostring(result)))
        return M.failure("driver_fault", tostring(result))
    end

    local shapeOk, problem = M.validateResponse(result, method)
    if not shapeOk then
        log(string.format("%s.%s returned a malformed Response: %s", driverId, method, problem))
        return M.failure("driver_fault", problem)
    end

    return result
end

return M
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `python tests/run.py contract`
Expected: 25 PASS, `25 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add VenzAI.lrdevplugin/VenzAIProviderContract.lua tests/test_contract.lua
git commit -m "feat: the provider driver contract and its call funnel

A driver declares capabilities and settings fields and returns codes, never
prose. Contract.call checks the capability, validates the config, runs the
method under pcall and checks the Response shape, so a buggy driver can fail
but cannot abort a run halfway."
```

---

### Task 4: VenzAIMessages — the only place a code becomes a sentence

**Files:**
- Create: `VenzAI.lrdevplugin/VenzAIMessages.lua`
- Create: `tests/test_messages.lua`

**Interfaces:**
- Consumes: `Contract.ERROR_KINDS`.
- Produces: `Messages.forError(errorKind, providerNameKey, modelName, reasonKey) -> title, body`; `Messages.forDriverProblem(problem) -> title, body`; `Messages.technicalSection(errorDetail) -> string` (empty when `errorDetail` is nil); `Messages.ERROR_MESSAGES` (exposed only so the test can check completeness).

`providerNameKey` is the driver's `displayName`, still a LOC key: `Messages` localizes it. Callers never concatenate it into a sentence.

- [ ] **Step 1: Write the failing test**

Create `tests/test_messages.lua`:

```lua
local Contract = require 'VenzAIProviderContract'
local Messages = require 'VenzAIMessages'

return {
    { "every errorKind in the closed set has a message", function()
        -- The set is closed partly so that this list is finite and translatable.
        -- A new kind with no message would otherwise reach a user as a blank dialog.
        local missing = {}
        for kind in pairs(Contract.ERROR_KINDS) do
            local entry = Messages.ERROR_MESSAGES[kind]
            if not entry or not entry.title or not entry.body then
                table.insert(missing, kind)
            end
        end
        assert(#missing == 0, "no message for: " .. table.concat(missing, ", "))
    end },

    { "no message is defined for a kind outside the set", function()
        local extra = {}
        for kind in pairs(Messages.ERROR_MESSAGES) do
            if not Contract.ERROR_KINDS[kind] then table.insert(extra, kind) end
        end
        assert(#extra == 0, "message for unknown kind: " .. table.concat(extra, ", "))
    end },

    { "the provider name is substituted, not concatenated", function()
        local title, body = Messages.forError("rate_limited",
            "$$$/VenzAI/Provider/Gemini/Name=Gemini", "gemini-2.5-pro")
        assert(title ~= nil and title ~= "", "no title")
        assert(body:find("Gemini", 1, true), "the provider name is missing from the body")
        assert(not body:find("^1", 1, true), "an unsubstituted placeholder survived")
        assert(not body:find("$$$", 1, true), "a raw LOC key leaked into the body")
    end },

    { "the model name is substituted where a message uses it", function()
        local _, body = Messages.forError("model_missing",
            "$$$/VenzAI/Provider/Ollama/Name=Ollama", "qwen2.5vl:latest")
        assert(body:find("qwen2.5vl:latest", 1, true), "the model name is missing")
    end },

    { "config_invalid explains which field is wrong", function()
        local _, withReason = Messages.forError("config_invalid",
            "$$$/VenzAI/Provider/Gemini/Name=Gemini", "gemini-2.5-pro", "missing_api_key")
        local _, withoutReason = Messages.forError("config_invalid",
            "$$$/VenzAI/Provider/Gemini/Name=Gemini", "gemini-2.5-pro")
        assert(withReason ~= withoutReason,
            "the reasonKey must change the message, otherwise carrying it forward is pointless")
        assert(not withReason:find("$$$", 1, true), "a raw LOC key leaked")
    end },

    { "an unknown reasonKey degrades to a generic sentence rather than a blank", function()
        local _, body = Messages.forError("config_invalid",
            "$$$/VenzAI/Provider/Gemini/Name=Gemini", "m", "some_key_nobody_defined")
        assert(body ~= nil and body ~= "", "empty body")
        assert(not body:find("$$$", 1, true), "a raw LOC key leaked")
    end },

    { "the technical section is omitted when there is no detail", function()
        assert(Messages.technicalSection(nil) == "", "expected an empty string")
        local section = Messages.technicalSection("HTTP 429 quota exceeded for project 42")
        assert(section:find("HTTP 429", 1, true), "the raw detail must survive verbatim")
    end },
}
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `python tests/run.py messages`
Expected: FAIL — `could not load VenzAI.lrdevplugin/VenzAIMessages.lua`.

- [ ] **Step 3: Write the module**

Create `VenzAI.lrdevplugin/VenzAIMessages.lua`:

```lua
--[[----------------------------------------------------------------------------

VenzAIMessages.lua
The single catalog mapping a code to a localized title and body.

Drivers return codes; this is the only file that turns one into a sentence.
Nothing here concatenates: word order differs between languages, so
"error on " .. provider .. ": " .. reason is untranslatable by construction.
Every sentence is one LOC key with ^1..^3 placeholders.

^1 is the provider's display name, itself a LOC key so that it is localized
too. ^2 is the model name. ^3, where a message uses it, is the explanation of
which setting is wrong.

errorDetail is NOT translated and NOT part of these sentences. It is the
provider's own raw text, shown below the message in a clearly marked technical
section. The localized message must be sufficient on its own: if the user has
to read Google's JSON to know what to do, the message is wrong.

------------------------------------------------------------------------------]]

local M = {}

-- One entry per errorKind of the closed set in VenzAIProviderContract. A kind
-- with no entry here would reach the user as a blank dialog, which is what
-- tests/test_messages.lua exists to prevent.
M.ERROR_MESSAGES = {
    config_invalid = {
        title = "$$$/VenzAI/Error/Kind/ConfigInvalid/Title=VenzAI is not ready to run",
        body = "$$$/VenzAI/Error/Kind/ConfigInvalid/Body=^1 cannot be used with the current settings.\n\n^3\n\nOpen File > Plug-in Manager > VenzAI to correct it.",
    },
    unreachable = {
        title = "$$$/VenzAI/Error/Kind/Unreachable/Title=VenzAI could not reach ^1",
        body = "$$$/VenzAI/Error/Kind/Unreachable/Body=No answer came back from ^1.\n\nCheck your network connection, and that the address in the plug-in settings is correct and the service is running.",
    },
    auth = {
        title = "$$$/VenzAI/Error/Kind/Auth/Title=^1 rejected the credentials",
        body = "$$$/VenzAI/Error/Kind/Auth/Body=^1 did not accept the API key.\n\nCheck the key in File > Plug-in Manager > VenzAI. A key that was working may have been revoked, or may not be enabled for the model '^2'.",
    },
    rate_limited = {
        title = "$$$/VenzAI/Error/Kind/RateLimited/Title=^1 is rate limiting VenzAI",
        body = "$$$/VenzAI/Error/Kind/RateLimited/Body=^1 refused the request because the quota is exhausted or too many requests arrived too quickly.\n\nWait and run VenzAI again. Nothing was applied to the photo by this pass.",
    },
    model_missing = {
        title = "$$$/VenzAI/Error/Kind/ModelMissing/Title=The model '^2' does not exist on ^1",
        body = "$$$/VenzAI/Error/Kind/ModelMissing/Body=^1 does not know a model called '^2'.\n\nCorrect the model name in File > Plug-in Manager > VenzAI. The 'Detect models' button next to the field lists the names that service currently offers.",
    },
    bad_request = {
        title = "$$$/VenzAI/Error/Kind/BadRequest/Title=^1 rejected the request as malformed",
        body = "$$$/VenzAI/Error/Kind/BadRequest/Body=^1 answered that the request VenzAI built is not valid.\n\nThis is a fault in the plug-in rather than in your settings. The technical detail below is what the service reported.",
    },
    server_error = {
        title = "$$$/VenzAI/Error/Kind/ServerError/Title=^1 reported an internal error",
        body = "$$$/VenzAI/Error/Kind/ServerError/Body=^1 failed on its own side.\n\nThis is usually temporary; running VenzAI again later is the remedy.",
    },
    empty = {
        title = "$$$/VenzAI/Error/Kind/Empty/Title=^1 answered without any content",
        body = "$$$/VenzAI/Error/Kind/Empty/Body=^1 accepted the request but returned no usable answer.\n\nThis happens when a safety filter blocks the response, or when the model '^2' cannot see images. Try another model.",
    },
    driver_fault = {
        title = "$$$/VenzAI/Error/Kind/DriverFault/Title=VenzAI failed while talking to ^1",
        body = "$$$/VenzAI/Error/Kind/DriverFault/Body=The part of VenzAI that speaks to ^1 failed.\n\nThis is a fault in the plug-in rather than in your settings, and the photo keeps whatever earlier passes applied. The technical detail below identifies where.",
    },
    not_supported = {
        title = "$$$/VenzAI/Error/Kind/NotSupported/Title=^1 does not support that step",
        body = "$$$/VenzAI/Error/Kind/NotSupported/Body=^1 does not offer the capability VenzAI asked for.\n\nThis is a fault in the plug-in: a step was requested that this provider never declared.",
    },
    unknown = {
        title = "$$$/VenzAI/Error/Kind/Unknown/Title=^1 failed for an unrecognized reason",
        body = "$$$/VenzAI/Error/Kind/Unknown/Body=^1 failed in a way VenzAI does not recognize.\n\nThe technical detail below is the raw report from the service.",
    },
}

-- Explanations for the reasonKey a driver's validate() returns. These are the
-- ^3 of config_invalid: the user is told WHICH field is wrong, not merely that
-- the configuration is invalid.
local CONFIG_REASONS = {
    missing_config = "$$$/VenzAI/Error/Reason/MissingConfig=No settings were found for this provider.",
    missing_api_key = "$$$/VenzAI/Error/Reason/MissingApiKey=The API key is empty.",
    missing_model = "$$$/VenzAI/Error/Reason/MissingModel=No analysis model is set.",
    missing_image_model = "$$$/VenzAI/Error/Reason/MissingImageModel=No reference image model is set.",
    missing_base_url = "$$$/VenzAI/Error/Reason/MissingBaseUrl=The server address is empty.",
    invalid_base_url = "$$$/VenzAI/Error/Reason/InvalidBaseUrl=The server address must start with http:// or https://.",
    config_unspecified = "$$$/VenzAI/Error/Reason/Unspecified=A required setting is missing or malformed.",
}

-- Returns title, body. `providerNameKey` is the driver's displayName, still a
-- LOC key; `reasonKey` is used only by the messages that carry a ^3.
function M.forError(errorKind, providerNameKey, modelName, reasonKey)
    local entry = M.ERROR_MESSAGES[errorKind] or M.ERROR_MESSAGES.unknown
    local providerName = LOC(providerNameKey or "$$$/VenzAI/Provider/Unknown/Name=the AI service")
    local model = modelName or ""
    -- An unrecognized reasonKey degrades to the generic sentence rather than
    -- leaving a hole in the middle of the message.
    local reason = LOC(CONFIG_REASONS[reasonKey] or CONFIG_REASONS.config_unspecified)

    return LOC(entry.title, providerName, model, reason),
           LOC(entry.body, providerName, model, reason)
end

-- A malformed driver is a programming error, not a user's mistake, so it gets
-- one message and the developer diagnostic goes in the technical section.
function M.forDriverProblem(problem)
    return LOC "$$$/VenzAI/Error/DriverProblem/Title=A VenzAI provider is misconfigured",
           LOC("$$$/VenzAI/Error/DriverProblem/Body=One of VenzAI's providers does not match the interface the plug-in expects, so it was not loaded.\n\n^1",
               tostring(problem))
end

-- The provider's own raw text, under a localized heading, kept separate from
-- the translated message above it. Empty when there is nothing to show, so a
-- caller can always append it unconditionally.
function M.technicalSection(errorDetail)
    if errorDetail == nil or errorDetail == "" then return "" end
    return LOC("$$$/VenzAI/Error/TechnicalSection=\n\nTechnical detail reported by the service:\n^1",
        tostring(errorDetail))
end

return M
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `python tests/run.py messages`
Expected: 7 PASS, `7 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add VenzAI.lrdevplugin/VenzAIMessages.lua tests/test_messages.lua
git commit -m "feat: one catalog from error code to localized message"
```

---

### Task 5: VenzAISettings — per-provider, declaration-driven configuration

**Files:**
- Modify: `VenzAI.lrdevplugin/VenzAISettings.lua` (replace `DEFAULTS`, `snapshot`, `getApiKey`/`setApiKey`, `migrateApiKeyFromPrefs`)
- Modify: `tests/test_settings.lua` (the suite from Task 1 pins the old shape and must change with it — see Step 1)

**Interfaces:**
- Consumes: `Contract.FIELD_ROLES` for the role check.
- Produces:
  - `Settings.DEFAULTS` — now only `{ activeProvider = "gemini", refinementPasses = 3 }`.
  - `Settings.getActiveProviderId() -> string`, `Settings.setActiveProviderId(id)`.
  - `Settings.providerConfig(driverId, settingsFields) -> table` keyed by each field's `key`.
  - `Settings.getProviderField(driverId, field) -> string`, `Settings.setProviderField(driverId, field, value)` — used by the panel, which needs one field at a time.
  - `Settings.purgeLegacyPlainTextKey() -> boolean`.
  - Unchanged: `applyDefaults`, `get`, `set`, `getRefinementPasses`, `MIN_PASSES`, `MAX_PASSES`.
- Removed: `snapshot`, `getApiKey`, `setApiKey`, `migrateApiKeyFromPrefs`, and the `engine`/`gemini*`/`ollama*` defaults.

**On migration:** §3 and §8.3 of the spec say there is none, and there is none — no old pref is read into a new key, and the user re-enters the API key once. `purgeLegacyPlainTextKey` is not a migration: it *deletes* `prefs.geminiApiKey` without reading it anywhere. Honouring "no migration" by leaving it in place would leave a plain-text credential in the preferences file forever, which is the exact problem `LrPasswords` was adopted to solve.

- [ ] **Step 1: Update the Task 1 suite to the new shape**

In `tests/test_settings.lua`, replace the last two cases — they name functions this task removes — with these. Keep the first three unchanged; they still hold.

```lua
    { "the active provider defaults to gemini", function()
        harness.reset()
        local S = require 'VenzAISettings'
        S.applyDefaults()
        assert(S.getActiveProviderId() == "gemini", "got " .. tostring(S.getActiveProviderId()))
    end },

    { "a legacy plain-text API key is deleted, not migrated", function()
        harness.reset()
        local S = require 'VenzAISettings'
        harness.prefs.geminiApiKey = "legacy-key"
        assert(S.purgeLegacyPlainTextKey() == true, "did not report a purge")
        assert(harness.prefs.geminiApiKey == nil, "the plain-text key is still on disk")
        -- Deliberately NOT carried over: the spec rules out migration, and the
        -- key is re-entered once. What must not happen is it lingering in a
        -- plain-text file.
        assert(harness.passwords["provider.gemini.apiKey"] == nil,
            "the legacy key must not be migrated into LrPasswords")
    end },

    { "a provider config is built from the driver's declared fields", function()
        harness.reset()
        local S = require 'VenzAISettings'
        local fields = {
            { key = "apiKey", role = "secret", label = "$$$/x=Key" },
            { key = "model", role = "model", default = "m-1", label = "$$$/x=Model" },
            { key = "baseUrl", role = "url", default = "http://localhost", label = "$$$/x=URL" },
        }
        harness.passwords["provider.fake.apiKey"] = "stored-secret"
        harness.prefs["provider.fake.model"] = "m-2"
        local config = S.providerConfig("fake", fields)
        assert(config.apiKey == "stored-secret", "secret not read from LrPasswords")
        assert(config.model == "m-2", "pref value not read")
        assert(config.baseUrl == "http://localhost", "declared default not applied")
    end },

    { "an empty stored value falls back to the declared default", function()
        harness.reset()
        local S = require 'VenzAISettings'
        harness.prefs["provider.fake.model"] = ""
        local config = S.providerConfig("fake", {
            { key = "model", role = "model", default = "m-1", label = "$$$/x=Model" },
        })
        assert(config.model == "m-1", "empty string was treated as a value")
    end },

    { "a secret with nothing stored comes back as an empty string, not nil", function()
        -- validate() compares against "", and a nil here would make every
        -- driver's check have to handle two shapes of absence.
        harness.reset()
        local S = require 'VenzAISettings'
        local config = S.providerConfig("fake", {
            { key = "apiKey", role = "secret", label = "$$$/x=Key" },
        })
        assert(config.apiKey == "", "got " .. tostring(config.apiKey))
    end },

    { "a secret is written to LrPasswords and a normal field to prefs", function()
        harness.reset()
        local S = require 'VenzAISettings'
        S.setProviderField("fake", { key = "apiKey", role = "secret", label = "$$$/x=K" }, "s3cret")
        S.setProviderField("fake", { key = "model", role = "model", label = "$$$/x=M" }, "m-9")
        assert(harness.passwords["provider.fake.apiKey"] == "s3cret", "secret not in LrPasswords")
        assert(harness.prefs["provider.fake.apiKey"] == nil, "a secret must never reach prefs")
        assert(harness.prefs["provider.fake.model"] == "m-9", "field not in prefs")
    end },

    { "two providers with the same field name do not collide", function()
        harness.reset()
        local S = require 'VenzAISettings'
        local field = { key = "model", role = "model", label = "$$$/x=M" }
        S.setProviderField("alpha", field, "a-model")
        S.setProviderField("beta", field, "b-model")
        assert(S.providerConfig("alpha", { field }).model == "a-model")
        assert(S.providerConfig("beta", { field }).model == "b-model")
    end },
```

- [ ] **Step 2: Run the suite to see the new cases fail**

Run: `python tests/run.py settings`
Expected: the three original cases PASS; the new ones FAIL with `attempt to call field 'getActiveProviderId' (a nil value)` and similar.

- [ ] **Step 3: Rework the module**

In `VenzAI.lrdevplugin/VenzAISettings.lua`: keep the file header (updating the paragraph about the Gemini key to speak of secrets in general), keep `prefs`, `valueOr`, `applyDefaults`, `get`, `set`, `getRefinementPasses`, `MIN_PASSES` and `MAX_PASSES` as they are, and replace everything else with:

```lua
M.DEFAULTS = {
    activeProvider = "gemini",
    refinementPasses = 3,
}

-- Per-provider settings are namespaced by driver id, so two providers can both
-- declare a field called "model" without colliding, and removing a driver
-- leaves an inert island of prefs rather than a conflict.
local function prefKey(driverId, fieldKey)
    return string.format("provider.%s.%s", tostring(driverId), tostring(fieldKey))
end

function M.getActiveProviderId()
    return valueOr(prefs.activeProvider, M.DEFAULTS.activeProvider)
end

function M.setActiveProviderId(id)
    prefs.activeProvider = id
end

-- Reads one declared field. A secret comes from LrPasswords, everything else
-- from LrPrefs. A secret never falls back to a default - the contract forbids
-- a default for one - and comes back as "" when unset, so every driver's
-- validate() has a single shape of absence to check.
function M.getProviderField(driverId, field)
    if field.role == "secret" then
        local ok, value = pcall(function()
            return LrPasswords.retrieve(prefKey(driverId, field.key))
        end)
        if not ok then
            log("LrPasswords.retrieve failed for " .. prefKey(driverId, field.key) .. ": " .. tostring(value))
            return ""
        end
        return value or ""
    end
    return valueOr(prefs[prefKey(driverId, field.key)], field.default or "")
end

function M.setProviderField(driverId, field, value)
    if field.role == "secret" then
        local ok, err = pcall(function()
            LrPasswords.store(prefKey(driverId, field.key), value or "")
        end)
        if not ok then
            log("LrPasswords.store failed for " .. prefKey(driverId, field.key) .. ": " .. tostring(err))
            return false
        end
        return true
    end
    prefs[prefKey(driverId, field.key)] = value
    return true
end

-- The `config` of the driver contract: one flat table keyed by each declared
-- field's own key. Built from the declaration, so adding a field to a driver
-- is a change in that driver and nowhere else.
function M.providerConfig(driverId, settingsFields)
    local config = {}
    for _, field in ipairs(settingsFields or {}) do
        config[field.key] = M.getProviderField(driverId, field)
    end
    return config
end

-- Deletes the plain-text API key an earlier version kept in prefs.geminiApiKey.
-- This is NOT a migration - the value is never read anywhere, and the key is
-- re-entered once, as the design states. It is deleted rather than ignored
-- because a credential sitting in a plain-text preferences file is the exact
-- problem LrPasswords was adopted to solve, and ignoring it would leave it
-- there forever.
function M.purgeLegacyPlainTextKey()
    if prefs.geminiApiKey == nil then return false end
    prefs.geminiApiKey = nil
    log("Removed the plain-text Gemini API key left in LrPrefs by an earlier version. Re-enter the key in the plug-in settings.")
    return true
end
```

Delete `M.snapshot`, `M.getApiKey`, `M.setApiKey`, `M.migrateApiKeyFromPrefs` and the `API_KEY_STORE_KEY` constant.

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `python tests/run.py settings`
Expected: 10 PASS, `10 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add VenzAI.lrdevplugin/VenzAISettings.lua tests/test_settings.lua
git commit -m "feat: configuration built from each driver's declared fields

snapshot() named seven Gemini and Ollama fields, so provider #4 would have had
to touch it. providerConfig reads whatever a driver declares instead. The
legacy plain-text key is deleted rather than migrated."
```

---

### Tasks 6, 7 and 8: the shared shape

These three move existing, working code out of `VenzAIProcess.lua` into modules, with no behaviour change. They are separate tasks because a reviewer could reasonably accept one and reject another, and because each shrinks the file that Task 14 then rewrites.

**Execute Task 7 before Task 6.** `readCurrentSettings`, which Task 6 moves, iterates `VALID_KEYS` and `STRING_VALID_KEYS`, which Task 7 moves. The vocabulary of "which develop parameters do we manage" is one thing and both the prompt and the parser need it, so `VenzAIPrompts` requires `VenzAIParse` and reads it from there rather than keeping a second copy that would drift. Task 7 therefore also exports `Parse.VALID_KEYS` and `Parse.STRING_VALID_KEYS`.

Each follows the same shape, so it is written once here:

1. Create the new file with the standard header comment naming what it owns and why it left `VenzAIProcess`.
2. Move the listed line range **verbatim**. Do not reword, reformat or "improve" it — a behaviour change hidden inside a move is the one thing that makes a move unreviewable.
3. Change each moved `local function foo` into `function M.foo` **only** for the names another module calls (listed per task). Names used only inside the module stay `local`.
4. Add `local M = {}` after the header and `return M` at the end.
5. Add the module's `require` line to `VenzAIProcess.lua` and prefix its call sites. Do not delete the original lines until Task 14; until then `VenzAIProcess` requires the module and the moved copy is the one that runs.
6. Run the full suite: `python tests/run.py`. Nothing should change.
7. Commit.

### Task 6: VenzAIPrompts

Follows the shared shape above. Execute AFTER Task 7: this module requires `VenzAIParse` for the parameter vocabulary.

- [ ] **Move the code** — move `VenzAIProcess.lua:214-478`: `PARAM_RULES`, `buildNanoBananaPrompt`, `SETTINGS_NOT_REPORTED`, `readCurrentSettings`, `buildAnalysisPrompt`. Exported: `M.buildReferencePrompt` (renamed from `buildNanoBananaPrompt` — the engine must not name a provider's model, and "Nano Banana" is Gemini's), `M.readCurrentSettings`, `M.buildAnalysisPrompt`. `readCurrentSettings` reads the photo through `photo:getDevelopSettings()`, so its test needs a stub photo:

```lua
-- tests/test_prompts.lua
local Prompts = require 'VenzAIPrompts'

local function fakePhoto(settings)
    return { getDevelopSettings = function() return settings end }
end

return {
    { "the analysis prompt is in English and asks for JSON only", function()
        local prompt = Prompts.buildAnalysisPrompt(1, 3, false, nil)
        assert(prompt:find("JSON", 1, true), "the prompt must ask for JSON")
        assert(prompt:find("Exposure2012", 1, true), "the parameter vocabulary is missing")
    end },

    { "pass 1 does not claim there is a reference image", function()
        local without = Prompts.buildAnalysisPrompt(1, 3, false, nil)
        local with = Prompts.buildAnalysisPrompt(1, 3, true, nil)
        assert(without ~= with, "hasReference must change the prompt")
    end },

    { "only non-zero settings are reported back to the model", function()
        local block = Prompts.readCurrentSettings(fakePhoto({
            Exposure2012 = 0.8, Contrast2012 = 0, Highlights2012 = -35,
        }))
        assert(block:find("Exposure2012", 1, true), "a non-zero value must be reported")
        assert(block:find("Highlights2012", 1, true))
        assert(not block:find("Contrast2012", 1, true),
            "a zero value must be omitted - the prompt states absent means zero")
    end },

    { "crop and angle are never reported as current state", function()
        -- They are the only parameters the model answers RELATIVE to the frame
        -- it sees; reporting them invites absolute answers, which the caller
        -- would then compose a second time and shrink the frame every pass.
        local block = Prompts.readCurrentSettings(fakePhoto({
            Exposure2012 = 0.5, CropLeft = 0.1, CropRight = 0.9, CropAngle = -2,
        }))
        assert(not block:find("Crop", 1, true), "crop state leaked into the prompt")
    end },

    { "a black and white photo is reported as such", function()
        local _, isGrayscale = Prompts.readCurrentSettings(fakePhoto({
            ConvertToGrayscale = true, Exposure2012 = 0.2,
        }))
        assert(isGrayscale == true, "the B&W flag must come back to the caller")
    end },
}
```

### Task 7: VenzAIParse

Follows the shared shape above. Execute BEFORE Task 6.

- [ ] **Move the code** — move `VenzAIProcess.lua:76-212` (the vocabulary: `HSL_COLORS`, `COLOR_GRADE_ZONES`, `VALID_KEYS`, `BOOLEAN_VALID_KEYS`, `STRING_VALID_KEYS`, `RANGES`, `LOCAL_VALID_KEYS`, `LOCAL_RANGES`, `MASK_SUBJECT_TYPES`, `MAX_MASKS_PER_PASS`) and `493-786` (`parseModelSettings`, `findMatchingClose`, `extractMaskBlocks`, `parseMasks`). Exported: `M.parseModelSettings`, `M.parseMasks`, `M.MASK_SUBJECT_TYPES`, `M.MAX_MASKS_PER_PASS`, and — for Task 6 — `M.VALID_KEYS` and `M.STRING_VALID_KEYS`.

  **One behaviour change, and it is the point of the exercise:** delete the first line of `parseModelSettings` and of `parseMasks`, `local unescapedBody = responseBody:gsub('\\"', '"')`, and rename the parameter to `text`. Both now receive `response.text`, already decoded by the driver. Every later reference to `unescapedBody` becomes `text`.

```lua
-- tests/test_parse.lua
local Parse = require 'VenzAIParse'

return {
    { "a plain JSON answer yields the settings", function()
        local s = Parse.parseModelSettings('{"Exposure2012": -0.25, "Contrast2012": 15}', false)
        assert(s.Exposure2012 == -0.25 and s.Contrast2012 == 15)
    end },

    { "an out-of-range value is discarded, not clamped", function()
        -- The Temperature=8 case: the model confused an absolute value with a
        -- delta. Applying 8 Kelvin would be worse than applying nothing.
        local s = Parse.parseModelSettings('{"Temperature": 8, "Exposure2012": 0.5}', false)
        assert(s.Temperature == nil, "an impossible Temperature must be dropped")
        assert(s.Exposure2012 == 0.5, "a valid neighbour must survive")
    end },

    { "a key outside the whitelist is ignored", function()
        local s = Parse.parseModelSettings('{"Exposure2012": 0.5, "MakeItPretty": 99}', false)
        assert(s.MakeItPretty == nil)
    end },

    { "a boolean is extracted, which the numeric pass cannot see", function()
        local s = Parse.parseModelSettings('{"ConvertToGrayscale": true, "Exposure2012": 0.1}', false)
        assert(s.ConvertToGrayscale == true)
    end },

    { "a CameraProfile outside the closed list is discarded", function()
        local ok = Parse.parseModelSettings('{"CameraProfile": "Adobe Color", "Exposure2012": 0.1}', false)
        assert(ok.CameraProfile == "Adobe Color")
        local bad = Parse.parseModelSettings('{"CameraProfile": "Adobe Colour", "Exposure2012": 0.1}', false)
        assert(bad.CameraProfile == nil, "a typo must not be written through")
    end },

    { "the grey mixer is dropped on a colour photo and kept on a B&W one", function()
        local colour = Parse.parseModelSettings('{"GrayMixerRed": 20, "Exposure2012": 0.1}', false)
        assert(colour.GrayMixerRed == nil, "inert on a colour photo")
        local mono = Parse.parseModelSettings('{"GrayMixerRed": 20, "Exposure2012": 0.1}', true)
        assert(mono.GrayMixerRed == 20, "a pass after the conversion must keep refining the mixer")
    end },

    { "out-of-order curve splits are discarded and the region sliders survive", function()
        local s = Parse.parseModelSettings(
            '{"ParametricShadowSplit": 80, "ParametricMidtoneSplit": 20, "ParametricHighlightSplit": 90, "ParametricLights": 15}', false)
        assert(s.ParametricShadowSplit == nil and s.ParametricMidtoneSplit == nil)
        assert(s.ParametricLights == 15, "the sliders the splits delimit stay valid")
    end },

    { "a crop that would distort the aspect ratio is corrected, not discarded", function()
        local s = Parse.parseModelSettings(
            '{"CropLeft": 0, "CropTop": 0, "CropRight": 1, "CropBottom": 0.5, "Exposure2012": 0.1}', false)
        local width = s.CropRight - s.CropLeft
        local height = s.CropBottom - s.CropTop
        assert(math.abs(width - height) < 0.002,
            string.format("fractions still differ: %.4f vs %.4f", width, height))
    end },

    { "an inverted crop is discarded entirely", function()
        local s = Parse.parseModelSettings(
            '{"CropLeft": 0.9, "CropRight": 0.1, "Exposure2012": 0.1}', false)
        assert(s.CropLeft == nil and s.CropRight == nil)
    end },

    { "an answer with nothing usable returns nil and a reason", function()
        local s, reason = Parse.parseModelSettings('{"nothing": "here"}', false)
        assert(s == nil and type(reason) == "string" and reason ~= "")
    end },

    -- Review Focus: the gsub hack is gone, so a decoded text with real quotes
    -- must still parse, including the nested Masks array.
    { "masks parse from an already-decoded text", function()
        local masks = Parse.parseMasks(
            '{"Exposure2012": 0.1, "Masks": [{"type": "sky", "local_Exposure": -0.4}]}')
        assert(#masks == 1, "expected one mask, got " .. #masks)
        assert(masks[1].type == "sky")
        assert(masks[1].params.local_Exposure == -0.4)
    end },

    { "a mask type outside the allowed list is discarded", function()
        local masks = Parse.parseMasks('{"Masks": [{"type": "unicorn", "local_Exposure": -0.4}]}')
        assert(#masks == 0)
    end },

    { "a duplicate mask type in one pass is discarded", function()
        local masks = Parse.parseMasks(
            '{"Masks": [{"type": "sky", "local_Exposure": -0.4}, {"type": "sky", "local_Exposure": 0.2}]}')
        assert(#masks == 1)
    end },

    { "a mask with no valid local parameter is discarded", function()
        local masks = Parse.parseMasks('{"Masks": [{"type": "sky", "local_Nonsense": 5}]}')
        assert(#masks == 0)
    end },

    { "more masks than the per-pass cap are trimmed", function()
        local masks = Parse.parseMasks('{"Masks": [' ..
            '{"type": "sky", "local_Exposure": -0.4},' ..
            '{"type": "subject", "local_Exposure": 0.3},' ..
            '{"type": "background", "local_Exposure": 0.1}]}')
        assert(#masks == Parse.MAX_MASKS_PER_PASS, "expected " .. Parse.MAX_MASKS_PER_PASS)
    end },

    { "no Masks key at all is an empty list, not an error", function()
        assert(#Parse.parseMasks('{"Exposure2012": 0.1}') == 0)
    end },
}
```

### Task 8: VenzAIMasks

Follows the shared shape above.

- [ ] **Move the code** — move `VenzAIProcess.lua:788-958`: `MASK_DETECT_ATTEMPTS`, `MASK_DETECT_INTERVAL`, `maskingApiAvailable`, `currentMaskIDs`, `waitForNewMaskID`, `maskStillExists`, `applyMasksToPhoto`. Exported: `M.maskingApiAvailable`, `M.applyMasksToPhoto`. This module imports `LrDevelopController`, `LrApplicationView` and `LrTasks`, so its verification is the manual Lightroom run of §12 plus one test that the graceful-degradation branch works:

```lua
-- tests/test_masks.lua
return {
    { "masking degrades instead of failing when the API is absent", function()
        -- A host between SDK 11.0 and the aiSelection subtypes' real minimum
        -- must fall back to global-only editing, not break the run.
        harness.reset()
        harness.stub('LrDevelopController', {})  -- no createNewMask, no getAllMasks
        local Masks = require 'VenzAIMasks'
        assert(Masks.maskingApiAvailable() == false)
    end },

    { "masking is reported available when every function is present", function()
        harness.reset()
        harness.stub('LrDevelopController', {
            createNewMask = function() end,
            getAllMasks = function() return {} end,
            selectMask = function() end,
        })
        local Masks = require 'VenzAIMasks'
        assert(Masks.maskingApiAvailable() == true)
    end },
}
```

The harness needs `LrDevelopController` and `LrApplicationView` in `defaultStubs()` for this; add them as empty tables, since every test that cares supplies its own.

---

### Task 9: VenzAIProviderGemini

**Files:**
- Create: `VenzAI.lrdevplugin/VenzAIProviderGemini.lua`
- Create: `tests/test_provider_gemini.lua`
- Source to consult (deleted in Task 14): `VenzAIProcess.lua:1031-1091` (`transportError`, `callGeminiAPI`) and `479-489` (`extractInlineImage`)

**Interfaces:**
- Consumes: `Contract.success`, `Contract.failure`; `Json.escape`, `Json.stringValues`, `Json.stringValue`; `LrHttp`.
- Produces: a driver table with `id = "gemini"`, all three capabilities, and `settingsFields` declaring `apiKey` (secret), `model` and `imageModel` (both role `model`).

- [ ] **Step 1: Write the failing test**

Create `tests/test_provider_gemini.lua`:

```lua
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
}
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `python tests/run.py gemini`
Expected: FAIL — `could not load VenzAI.lrdevplugin/VenzAIProviderGemini.lua`.

- [ ] **Step 3: Write the driver**

Create `VenzAI.lrdevplugin/VenzAIProviderGemini.lua`:

```lua
--[[----------------------------------------------------------------------------

VenzAIProviderGemini.lua
The Gemini protocol: serialization, auth, HTTP, extraction, classification.

Nothing in this file knows about develop parameters, passes or photographs.
Nothing outside it knows that Gemini puts the model in the URL path, answers
with camelCase keys even when asked in snake_case, or calls truncation
MAX_TOKENS.

------------------------------------------------------------------------------]]

local LrHttp = import 'LrHttp'

local Json = require 'VenzAIJson'
local Contract = require 'VenzAIProviderContract'
local VenzAILog = require 'VenzAILog'
local log = VenzAILog.scoped("Gemini")

local BASE = "https://generativelanguage.googleapis.com/v1beta/models"
local LIST_TIMEOUT = 10

local M = {
    id = "gemini",
    displayName = "$$$/VenzAI/Provider/Gemini/Name=Gemini (Google, cloud)",
    -- A reasoning model spends a while before emitting a token, so this is
    -- minutes rather than seconds. Without a timeout a stalled connection
    -- leaves the progress bar spinning with no way out but restarting.
    defaultTimeout = 300,
    capabilities = { analyze = true, generateReference = true, listModels = true },
    settingsFields = {
        { key = "apiKey", role = "secret", required = true,
          label = "$$$/VenzAI/Provider/Gemini/ApiKey=API key" },
        { key = "model", role = "model", default = "gemini-2.5-pro",
          label = "$$$/VenzAI/Provider/Gemini/Model=Analysis model" },
        { key = "imageModel", role = "model", default = "gemini-2.5-flash-image",
          label = "$$$/VenzAI/Provider/Gemini/ImageModel=Reference image model" },
    },
}

function M.validate(config)
    if type(config) ~= "table" then return false, "missing_config" end
    if config.apiKey == nil or config.apiKey == "" then return false, "missing_api_key" end
    if config.model == nil or config.model == "" then return false, "missing_model" end
    return true
end

-- A connection that never got off the ground comes back with no body and no
-- status, which reads in the log exactly like a server that answered with
-- nothing. The SDK documents only the success shape of the headers table, but
-- in practice it carries an `error` entry here; reading it is guarded so that
-- if it ever stops being provided we fall back to the generic message.
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

local function partsJson(parts)
    local out = {}
    for _, part in ipairs(parts or {}) do
        if part.text then
            table.insert(out, string.format('{ "text": %s }', Json.escape(part.text)))
        elseif part.image then
            table.insert(out, string.format(
                '{ "inline_data": { "mime_type": %s, "data": %s } }',
                Json.escape(part.image.mimeType), Json.escape(part.image.data)))
        end
    end
    return table.concat(out, ",")
end

-- The key travels in the x-goog-api-key header rather than the query string: a
-- URL is the part most likely to end up in a log line, a proxy access log or a
-- bug report.
local function post(url, payload, apiKey, timeout)
    local body, headers = LrHttp.post(url, payload, {
        { field = "Content-Type", value = "application/json" },
        { field = "x-goog-api-key", value = apiKey },
    }, "POST", timeout)
    return body, headers and headers.status, transportError(headers)
end

local function generateContent(model, payload, config, timeout)
    local url = string.format("%s/%s:generateContent", BASE, model)
    log("POST " .. url)
    local body, status, transport = post(url, payload, config.apiKey, timeout)

    if not body then
        return nil, Contract.failure("unreachable", transport or "no response received", nil, status)
    end
    if status ~= 200 then
        return nil, Contract.failure(classifyStatus(status), body:sub(1, 600), nil, status)
    end
    return body, nil, status
end

function M.analyze(request, config)
    local generationConfig = request.wantsJson
        and '{ "response_mime_type": "application/json", "temperature": 0.9 }'
        or '{ "temperature": 0.9 }'
    local payload = string.format('{ "contents": [{ "parts": [%s] }], "generationConfig": %s }',
        partsJson(request.parts), generationConfig)

    local body, failure, status = generateContent(config.model, payload, config,
        request.timeout or M.defaultTimeout)
    if failure then return failure end

    -- Several text parts are possible; the model's answer is their
    -- concatenation, already decoded by Json.
    local texts = Json.stringValues(body, "text")
    if #texts == 0 then
        return Contract.failure("empty", body:sub(1, 600), nil, status)
    end

    return Contract.success({
        text = table.concat(texts),
        truncated = (Json.stringValue(body, "finishReason") == "MAX_TOKENS"),
        httpStatus = status,
    })
end

function M.generateReference(request, config)
    if config.imageModel == nil or config.imageModel == "" then
        return Contract.failure("config_invalid", nil, "missing_image_model")
    end

    local payload = string.format(
        '{ "contents": [{ "parts": [%s] }], "generationConfig": { "responseModalities": ["TEXT", "IMAGE"] } }',
        partsJson(request.parts))

    local body, failure, status = generateContent(config.imageModel, payload, config,
        request.timeout or M.defaultTimeout)
    if failure then return failure end

    -- The container is called inlineData in the answer even though the request
    -- said inline_data, so the data field is matched on its base64 alphabet
    -- rather than on the container's name.
    local data = body:match('"data"%s*:%s*"([A-Za-z0-9+/=]+)"')
    if not data then
        return Contract.failure("empty", body:sub(1, 600), nil, status)
    end

    return Contract.success({
        image = {
            data = data,
            mimeType = body:match('"mime[Tt]ype"%s*:%s*"([^"]+)"') or "image/png",
        },
        httpStatus = status,
    })
end

function M.listModels(config)
    local body, headers = LrHttp.get(BASE,
        { { field = "x-goog-api-key", value = config.apiKey } }, LIST_TIMEOUT)
    local status = headers and headers.status

    if not body then
        return nil, "unreachable", transportError(headers) or "no response received"
    end
    if status ~= 200 then
        return nil, classifyStatus(status), body:sub(1, 600)
    end

    local names = {}
    for _, name in ipairs(Json.stringValues(body, "name")) do
        table.insert(names, (name:gsub("^models/", "")))
    end
    return names
end

return M
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `python tests/run.py gemini`
Expected: 15 PASS, `15 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add VenzAI.lrdevplugin/VenzAIProviderGemini.lua tests/test_provider_gemini.lua
git commit -m "feat: the Gemini driver behind the contract"
```

---

### Task 10: VenzAIProviderOpenAI — implemented second, on purpose

The interface was defined from two examples and risks being Gemini-shaped. OpenAI is where that leaks, so it comes before Ollama rather than last: any special case needed here is evidence of a crack in the contract and gets reported rather than worked around.

OpenAI differs from Gemini in every place the contract abstracts: the model is a field in the body, not a path segment; auth is `Authorization: Bearer`; images are data URLs inside a `content` array; JSON mode is `response_format`; truncation is `finish_reason == "length"`; the answer is at `choices[].message.content`.

**Files:**
- Create: `VenzAI.lrdevplugin/VenzAIProviderOpenAI.lua`
- Create: `tests/test_provider_openai.lua`

**Interfaces:** same as Task 9. The same four requires open the file — `LrHttp` via `import`, then `VenzAIJson`, `VenzAIProviderContract` and `VenzAILog` — and `transportError`, `classifyStatus` and `endpoint` are this file's own copies, not shared. `settingsFields`: `apiKey` (secret), `model` (default `gpt-5`), `baseUrl` (default `https://api.openai.com/v1`, role `url`). Capabilities: `analyze` and `listModels` only — **no `generateReference`**, which is the capability check of §11 doing real work rather than being decoration.

- [ ] **Step 1: Write the failing test**

Create `tests/test_provider_openai.lua` with the same shape as Task 9's suite, replacing the response bodies and adding these cases, which are the ones that test the contract rather than the driver:

```lua
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
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `python tests/run.py openai` — FAIL, the module does not exist.

- [ ] **Step 3: Write the driver**

Create `VenzAI.lrdevplugin/VenzAIProviderOpenAI.lua`, following Task 9's structure. The parts that differ:

```lua
local M = {
    id = "openai",
    displayName = "$$$/VenzAI/Provider/OpenAI/Name=OpenAI (cloud)",
    defaultTimeout = 300,
    -- No generateReference: OpenAI's image models are a different endpoint
    -- with a different shape, and the design forbids mixing roles. The engine
    -- asks for the capability and proceeds without a reference, which is
    -- already the path a local model takes.
    capabilities = { analyze = true, listModels = true },
    settingsFields = {
        { key = "apiKey", role = "secret", required = true,
          label = "$$$/VenzAI/Provider/OpenAI/ApiKey=API key" },
        { key = "model", role = "model", default = "gpt-5",
          label = "$$$/VenzAI/Provider/OpenAI/Model=Analysis model" },
        { key = "baseUrl", role = "url", default = "https://api.openai.com/v1",
          label = "$$$/VenzAI/Provider/OpenAI/BaseUrl=API base URL" },
    },
}

function M.validate(config)
    if type(config) ~= "table" then return false, "missing_config" end
    if config.apiKey == nil or config.apiKey == "" then return false, "missing_api_key" end
    if config.model == nil or config.model == "" then return false, "missing_model" end
    if config.baseUrl == nil or config.baseUrl == "" then return false, "missing_base_url" end
    if not config.baseUrl:match("^https?://") then return false, "invalid_base_url" end
    return true
end

-- Trims a trailing slash so that a base URL entered either way produces one
-- correct endpoint rather than a doubled slash some proxies reject.
local function endpoint(baseUrl, path)
    return (baseUrl:gsub("/+$", "")) .. path
end

-- OpenAI takes one message whose content is an array of typed parts, and an
-- image is a data URL rather than a separate field.
local function contentJson(parts)
    local out = {}
    for _, part in ipairs(parts or {}) do
        if part.text then
            table.insert(out, string.format('{ "type": "text", "text": %s }',
                Json.escape(part.text)))
        elseif part.image then
            table.insert(out, string.format(
                '{ "type": "image_url", "image_url": { "url": %s } }',
                Json.escape(string.format("data:%s;base64,%s",
                    part.image.mimeType, part.image.data))))
        end
    end
    return table.concat(out, ",")
end

function M.analyze(request, config)
    local responseFormat = request.wantsJson
        and ', "response_format": { "type": "json_object" }' or ''
    local payload = string.format(
        '{ "model": %s, "messages": [{ "role": "user", "content": [%s] }], "temperature": 0.9%s }',
        Json.escape(config.model), contentJson(request.parts), responseFormat)

    local url = endpoint(config.baseUrl, "/chat/completions")
    local body, headers = LrHttp.post(url, payload, {
        { field = "Content-Type", value = "application/json" },
        { field = "Authorization", value = "Bearer " .. config.apiKey },
    }, "POST", request.timeout or M.defaultTimeout)
    local status = headers and headers.status

    if not body then
        return Contract.failure("unreachable", transportError(headers) or "no response received", nil, status)
    end
    if status ~= 200 then
        return Contract.failure(classifyStatus(status), body:sub(1, 600), nil, status)
    end

    -- "content" is the assistant's answer. A refusal also arrives under
    -- "content", so an empty one is genuinely empty rather than a fault.
    local contents = Json.stringValues(body, "content")
    if #contents == 0 or contents[1] == "" then
        return Contract.failure("empty", body:sub(1, 600), nil, status)
    end

    return Contract.success({
        text = table.concat(contents),
        truncated = (Json.stringValue(body, "finish_reason") == "length"),
        httpStatus = status,
    })
end

function M.listModels(config)
    local body, headers = LrHttp.get(endpoint(config.baseUrl, "/models"),
        { { field = "Authorization", value = "Bearer " .. config.apiKey } }, 10)
    local status = headers and headers.status
    if not body then
        return nil, "unreachable", transportError(headers) or "no response received"
    end
    if status ~= 200 then
        return nil, classifyStatus(status), body:sub(1, 600)
    end
    return Json.stringValues(body, "id")
end
```

`transportError` and `classifyStatus` are identical to Gemini's. Copy them into this file rather than sharing them: they are each a driver's own reading of its service's failures, and OpenAI's mapping will diverge from Google's the first time one of them uses a status the other does not. Two eight-line functions that are allowed to differ beat one shared function with a provider flag.

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `python tests/run.py openai` — expect 11 PASS.

- [ ] **Step 5: Report any contract leak**

If writing this driver required a change to `VenzAIProviderContract.lua`, note what and why in the commit message. That is the signal §4.2 predicted, and it is information, not a failure.

- [ ] **Step 6: Commit**

```bash
git add VenzAI.lrdevplugin/VenzAIProviderOpenAI.lua tests/test_provider_openai.lua
git commit -m "feat: the OpenAI driver, written second to test the contract"
```

---

### Task 11: VenzAIProviderOllama

**Files:**
- Create: `VenzAI.lrdevplugin/VenzAIProviderOllama.lua`
- Create: `tests/test_provider_ollama.lua`
- Source to consult: `VenzAIProcess.lua:1093-1111` (`callOllamaAPI`, including the `num_ctx` comment, which moves with the code) and `PluginInfoProvider.lua:44-82` (`detectOllamaModels`, which becomes `listModels`)

**Interfaces:** `settingsFields`: `baseUrl` (default `http://localhost:11434`, role `url`), `model` (default `qwen2.5vl:latest`, role `model`). **No `apiKey`** — a local server needs none, and the panel must render this driver with no secret field at all, which is what proves the panel renders from declarations rather than from a hardcoded layout. Capabilities: `analyze` and `listModels`. `defaultTimeout = 900` — a local model on CPU is slower than any cloud one.

- [ ] **Step 1: Write the failing test**

Create `tests/test_provider_ollama.lua`. Beyond the shape of Task 9's suite, these are the Ollama-specific cases:

```lua
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
```

- [ ] **Step 2: Run it to make sure it fails** — `python tests/run.py ollama`

- [ ] **Step 3: Write the driver**

Follow Task 9's structure, with the same four requires and this file's own copies of `transportError`, `classifyStatus` and `endpoint` (the latter identical to Task 10's). The body differs as follows, and the `num_ctx` comment from `VenzAIProcess.lua:1093` moves here verbatim because it records why the number is what it is:

```lua
function M.analyze(request, config)
    -- Ollama's /api/generate takes one prompt string and a separate array of
    -- bare base64 images, so the contract's ordered parts collapse: the texts
    -- are joined in order, the images collected.
    local texts, images = {}, {}
    for _, part in ipairs(request.parts or {}) do
        if part.text then table.insert(texts, part.text) end
        if part.image then table.insert(images, Json.escape(part.image.data)) end
    end

    local payload = string.format(
        '{ "model": %s, "prompt": %s, "images": [%s], %s "stream": false, ' ..
        '"options": { "temperature": 0.9, "num_ctx": 32768, "num_predict": 4096 } }',
        Json.escape(config.model),
        Json.escape(table.concat(texts, "\n\n")),
        table.concat(images, ","),
        request.wantsJson and '"format": "json",' or '')

    local body, headers = LrHttp.post(endpoint(config.baseUrl, "/api/generate"), payload,
        { { field = "Content-Type", value = "application/json" } },
        "POST", request.timeout or M.defaultTimeout)
    local status = headers and headers.status

    if not body then
        return Contract.failure("unreachable", transportError(headers) or "no response received", nil, status)
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
    local body, headers = LrHttp.get(endpoint(config.baseUrl, "/api/tags"), nil, 10)
    local status = headers and headers.status
    if not body then
        return nil, "unreachable", transportError(headers) or "no response received"
    end
    if status ~= 200 then
        return nil, classifyStatus(status), body:sub(1, 600)
    end
    -- A reachable server with nothing pulled is an empty list, NOT a failure:
    -- the panel says "no models installed", which is actionable, rather than
    -- "could not detect models", which sends the user looking for a network
    -- problem that is not there.
    return Json.stringValues(body, "name")
end
```

- [ ] **Step 4: Run the tests and make sure they pass** — expect 11 PASS.

- [ ] **Step 5: Commit**

```bash
git add VenzAI.lrdevplugin/VenzAIProviderOllama.lua tests/test_provider_ollama.lua
git commit -m "feat: the Ollama driver behind the contract"
```

---

### Task 12: VenzAIProviderRegistry

**Files:**
- Create: `VenzAI.lrdevplugin/VenzAIProviderRegistry.lua`
- Create: `tests/test_registry.lua`

**Interfaces:**
- Produces: `Registry.all() -> array of drivers` in declaration order; `Registry.byId(id) -> driver or nil`; `Registry.active() -> driver` (never nil as long as one driver is registered); `Registry.problems() -> array of strings` (what `validateDriver` rejected, for the self-test and the log).

- [ ] **Step 1: Write the failing test**

```lua
-- tests/test_registry.lua
local Registry = require 'VenzAIProviderRegistry'
local Settings = require 'VenzAISettings'

return {
    { "every registered driver satisfies the contract", function()
        local problems = Registry.problems()
        assert(#problems == 0, "rejected drivers: " .. table.concat(problems, " | "))
    end },

    { "the three designed drivers are registered, in order", function()
        local ids = {}
        for _, driver in ipairs(Registry.all()) do table.insert(ids, driver.id) end
        assert(table.concat(ids, ",") == "gemini,openai,ollama", "got " .. table.concat(ids, ","))
    end },

    { "byId finds a driver and returns nil for an unknown one", function()
        assert(Registry.byId("ollama").id == "ollama")
        assert(Registry.byId("nonesuch") == nil)
    end },

    { "the active driver follows the pref", function()
        harness.reset()
        local R = require 'VenzAIProviderRegistry'
        local S = require 'VenzAISettings'
        S.setActiveProviderId("ollama")
        assert(R.active().id == "ollama", "got " .. R.active().id)
    end },

    -- Review Focus: a pref naming a driver that no longer exists.
    { "an activeProvider naming an unknown driver falls back to the first", function()
        harness.reset()
        local R = require 'VenzAIProviderRegistry'
        local S = require 'VenzAISettings'
        S.setActiveProviderId("a-driver-that-was-removed")
        local active = R.active()
        assert(active ~= nil, "active() must never return nil")
        assert(active.id == R.all()[1].id, "expected the first driver, got " .. active.id)
    end },

    { "no two drivers share an id", function()
        local seen = {}
        for _, driver in ipairs(Registry.all()) do
            assert(not seen[driver.id], "duplicate id " .. driver.id)
            seen[driver.id] = true
        end
    end },
}
```

- [ ] **Step 2: Run it to make sure it fails** — `python tests/run.py registry`

- [ ] **Step 3: Write the module**

```lua
--[[----------------------------------------------------------------------------

VenzAIProviderRegistry.lua
The hand-written list of provider drivers.

Deliberately not discovered at run time: a table that a person edits is a
table a person can read, and the order here is the order the settings panel
shows. Adding a provider is one line.

------------------------------------------------------------------------------]]

local Contract = require 'VenzAIProviderContract'
local Settings = require 'VenzAISettings'
local VenzAILog = require 'VenzAILog'
local log = VenzAILog.scoped("Registry")

local declared = {
    require 'VenzAIProviderGemini',
    require 'VenzAIProviderOpenAI',
    require 'VenzAIProviderOllama',
}

local M = {}

-- Validated once, at load: a malformed driver is named precisely here instead
-- of failing obscurely halfway through a photograph.
local drivers = {}
local problems = {}
local byId = {}

for index, driver in ipairs(declared) do
    local ok, problem = Contract.validateDriver(driver)
    if not ok then
        local message = string.format("driver #%d rejected: %s", index, tostring(problem))
        log(message)
        table.insert(problems, message)
    elseif byId[driver.id] then
        local message = string.format("driver #%d rejected: duplicate id '%s'", index, driver.id)
        log(message)
        table.insert(problems, message)
    else
        table.insert(drivers, driver)
        byId[driver.id] = driver
    end
end

log(string.format("%d driver(s) registered, %d rejected.", #drivers, #problems))

function M.all() return drivers end
function M.byId(id) return byId[id] end
function M.problems() return problems end

-- Falls back to the first registered driver when the pref names one that is no
-- longer here, which is what a removed or renamed driver leaves behind. The
-- plug-in keeps working with a provider the user can see and change, rather
-- than failing at load over a stale string.
function M.active()
    local id = Settings.getActiveProviderId()
    local driver = byId[id]
    if driver then return driver end

    local fallback = drivers[1]
    if fallback then
        log(string.format("activeProvider is '%s', which is not registered; falling back to '%s'.",
            tostring(id), fallback.id))
    else
        log("No driver is registered at all.")
    end
    return fallback
end

return M
```

- [ ] **Step 4: Run the whole suite** — `python tests/run.py`, expect every suite green.

- [ ] **Step 5: Commit**

```bash
git add VenzAI.lrdevplugin/VenzAIProviderRegistry.lua tests/test_registry.lua
git commit -m "feat: the driver registry, validated at load"
```

---

### Task 13: PluginInfoProvider rendered from declarations

**Files:**
- Rewrite: `VenzAI.lrdevplugin/PluginInfoProvider.lua`

Adding a provider must not touch this file. It iterates `Registry.all()`, emits one `group_box` per driver and one row per declared field, and enables the group bound to `activeProvider`.

**Interfaces:** consumes `Registry.all()`, `Settings.providerConfig`/`getProviderField`/`setProviderField`/`getActiveProviderId`/`setActiveProviderId`, `Messages.forError`, and each driver's `listModels`.

Keep from the current file, unchanged: `showLogAction` and the whole diagnostics row; the refinement-passes row; `Settings.applyDefaults()` on panel open. Replace everything else.

Points that the current file's comments record and that must survive the rewrite:
- `bind_to_object = propertyTable` must be set explicitly on every `group_box`, or controls nested inside it do not resolve their binding and the fields render empty.
- `enabled` goes on individual controls, not on the `group_box`.
- The "Detect models" action must run inside `LrTasks.startAsyncTask`, because `LrHttp` yields and a button callback may not.

Property-table keys are namespaced the same way as the prefs, `provider.<id>.<key>`, so two drivers declaring `model` do not collide in the binding either.

`detectModelsAction` and `groupForDriver` refer to each other, and in Lua a `local` declared later is not in scope for a closure written earlier. Forward-declare it:

```lua
-- Forward declaration: groupForDriver closes over this, and it is defined
-- below. Without the declaration the closure would capture a global instead
-- and the button would do nothing.
local detectModelsAction

-- The popup that chooses the active provider is built from the registry, so a
-- new driver appears here with no edit to this file.
local providerItems = {}
for _, driver in ipairs(Registry.all()) do
    table.insert(providerItems, { title = LOC(driver.displayName), value = driver.id })
end

local function propertyKey(driverId, fieldKey)
    return string.format("provider.%s.%s", driverId, fieldKey)
end

-- One group box per driver, one row per declared field. The role picks the
-- control: a secret gets a password_field, everything else an edit_field. A
-- field with role "model" also gets the Detect button, but only when its
-- driver declares the listModels capability.
local function groupForDriver(f, propertyTable, driver)
    local rows = {
        bind_to_object = propertyTable,
        title = LOC(driver.displayName),
        fill_horizontal = 1,
    }

    local function enabledForThisDriver()
        return LrView.bind {
            key = "activeProvider",
            transform = function(value) return value == driver.id end,
        }
    end

    for _, field in ipairs(driver.settingsFields) do
        local key = propertyKey(driver.id, field.key)
        local control
        if field.role == "secret" then
            control = f:password_field {
                value = LrView.bind(key),
                width_in_chars = 30,
                enabled = enabledForThisDriver(),
            }
        else
            control = f:edit_field {
                value = LrView.bind(key),
                width_in_chars = 30,
                enabled = enabledForThisDriver(),
            }
        end

        local row = {
            spacing = f:control_spacing(),
            f:static_text {
                title = LOC(field.label),
                width = LrView.share "venzai_label_width",
                enabled = enabledForThisDriver(),
            },
            control,
        }

        if field.role == "model" and driver.capabilities.listModels then
            table.insert(row, f:push_button {
                title = LOC "$$$/VenzAI/Settings/DetectModels=Detect models",
                enabled = enabledForThisDriver(),
                action = function() detectModelsAction(propertyTable, driver, field) end,
            })
        end

        table.insert(rows, f:row(row))
    end

    if #driver.settingsFields == 0 then
        table.insert(rows, f:row { f:static_text {
            title = LOC "$$$/VenzAI/Settings/NoSettings=This provider needs no settings.",
        } })
    end

    return f:group_box(rows)
end
```

`detectModelsAction` replaces the Ollama-specific one and works for any driver declaring the capability. A failure is reported through `Messages.forError` with the driver's `displayName`, so the dialog is localized and names the provider. **An empty list is not a failure:** it gets its own message, because "reachable but nothing installed" and "could not reach the server" send the user to different places.

```lua
function detectModelsAction(propertyTable, driver, field)  -- declared above
    LrTasks.startAsyncTask(function()
        LrFunctionContext.callWithContext("VenzAI_DetectModels", function(context)
            -- Read the config from the panel's live values, not from prefs:
            -- the user may have just typed a new URL without committing it.
            local config = {}
            for _, declared in ipairs(driver.settingsFields) do
                config[declared.key] = propertyTable[propertyKey(driver.id, declared.key)]
            end

            local names, errorKind, errorDetail = driver.listModels(config)

            if not names then
                local title, body = Messages.forError(errorKind or "unknown",
                    driver.displayName, config[field.key])
                LrDialogs.message(title, body .. Messages.technicalSection(errorDetail), "warning")
                return
            end

            if #names == 0 then
                LrDialogs.message(
                    LOC "$$$/VenzAI/Settings/NoModelsTitle=No models are installed",
                    LOC("$$$/VenzAI/Settings/NoModelsBody=^1 answered, but has no model installed yet.\n\nInstall one on that service, then detect again.",
                        LOC(driver.displayName)),
                    "info")
                return
            end

            if #names == 1 then
                propertyTable[propertyKey(driver.id, field.key)] = names[1]
                return
            end

            -- More than one: a small picker rather than choosing at random.
            local pickerProps = LrBinding.makePropertyTable(context)
            pickerProps.selected = names[1]
            local items = {}
            for _, name in ipairs(names) do
                table.insert(items, { title = name, value = name })
            end
            local f = LrView.osFactory()
            local result = LrDialogs.presentModalDialog {
                title = LOC "$$$/VenzAI/Settings/PickModelTitle=Select a model",
                contents = f:row {
                    bind_to_object = pickerProps,
                    f:popup_menu { value = LrView.bind "selected", items = items, width_in_chars = 30 },
                },
            }
            if result == "ok" then
                propertyTable[propertyKey(driver.id, field.key)] = pickerProps.selected
            end
        end)
    end)
end
```

In `sectionsForTopOfDialog`, the mirroring loop becomes:

```lua
    Settings.applyDefaults()
    Settings.purgeLegacyPlainTextKey()

    propertyTable.activeProvider = Settings.getActiveProviderId()
    propertyTable:addObserver("activeProvider", function()
        Settings.setActiveProviderId(propertyTable.activeProvider)
    end)

    propertyTable.refinementPasses = Settings.get("refinementPasses")
    propertyTable:addObserver("refinementPasses", function()
        Settings.set("refinementPasses", propertyTable.refinementPasses)
    end)

    -- Every declared field of every driver, mirrored in and written straight
    -- back. A secret is never logged, not even as a length.
    for _, driver in ipairs(Registry.all()) do
        for _, field in ipairs(driver.settingsFields) do
            local key = propertyKey(driver.id, field.key)
            propertyTable[key] = Settings.getProviderField(driver.id, field)
            propertyTable:addObserver(key, function()
                Settings.setProviderField(driver.id, field, propertyTable[key])
                if field.role == "secret" then
                    log(string.format("User changed %s (value hidden).", key))
                else
                    log(string.format("User changed %s -> '%s'", key, tostring(propertyTable[key])))
                end
            end)
        end
    end
```

- [ ] **Step 1: Rewrite the file** as above, keeping the diagnostics row and the passes row from the current version.
- [ ] **Step 2: Run the whole suite** — `python tests/run.py`. It must stay green; this file has no test of its own, because `LrView`'s factory builds real widgets.
- [ ] **Step 3: Load the plug-in in Lightroom** (File > Plug-in Manager > Add) and check by eye: three group boxes; Ollama's box has **no** API-key row; only the active provider's controls are enabled; "Detect models" appears next to each model field; changing the popup enables a different box.
- [ ] **Step 4: Commit**

```bash
git add VenzAI.lrdevplugin/PluginInfoProvider.lua
git commit -m "feat: render the settings panel from each driver's declarations"
```

---

### Task 14: VenzAIProcess, reduced to the pass loop

**Files:**
- Modify heavily: `VenzAI.lrdevplugin/VenzAIProcess.lua`

Delete everything now living elsewhere: lines 31-46 (the config and timeout locals), 76-212 (the vocabulary → Task 7), 214-478 (the prompts → Task 6), 479-489 (`extractInlineImage` → Task 9), 493-786 (parsing → Task 7), 788-958 (masks → Task 8), 1012-1029 (`jsonEscape` → Task 2), 1031-1111 (`transportError`, `callGeminiAPI`, `callOllamaAPI` → Tasks 9-11). Keep `ensureWorkDir`, `failToUser`, `exportCurrentPhoto`, `encodeFileBase64` and the whole loop.

The three changes of substance:

**1. Resolve the driver and its config inside the task**, where the failure handler and the progress scope exist (§8.5):

```lua
LrTasks.startAsyncTask(function()
    LrFunctionContext.callWithContext("VenzAIProcess", function(context)
        local progressScope
        context:addFailureHandler(...)   -- unchanged

        local driver = Registry.active()
        if not driver then
            failToUser(Messages.forError("driver_fault", nil, nil))
            return
        end
        local config = Settings.providerConfig(driver.id, driver.settingsFields)
        local passes = Settings.getRefinementPasses()
        log(string.format("=== VenzAI start (provider=%s, model=%s) ===",
            driver.id, tostring(config.model)))
```

The API-key check at line 1146 is deleted. It was a second implementation of what `validate` now does, and it named a provider.

**2. The reference step becomes a capability check** — the last place the engine named a provider:

```lua
        if driver.capabilities.generateReference and pass == 1 then
            progressScope:setCaption(LOC "$$$/VenzAI/Progress/GeneratingReference=Generating a professional reference...")
            local response = Contract.call(driver, "generateReference", {
                parts = {
                    { text = Prompts.buildReferencePrompt() },
                    { image = { mimeType = "image/jpeg", data = currentBase64 } },
                },
                timeout = driver.defaultTimeout,
            }, config)

            if response.ok then
                referenceImage = response.image
                saveReferenceToWorkDir(response.image)
            else
                -- A missing reference is not a reason to stop: analysis on the
                -- plain photo is the path a provider without the capability
                -- takes anyway.
                log(string.format("No reference image (%s): continuing without one.",
                    tostring(response.errorKind)))
            end
        end
```

`saveReferenceToWorkDir` is the reference-writing block of lines 1276-1294, moved into a named function near `ensureWorkDir` because it is now called from inside a capability branch rather than inline. It keeps its best-effort character:

```lua
-- Writes the reference beside the working files so it can be inspected after a
-- run. Best effort only: the image is held in memory for the rest of the run,
-- so a failed write costs nothing but a file to look at afterwards.
local function saveReferenceToWorkDir(image)
    if not ensureWorkDir() then return end
    local extension = image.mimeType and image.mimeType:match("image/(%w+)") or "png"
    local path = REFERENCE_IMAGE_BASE_PATH .. "." .. extension
    local file = io.open(path, "wb")
    if not file then
        log("Could not write the reference image to " .. path ..
            " (continuing, it is kept in memory for this run).")
        return
    end
    file:write(LrStringUtils.decodeBase64(image.data))
    file:close()
    log("Reference saved to: " .. path)
end
```

**3. One analysis call for every provider**, replacing the `if ENGINE == "gemini" ... else ...` at line 1303:

```lua
        progressScope:setCaption(LOC("$$$/VenzAI/Progress/PassAnalyzing=Pass ^1/^2: analyzing with ^3...",
            tostring(pass), tostring(passes), LOC(driver.displayName)))

        local parts = {
            { text = "IMAGE 1:" },
            { image = { mimeType = "image/jpeg", data = currentBase64 } },
        }
        if referenceImage then
            table.insert(parts, { text = "IMAGE 2 (AI-generated reference):" })
            table.insert(parts, { image = referenceImage })
        end
        table.insert(parts, { text = Prompts.buildAnalysisPrompt(
            pass, passes, referenceImage ~= nil, currentSettingsBlock) })

        local response = Contract.call(driver, "analyze", {
            parts = parts,
            wantsJson = true,
            timeout = driver.defaultTimeout,
        }, config)

        if not response.ok then
            local title, body = Messages.forError(response.errorKind,
                driver.displayName, config.model, response.reasonKey)
            if passFailure(pass, title, body .. Messages.technicalSection(response.errorDetail)) then
                return
            end
            break
        end

        if response.truncated then
            log(string.format("Pass %d: WARNING - the answer was TRUNCATED. Whatever follows the cutoff, including any Masks, was never generated rather than deliberately omitted.", pass))
        end

        local developSettings, parseErr = Parse.parseModelSettings(response.text, isGrayscale)
        ...
        local masks = Parse.parseMasks(response.text)
```

The three separate failure branches at lines 1341-1379 (`not responseBody`, `status ~= 200`, the `done_reason` grep) collapse into the one `if not response.ok` above: the driver has already classified all of them. `passFailure` keeps its current shape and logic exactly.

Snapshot names use `driver.id` where they used `ENGINE`.

- [ ] **Step 1: Make the changes above.**
- [ ] **Step 2: Check the file no longer names a provider**

Run: `grep -niE "gemini|ollama|openai|nano.?banana" VenzAI.lrdevplugin/VenzAIProcess.lua`
Expected: **no output.** Any hit is a place the driver layer did not reach, and is the measure of whether this task succeeded.

- [ ] **Step 3: Check the file shrank as predicted**

Run: `wc -l VenzAI.lrdevplugin/VenzAIProcess.lua`
Expected: roughly 450-500 lines, down from 1457.

- [ ] **Step 4: Run the whole suite** — `python tests/run.py`, every suite green.
- [ ] **Step 5: Commit**

```bash
git add VenzAI.lrdevplugin/VenzAIProcess.lua
git commit -m "refactor: the engine no longer names a provider

The pass loop calls Contract.call for analysis and asks for the
generateReference capability instead of testing for Gemini. The API key check,
the two HTTP functions and the done_reason grep are gone; grep for a provider
name in this file now returns nothing."
```

---

### Task 15: The self-test menu item

Lightroom has no test framework and the drivers only reach their services from inside the application. When a provider changes its API, or driver #4 arrives months from now, this is the difference between finding out immediately and finding out halfway through a real photograph.

**Files:**
- Create: `VenzAI.lrdevplugin/VenzAISelfTest.lua`
- Modify: `VenzAI.lrdevplugin/Info.lua` (one new `LrLibraryMenuItems` entry — the only manifest change in the whole design)

It touches no photo. For each registered driver it reports: the contract verdict, `validate(config)` and its reason key, and `listModels` with its outcome — a count, an `errorKind`, or "reachable, none installed".

```lua
-- VenzAISelfTest.lua
local LrDialogs = import 'LrDialogs'
local LrTasks = import 'LrTasks'

local Registry = require 'VenzAIProviderRegistry'
local Contract = require 'VenzAIProviderContract'
local Settings = require 'VenzAISettings'
local VenzAILog = require 'VenzAILog'
local log = VenzAILog.scoped("SelfTest")

LrTasks.startAsyncTask(function()
    local lines = {}
    local function report(line)
        table.insert(lines, line)
        log(line)
    end

    local problems = Registry.problems()
    if #problems > 0 then
        report(LOC("$$$/VenzAI/SelfTest/Rejected=^1 driver(s) were rejected at load:", tostring(#problems)))
        for _, problem in ipairs(problems) do report("  " .. problem) end
    end

    report(LOC("$$$/VenzAI/SelfTest/Active=Active provider: ^1", Registry.active() and LOC(Registry.active().displayName) or "none"))

    for _, driver in ipairs(Registry.all()) do
        report("")
        report(LOC(driver.displayName))

        local contractOk, contractProblem = Contract.validateDriver(driver)
        report("  contract: " .. (contractOk and "ok" or tostring(contractProblem)))

        local config = Settings.providerConfig(driver.id, driver.settingsFields)
        local valid, reasonKey = driver.validate(config)
        report("  settings: " .. (valid and "ok" or ("rejected (" .. tostring(reasonKey) .. ")")))

        if not driver.capabilities.listModels then
            report("  models: this provider does not offer a model list")
        elseif not valid then
            report("  models: not attempted, the settings are incomplete")
        else
            local names, errorKind, errorDetail = driver.listModels(config)
            if not names then
                report("  models: " .. tostring(errorKind) .. " - " .. tostring(errorDetail))
            elseif #names == 0 then
                report("  models: reachable, none installed")
            else
                report(string.format("  models: %d found, e.g. %s", #names, names[1]))
            end
        end
    end

    LrDialogs.message(
        LOC "$$$/VenzAI/SelfTest/Title=VenzAI provider self-test",
        table.concat(lines, "\n"),
        "info")
end)
```

In `Info.lua`, add to **both** `LrLibraryMenuItems` and nothing else (the export menu is for acting on photos, and this acts on none):

```lua
        {
            title = LOC "$$$/VenzAI/Menu/TestProviders=Test VenzAI providers",
            file = "VenzAISelfTest.lua",
        },
```

- [ ] **Step 1: Write both files.**
- [ ] **Step 2: Run the whole suite** — `python tests/run.py`, still green.
- [ ] **Step 3: Run it in Lightroom** — Library > Plug-in Extras > Test VenzAI providers. With a real Gemini key, expect `contract: ok`, `settings: ok`, and a model count. With Ollama not running, expect `models: unreachable`. This is the first real network check of the drivers.
- [ ] **Step 4: Commit**

```bash
git add VenzAI.lrdevplugin/VenzAISelfTest.lua VenzAI.lrdevplugin/Info.lua
git commit -m "feat: a self-test that checks every driver without touching a photo"
```

---

### Task 16: Translation key completeness

**Files:**
- Create: `tests/check_translations.py`
- Modify: `VenzAI.lrdevplugin/TranslatedStrings_it.txt`

With one language this was a luxury; with a catalog of eleven error kinds plus per-driver field labels it is part of the work.

- [ ] **Step 1: Write the checker**

```python
"""Compares the LOC keys used in the bundle against each translation file.

A key in the source but not in a translation degrades to English, which is
correct behaviour but silent. A key in a translation but not in the source is
dead weight that hides a rename. Both are reported; only the first fails.

Usage: python tests/check_translations.py
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUNDLE = ROOT / "VenzAI.lrdevplugin"

# A LOC key as it appears in Lua source: "$$$/Path/To/Key=default text"
SOURCE_KEY = re.compile(r'"\$\$\$/([^"=]+)=')
# A line of a TranslatedStrings file: "$$$/Path/To/Key=translated text"
TRANSLATION_KEY = re.compile(r'^"\$\$\$/([^"=]+)=')


def keys_in_source():
    keys = set()
    for path in sorted(BUNDLE.glob("*.lua")):
        keys |= set(SOURCE_KEY.findall(path.read_text(encoding="utf-8")))
    return keys


def keys_in_translation(path):
    keys = set()
    for line in path.read_text(encoding="utf-8").splitlines():
        found = TRANSLATION_KEY.match(line.strip())
        if found:
            keys.add(found.group(1))
    return keys


def main():
    source = keys_in_source()
    print("%d keys used in the source" % len(source))

    failed = False
    for path in sorted(BUNDLE.glob("TranslatedStrings_*.txt")):
        translated = keys_in_translation(path)
        missing = sorted(source - translated)
        orphaned = sorted(translated - source)

        print("\n%s: %d keys" % (path.name, len(translated)))
        if missing:
            failed = True
            print("  MISSING (%d) - these degrade to English:" % len(missing))
            for key in missing:
                print("    %s" % key)
        if orphaned:
            print("  ORPHANED (%d) - no longer used in the source:" % len(orphaned))
            for key in orphaned:
                print("    %s" % key)
        if not missing and not orphaned:
            print("  complete")

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 2: Run it and read the list**

Run: `python tests/check_translations.py`
Expected: a long MISSING list (every new provider, error-kind and reason key) and an ORPHANED list (the old `Settings/Gemini/*`, `Settings/Local/*`, `Settings/Engine/*`, `Error/NoApiKey*`, `Error/NoResponse*`, `Error/Http*`, `Progress/TitleGemini`, `Progress/PassAnalyzingOllama` keys, which no longer exist).

- [ ] **Step 3: Rewrite the Italian file**

Delete every orphaned key. Add an Italian line for every missing one. Two rules: keep `^1 ^2 ^3` in the order the Italian sentence needs, which is not necessarily the English order — that is the whole reason placeholders exist rather than concatenation; and keep `\n` as the two characters, as the existing file already does.

- [ ] **Step 4: Run it again**

Run: `python tests/check_translations.py`
Expected: `complete`, zero missing and zero orphaned, exit code 0.

- [ ] **Step 5: Run everything one last time**

```bash
python tests/run.py
python tests/check_translations.py
grep -niE "gemini|ollama|openai" VenzAI.lrdevplugin/VenzAIProcess.lua
```
Expected: every suite green, translations complete, and no provider name in the engine.

- [ ] **Step 6: Commit**

```bash
git add tests/check_translations.py VenzAI.lrdevplugin/TranslatedStrings_it.txt
git commit -m "feat: check translation key completeness, and complete Italian"
```

---

## Verifying the success criterion

The design's claim (§13) is that provider #4 touches one new file, one registry line and some translation labels. Once Task 16 is done, test it — not by adding a real provider, but by checking the claim holds:

```bash
# Every file that mentions a provider by name, other than its own driver:
grep -rliE "gemini|ollama|openai" VenzAI.lrdevplugin/ --include=*.lua \
  | grep -v "VenzAIProvider\(Gemini\|OpenAI\|Ollama\).lua"
```

Expected output: `VenzAIProviderRegistry.lua` and nothing else. `PluginInfoProvider.lua`, `VenzAIProcess.lua`, `VenzAISettings.lua`, `VenzAIMessages.lua` and `VenzAISelfTest.lua` must not appear. If one of them does, the driver layer has a leak there, and it should be reported rather than patched with a special case.

## What still requires Lightroom

Nothing above proves any of this works in the application. After Task 16, run in Lightroom Classic:

1. **Self-test** (Task 15) — the first real network contact for all three drivers.
2. **A full run on one photo per provider** — Gemini with a reference, OpenAI without one, Ollama offline. Check the log names the right driver and that snapshots appear per pass.
3. **Masks** — that local corrections land on the mask they name, and that a second pass updates the same mask instead of stacking a new one. This is what `maskIDsByType` exists for and no test outside Lightroom can reach it.
4. **A deliberately wrong setting per driver** — empty key, wrong model name, Ollama stopped — and check the dialog is localized, names the provider, and tells the user which field to fix.
