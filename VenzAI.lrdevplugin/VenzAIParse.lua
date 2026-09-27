--[[----------------------------------------------------------------------------

VenzAIParse.lua
The develop-parameter vocabulary, and turning a model's answer into settings.

Moved out of VenzAIProcess unchanged except as noted below. It stays shared and
downstream of every provider driver on purpose: this is the plug-in's only
defence against a model answering Temperature = 8, and one copy per driver
would guarantee that two of them eventually disagree about what is valid.

Changed in the move: parseModelSettings and parseMasks used to take the raw HTTP
body and run gsub over it to neutralize the escaping of JSON nested inside JSON.
That was a guess rather than a decoder - it turned an escaped backslash into a
quote as well, and left a newline escape as two characters. Both now take
response.text, which the driver contract guarantees is already decoded (see
VenzAIJson), so the parameter is named text and the gsub is gone.

------------------------------------------------------------------------------]]

local VenzAILog = require 'VenzAILog'

-- Resolved lazily: VenzAIDelta requires this module for its key tables, so a
-- require at load time here would be a cycle. By the time a model answer is
-- being parsed, both modules are loaded.
local DeltaModule
local Delta = setmetatable({}, {
    __index = function(_, field)
        DeltaModule = DeltaModule or require 'VenzAIDelta'
        return DeltaModule[field]
    end,
})
local log = VenzAILog.log

local M = {}

local HSL_COLORS = { "Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta" }
local COLOR_GRADE_ZONES = { "Shadow", "Midtone", "Highlight", "Global" }

M.VALID_KEYS = {
    -- Global tone
    Exposure2012 = true, Highlights2012 = true, Shadows2012 = true, Whites2012 = true,
    Blacks2012 = true, Contrast2012 = true, Texture = true, Clarity2012 = true, Dehaze = true,
    -- Base color
    Temperature = true, Tint = true, Vibrance = true, Saturation = true,

    -- Camera calibration. These act on the primaries, before everything else,
    -- which is why they reach a colour character the HSL mixer cannot: HSL
    -- moves colours that are already there, and this changes how the file
    -- reads them in the first place. Seven sliders the plug-in never offered.
    ShadowTint = true,
    RedHue = true, RedSaturation = true,
    GreenHue = true, GreenSaturation = true,
    BlueHue = true, BlueSaturation = true,
    -- Parametric tone curve (scalar sliders, unlike the point curve which is
    -- an array of coordinates and therefore outside this numeric vocabulary)
    ParametricShadows = true, ParametricDarks = true, ParametricLights = true, ParametricHighlights = true,
    ParametricShadowSplit = true, ParametricMidtoneSplit = true, ParametricHighlightSplit = true,
    -- Detail
    Sharpness = true, SharpenRadius = true, SharpenDetail = true, SharpenEdgeMasking = true,
    LuminanceSmoothing = true, ColorNoiseReduction = true,
    LuminanceNoiseReductionDetail = true, LuminanceNoiseReductionContrast = true,
    ColorNoiseReductionDetail = true, ColorNoiseReductionSmoothness = true,
    DefringePurpleAmount = true, DefringeGreenAmount = true,
    -- Grain (the global counterpart of the already-supported local_Grain)
    GrainAmount = true, GrainSize = true, GrainFrequency = true,
    -- Geometry
    CropAngle = true, CropLeft = true, CropTop = true, CropRight = true, CropBottom = true,
    -- Post-crop vignette
    PostCropVignetteAmount = true, PostCropVignetteMidpoint = true, PostCropVignetteFeather = true,
    PostCropVignetteRoundness = true, PostCropVignetteStyle = true, PostCropVignetteHighlightContrast = true,
    -- Three-way color grading
    ColorGradeShadowHue = true, ColorGradeShadowSat = true, ColorGradeShadowLum = true,
    ColorGradeMidtoneHue = true, ColorGradeMidtoneSat = true, ColorGradeMidtoneLum = true,
    ColorGradeHighlightHue = true, ColorGradeHighlightSat = true, ColorGradeHighlightLum = true,
    ColorGradeGlobalHue = true, ColorGradeGlobalSat = true, ColorGradeGlobalLum = true,
    ColorGradeBlending = true,
}
for _, color in ipairs(HSL_COLORS) do
    M.VALID_KEYS["HueAdjustment" .. color] = true
    M.VALID_KEYS["SaturationAdjustment" .. color] = true
    M.VALID_KEYS["LuminanceAdjustment" .. color] = true
    -- B&W channel mixer: how each original color maps to a grey tone. Only
    -- meaningful together with ConvertToGrayscale.
    M.VALID_KEYS["GrayMixer" .. color] = true
end

-- Boolean parameters. Kept in their own table because the numeric extraction
-- in parseModelSettings matches "key": <number> and would silently skip
-- "key": true - these need their own pass over the response body.
local BOOLEAN_VALID_KEYS = {
    ConvertToGrayscale = true,
}

-- String parameters, each with a CLOSED whitelist of accepted values. An
-- arbitrary string is never written through to Lightroom: an unrecognized
-- profile name is silently ignored by applyDevelopSettings, which would look
-- exactly like "the model chose not to change the profile" while actually
-- being a typo. Validating against a fixed list turns that into a log line.
M.STRING_VALID_KEYS = {
    -- CameraProfile used to be here. 53 attempts in the log, 53 failures,
    -- every Adobe profile name, and the photograph answered "Adobe Standard"
    -- every single time: applyDevelopSettings does not honour it. A control
    -- that has never once worked is noise in the prompt and noise in the log,
    -- so it is no longer offered.
}

local RANGES = {
    Exposure2012 = { -5, 5 },
    Highlights2012 = { -100, 100 }, Shadows2012 = { -100, 100 },
    Whites2012 = { -100, 100 }, Blacks2012 = { -100, 100 },
    Contrast2012 = { -100, 100 }, Texture = { -100, 100 },
    Clarity2012 = { -100, 100 }, Dehaze = { -100, 100 },
    Temperature = { 2000, 50000 }, Tint = { -150, 150 },
    ShadowTint = { -100, 100 },
    RedHue = { -100, 100 }, RedSaturation = { -100, 100 },
    GreenHue = { -100, 100 }, GreenSaturation = { -100, 100 },
    BlueHue = { -100, 100 }, BlueSaturation = { -100, 100 },
    Vibrance = { -100, 100 }, Saturation = { -100, 100 },
    ParametricShadows = { -100, 100 }, ParametricDarks = { -100, 100 },
    ParametricLights = { -100, 100 }, ParametricHighlights = { -100, 100 },
    ParametricShadowSplit = { 0, 100 }, ParametricMidtoneSplit = { 0, 100 },
    ParametricHighlightSplit = { 0, 100 },
    Sharpness = { 0, 150 }, SharpenRadius = { 0.5, 3.0 },
    SharpenDetail = { 0, 100 }, SharpenEdgeMasking = { 0, 100 },
    LuminanceSmoothing = { 0, 100 }, ColorNoiseReduction = { 0, 100 },
    LuminanceNoiseReductionDetail = { 0, 100 }, LuminanceNoiseReductionContrast = { 0, 100 },
    ColorNoiseReductionDetail = { 0, 100 }, ColorNoiseReductionSmoothness = { 0, 100 },
    DefringePurpleAmount = { 0, 20 }, DefringeGreenAmount = { 0, 20 },
    GrainAmount = { 0, 100 }, GrainSize = { 0, 100 }, GrainFrequency = { 0, 100 },
    CropAngle = { -45, 45 },
    PostCropVignetteAmount = { -100, 100 }, PostCropVignetteMidpoint = { 0, 100 },
    PostCropVignetteFeather = { 0, 100 }, PostCropVignetteRoundness = { -100, 100 },
    PostCropVignetteStyle = { 1, 3 }, PostCropVignetteHighlightContrast = { 0, 100 },
    ColorGradeBlending = { 0, 100 },
}
for _, zone in ipairs(COLOR_GRADE_ZONES) do
    RANGES["ColorGrade" .. zone .. "Hue"] = { 0, 360 }
    RANGES["ColorGrade" .. zone .. "Sat"] = { 0, 100 }
    RANGES["ColorGrade" .. zone .. "Lum"] = { -100, 100 }
end
for _, color in ipairs(HSL_COLORS) do
    RANGES["HueAdjustment" .. color] = { -100, 100 }
    RANGES["SaturationAdjustment" .. color] = { -100, 100 }
    RANGES["LuminanceAdjustment" .. color] = { -100, 100 }
    RANGES["GrayMixer" .. color] = { -100, 100 }
end

-- LOCAL (masked) correction vocabulary. This is a completely separate
-- parameter namespace from the global M.VALID_KEYS/RANGES above: it exists
-- only inside LrDevelopController.setValue()/getValue() while a mask is
-- selected and the Develop module is active, and it writes into
-- MaskGroupBasedCorrections[N] on the photo instead of the top-level
-- develop settings applied via photo:applyDevelopSettings(). Verified
-- empirically against the documented "local_*" vocabulary from
-- LrDevelopController.html (see VenzAI_APIDiag.lrdevplugin's
-- LOCAL_MASK_API_FINDINGS.md for the full investigation and field mapping).
-- Exported because VenzAIDelta classifies these keys as movements too.
M.LOCAL_VALID_KEYS = {
    local_Temperature = true, local_Tint = true, local_Exposure = true, local_Contrast = true,
    local_Highlights = true, local_Shadows = true, local_Whites = true, local_Blacks = true,
    local_Clarity = true, local_Texture = true, local_Dehaze = true, local_Saturation = true,
    local_Sharpness = true, local_Amount = true,
    local_LuminanceNoise = true, local_Moire = true, local_Defringe = true, local_Grain = true,
    local_RefineSaturation = true, local_ToningHue = true, local_ToningSaturation = true, local_Hue = true,
}
local LOCAL_RANGES = {
    local_Temperature = { -100, 100 }, local_Tint = { -100, 100 },
    local_Exposure = { -4, 4 }, local_Contrast = { -100, 100 },
    local_Highlights = { -100, 100 }, local_Shadows = { -100, 100 },
    local_Whites = { -100, 100 }, local_Blacks = { -100, 100 },
    local_Clarity = { -100, 100 }, local_Texture = { -100, 100 },
    local_Dehaze = { -100, 100 }, local_Saturation = { -100, 100 },
    local_Sharpness = { -100, 100 }, local_Amount = { 0, 200 },
    local_LuminanceNoise = { -100, 100 }, local_Moire = { -100, 100 },
    local_Defringe = { -100, 100 }, local_Grain = { -100, 100 },
    local_RefineSaturation = { 0, 100 }, local_ToningHue = { 0, 360 },
    local_ToningSaturation = { 0, 100 }, local_Hue = { -180, 180 },
}
-- Only the AI-detectable region types are exposed to the model: these are
-- the subtypes accepted by LrDevelopController.createNewMask("aiSelection", subtype)
-- that make sense as a self-contained, semantically-named mask without any
-- geometry/coordinates the model would otherwise have to guess.
M.MASK_SUBJECT_TYPES = {
    subject = true, sky = true, background = true, people = true, landscape = true, objects = true,
}
-- No arbitrary cap. The mechanism caps itself: createNewMask("aiSelection")
-- knows these six regions and no more, and a second mask of a type already
-- used would select the same pixels, so it is rejected as a duplicate below.
-- A fixed number on top of that only told the model to do less.

-- Extracts and validates the develop settings from the model's JSON response.
-- CropLeft/Top/Right/Bottom and CropAngle remain RELATIVE to the frame seen in
-- this pass: composing them with previous passes happens outside this function.
--------------------------------------------------------------------------------
-- Lightroom's own names
--------------------------------------------------------------------------------

-- Colour grading is stored under two generations of names at once, and reading
-- back what a photograph reports is the only way to find out which is which:
--
--   ColorGradeMidtone*, ColorGradeGlobal*, ColorGradeShadowLum,
--   ColorGradeHighlightLum, ColorGradeBlending   -> the new names, correct
--   the HUE and SATURATION of shadows and highlights -> still the legacy
--   split-toning names, because that is where those two wheels came from
--
-- We wrote ColorGradeShadowHue, which does not exist, so the model's warm
-- highlight grading vanished on every pass of every run - and a golden light
-- is exactly what lives in those four values.
--
-- The vocabulary the prompt documents does not change: the translation happens
-- at the two boundaries that touch Lightroom, and nothing upstream needs to
-- know there were ever two spellings.
local TO_LIGHTROOM = {
    ColorGradeShadowHue = "SplitToningShadowHue",
    ColorGradeShadowSat = "SplitToningShadowSaturation",
    ColorGradeHighlightHue = "SplitToningHighlightHue",
    ColorGradeHighlightSat = "SplitToningHighlightSaturation",
}

local FROM_LIGHTROOM = {}
for ours, theirs in pairs(TO_LIGHTROOM) do
    FROM_LIGHTROOM[theirs] = ours
end

-- Our vocabulary -> what applyDevelopSettings expects.
function M.toLightroomSettings(settings)
    local out = {}
    for key, value in pairs(settings or {}) do
        out[TO_LIGHTROOM[key] or key] = value
    end
    return out
end

-- What the photograph reports -> our vocabulary.
function M.fromLightroomSettings(settings)
    local out = {}
    for key, value in pairs(settings or {}) do
        out[FROM_LIGHTROOM[key] or key] = value
    end
    return out
end

--------------------------------------------------------------------------------
-- The point tone curve
--------------------------------------------------------------------------------

-- Lightroom stores a curve as a FLAT list of alternating x and y values on a
-- 0-255 grid. A probe on a real photograph answered {0, 0, 255, 255} - the two
-- corners, which is the identity. This is the only value in the whole
-- vocabulary that is not a single number, and it is where a photograph gets a
-- character the four parametric sliders cannot reach.
M.CURVE_KEYS = {
    ToneCurvePV2012 = true,
    ToneCurvePV2012Red = true,
    ToneCurvePV2012Green = true,
    ToneCurvePV2012Blue = true,
}

-- More than this is not a curve any more, it is a drawing - and a model that
-- returns fifty points has misunderstood the question.
M.MAX_CURVE_POINTS = 16

-- Returns the curve, or nil and the reason. Everything here is a rule
-- Lightroom itself enforces in its own UI: the curve spans the whole tonal
-- range, x climbs, and every value sits on the grid. A malformed curve is
-- discarded rather than repaired, because guessing at what the model meant is
-- how a photograph gets a shape nobody chose.
function M.validateCurve(values)
    if type(values) ~= "table" then return nil, "not a list" end

    local count = #values
    if count % 2 ~= 0 then return nil, "an odd number of values: a point needs an x and a y" end

    local points = count / 2
    if points < 2 then return nil, "fewer than two points" end
    if points > M.MAX_CURVE_POINTS then
        return nil, string.format("%d points, more than the %d allowed", points, M.MAX_CURVE_POINTS)
    end

    local previousX
    for i = 1, count, 2 do
        local x, y = values[i], values[i + 1]
        if type(x) ~= "number" or type(y) ~= "number" then return nil, "a value is not a number" end
        if x < 0 or x > 255 or y < 0 or y > 255 then return nil, "a value is outside 0-255" end
        if previousX and x <= previousX then return nil, "x does not climb: the curve doubles back" end
        previousX = x
    end

    if values[1] ~= 0 then return nil, "does not start at x=0" end
    if values[count - 1] ~= 255 then return nil, "does not end at x=255" end

    return values
end

function M.parseModelSettings(text, currentlyGrayscale)
    local developSettings = {}
    for key, val in text:gmatch('"([%w_]+)"%s*:%s*(%-?%d+%.?%d*)') do
        if M.VALID_KEYS[key] then
            developSettings[key] = tonumber(val)
            log("Extracted parameter: " .. key .. " = " .. tostring(val))
        end
    end

    -- Curves need their own pass too: the value is a JSON array, and the
    -- numeric pattern above stops at the first non-digit so it never sees one.
    for key, body in text:gmatch('"([%w_]+)"%s*:%s*%[([^%]]*)%]') do
        if M.CURVE_KEYS[key] then
            local values = {}
            for number in body:gmatch("%-?%d+%.?%d*") do
                table.insert(values, tonumber(number))
            end

            local curve, why = M.validateCurve(values)
            if curve then
                developSettings[key] = curve
                log(string.format("Extracted curve: %s with %d point(s)", key, #curve / 2))
            else
                log(string.format("%s discarded: %s.", key, tostring(why)))
            end
        end
    end

    -- Booleans need their own pass: the numeric pattern above stops at the
    -- first non-digit, so "ConvertToGrayscale": true never matches it. %a+
    -- deliberately matches only bare words, so a quoted string value (which
    -- starts with '"') is left to the string pass below.
    for key, val in text:gmatch('"([%w_]+)"%s*:%s*(%a+)') do
        if BOOLEAN_VALID_KEYS[key] and (val == "true" or val == "false") then
            developSettings[key] = (val == "true")
            log("Extracted boolean parameter: " .. key .. " = " .. val)
        end
    end

    for key, val in text:gmatch('"([%w_]+)"%s*:%s*"([^"]*)"') do
        local allowedValues = M.STRING_VALID_KEYS[key]
        if allowedValues then
            if allowedValues[val] then
                developSettings[key] = val
                log("Extracted string parameter: " .. key .. " = " .. val)
            else
                log(string.format("%s '%s' is not in the allowed list, discarded.", key, tostring(val)))
            end
        end
    end

    if next(developSettings) == nil then
        return nil, "No parameter extracted from the JSON response."
    end

    -- Range validation applies ONLY to the keys that are still positions.
    --
    -- This loop used to run over every key, and it was right while the model
    -- answered absolutes. Under delta semantics the numbers are movements, and
    -- a movement legitimately sits outside the slider's absolute range: -20 on
    -- Sharpness (range 0..150) is an ordinary request to sharpen less, and
    -- every white-balance movement is below Temperature's 2000 floor. Checking
    -- a movement against an absolute range threw away the correction instead of
    -- applying it - silently, with the photograph left half-edited.
    --
    -- The guard this loop was built for has not disappeared: VenzAIDelta clamps
    -- the SUM at the range, and rejects a movement so large it can only be an
    -- absolute the model sent out of habit. It moved downstream, where the two
    -- kinds of number can be told apart.
    for key, range in pairs(RANGES) do
        local v = developSettings[key]
        if v and Delta.ABSOLUTE_KEYS[key] and (v < range[1] or v > range[2]) then
            log(string.format("%s out of range (%s, expected %s..%s), discarded.", key, tostring(v), tostring(range[1]), tostring(range[2])))
            developSettings[key] = nil
        end
    end

    if developSettings.PostCropVignetteStyle then
        developSettings.PostCropVignetteStyle = math.floor(developSettings.PostCropVignetteStyle + 0.5)
    end

    -- The three parametric curve split points must stay strictly increasing
    -- (shadow < midtone < highlight): they are region boundaries, not
    -- independent sliders. Lightroom's own UI enforces this by construction,
    -- so out-of-order values never occur through the GUI and their behaviour
    -- when written directly is unspecified. Only the splits are discarded -
    -- the four region sliders they delimit stay valid against their defaults
    -- (25/50/75), so a usable curve correction survives.
    local shadowSplit = developSettings.ParametricShadowSplit
    local midtoneSplit = developSettings.ParametricMidtoneSplit
    local highlightSplit = developSettings.ParametricHighlightSplit
    if shadowSplit or midtoneSplit or highlightSplit then
        local s = shadowSplit or 25
        local m = midtoneSplit or 50
        local h = highlightSplit or 75
        if not (s < m and m < h) then
            log(string.format("Parametric curve split points out of order (shadow=%s midtone=%s highlight=%s), discarded.", tostring(s), tostring(m), tostring(h)))
            developSettings.ParametricShadowSplit = nil
            developSettings.ParametricMidtoneSplit = nil
            developSettings.ParametricHighlightSplit = nil
        end
    end

    -- The B&W channel mixer only does anything when the photo is actually
    -- converted: GrayMixer* values on a colour photo are silently inert, so
    -- keeping them would make the log misleading about what was applied.
    -- The photo counts as B&W if this pass converts it OR if an earlier pass
    -- already did and this response simply doesn't repeat the flag - without
    -- `currentlyGrayscale` the mixer refinements of every pass after the
    -- conversion would be thrown away.
    local willBeGrayscale = currentlyGrayscale or false
    if developSettings.ConvertToGrayscale ~= nil then
        willBeGrayscale = developSettings.ConvertToGrayscale
    end
    if not willBeGrayscale then
        for _, color in ipairs(HSL_COLORS) do
            local mixerKey = "GrayMixer" .. color
            if developSettings[mixerKey] then
                log(string.format("%s ignored: the photo is not being converted to black and white.", mixerKey))
                developSettings[mixerKey] = nil
            end
        end
    end

    -- Defensive crop validation: it must be a subtractive crop within the
    -- bounds of the seen frame (0..1). If the values aren't consistent, ignore it.
    local cl, ct, cr, cb = developSettings.CropLeft, developSettings.CropTop, developSettings.CropRight, developSettings.CropBottom
    if cl or ct or cr or cb then
        cl = cl or 0
        ct = ct or 0
        cr = cr or 1
        cb = cb or 1

        local valid = cl >= 0 and ct >= 0 and cr <= 1 and cb <= 1 and cr > cl and cb > ct

        if valid then
            -- The aspect ratio is preserved only by removing the SAME fraction
            -- from width and height (for any W,H: (f*W)/(f*H) = W/H). If the
            -- model proposes different fractions, the image ends up distorted:
            -- fix it by forcing the two fractions to match, centering the crop
            -- on the chosen area.
            local widthFrac = cr - cl
            local heightFrac = cb - ct

            if math.abs(widthFrac - heightFrac) > 0.001 then
                local targetFrac = math.min(widthFrac, heightFrac)
                local centerX = (cl + cr) / 2
                local centerY = (ct + cb) / 2

                cl = centerX - targetFrac / 2
                cr = centerX + targetFrac / 2
                ct = centerY - targetFrac / 2
                cb = centerY + targetFrac / 2

                if cl < 0 then cr = cr - cl; cl = 0 end
                if ct < 0 then cb = cb - ct; ct = 0 end
                if cr > 1 then cl = cl - (cr - 1); cr = 1 end
                if cb > 1 then ct = ct - (cb - 1); cb = 1 end

                log(string.format("Proposed crop distorted the aspect ratio (widthFrac=%.4f heightFrac=%.4f), corrected to: Left=%.4f Top=%.4f Right=%.4f Bottom=%.4f", widthFrac, heightFrac, cl, ct, cr, cb))
            end

            developSettings.CropLeft, developSettings.CropTop = cl, ct
            developSettings.CropRight, developSettings.CropBottom = cr, cb
        else
            log(string.format("Invalid crop, discarded: Left=%s Top=%s Right=%s Bottom=%s", tostring(cl), tostring(ct), tostring(cr), tostring(cb)))
            developSettings.CropLeft, developSettings.CropTop = nil, nil
            developSettings.CropRight, developSettings.CropBottom = nil, nil
        end
    end

    return developSettings
end

-- Scans `body` starting at `openPos` (the index of an opening '[' or '{')
-- and returns the index of its matching close character, correctly
-- skipping over characters inside JSON string literals so that a bracket
-- appearing inside a string value doesn't throw off the depth count. Used
-- to extract the "Masks" array and each mask object without needing a full
-- JSON parser (the rest of this file already relies on simple gmatch-based
-- extraction for flat key/value pairs).
local function findMatchingClose(body, openPos, openChar, closeChar)
    local depth = 0
    local inString = false
    local i = openPos
    local n = #body
    while i <= n do
        local c = body:sub(i, i)
        if inString then
            if c == '\\' then
                i = i + 1 -- skip the escaped character
            elseif c == '"' then
                inString = false
            end
        else
            if c == '"' then
                inString = true
            elseif c == openChar then
                depth = depth + 1
            elseif c == closeChar then
                depth = depth - 1
                if depth == 0 then
                    return i
                end
            end
        end
        i = i + 1
    end
    return nil
end

-- Locates the "Masks": [ ... ] array (if any) in the response body and
-- returns each top-level {...} object inside it as a raw string, ready to
-- be scanned individually for its "type" and local_* fields.
local function extractMaskBlocks(body)
    local blocks = {}
    local keyPos = body:find('"Masks"%s*:%s*%[')
    if not keyPos then
        return blocks
    end
    local openBracketPos = body:find('%[', keyPos)
    if not openBracketPos then return blocks end
    local closeBracketPos = findMatchingClose(body, openBracketPos, '[', ']')
    if not closeBracketPos then return blocks end

    local arrayContent = body:sub(openBracketPos + 1, closeBracketPos - 1)

    local pos = 1
    while true do
        local braceStart = arrayContent:find('{', pos)
        if not braceStart then break end
        local braceEnd = findMatchingClose(arrayContent, braceStart, '{', '}')
        if not braceEnd then break end
        table.insert(blocks, arrayContent:sub(braceStart, braceEnd))
        pos = braceEnd + 1
    end
    return blocks
end

-- Extracts and validates the optional "Masks" array from the model's JSON
-- response: each entry becomes { type = "sky", params = { local_Exposure = -0.4, ... } }.
-- Returns an empty table if there is no "Masks" key, or if nothing in it
-- survives validation - this feature is additive and must never break the
-- (already working) global-settings parsing in parseModelSettings above.
function M.parseMasks(text)
    local blocks = extractMaskBlocks(text)

    local masks = {}
    local seenTypes = {}
    for _, block in ipairs(blocks) do
        local maskType = block:match('"type"%s*:%s*"([%a_]+)"')
        if not maskType then
            log("Mask block without a valid 'type' field, discarded.")
        elseif not M.MASK_SUBJECT_TYPES[maskType] then
            log("Mask type '" .. tostring(maskType) .. "' not in the allowed list, discarded.")
        elseif seenTypes[maskType] then
            log("Duplicate mask type '" .. maskType .. "' in the same pass, discarded.")
        else
            local params = {}
            local count = 0
            for key, val in block:gmatch('"(local_%a+)"%s*:%s*(%-?%d+%.?%d*)') do
                if M.LOCAL_VALID_KEYS[key] then
                    local numVal = tonumber(val)
                    -- Same reasoning as the global loop above: a local value
                    -- is a movement now, and -10 on local_ToningSaturation
                    -- (range 0..100) is an ordinary request. Only the local
                    -- keys that are still positions are range-checked here;
                    -- the sum is clamped in VenzAIDelta.
                    local range = LOCAL_RANGES[key]
                    local isPosition = Delta.ABSOLUTE_KEYS[key]
                    if not isPosition or not range
                        or (numVal >= range[1] and numVal <= range[2]) then
                        params[key] = numVal
                        count = count + 1
                    else
                        log(string.format("Mask '%s': %s=%s out of range, discarded.", maskType, key, tostring(numVal)))
                    end
                end
            end

            if count > 0 then
                seenTypes[maskType] = true
                table.insert(masks, { type = maskType, params = params })
                log(string.format("Mask parsed: type=%s, %d local parameter(s).", maskType, count))
            else
                log("Mask type '" .. maskType .. "' had no valid local_* parameter, discarded.")
            end
        end
    end

    return masks
end

--------------------------------------------------------------------------------
-- What Lightroom actually kept
--------------------------------------------------------------------------------

-- Compares what we asked applyDevelopSettings for with what the photo reports
-- afterwards, and returns the ones that did not stick: { key, asked, got }.
--
-- "The call returned" is not "Lightroom kept it". Some settings are computed
-- from others and quietly overridden - Temperature and Tint are recomputed
-- from the as-shot values while WhiteBalance says As Shot - and from outside
-- that is indistinguishable from a model that never proposed them. This turns
-- the difference into a log line instead of an afternoon at the sliders.
local FLOAT_TOLERANCE = 1e-4

-- The valid range of one managed key, global or local, or nil for a key that
-- has no range (the HSL and GrayMixer channels are generated, and the crop
-- bounds are fractions). Exposed because VenzAIDelta clamps against it: under
-- delta semantics a sum outside the range must be CLAMPED, never discarded,
-- or the only correction asked for is thrown away.
function M.rangeFor(key)
    return RANGES[key] or LOCAL_RANGES[key]
end

function M.settingsNotKept(asked, actual)
    local missed = {}
    actual = actual or {}

    for key, wanted in pairs(asked or {}) do
        local got = actual[key]
        local same
        if type(wanted) == "number" and type(got) == "number" then
            local scale = math.max(1, math.abs(wanted))
            same = math.abs(wanted - got) <= FLOAT_TOLERANCE * scale
        elseif type(wanted) == "table" and type(got) == "table" then
            -- A curve. Two tables are never == in Lua even when they hold the
            -- same numbers, so comparing them by identity would report every
            -- curve as refused.
            same = #wanted == #got
            if same then
                for i = 1, #wanted do
                    if wanted[i] ~= got[i] then same = false break end
                end
            end
        else
            same = (wanted == got)
        end
        if not same then
            table.insert(missed, { key = key, asked = wanted, got = got })
        end
    end

    table.sort(missed, function(a, b) return a.key < b.key end)
    return missed
end

return M
