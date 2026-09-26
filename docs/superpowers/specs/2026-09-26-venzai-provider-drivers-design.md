# VenzAI — Multi-provider driver architecture

Design spec · 2026-09-26

## 1. Purpose

VenzAI analyzes a photograph with an AI model and applies the resulting
Lightroom develop settings over several refinement passes. It currently
supports two engines, Gemini and a local Ollama server, and knows which one it
is talking to in five different places in `VenzAIProcess.lua`.

This design introduces a driver layer so that the processing engine never names
a provider, and adding a provider becomes a local change instead of an edit
spread across the codebase.

The stated goal is evolution over time: the plug-in should absorb a new
provider, or a new Lightroom develop parameter, without a general rewrite.

## 2. Goals

- One active provider at a time, chosen in the plug-in settings.
- Three drivers at the outset: Gemini, Ollama, OpenAI.
- The engine never branches on provider identity, including for the
  reference-image step.
- Every failure — of the service, of the configuration, or of the driver
  itself — reaches the user as a localized, actionable message.
- All user-facing text is localizable; English and Italian are maintained.
- Adding provider #4 touches exactly two existing lines plus one new file.

## 3. Non-goals

These were considered and deliberately excluded.

- **No fallback chains.** A failing provider reports the failure; it does not
  hand off to another.
- **No parallel or comparative runs.** One provider analyzes one photo.
- **No mixed roles.** The provider that generates the reference image is the
  same one that performs the analysis.
- **No dynamic driver discovery.** The registry is a hand-written table.
- **No settings migration.** The plug-in is in development on a single
  machine. Settings reset once; the API key is re-entered.
- **No retry policy in this iteration.** Drivers never retry; see §6.5.

## 4. Architecture

### 4.1 Layers

| Layer | Responsibility | Provider-specific |
|---|---|---|
| Engine | pass loop, cumulative crop, snapshots, progress, cancellation | no |
| Prompts | building the analysis and reference prompts | no |
| **Drivers** | **serialization, auth, HTTP, text/image extraction, error classification** | **yes** |
| Parsing | whitelist, ranges, crop coherence, mask extraction | no |
| Application | `applyDevelopSettings`, `LrDevelopController` | no |

The driver owns the *protocol*. The engine owns the *photography*.

Parsing and validation stay shared and downstream of every driver. They are the
plug-in's only defence against a model returning `Temperature = 8`, and
duplicating them per provider would guarantee that two copies eventually
diverge.

### 4.2 Analogy and its limits

The model is the device-independent / device-dependent split of an OS graphics
stack: a stable interface, per-device translation, declared capabilities, a
registry. Three differences shape the design:

1. **Non-determinism.** Conforming drivers are not interchangeable in outcome,
   only in form. The validation layer, not the contract, is where correctness
   is actually enforced.
2. **The interface is not a standard.** It is defined by us from two examples
   and risks being "Gemini-shaped". Mitigation: implement the OpenAI driver
   second, not last, because that is where the leaks surface.
3. **Failures are ordinary, not catastrophic.** Quota exhaustion, rate limits
   and truncation are normal operation, so the error model is a first-class
   part of the contract rather than an afterthought.

### 4.3 File layout

Flat files in the bundle root. No Lua subfolders: no Adobe sample uses them,
every sample `require` is a flat name, and there is no evidence Lightroom's
loader searches subdirectories. Nine files do not justify finding out at
runtime.

```
VenzAI.lrdevplugin/
  Info.lua
  VenzAILog.lua                  existing
  VenzAISettings.lua             extended: per-provider settings
  VenzAIMessages.lua             new: the single user-facing message catalog
  PluginInfoProvider.lua         rewritten: renders from declarations
  VenzAIProcess.lua              slimmed: pass loop only
  VenzAIPrompts.lua              extracted from VenzAIProcess
  VenzAIParse.lua                extracted: parsing, validation, masks parsing
  VenzAIMasks.lua                extracted: LrDevelopController application
  VenzAISelfTest.lua             new: the "test providers" menu item
  VenzAIProviderContract.lua     new: shapes + the call funnel
  VenzAIProviderRegistry.lua     new: static list
  VenzAIProviderGemini.lua       new
  VenzAIProviderOllama.lua       new
  VenzAIProviderOpenAI.lua       new
  TranslatedStrings_it.txt
```

`VenzAIProcess.lua` is split as part of this work, not as unrelated
refactoring. It is 1389 lines; extracting the drivers alone removes about 120.
The bulk is prompts (~200 lines of text) and parsing/validation (~350), and
leaving them in place would keep the file unreadable and hide the very boundary
this design creates. The parameter vocabulary in particular is the part that
gets edited most often — adding a develop parameter currently touches
`VALID_KEYS`, `RANGES`, the prompt text and sometimes the validation, four
points scattered through one large file.

## 5. The driver contract

A driver is a table. `VenzAIProviderContract.lua` defines the shapes and
validates them at load time.

### 5.1 Fields

```lua
driver.id             -- "gemini" | "ollama" | "openai"; stable, used as a pref key
driver.displayName    -- LOC key for the provider popup
driver.capabilities   -- { analyze, generateReference, listModels }
driver.settingsFields -- see §8
driver.defaultTimeout -- seconds
```

### 5.2 Methods

```lua
driver.validate(config)                    -> ok, reasonKey
driver.analyze(request, config)            -> Response
driver.generateReference(request, config)  -> Response   -- iff capabilities.generateReference
driver.listModels(config)                  -> names, errorKind, errorDetail
                                                          -- iff capabilities.listModels
```

`validate` returns a `reasonKey` — an error-catalog key, never prose (§7). On
failure the funnel produces a Response with `errorKind = "config_invalid"` and
carries `reasonKey` forward as the message key, so the user is told *which*
field is wrong rather than merely that the configuration is invalid.

### 5.3 Request

What the engine can express without knowing the recipient.

```lua
{
  parts = {                    -- ordered, mixed text and images
    { text = "IMAGE 1:" },
    { image = { mimeType = "image/jpeg", data = <base64> } },
    { text = <analysis prompt> },
  },
  wantsJson = true,            -- ask the service for a JSON-only answer
  timeout = 300,               -- seconds
}
```

`wantsJson` maps to `response_mime_type` on Gemini, `"format": "json"` on
Ollama, and `response_format: { type = "json_object" }` on OpenAI.

### 5.4 Response

Always this shape, whatever happened.

```lua
{
  ok          = false,
  text        = nil,           -- the model's answer, ALREADY unescaped
  image       = nil,           -- { mimeType, data } when a reference was generated
  truncated   = false,
  httpStatus  = 429,
  errorKind   = "rate_limited",
  errorDetail = "...",         -- raw provider text; log and technical section only
}
```

Two consequences that are directly checkable in the resulting code:

- **The unescape hack disappears.** `parseModelSettings` currently receives the
  raw HTTP body and runs `gsub('\\"', '"')` to neutralize the escaping of JSON
  nested inside JSON. With the contract, `response.text` is the real string and
  that line is deleted.
- **The `done_reason` grep disappears.** It becomes `response.truncated`,
  derived by the Ollama driver from `done_reason == "length"` and by the Gemini
  driver from `finishReason == "MAX_TOKENS"`.

## 6. Error model

### 6.1 Three layers

| Layer | When | `errorKind` |
|---|---|---|
| Configuration | before any network call | `config_invalid` |
| Service | the provider answered badly or not at all | `unreachable`, `auth`, `rate_limited`, `model_missing`, `bad_request`, `server_error`, `empty` |
| Driver | the driver's own code failed | `driver_fault`, `not_supported` |

The set is closed. It is also the list of messages to translate, which is the
second reason to keep it closed.

| `errorKind` | Meaning |
|---|---|
| `config_invalid` | a required field is missing or malformed |
| `unreachable` | DNS, connection refused, TLS, timeout |
| `auth` | missing or rejected credentials |
| `rate_limited` | quota exhausted or too many requests |
| `model_missing` | the configured model name does not exist on that service |
| `bad_request` | malformed payload — our bug, not the user's |
| `server_error` | provider 5xx |
| `empty` | HTTP 200 with no usable text |
| `driver_fault` | the driver raised, or returned a malformed Response |
| `not_supported` | a capability was requested that the driver does not declare |
| `unknown` | anything else |

### 6.2 The call funnel

The engine never calls a driver method directly. It calls:

```lua
Contract.call(driver, method, request, config) -> Response
```

which, in order:

1. checks `method` is among the declared capabilities, else `not_supported`;
2. runs `driver.validate(config)`, else `config_invalid`;
3. invokes the method inside `pcall`; a Lua error becomes `driver_fault` with
   the error text in `errorDetail`;
4. validates the returned value against the Response shape; `nil`, a string, or
   a table without `ok` becomes `driver_fault`.

The engine therefore always receives a well-formed Response. A buggy driver can
fail, but cannot abort a run midway and leave the photo in an intermediate
state, and the log names the driver and the method rather than showing an
anonymous stack trace.

### 6.3 Load-time contract validation

`Contract.validateDriver(driver)` runs for every registered driver when the
registry loads, checking that declared capabilities have matching functions,
that `settingsFields` entries are well formed, and that `id` and `displayName`
are present. A malformed driver is reported once, precisely, at load, instead
of failing obscurely halfway through processing.

### 6.4 What the engine does with an error

Failure handling in the pass loop keeps its current shape, which is correct: if
no pass has been applied, report and stop; if at least one pass succeeded, keep
the result and end the loop quietly. The `errorKind` selects the message; the
provider's `displayName` and the failing model name are substituted into it.

### 6.5 No retries

Drivers do not retry. Retrying is a policy, and policies belong in the engine
where they are visible and identical for every provider — the same reason a
graphics driver does not decide on its own to redraw a frame. `rate_limited`
makes a future retry-with-backoff policy easy to add in one place; it is out of
scope here.

## 7. Localization

**Invariant: drivers return codes, never prose.** No driver ever builds a
sentence intended for a human.

- `VenzAIMessages.lua` is the single catalog mapping each `errorKind` and each
  `validate` reason key to a title/body pair. It and the UI labels are the only
  places with user-facing text.
- No string concatenation to build sentences. Everything goes through `LOC`
  with `^1 ^2 ^3` placeholders, because word order differs between languages
  and `"error on " .. provider .. ": " .. reason` is untranslatable by
  construction. This applies to provider names too: `displayName` is a LOC key,
  as are the labels of driver-declared fields.
- `errorDetail` is not translated and is kept separate. It is the provider's
  own raw text. It appears below the localized message in a clearly marked
  technical section, and in full in the log. The localized message must be
  sufficient on its own: if the user has to read Google's JSON to know what to
  do, the message is wrong.
- Fallback stays as it is: English lives in the source as the `LOC` default,
  translations in `TranslatedStrings_<xx>.txt`. An incomplete language degrades
  to English phrase by phrase.
- Languages maintained: English (in source) and Italian. The infrastructure is
  language-agnostic; adding one is a new file.
- A key-completeness check compares the keys used in the source against each
  translation file and lists missing and orphaned keys. With one language this
  was a luxury; it is now part of the work.

## 8. Settings

### 8.1 Declaration

```lua
driver.settingsFields = {
    { key = "apiKey",  role = "secret", required = true,
      label = "$$$/VenzAI/Provider/OpenAI/ApiKey=API key" },
    { key = "model",   role = "model",  default = "gpt-5",
      label = "$$$/VenzAI/Provider/OpenAI/Model=Analysis model" },
    { key = "baseUrl", role = "url",    default = "https://api.openai.com/v1",
      label = "$$$/VenzAI/Provider/OpenAI/BaseUrl=API base URL" },
}
```

`role` selects the control: `secret` renders a `password_field` and persists
through `LrPasswords`; every other role renders an `edit_field` and persists
through `LrPrefs`.

Default model names are configuration, not facts baked into the design. They
are sanity-checked at implementation time against each provider's current model
list through the self-test of §10.

### 8.2 The "Detect models" button is not a special case

All three providers expose a model list — Ollama `/api/tags`, OpenAI
`/v1/models`, Gemini `v1beta/models`. It is therefore a capability, not a
custom UI fragment contributed by a driver:

```lua
driver.capabilities.listModels = true
driver.listModels(config) -> names, errorKind, errorDetail
```

The panel renders the button next to any field with `role = "model"`, for any
driver declaring the capability. The contract stays pure data and functions,
with no view fragments inside it.

### 8.3 Persistence

| What | Where |
|---|---|
| normal field | `prefs["provider.<id>.<key>"]` |
| `secret` field | `LrPasswords.store("provider.<id>.<key>")` |
| active provider | `prefs.activeProvider` |

No migration from the current keys. See §3.

### 8.4 Panel rendering

`PluginInfoProvider.lua` iterates the registry, emits one `group_box` per
driver and one row per declared field, and enables the group bound to
`activeProvider`. Adding a provider does not touch this file.

## 9. Registry

`VenzAIProviderRegistry.lua` is a hand-written table:

```lua
local drivers = {
    require 'VenzAIProviderGemini',
    require 'VenzAIProviderOllama',
    require 'VenzAIProviderOpenAI',
}
```

It validates each driver against the contract at load, exposes
`Registry.all()` and `Registry.byId(id)`, and falls back to the first
registered driver if `prefs.activeProvider` names one that no longer exists.

## 10. Self-test menu item

A `VenzAI: test providers` entry in the Library menu that touches no photo. For
each registered driver it validates the contract, runs `validate(config)`,
calls `listModels`, and reports a table of outcomes and `errorKind` values.

This exists because Lightroom has no test framework and the code only runs
inside the application. When a provider changes its API, or a fourth driver is
added months from now, this is the difference between finding out immediately
and finding out halfway through processing a real photograph.

It requires a second entry in `Info.lua`'s `LrLibraryMenuItems`. That is the
only manifest change in this design, and it is made once, now — adding a
provider later does not touch `Info.lua`.

## 11. Reference image

The reference-image step becomes a declared capability. The engine asks
`driver.capabilities.generateReference`; if present it calls
`Contract.call(driver, "generateReference", ...)` and passes the returned image
into the analysis request as a second image part, exactly as today. If absent
it proceeds without one, which is already the Ollama path.

This removes the last place where the engine names a provider.

## 12. Verification

What can genuinely be checked without running Lightroom:

- all files compile with the SDK's `luac.exe`;
- no unexpected global reads, via `luac -l` bytecode inspection;
- the contract validator rejects a malformed driver with a precise message;
- the translation key-completeness script reports zero missing and zero
  orphaned keys.

What requires a manual run in Lightroom: that masks land on the correct mask,
that prompts produce sensible edits, that timeouts are well calibrated, and
that each driver's request shape is accepted by its live service.

## 13. Success criterion

Adding provider #4 touches:

| File | Change |
|---|---|
| `VenzAIProviderAnthropic.lua` | new, ~150 lines |
| `VenzAIProviderRegistry.lua` | +1 line |
| `TranslatedStrings_it.txt` | +N label lines |
| everything else | none |

If implementation reveals that anything else must change, that is evidence of a
crack in the contract, and it gets reported rather than worked around with a
special case.
