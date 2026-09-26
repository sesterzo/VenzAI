# VenzAI Delta Semantics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the numbers the model returns mean "move this setting by N" instead of "set this setting to N", so that zero becomes the safe answer and three refinement passes converge on a fixed target instead of overwriting each other.

**Architecture:** One new module, `VenzAIDelta`, owns the whole semantics: which keys are movements and which are positions, how a movement is added to the value a photograph already carries, and when a run has arrived. `VenzAIParse` keeps parsing and stays ignorant of meaning; `VenzAIProcess` holds the absolute state and writes it to Lightroom; `VenzAIPrompts` renders the rule and the exception list from the same table the accumulator uses, so the two cannot drift.

**Tech Stack:** Lua 5.1 (Lightroom Classic SDK 15.3, minimum 11.0). Tests run outside Lightroom on the `lua51` runtime embedded in the Python package `lupa`, driven by `python tests/run.py`.

**Spec:** [docs/superpowers/specs/2026-09-26-venzai-delta-semantics-design.md](../specs/2026-09-26-venzai-delta-semantics-design.md)

## Global Constraints

- `LrSdkVersion = 15.3`, `LrSdkMinimumVersion = 11.0`. Do not change either.
- Flat files in the bundle root. No Lua subfolders.
- Drivers return codes, never prose. This plan does not touch a driver.
- Every call that reaches Lightroom or the network goes through `LrTasks.pcall`, never Lua's `pcall`: a function called through `pcall` may not yield in Lua 5.1, and every catalog and HTTP call yields.
- Property-table binding keys contain no dot. Not touched here, but do not reintroduce one.
- **Do not run `git commit`.** Pietro commits himself. The "Commit" step of each task is replaced by "stop and report the files touched".
- One source of truth for the absolute-key list: `VenzAIDelta.ABSOLUTE_KEYS`. `VenzAIPrompts` renders it; nothing else declares it.

## Review Focus

Five conditions the spec implies, that a person will actually hit, and that no task's happy-path test would catch. Each has its test in the task that owns the code.

1. **A photograph whose current value is absent** — a key the photo does not report at all (Task 2). `nil + delta` raises in Lua; the delta must apply against the parameter's neutral starting point instead.
2. **`Temperature` on a JPEG** — the −100…100 scale, where the current range check already assumes Kelvin and is wrong today (Task 2).
3. **A delta on a parameter whose range does not include zero** — `SharpenRadius` is 0.5…3.0, so "neutral" is not 0 and a clamp to 0 would be invalid (Task 2).
4. **A model that returns an absolute out of habit** — the implausibility guard must drop that one key and keep the rest of the response (Task 2).
5. **A mask key set by an earlier pass and not repeated** — it is still on the mask, so the accumulator must not treat its absence as zero (Task 4).

---

### Task 1: VenzAIDelta — the classification, and nothing else

The list of which keys are movements and which are positions, with the neutral value each movement starts from. Kept in its own module because two consumers read it — the accumulator and the prompt — and a second copy is the defect the spec names as most likely.

**Files:**
- Create: `VenzAI.lrdevplugin/VenzAIDelta.lua`
- Test: `tests/test_delta.lua`
- Modify: `tests/run.py` — nothing. The runner globs `tests/test_*.lua`; a new file is picked up automatically.

**Interfaces:**
- Produces:
  - `M.ABSOLUTE_KEYS` — set, `{ [key] = true }`. Keys whose value is a position, a name or a state.
  - `M.isDelta(key)` — returns `true` when the key is a movement. False for an absolute key and for any key the parser does not manage.
  - `M.NEUTRAL` — table, `{ [key] = number }`. The value a parameter sits at on an untouched photograph, for the few where that is not 0.
  - `M.neutralFor(key)` — returns `M.NEUTRAL[key]` or 0.

- [ ] **Step 1: Write the failing test**

Create `tests/test_delta.lua`:

```lua
-- tests/test_delta.lua
local Delta = require 'VenzAIDelta'
local Parse = require 'VenzAIParse'

return {
    { "an amount is a delta", function()
        for _, key in ipairs({ "Exposure2012", "Contrast2012", "Vibrance",
                               "Temperature", "Tint", "GrainAmount",
                               "SaturationAdjustmentGreen", "GrayMixerBlue",
                               "ColorGradeShadowSat", "ColorGradeShadowLum",
                               "local_Exposure", "local_Saturation" }) do
            assert(Delta.isDelta(key), key .. " should be a movement")
        end
    end },

    { "a position, a name or a state is not a delta", function()
        for _, key in ipairs({ "ColorGradeShadowHue", "ColorGradeHighlightHue",
                               "ColorGradeMidtoneHue", "ColorGradeGlobalHue",
                               "ParametricShadowSplit", "ParametricMidtoneSplit",
                               "ParametricHighlightSplit", "PostCropVignetteStyle",
                               "CameraProfile", "ConvertToGrayscale",
                               "CropLeft", "CropTop", "CropRight", "CropBottom",
                               "CropAngle", "local_ToningHue" }) do
            assert(not Delta.isDelta(key), key .. " must stay absolute")
        end
    end },

    { "local_ToningSaturation stays a delta although its companion does not", function()
        assert(Delta.isDelta("local_ToningSaturation"))
        assert(not Delta.isDelta("local_ToningHue"))
    end },

    { "a key the parser does not manage is not a delta", function()
        assert(not Delta.isDelta("Nonsense"))
        assert(not Delta.isDelta(nil))
    end },

    { "every managed numeric key is classified one way or the other", function()
        -- The guard against a key added to the parser and forgotten here: it
        -- would silently be treated as absolute and overwrite the photograph.
        for key in pairs(Parse.VALID_KEYS) do
            local classified = Delta.isDelta(key) or Delta.ABSOLUTE_KEYS[key]
            assert(classified, key .. " is in neither list")
        end
    end },

    { "the neutral value is 0 except where the slider does not start there", function()
        assert(Delta.neutralFor("Exposure2012") == 0)
        assert(Delta.neutralFor("SharpenRadius") == 1.0,
            "got " .. tostring(Delta.neutralFor("SharpenRadius")))
        assert(Delta.neutralFor("local_Amount") == 100,
            "got " .. tostring(Delta.neutralFor("local_Amount")))
        assert(Delta.neutralFor("Nonsense") == 0)
    end },
}
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `python tests/run.py delta`
Expected: `test_delta.lua did not load` — `VenzAIDelta` does not exist yet.

- [ ] **Step 3: Write the module**

Create `VenzAI.lrdevplugin/VenzAIDelta.lua`:

```lua
--[[----------------------------------------------------------------------------

VenzAIDelta.lua
What the numbers in the model's answer MEAN.

A vision model can see that a photograph is still half a stop dark. It cannot
see that Exposure2012 is currently 0.35 - that number is not in the pixels. So
it reports a MOVEMENT, and this module holds the one table that says which
keys are movements and which are positions, plus the arithmetic for applying a
movement to a value the photograph already carries.

It lives apart from VenzAIParse on purpose: the parser reads JSON and knows
nothing about meaning, while both the accumulator and the prompt builder need
this classification. Two copies of it drifting apart is the failure this
module exists to prevent.

------------------------------------------------------------------------------]]

local Parse = require 'VenzAIParse'

local M = {}

--------------------------------------------------------------------------------
-- The classification
--------------------------------------------------------------------------------

-- A position on a wheel, a boundary, an enumeration, a name, a state, or a
-- value that is already relative and composed elsewhere. Everything else the
-- parser manages is a quantity, and a quantity is a movement.
M.ABSOLUTE_KEYS = {
    -- Angles on a colour wheel: adding degrees needs wrap-around at 360.
    ColorGradeShadowHue = true, ColorGradeMidtoneHue = true,
    ColorGradeHighlightHue = true, ColorGradeGlobalHue = true,
    local_ToningHue = true,

    -- Region boundaries, which must stay strictly increasing - a rule that is
    -- checkable on positions and awkward on movements.
    ParametricShadowSplit = true, ParametricMidtoneSplit = true,
    ParametricHighlightSplit = true,

    -- An enumeration, a closed string list, a boolean.
    PostCropVignetteStyle = true,
    CameraProfile = true,
    ConvertToGrayscale = true,

    -- Already relative, already composed with previous passes in VenzAIProcess.
    CropLeft = true, CropTop = true, CropRight = true, CropBottom = true,
    CropAngle = true,
}

-- The value a slider sits at on an untouched photograph, where that is not 0.
-- A movement is applied from here when the photograph reports nothing for the
-- key, and clamping a movement to 0 would be wrong for these.
M.NEUTRAL = {
    SharpenRadius = 1.0,
    local_Amount = 100,
}

function M.neutralFor(key)
    return M.NEUTRAL[key] or 0
end

function M.isDelta(key)
    if type(key) ~= "string" then return false end
    if M.ABSOLUTE_KEYS[key] then return false end
    if Parse.VALID_KEYS[key] then return true end
    if Parse.LOCAL_VALID_KEYS and Parse.LOCAL_VALID_KEYS[key] then return true end
    return false
end

return M
```

- [ ] **Step 4: Check the parser exposes its local key set**

`M.isDelta` reads `Parse.LOCAL_VALID_KEYS`. Confirm it is exported:

Run: `grep -n "^local LOCAL_VALID_KEYS\|^M.LOCAL_VALID_KEYS" VenzAI.lrdevplugin/VenzAIParse.lua`

If it prints `local LOCAL_VALID_KEYS`, it is file-local. Change that one line to `M.LOCAL_VALID_KEYS` and update its uses in that file (`grep -n "LOCAL_VALID_KEYS" VenzAI.lrdevplugin/VenzAIParse.lua`). The table's contents do not change.

- [ ] **Step 5: Run the tests and make sure they pass**

Run: `python tests/run.py delta`
Expected: 6 PASS.

Then `python tests/run.py` — every suite still green.

- [ ] **Step 6: Stop and report**

Do not commit. Report: `VenzAI.lrdevplugin/VenzAIDelta.lua` created, `tests/test_delta.lua` created, `VenzAIParse.lua` possibly modified to export `LOCAL_VALID_KEYS`.

---

### Task 2: The accumulator

Adding a movement to what the photograph carries, clamped at the ends, with the two guards the spec names.

**Files:**
- Modify: `VenzAI.lrdevplugin/VenzAIDelta.lua`
- Test: `tests/test_delta.lua`

**Interfaces:**
- Consumes: `M.isDelta`, `M.neutralFor`, `M.ABSOLUTE_KEYS` from Task 1; `Parse.rangeFor(key)` (added in Step 3 below).
- Produces:
  - `M.apply(current, answer)` — `current` is the absolute state the photograph is in (a flat table, may be missing keys), `answer` is the parsed model response. Returns `absolute, report` where `absolute` is the flat table to hand to `applyDevelopSettings` or `setValue`, and `report` is a list of `{ key, asked, from, to, outcome }`.

  `outcome` is one of:
  - `"applied"` — a movement that changed something.
  - `"negligible"` — a movement smaller than `M.CONVERGENCE_FRACTION` of its range. Still applied; it just asked for nothing worth another pass.
  - `"clamped"` — the sum hit an end of the range.
  - `"implausible"` — larger than the whole range, so dropped.
  - `"absolute"` — a position key whose value differs from the current one.
  - `"unchanged"` — a position key repeating the value already in place.

  The last two exist because the model returns `CropLeft`, `CropTop`, `CropRight`, `CropBottom`, `CropAngle` and `PostCropVignetteStyle` in almost every response, at their neutral values, simply because the prompt asks for them. Treating their mere presence as "still wants something" would make convergence unreachable — the early exit would be dead code on the first run.

- [ ] **Step 1: Write the failing test**

Append to `tests/test_delta.lua`, inside the returned table:

```lua
    --------------------------------------------------------------------------
    -- Accumulation
    --------------------------------------------------------------------------
    { "a movement is added to what the photo carries", function()
        local absolute = Delta.apply({ Exposure2012 = 0.35 }, { Exposure2012 = 0.2 })
        assert(math.abs(absolute.Exposure2012 - 0.55) < 1e-9,
            "got " .. tostring(absolute.Exposure2012))
    end },

    { "the example from the design: -10 then +5 lands on -5", function()
        local after1 = Delta.apply({}, { Contrast2012 = -10 })
        assert(after1.Contrast2012 == -10, "got " .. tostring(after1.Contrast2012))
        local after2 = Delta.apply(after1, { Contrast2012 = 5 })
        assert(after2.Contrast2012 == -5, "got " .. tostring(after2.Contrast2012))
    end },

    { "zero means leave it alone", function()
        local absolute = Delta.apply({ Exposure2012 = 0.35 }, { Exposure2012 = 0 })
        assert(absolute.Exposure2012 == 0.35,
            "zero destroyed the value: " .. tostring(absolute.Exposure2012))
    end },

    { "a key the photo does not report starts from neutral", function()
        -- Review Focus 1: nil + delta raises in Lua.
        local absolute = Delta.apply({}, { Clarity2012 = 12 })
        assert(absolute.Clarity2012 == 12, "got " .. tostring(absolute.Clarity2012))
    end },

    { "a slider whose neutral is not zero starts from its own neutral", function()
        -- Review Focus 3: SharpenRadius is 0.5..3.0, neutral 1.0.
        local absolute = Delta.apply({}, { SharpenRadius = 0.4 })
        assert(math.abs(absolute.SharpenRadius - 1.4) < 1e-9,
            "got " .. tostring(absolute.SharpenRadius))
    end },

    { "the sum is clamped at the end of the range, not discarded", function()
        local absolute, report = Delta.apply({ Clarity2012 = 80 }, { Clarity2012 = 40 })
        assert(absolute.Clarity2012 == 100, "got " .. tostring(absolute.Clarity2012))
        local found
        for _, row in ipairs(report) do
            if row.key == "Clarity2012" then found = row end
        end
        assert(found and found.outcome == "clamped", "the clamp must be reported")
        assert(found.from == 80 and found.to == 100, "the report must carry both ends")
    end },

    { "clamping works at the bottom too", function()
        local absolute = Delta.apply({ Shadows2012 = -90 }, { Shadows2012 = -40 })
        assert(absolute.Shadows2012 == -100, "got " .. tostring(absolute.Shadows2012))
    end },

    { "an absolute key passes through untouched", function()
        local absolute = Delta.apply({ ColorGradeShadowHue = 200 },
                                     { ColorGradeShadowHue = 35 })
        assert(absolute.ColorGradeShadowHue == 35,
            "an angle must be taken as given, got " .. tostring(absolute.ColorGradeShadowHue))
    end },

    { "a string and a boolean pass through untouched", function()
        local absolute = Delta.apply({}, { CameraProfile = "Adobe Portrait",
                                           ConvertToGrayscale = true })
        assert(absolute.CameraProfile == "Adobe Portrait")
        assert(absolute.ConvertToGrayscale == true)
    end },

    { "a movement larger than the whole range is the model reverting to absolutes", function()
        -- Review Focus 4. Contrast2012 spans 200; a 5400 is not a movement.
        local absolute, report = Delta.apply({ Temperature = 5200 }, {
            Temperature = 5400,
            Contrast2012 = 15,
        })
        assert(absolute.Temperature == 5200,
            "the implausible delta must not be added: " .. tostring(absolute.Temperature))
        assert(absolute.Contrast2012 == 15, "the rest of the answer must still apply")
        local found
        for _, row in ipairs(report) do
            if row.key == "Temperature" then found = row end
        end
        assert(found and found.outcome == "implausible", "it must be named in the report")
    end },

    { "Temperature on a JPEG uses the -100..100 scale", function()
        -- Review Focus 2: the range check assumes Kelvin and is wrong for JPEG.
        local absolute = Delta.apply({ Temperature = 20 }, { Temperature = 30 })
        assert(absolute.Temperature == 50, "got " .. tostring(absolute.Temperature))
    end },

    { "Temperature on a raw stays on the Kelvin scale", function()
        local absolute = Delta.apply({ Temperature = 5200 }, { Temperature = 300 })
        assert(absolute.Temperature == 5500, "got " .. tostring(absolute.Temperature))
    end },

    { "a key with no range is passed through without clamping", function()
        local absolute = Delta.apply({}, { CropLeft = 0.02 })
        assert(absolute.CropLeft == 0.02)
    end },

    { "a position repeating what is already there is reported as unchanged", function()
        -- The model returns the crop bounds and the vignette style in nearly
        -- every response, at their neutral values, because the prompt asks for
        -- them. Convergence has to be able to tell that apart from a decision.
        local _, report = Delta.apply(
            { CropLeft = 0, CropRight = 1, PostCropVignetteStyle = 2 },
            { CropLeft = 0, CropRight = 1, PostCropVignetteStyle = 2 })
        for _, row in ipairs(report) do
            assert(row.outcome == "unchanged",
                row.key .. " reported " .. row.outcome .. ", expected unchanged")
        end
    end },

    { "a position that really changes is reported as a decision", function()
        local _, report = Delta.apply({ PostCropVignetteStyle = 2 },
                                      { PostCropVignetteStyle = 1 })
        assert(report[1].outcome == "absolute", "got " .. report[1].outcome)
    end },

    { "a negligible movement is applied but marked as such", function()
        local absolute, report = Delta.apply({ Contrast2012 = 15 }, { Contrast2012 = 1 })
        assert(absolute.Contrast2012 == 16, "it must still be applied")
        assert(report[1].outcome == "negligible", "got " .. report[1].outcome)
    end },
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `python tests/run.py delta`
Expected: the accumulation tests fail with "attempt to call field 'apply' (a nil value)".

- [ ] **Step 3: Export the ranges from the parser**

`Delta.apply` needs the range of a key, and `RANGES` / `LOCAL_RANGES` are file-local in `VenzAIParse.lua`. Add this accessor to `VenzAIParse.lua`, immediately above `function M.settingsNotKept`:

```lua
-- The valid range of one managed key, global or local, or nil for a key that
-- has no range (the HSL and GrayMixer channels are generated, and the crop
-- bounds are fractions). Exposed because VenzAIDelta clamps against it: under
-- delta semantics a sum outside the range must be CLAMPED, never discarded,
-- or the only correction asked for is thrown away.
function M.rangeFor(key)
    return RANGES[key] or LOCAL_RANGES[key]
end
```

Check the generated HSL and GrayMixer ranges are in `RANGES` already:

Run: `grep -n 'RANGES\["HueAdjustment"' VenzAI.lrdevplugin/VenzAIParse.lua`
Expected: a line adding them in a loop. If so they come back from `rangeFor` too, and the last test above ("a key with no range") must be changed to use a key that genuinely has none — `CropLeft`. Adjust the test rather than the code.

- [ ] **Step 4: Write the accumulator**

Append to `VenzAI.lrdevplugin/VenzAIDelta.lua`, above `return M`:

```lua
--------------------------------------------------------------------------------
-- Accumulation
--------------------------------------------------------------------------------

local VenzAILog = require 'VenzAILog'
local log = VenzAILog.scoped("Delta")

-- Lightroom reports Temperature in Kelvin for a raw file and on a -100..100
-- scale for a JPEG. The photograph itself tells us which: nothing on the
-- -100..100 scale reaches 1000. The scale decides both the clamp and what
-- counts as an implausible movement.
-- How small a movement has to be, as a fraction of its parameter's span,
-- before it counts as "nothing left to do". A starting value: it is meant to
-- be tuned once there are real runs to look at, and it lives here alone so
-- that tuning it is one edit.
M.CONVERGENCE_FRACTION = 0.01

local KELVIN_THRESHOLD = 1000
local TEMPERATURE_KELVIN_RANGE = { 2000, 50000 }
local TEMPERATURE_RELATIVE_RANGE = { -100, 100 }

local function rangeFor(key, currentValue)
    if key == "Temperature" then
        if type(currentValue) == "number" and math.abs(currentValue) >= KELVIN_THRESHOLD then
            return TEMPERATURE_KELVIN_RANGE
        end
        return TEMPERATURE_RELATIVE_RANGE
    end
    return Parse.rangeFor(key)
end

-- A movement bigger than the whole span of its parameter is not a movement:
-- it is the model falling back to absolutes out of habit. Dropped, named in
-- the report, and the rest of the answer still applies.
local function isImplausible(range, delta)
    if not range then return false end
    local span = range[2] - range[1]
    return math.abs(delta) > span
end

-- Applies one parsed answer to the absolute state the photograph is in.
-- Returns the new absolute table and a report of what happened to each key.
function M.apply(current, answer)
    current = current or {}
    answer = answer or {}

    local absolute = {}
    for key, value in pairs(current) do
        absolute[key] = value
    end

    local report = {}

    for key, value in pairs(answer) do
        if not M.isDelta(key) or type(value) ~= "number" then
            -- A position, a name or a state. Taken as given - but whether it
            -- CHANGES anything is what convergence needs to know, because the
            -- model returns the crop bounds and the vignette style in nearly
            -- every answer whether or not it wants them different.
            local outcome = (current[key] == value) and "unchanged" or "absolute"
            absolute[key] = value
            table.insert(report, { key = key, asked = value, from = current[key],
                                   to = value, outcome = outcome })
        else
            local from = current[key]
            if type(from) ~= "number" then
                from = M.neutralFor(key)
            end

            local range = rangeFor(key, from)

            if isImplausible(range, value) then
                log(string.format("%s: %s is larger than the whole range; " ..
                    "the model answered an absolute, not a movement. Dropped.",
                    key, tostring(value)))
                table.insert(report, { key = key, asked = value, from = from,
                                       to = from, outcome = "implausible" })
            else
                local sum = from + value
                local outcome = "applied"

                -- A movement too small to be worth another pass. Applied all
                -- the same: it is the caller's business, not this function's.
                if range and math.abs(value) <= (range[2] - range[1]) * M.CONVERGENCE_FRACTION then
                    outcome = "negligible"
                elseif not range and value == 0 then
                    outcome = "negligible"
                end

                if range then
                    if sum < range[1] then
                        sum = range[1]
                        outcome = "clamped"
                    elseif sum > range[2] then
                        sum = range[2]
                        outcome = "clamped"
                    end
                end

                absolute[key] = sum
                table.insert(report, { key = key, asked = value, from = from,
                                       to = sum, outcome = outcome })
            end
        end
    end

    return absolute, report
end
```

- [ ] **Step 5: Run the tests and make sure they pass**

Run: `python tests/run.py delta`
Expected: every test PASS. Then `python tests/run.py` — all suites green.

- [ ] **Step 6: Stop and report**

Do not commit. Report the two files touched.

---

### Task 3: Convergence

Telling a pass that asked for nothing from a pass that asked for something.

**Files:**
- Modify: `VenzAI.lrdevplugin/VenzAIDelta.lua`
- Test: `tests/test_delta.lua`

**Interfaces:**
- Consumes: `M.isDelta`, `Parse.rangeFor`.
- Produces: `M.hasConverged(report, masks)` — true when nothing in the report actually changed the photograph and `masks` is empty or nil. It takes the REPORT from `M.apply`, not the raw answer: only the report knows whether a position key repeated what was already there.

- [ ] **Step 1: Write the failing test**

Append to `tests/test_delta.lua`:

```lua
    --------------------------------------------------------------------------
    -- Convergence
    --------------------------------------------------------------------------
    { "an answer of all zeros has converged", function()
        local _, report = Delta.apply({ Exposure2012 = 0.3 },
                                      { Exposure2012 = 0, Contrast2012 = 0 })
        assert(Delta.hasConverged(report, {}))
    end },

    { "an empty answer has converged", function()
        local _, report = Delta.apply({}, {})
        assert(Delta.hasConverged(report, {}))
    end },

    { "a negligible movement has converged", function()
        -- 1% of Contrast2012's span of 200 is 2.
        local _, report = Delta.apply({ Contrast2012 = 15 }, { Contrast2012 = 1 })
        assert(Delta.hasConverged(report, {}))
    end },

    { "one real value among zeros has NOT converged", function()
        local _, report = Delta.apply({}, { Exposure2012 = 0, Contrast2012 = 25 })
        assert(not Delta.hasConverged(report, {}))
    end },

    { "a proposed mask means there is still work to do", function()
        local _, report = Delta.apply({}, {})
        assert(not Delta.hasConverged(report, { { type = "sky", params = {} } }))
    end },

    { "the crop keys the model always returns do not block convergence", function()
        -- The model returns CropLeft/Top/Right/Bottom, CropAngle and
        -- PostCropVignetteStyle in nearly every response because the prompt
        -- asks for them. At their neutral values they are not a decision, and
        -- treating them as one would make the early exit unreachable.
        local current = { CropLeft = 0, CropTop = 0, CropRight = 1, CropBottom = 1,
                          CropAngle = 0, PostCropVignetteStyle = 2 }
        local _, report = Delta.apply(current, {
            CropLeft = 0, CropTop = 0, CropRight = 1, CropBottom = 1,
            CropAngle = 0, PostCropVignetteStyle = 2, Exposure2012 = 0,
        })
        assert(Delta.hasConverged(report, {}), "the early exit would never fire")
    end },

    { "a real crop IS a decision", function()
        local _, report = Delta.apply({ CropLeft = 0 }, { CropLeft = 0.08 })
        assert(not Delta.hasConverged(report, {}))
    end },

    { "a conversion or a profile change is a decision", function()
        local _, r1 = Delta.apply({}, { ConvertToGrayscale = true })
        assert(not Delta.hasConverged(r1, {}))
        local _, r2 = Delta.apply({ CameraProfile = "Adobe Color" },
                                  { CameraProfile = "Adobe Portrait" })
        assert(not Delta.hasConverged(r2, {}))
    end },
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `python tests/run.py delta`
Expected: FAIL, "attempt to call field 'hasConverged' (a nil value)".

- [ ] **Step 3: Write it**

Append to `VenzAI.lrdevplugin/VenzAIDelta.lua`, above `return M`:

```lua
--------------------------------------------------------------------------------
-- Convergence
--------------------------------------------------------------------------------

-- Outcomes that mean the photograph actually moved. Everything else - a
-- negligible movement, a position repeating itself, a dropped implausible
-- value - leaves the picture where it was.
local CHANGED = {
    applied = true,
    clamped = true,
    absolute = true,
}

-- True when a pass asked for nothing worth running another one. Reads the
-- REPORT rather than the answer, because only the report knows that the crop
-- bounds and the vignette style the model returns in every response were
-- repeating what was already in place.
function M.hasConverged(report, masks)
    if masks and #masks > 0 then return false end

    for _, row in ipairs(report or {}) do
        if CHANGED[row.outcome] then return false end
    end

    return true
end
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `python tests/run.py delta`, then `python tests/run.py`.

- [ ] **Step 5: Stop and report**

Do not commit.

---

### Task 4: The engine holds the absolute state

`VenzAIProcess` stops handing the model's answer straight to `applyDevelopSettings` and starts accumulating it, globally and per mask.

**Files:**
- Modify: `VenzAI.lrdevplugin/VenzAIProcess.lua` — the pass loop around lines 216-470
- Test: none of its own. `VenzAIProcess` is a top-level task script with no seam a test can reach; the arithmetic it now delegates is covered by Tasks 2 and 3, and the mask memory by Task 5's test.

**Interfaces:**
- Consumes: `Delta.apply`, `Delta.hasConverged` from Tasks 2-3; `Prompts.formatAppliedMasks` and the existing `appliedMasksByType` table.
- Produces: nothing other modules read.

- [ ] **Step 1: Require the module**

In the requires block near the top of `VenzAIProcess.lua`, beside `local Parse = require 'VenzAIParse'`:

```lua
local Delta = require 'VenzAIDelta'
```

- [ ] **Step 2: Seed the absolute state before the pass loop**

Immediately after `local priorAngle = 0` (near line 217):

```lua
    -- The absolute state the photograph is in, which the model's movements are
    -- added to. Seeded from what the photo actually reports, so a file that
    -- arrives already edited is a starting point rather than a surprise.
    local absoluteState = {}
    local okSeed, seeded = LrTasks.pcall(function() return photo:getDevelopSettings() end)
    if okSeed and type(seeded) == "table" then
        for key in pairs(Parse.VALID_KEYS) do
            if type(seeded[key]) == "number" then
                absoluteState[key] = seeded[key]
            end
        end
        log("Absolute state seeded from the photograph.")
    else
        log("Could not read the photograph's settings to seed the state; " ..
            "movements will start from each parameter's neutral value.")
    end
```

- [ ] **Step 3: Accumulate instead of overwriting**

Find:

```lua
        catalog:withWriteAccessDo("VenzAI develop (pass " .. pass .. ")", function()
            photo:applyDevelopSettings(developSettings)
        end)
```

Replace with:

```lua
        -- The model answered with MOVEMENTS. Lightroom only accepts absolutes,
        -- so the sum happens here and the log says what each one did.
        local absolute, report = Delta.apply(absoluteState, developSettings)
        absoluteState = absolute

        for _, row in ipairs(report) do
            if row.outcome == "clamped" then
                log(string.format("Pass %d: %s asked %+.4g from %.4g, clamped to %.4g.",
                    pass, row.key, row.asked, row.from, row.to))
            elseif row.outcome == "implausible" then
                log(string.format("Pass %d: %s asked %+.4g, larger than its whole range: dropped.",
                    pass, row.key, row.asked))
            end
        end

        catalog:withWriteAccessDo("VenzAI develop (pass " .. pass .. ")", function()
            photo:applyDevelopSettings(absolute)
        end)
```

Note the crop keys are absolute and were already composed into `developSettings` above this point, so they pass through `Delta.apply` untouched — this is why `CropLeft`…`CropAngle` are in `ABSOLUTE_KEYS`.

- [ ] **Step 4: Stop when it has arrived**

`report` comes from `Delta.apply` in Step 3 and is still in scope. After the mask-application block and before the end of the pass loop, add:

```lua
        if Delta.hasConverged(report, masks) then
            log(string.format("Pass %d: the model asked for nothing more; " ..
                "the photograph has arrived. Skipping the remaining %d pass(es).",
                pass, passes - pass))
            break
        end
```

- [ ] **Step 5: Run the whole suite**

Run: `python tests/run.py`
Expected: every suite green. This file has no test of its own; the suite must not regress.

- [ ] **Step 6: Check the file still compiles under Lua 5.1**

Run: `python tests/run.py compiles`
Expected: PASS. This is the only check that catches a syntax error in a file no test requires.

- [ ] **Step 7: Stop and report**

Do not commit.

---

### Task 5: Masks accumulate the same way

**Files:**
- Modify: `VenzAI.lrdevplugin/VenzAIProcess.lua` — the mask block added earlier today
- Modify: `VenzAI.lrdevplugin/VenzAIMasks.lua` — `applyMasksToPhoto` takes absolutes
- Test: `tests/test_delta.lua`

**Interfaces:**
- Consumes: `Delta.apply`.
- Produces: `applyMasksToPhoto` unchanged in signature; it receives masks whose `params` are already absolute.

- [ ] **Step 1: Write the failing test**

Append to `tests/test_delta.lua`:

```lua
    --------------------------------------------------------------------------
    -- Masks
    --------------------------------------------------------------------------
    { "a mask accumulates its own movements", function()
        local onMask = { local_Exposure = -0.5, local_Temperature = 25 }
        local after = Delta.apply(onMask, { local_Exposure = 0.2 })
        assert(math.abs(after.local_Exposure - (-0.3)) < 1e-9,
            "got " .. tostring(after.local_Exposure))
    end },

    { "a mask key an earlier pass set and this one did not mention survives", function()
        -- Review Focus 5: setValue writes only the keys it is given, so the
        -- value is still on the mask. Absence is not zero.
        local onMask = { local_Exposure = -0.5, local_Highlights = -30 }
        local after = Delta.apply(onMask, { local_Exposure = 0.2 })
        assert(after.local_Highlights == -30,
            "an untouched mask value was lost: " .. tostring(after.local_Highlights))
    end },

    { "a local movement is clamped against the local range", function()
        -- local_Exposure is -4..4, not -5..5 like the global one.
        local after = Delta.apply({ local_Exposure = 3.8 }, { local_Exposure = 1 })
        assert(after.local_Exposure == 4, "got " .. tostring(after.local_Exposure))
    end },
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `python tests/run.py delta`
Expected: the local_Exposure clamp test fails if `Parse.rangeFor` does not consult `LOCAL_RANGES`. If all three pass already, Task 2 Step 3 covered it — tick this step and continue.

- [ ] **Step 3: Accumulate per mask in the engine**

In `VenzAIProcess.lua`, replace the merge block added earlier today:

```lua
            for _, mask in ipairs(masks) do
                appliedMasksByType[mask.type] = appliedMasksByType[mask.type] or {}
                for key, value in pairs(mask.params) do
                    appliedMasksByType[mask.type][key] = value
                end
            end
```

with this, placed BEFORE `Masks.applyMasksToPhoto` rather than after it, because the mask must now be written the absolute value:

```lua
            -- The model's local values are movements too. Sum them onto what
            -- the mask already carries, then hand Lightroom the absolute -
            -- setValue writes a position, not an offset.
            for _, mask in ipairs(masks) do
                local carried = appliedMasksByType[mask.type] or {}
                local absoluteParams, maskReport = Delta.apply(carried, mask.params)
                for _, row in ipairs(maskReport) do
                    if row.outcome == "clamped" or row.outcome == "implausible" then
                        log(string.format("Pass %d: mask '%s' %s asked %+.4g -> %s.",
                            pass, mask.type, row.key, row.asked, row.outcome))
                    end
                end
                mask.params = absoluteParams
                appliedMasksByType[mask.type] = absoluteParams
            end
```

and delete the old post-call merge block entirely.

- [ ] **Step 4: Check the ordering by reading**

`Masks.applyMasksToPhoto(photo, masks, maskIDsByType)` must come AFTER the loop above. Confirm with:

Run: `grep -n "applyMasksToPhoto\|absoluteParams" VenzAI.lrdevplugin/VenzAIProcess.lua`
Expected: the `absoluteParams` lines print with a smaller line number than the `applyMasksToPhoto` call.

- [ ] **Step 5: Run everything**

Run: `python tests/run.py`
Expected: all suites green.

- [ ] **Step 6: Stop and report**

Do not commit.

---

### Task 6: The prompt states the new rule

**Files:**
- Modify: `VenzAI.lrdevplugin/VenzAIPrompts.lua`
- Test: `tests/test_prompts.lua`

**Interfaces:**
- Consumes: `Delta.ABSOLUTE_KEYS` — rendered into the prompt, so the list the model is told matches the list the accumulator uses.

- [ ] **Step 1: Write the failing test**

Append to `tests/test_prompts.lua`:

```lua
    --------------------------------------------------------------------------
    -- Delta semantics
    --------------------------------------------------------------------------
    { "the prompt says the numbers are movements", function()
        local prompt = Prompts.buildAnalysisPrompt(2, 3, true, "Exposure2012 = 0.35", nil)
        assert(prompt:lower():find("movement", 1, true) or prompt:lower():find("move", 1, true),
            "the delta rule is not stated")
        assert(prompt:find("0 means", 1, true) or prompt:lower():find("zero means", 1, true),
            "the model must be told what 0 means now")
    end },

    { "the destructive-zero warning is gone", function()
        -- It existed only because 0 overwrote under absolute semantics.
        local prompt = Prompts.buildAnalysisPrompt(2, 3, true, "Exposure2012 = 0.35", nil)
        assert(not prompt:find("would DESTROY", 1, true),
            "the old warning contradicts the new rule")
        assert(not prompt:find("REPLACES the one above", 1, true),
            "the old replacement rule is still in the prompt")
    end },

    { "every absolute key is named to the model, from the one list", function()
        local Delta = require 'VenzAIDelta'
        local prompt = Prompts.buildAnalysisPrompt(1, 3, false, nil, nil)
        for key in pairs(Delta.ABSOLUTE_KEYS) do
            -- The crop keys are described in their own section already.
            if not key:find("^Crop") then
                assert(prompt:find(key, 1, true),
                    "the model is not told that " .. key .. " is absolute")
            end
        end
    end },
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `python tests/run.py prompts`
Expected: three FAIL.

- [ ] **Step 3: Replace the state paragraph**

In `VenzAIPrompts.lua`, find the block inside `buildAnalysisPrompt` that begins `Read them as your own starting point, not as a suggestion.` and ends at the line about returning 0. Replace the whole `[[ ... ]]` string with:

```lua
            .. [[

Read them as information about where you are, not as something to repeat. They tell you how far each slider has already travelled and which units Temperature is in on this file.
]]
```

- [ ] **Step 4: Add the delta rule, rendered from the one list**

Add this function to `VenzAIPrompts.lua` above `buildAnalysisPrompt`:

```lua
local Delta = require 'VenzAIDelta'

-- The rule, and the exceptions, rendered from VenzAIDelta's own table. Written
-- rather than hand-listed so the sentence the model reads and the arithmetic
-- the engine performs cannot drift apart - which the design names as this
-- change's most likely defect.
local function deltaRuleBlock()
    local absolutes = {}
    for key in pairs(Delta.ABSOLUTE_KEYS) do
        if not key:find("^Crop") then
            table.insert(absolutes, key)
        end
    end
    table.sort(absolutes)

    return [[

HOW TO EXPRESS YOUR ANSWER - read this twice, it is the part most easily got wrong.

Every number you return is a MOVEMENT: how far to move that setting from where it is now, not where to put it. If the photograph needs to be a third of a stop brighter, return Exposure2012: 0.33 - whatever it is currently at. The plug-in adds your movement to the current value and clamps it at the end of the slider.

0 means LEAVE IT ALONE, and omitting a key means the same thing. Both are correct, ordinary answers for a setting that is already where it should be. You are never required to repeat a value to keep it.

Movements are how you converge: each pass, report what is STILL missing between the photograph in front of you and the result you want. As the image gets closer, your movements get smaller, and when nothing is missing you return nothing.

THE EXCEPTIONS - these few keys are POSITIONS, not movements, and you give them as an absolute value exactly as before:
]] .. table.concat(absolutes, ", ") .. [[

The crop bounds and CropAngle are relative to the frame you are looking at, exactly as described in their own section below.
]]
end
```

Then insert `deltaRuleBlock()` into the returned prompt, immediately after `PARAM_RULES`:

```lua
]] .. PARAM_RULES .. deltaRuleBlock() .. [[
```

- [ ] **Step 5: Update the self-check step**

In the step 9 text, after `Silently fix anything that violates these constraints`, insert:

```
Also confirm that every number you are returning is a MOVEMENT from the current value and not the value itself, except for the keys listed as positions.
```

- [ ] **Step 6: Update the local-values paragraph**

In the mask-state block added earlier today, replace the sentence beginning `The same rule applies here as to the global values` with:

```
Your local values are movements too: added to what the mask already carries, clamped at the ends. 0 or an omitted key leaves that local correction as it is.
```

- [ ] **Step 7: Run the tests**

Run: `python tests/run.py prompts`, then `python tests/run.py`.
Expected: all green.

- [ ] **Step 8: Stop and report**

Do not commit.

---

### Task 7: Regenerate the prompt and read it

The one check no assertion makes: that the assembled prompt reads as one coherent instruction rather than two contradictory ones.

**Files:**
- No production file. A throwaway script, written to the scratchpad.

- [ ] **Step 1: Render the prompt as it will be sent**

```bash
python - <<'PY'
from pathlib import Path
from lupa import lua51
ROOT = Path.cwd(); BUNDLE = ROOT / "VenzAI.lrdevplugin"
rt = lua51.LuaRuntime(unpack_returned_tuples=True)
rt.globals()["VENZAI_BUNDLE"] = BUNDLE.as_posix()
rt.globals()["VENZAI_BUNDLE_FILES"] = ",".join(sorted(p.stem for p in BUNDLE.glob("*.lua")))
rt.execute((ROOT / "tests" / "harness.lua").read_text(encoding="utf-8"))
lua = rt.eval("""
function()
    local P = require 'VenzAIPrompts'
    return P.buildAnalysisPrompt(2, 3, true, "Exposure2012 = 0.35\\nClarity2012 = 20",
        { sky = { local_Exposure = -0.5 } })
end""")()
print(lua)
PY
```

- [ ] **Step 2: Read it against this checklist**

- The word "absolute" never describes a slider that is now a movement.
- No sentence still tells the model a value replaces the current one.
- The exception list appears once, not twice.
- The Temperature paragraph in the ranges section does not contradict the delta rule; if it still says "an ABSOLUTE color temperature value in Kelvin (NOT a delta)", that line must change to describe the unit and the scale without forbidding a delta.

Fix anything the checklist catches, rerun `python tests/run.py`, and read it once more.

- [ ] **Step 3: Stop and report**

Do not commit. Report what the read-through changed.

---

## What still requires Lightroom

No test here proves the loop behaves. After Task 7, run in Lightroom Classic on one photograph and read the log:

1. **Three passes moving in one direction.** The sky mask that went +25, −50, +40 should now move once and then in shrinking steps, or not at all.
2. **A clamp that is not a discard.** Push a photograph that needs a lot of one thing and look for `clamped to 100` rather than a missing correction.
3. **Early exit.** A photograph that arrives at pass 2 should log `the photograph has arrived` and stop.
4. **The implausibility guard staying quiet.** If it fires often, the model is ignoring the rule, and the fallback is approach B from the spec's risk section.
5. **`Temperature` on a JPEG and on a raw**, since the scale is chosen from the photograph and only Lightroom reports the real value.
