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
    CameraProfile = {
        ["Adobe Color"] = true, ["Adobe Landscape"] = true, ["Adobe Portrait"] = true,
        ["Adobe Neutral"] = true, ["Adobe Standard"] = true, ["Adobe Vivid"] = true,
        ["Adobe Monochrome"] = true,
    },
}

local RANGES = {
    Exposure2012 = { -5, 5 },
    Highlights2012 = { -100, 100 }, Shadows2012 = { -100, 100 },
    Whites2012 = { -100, 100 }, Blacks2012 = { -100, 100 },
    Contrast2012 = { -100, 100 }, Texture = { -100, 100 },
    Clarity2012 = { -100, 100 }, Dehaze = { -100, 100 },
    Temperature = { 2000, 50000 }, Tint = { -150, 150 },
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
local LOCAL_VALID_KEYS = {
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
M.MAX_MASKS_PER_PASS = 2

-- Extracts and validates the develop settings from the model's JSON response.
-- CropLeft/Top/Right/Bottom and CropAngle remain RELATIVE to the frame seen in
-- this pass: composing them with previous passes happens outside this function.
function M.parseModelSettings(text, currentlyGrayscale)
    local developSettings = {}
    for key, val in text:gmatch('"([%w_]+)"%s*:%s*(%-?%d+%.?%d*)') do
        if M.VALID_KEYS[key] then
            developSettings[key] = tonumber(val)
            log("Extracted parameter: " .. key .. " = " .. tostring(val))
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

    -- Generic defensive validation: every parameter must fall within the
    -- physically valid range for Lightroom. If the model gets it wrong (e.g.
    -- confusing an absolute value with a delta, as happened with
    -- Temperature=8 instead of 5600K), discard it instead of applying it blindly.
    for key, range in pairs(RANGES) do
        local v = developSettings[key]
        if v and (v < range[1] or v > range[2]) then
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
                if LOCAL_VALID_KEYS[key] then
                    local numVal = tonumber(val)
                    local range = LOCAL_RANGES[key]
                    if range and numVal >= range[1] and numVal <= range[2] then
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

    if #masks > M.MAX_MASKS_PER_PASS then
        log(string.format("%d masks proposed, capping to %d.", #masks, M.MAX_MASKS_PER_PASS))
        for i = #masks, M.MAX_MASKS_PER_PASS + 1, -1 do
            table.remove(masks, i)
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

function M.settingsNotKept(asked, actual)
    local missed = {}
    actual = actual or {}

    for key, wanted in pairs(asked or {}) do
        local got = actual[key]
        local same
        if type(wanted) == "number" and type(got) == "number" then
            local scale = math.max(1, math.abs(wanted))
            same = math.abs(wanted - got) <= FLOAT_TOLERANCE * scale
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
