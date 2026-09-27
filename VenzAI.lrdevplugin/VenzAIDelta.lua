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

    -- Properties of the mask MECHANISM rather than corrections to the
    -- photograph: how strongly the mask is applied, and how tightly the AI
    -- selection follows colour boundaries. The prompt describes both as
    -- positions on their own scale ("default 100 = full strength"), and a
    -- model asking for 60% strength returning 60 would otherwise have become
    -- 100 + 60 = 160.
    local_Amount = true,
    local_RefineSaturation = true,

    -- A curve is a SHAPE. The model sends the whole curve it wants, and
    -- adding one curve to another is not an operation that means anything.
    ToneCurvePV2012 = true, ToneCurvePV2012Red = true,
    ToneCurvePV2012Green = true, ToneCurvePV2012Blue = true,

    -- The SHAPE of the vignette, not its strength: where it starts reaching
    -- inward, how soft its edge is, how round it is. Midpoint and Feather sit
    -- at 50 on an untouched photograph, and accumulating carried a real run to
    -- Midpoint 95 and Feather 100 - a vignette that never reaches the frame,
    -- so the darkened corners of the reference simply were not there.
    -- PostCropVignetteAmount stays a movement: that one IS an amount.
    PostCropVignetteMidpoint = true, PostCropVignetteFeather = true,
    PostCropVignetteRoundness = true, PostCropVignetteHighlightContrast = true,

    -- Where the three grading zones meet, not a correction to the photograph:
    -- 50 is the balanced position and 100 is all-highlights. Accumulated, a
    -- model asking twice for 70 would have reached 140 and been clamped to
    -- all-highlights - the opposite of what it asked for the second time.
    ColorGradeBlending = true,

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
-- A white-balance movement smaller than this is not worth another pass. An
-- absolute figure rather than a fraction of the Kelvin scale, because that
-- scale's span says nothing about how big a correction feels.
local NEGLIGIBLE_KELVIN = 25
local TEMPERATURE_RELATIVE_RANGE = { -100, 100 }

-- Which scale this FILE puts Temperature on. Lightroom reports Kelvin for a
-- raw and a -100..100 scale for a rendered file, and the difference is not
-- guessable from the value: a raw whose white balance is still "As Shot"
-- reports no usable Temperature at all, and reading that absence as "small
-- number, therefore the relative scale" is what wrote an 18 K white balance
-- onto a NEF and turned the photograph solid blue.
--
-- An unrecognised format is treated as raw on purpose. The two mistakes are
-- not equal: a small number written as Kelvin destroys the picture, while a
-- Kelvin-sized movement on a relative scale merely overshoots and clamps.
local RENDERED_FORMATS = {
    JPG = true, JPEG = true, TIFF = true, TIF = true, PSD = true, PNG = true,
    VIDEO = true,
}

function M.temperatureScale(fileFormat)
    if type(fileFormat) == "string" and RENDERED_FORMATS[fileFormat:upper()] then
        return "relative"
    end
    return "kelvin"
end

local function rangeFor(key, currentValue, scale)
    if key == "Temperature" then
        if scale == "relative" then
            return TEMPERATURE_RELATIVE_RANGE
        end
        if scale == "kelvin" then
            return TEMPERATURE_KELVIN_RANGE
        end
        -- No scale supplied: fall back to the old inference, which is right
        -- whenever the photograph actually reports a Kelvin value.
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
--
-- Temperature in Kelvin needs its own test, because its span is 48,000 and a
-- 5400 would sail through the span rule while being obviously an absolute. The
-- rule there: a number that would itself be a VALID absolute temperature is an
-- absolute. No plausible white-balance movement reaches 2000 K.
local function isImplausible(range, delta)
    if not range then return false end
    if range == TEMPERATURE_KELVIN_RANGE then
        return math.abs(delta) >= range[1]
    end
    local span = range[2] - range[1]
    return math.abs(delta) > span
end

-- Applies one parsed answer to the absolute state the photograph is in.
-- Returns the new absolute table and a report of what happened to each key.
-- `temperatureScale` is "kelvin", "relative", or nil when the caller does not
-- know; see M.temperatureScale. It decides the units of the Temperature
-- movement, and nothing else in the answer.
function M.apply(current, answer, temperatureScale)
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
            local outcome = "absolute"
            if current[key] == value then
                outcome = "unchanged"
            elseif type(current[key]) == "table" and type(value) == "table"
                and #current[key] == #value then
                -- Two curves holding the same numbers are the same curve, and
                -- == would say otherwise. Convergence depends on telling "the
                -- same curve again" from "a new one".
                local identical = true
                for i = 1, #value do
                    if current[key][i] ~= value[i] then identical = false break end
                end
                if identical then outcome = "unchanged" end
            end
            absolute[key] = value
            table.insert(report, { key = key, asked = value, from = current[key],
                                   to = value, outcome = outcome })
        else
            local from = current[key]
            if type(from) ~= "number" then
                from = M.neutralFor(key)
            end

            local range = rangeFor(key, from, temperatureScale)

            -- A movement needs something to move FROM. On a raw whose white
            -- balance is still "As Shot" the photograph reports no Kelvin, so
            -- there is no absolute to add to and any number we write is read
            -- as an absolute temperature. Refuse it and say so, rather than
            -- inventing a white balance.
            if key == "Temperature" and range == TEMPERATURE_KELVIN_RANGE
                and (type(current[key]) ~= "number" or current[key] < KELVIN_THRESHOLD) then
                log(string.format("Temperature: the photograph reports no Kelvin value " ..
                    "(white balance still As Shot?), so a movement of %s has nothing to " ..
                    "move from. Skipped.", tostring(value)))
                table.insert(report, { key = key, asked = value, from = current[key],
                                       to = current[key], outcome = "unknown_scale" })
                range = nil
            end

            if range == nil and key == "Temperature" and temperatureScale == "kelvin" then
                -- Handled above; fall through without writing anything.
            else

            if range == TEMPERATURE_KELVIN_RANGE and isImplausible(range, value)
                and value >= range[1] then
                -- A number that can only be an absolute temperature IS one.
                -- Dropping it served nobody: the log showed a run cool the
                -- photograph by 500 K, notice, ask for 6150 to climb back, and
                -- be refused - ending colder than it started while the target
                -- was warmer. The intent was unambiguous, so it is honoured.
                log(string.format("Temperature: %s can only be an absolute, " ..
                    "so it is read as the temperature to go to rather than a movement.",
                    tostring(value)))
                local target = value
                if target > range[2] then target = range[2] end
                absolute[key] = target
                table.insert(report, { key = key, asked = value, from = from,
                                       to = target, outcome = "absolute" })

            elseif isImplausible(range, value) then
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
                --
                -- Temperature needs its own threshold: a fraction of its span
                -- means 1% of 48,000 Kelvin, so a 450 K shift - plainly visible
                -- - was being called "nothing left to do" and ending the run.
                -- The fraction is right for a slider whose range IS the range
                -- of a correction, and wrong for an absolute scale.
                local negligible
                if range == TEMPERATURE_KELVIN_RANGE then
                    negligible = NEGLIGIBLE_KELVIN
                elseif range then
                    negligible = (range[2] - range[1]) * M.CONVERGENCE_FRACTION
                end

                if negligible and math.abs(value) <= negligible then
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
    end

    return absolute, report
end

--------------------------------------------------------------------------------
-- Unlocking the white balance
--------------------------------------------------------------------------------

-- True when a Temperature movement was refused because the photograph reports
-- no Kelvin value. That happens on a raw whose white balance is still "As
-- Shot": Lightroom computes the temperature from the file and does not expose
-- it until the white balance is Custom. Setting it to Custom makes Lightroom
-- fill in the as-shot Kelvin, so the next pass has a real number to move from.
--
-- The engine, not this module, does the setting: it owns the write.
function M.needsWhiteBalanceUnlock(report)
    return M.refusedTemperatureMove(report) ~= nil
end

-- The movement that was refused, so the caller can carry it out once the
-- unlock has given the photograph a Kelvin value. Without this the first
-- Temperature the model ever asks for is silently thrown away on every raw
-- that is still at "As Shot", and the pass that follows sees a white balance
-- nobody moved and leaves it alone: the run ends with the one correction the
-- model asked for first never made.
function M.refusedTemperatureMove(report)
    for _, row in ipairs(report or {}) do
        if row.key == "Temperature" and row.outcome == "unknown_scale" then
            return row.asked
        end
    end
    return nil
end

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
    -- A rejected value is NOT an arrival. The model asked for something and we
    -- refused it; the photograph is no closer than it was. Reading that as
    -- "nothing left to do" ended a run one pass in, reporting success over an
    -- untouched picture.
    implausible = true,
    -- Refused for want of a scale: the model asked for something and got
    -- nothing, so the photograph is no closer than it was.
    unknown_scale = true,
}

-- True when a pass asked for nothing worth running another one. Reads the
-- REPORT rather than the answer, because only the report knows that the crop
-- bounds and the vignette style the model returns in every response were
-- repeating what was already in place.
function M.hasConverged(report, maskReports)
    for _, row in ipairs(report or {}) do
        if CHANGED[row.outcome] then return false end
    end

    -- A mask's mere presence used to end the question here, which made the
    -- early exit unreachable on any photograph that uses one: a settled run
    -- keeps naming sky and subject with zero movements, because the prompt
    -- asks it to. What matters is whether the mask asked for anything, which
    -- is the same test as for the global settings - so the caller passes the
    -- report from each mask, not the masks themselves.
    for _, maskReport in ipairs(maskReports or {}) do
        for _, row in ipairs(maskReport or {}) do
            if CHANGED[row.outcome] then return false end
        end
    end

    return true
end

return M
