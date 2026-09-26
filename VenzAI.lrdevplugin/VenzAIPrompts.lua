--[[----------------------------------------------------------------------------

VenzAIPrompts.lua
Building the prompts: the analysis prompt used on every pass, and the prompt
for the reference image.

Moved out of VenzAIProcess verbatim, except that buildNanoBananaPrompt is now
buildReferencePrompt: "Nano Banana" is the name of one Gemini model, and after
the driver layer the engine must not name a provider's anything. The comment
recording which model the prompt was written against stays, because that is
history rather than coupling.

All text sent to a model is in ENGLISH on purpose - see the note below.

The parameter vocabulary comes from VenzAIParse rather than being repeated here:
readCurrentSettings reports the parameters we manage, and the parser validates
the same set. One table, two readers; two tables would drift.

------------------------------------------------------------------------------]]

local LrTasks = import 'LrTasks'

local VenzAILog = require 'VenzAILog'
local Parse = require 'VenzAIParse'

local log = VenzAILog.log

local M = {}

-- All text sent to the model (prompts) is in ENGLISH: vision-language models
-- follow technical instructions more reliably in English, and it's the
-- language the Lightroom develop settings format is documented in.
local PARAM_RULES = [[
Return ONLY a valid JSON object (no markdown fences, no ```json) containing only the keys actually needed, from these categories. Values are numbers, except ConvertToGrayscale which is a JSON boolean and CameraProfile which is a quoted string from a closed list:

GLOBAL TONE: Exposure2012, Highlights2012, Shadows2012, Whites2012, Blacks2012, Contrast2012, Texture, Clarity2012, Dehaze.
BASE COLOR: Temperature, Tint, Vibrance, Saturation.
PARAMETRIC TONE CURVE: ParametricShadows, ParametricDarks, ParametricLights, ParametricHighlights, plus the three region boundaries ParametricShadowSplit, ParametricMidtoneSplit, ParametricHighlightSplit.
DETAIL: Sharpness, SharpenRadius, SharpenDetail, SharpenEdgeMasking, LuminanceSmoothing, LuminanceNoiseReductionDetail, LuminanceNoiseReductionContrast, ColorNoiseReduction, ColorNoiseReductionDetail, ColorNoiseReductionSmoothness, DefringePurpleAmount, DefringeGreenAmount.
GRAIN: GrainAmount, GrainSize, GrainFrequency.
BLACK AND WHITE: ConvertToGrayscale (boolean), GrayMixer<Color> for the same 8 colors.
COLOR PROFILE: CameraProfile (string, closed list - see below).
GEOMETRY: CropAngle, CropLeft, CropTop, CropRight, CropBottom.
POST-CROP VIGNETTE: PostCropVignetteAmount, PostCropVignetteMidpoint, PostCropVignetteFeather, PostCropVignetteRoundness, PostCropVignetteStyle, PostCropVignetteHighlightContrast.
THREE-WAY COLOR GRADING: ColorGradeShadowHue, ColorGradeShadowSat, ColorGradeShadowLum, ColorGradeMidtoneHue, ColorGradeMidtoneSat, ColorGradeMidtoneLum, ColorGradeHighlightHue, ColorGradeHighlightSat, ColorGradeHighlightLum, ColorGradeGlobalHue, ColorGradeGlobalSat, ColorGradeGlobalLum, ColorGradeBlending.
SELECTIVE COLOR PER CHANNEL (HSL mixer, one or more of these 8 colors: Red, Orange, Yellow, Green, Aqua, Blue, Purple, Magenta): HueAdjustment<Color>, SaturationAdjustment<Color>, LuminanceAdjustment<Color> (e.g. HueAdjustmentGreen, SaturationAdjustmentBlue, LuminanceAdjustmentOrange).

Rules on ranges and meaning of values (always respect these, they are technical constraints of the Lightroom format):
- Temperature: on a raw file this is measured in Kelvin, where daylight sits around 4500-7500 and the whole scale runs 2000-50000; on a JPEG it is a -100 to 100 scale instead. The current value is reported to you, so you can see which scale this file uses. Your movement is in the same units: on a raw file, +300 means 300 K warmer.
- Tint: -150 to 150.
- Saturation vs Vibrance: Saturation moves every colour by the same amount, including the ones already vivid and including skin, fur and feathers. Vibrance moves the weaker colours more than the strong ones and largely spares orange, red and yellow. Two different instruments; pick the one whose behaviour you want.
- Texture vs Clarity: Texture acts on medium-sized detail (positive for fur, feathers, foliage; negative to smooth skin and surfaces) and barely touches colour. Clarity is midtone edge contrast over a wider radius and also moves luminance and saturation. Two different instruments; pick the one whose behaviour you want.
- PostCropVignetteAmount: -100 (dark corners) to 100 (bright corners).
- PostCropVignetteMidpoint: 0-100, how far it reaches toward the centre.
- PostCropVignetteFeather: 0-100, edge softness.
- PostCropVignetteRoundness: -100 to 100.
- PostCropVignetteStyle: integer 1 (Highlight Priority), 2 (Color Priority), or 3 (Paint Overlay). Per Adobe, Highlight Priority can cause color shifts in the darkened corners and is meant for photos with bright/near-clipped highlights there (e.g. sky); Color Priority minimizes those color shifts but cannot recover highlights. Default to 2 (Color Priority) in most scenes; use 1 only when the corners contain bright highlights that need recovery.
- PostCropVignetteHighlightContrast: 0-100.
- ColorGrade*Hue: 0-360. ColorGrade*Sat: 0-100. ColorGrade*Lum: -100 to 100. ColorGradeBlending: 0-100.
- HueAdjustment<Color>, SaturationAdjustment<Color>, LuminanceAdjustment<Color>: -100 to 100 each.
- SharpenRadius: 0.5-3.0. SharpenDetail: 0-100. SharpenEdgeMasking: 0-100.
- PARAMETRIC TONE CURVE: ParametricShadows, ParametricDarks, ParametricLights, ParametricHighlights are -100 to 100 each and act on four adjoining tonal regions, from darkest to brightest - the tool for shaping tonality region by region rather than moving the whole range. The three split points are 0-100 and define where those regions meet; their defaults are 25, 50 and 75, and moving them moves the boundaries themselves. They MUST stay strictly increasing (ParametricShadowSplit < ParametricMidtoneSplit < ParametricHighlightSplit) - out-of-order splits are discarded.
- LuminanceNoiseReductionDetail / LuminanceNoiseReductionContrast: 0-100, refine LuminanceSmoothing and do nothing without it. ColorNoiseReductionDetail / ColorNoiseReductionSmoothness: 0-100, likewise refine ColorNoiseReduction.
- DefringePurpleAmount / DefringeGreenAmount: 0-20, remove purple/green colour fringing on high-contrast edges.
- GRAIN: GrainAmount 0-100 is the master control and the other two do nothing without it (GrainSize 0-100, GrainFrequency 0-100). Grain is a style decision: it unifies noise in a high-ISO frame and gives a filmic or documentary rendering, and it costs fine resolution.
- BLACK AND WHITE: ConvertToGrayscale is a JSON boolean (true or false, never a number or a quoted string). GrayMixer<Color> (-100 to 100 for each of the 8 colours) sets how each ORIGINAL colour maps to a grey tone - GrayMixerBlue negative darkens a sky, GrayMixerOrange positive lifts skin or fur - and it applies ONLY when ConvertToGrayscale is true; on a colour photo those values are discarded. In black and white, Vibrance, Saturation and the HSL Saturation/Hue keys do nothing, so do not return them. ColorGrade* still works, as toning.
- CameraProfile: a string, and ONLY one of exactly these values: "Adobe Color", "Adobe Landscape", "Adobe Portrait", "Adobe Neutral", "Adobe Standard", "Adobe Vivid", "Adobe Monochrome". Anything else is discarded. It sets the starting rendering the rest of your values work on: "Adobe Portrait" renders skin more gently, "Adobe Landscape" pushes colour harder, "Adobe Neutral" gives a flatter base to grade from yourself, "Adobe Monochrome" goes with ConvertToGrayscale = true. Omit the key to keep the photo's current profile.

LOCAL (MASKED) CORRECTIONS - you can select a REGION of the photograph with an automatic AI-detected mask and treat it independently of the rest of the frame. This is where an edit stops being a filter laid over the whole picture: a subject brought forward while the ground falls back, a sky given its own light, a face treated differently from the scene around it, a distracting background pushed down so the eye stays where you want it.

Six regions are available, and all six are equally valid: "subject", "people" and "objects" isolate what the picture is of; "sky" and "landscape" isolate the environment; "background" isolates everything behind the subject. There is NO limit on how many you use and no expectation either way - use every region this photograph genuinely contains if that is what your reading of it needs, or none at all if a global treatment says what you want to say. Each region may appear only once per response, because a second mask of the same type selects the same pixels.

THE ONE HARD RULE: the region has to be really there in THIS frame, and you must confirm it by looking before you name it. The AI detector runs on the real photograph afterwards, and asking it to isolate something absent - a sky in a studio portrait, people in an empty landscape, a distinct subject where the frame is an even texture - returns a wrong or garbage selection, and your values then land on the wrong pixels. This check is yours; nothing downstream validates it.

If used, add a top-level "Masks" array. Each element is an object with:
- "type": exactly one of these AI-detectable region names (string, no other value allowed): "subject", "sky", "background", "people", "landscape", "objects".
- one or more LOCAL parameters, same meaning as their global counterparts but affecting ONLY the masked region: local_Exposure (-4 to 4), local_Contrast (-100 to 100), local_Highlights (-100 to 100), local_Shadows (-100 to 100), local_Whites (-100 to 100), local_Blacks (-100 to 100), local_Clarity (-100 to 100), local_Texture (-100 to 100), local_Dehaze (-100 to 100), local_Saturation (-100 to 100), local_Temperature (-100 to 100), local_Tint (-100 to 100), local_Sharpness (-100 to 100), local_Hue (-180 to 180), local_LuminanceNoise (-100 to 100), local_Moire (-100 to 100), local_Defringe (-100 to 100), local_Grain (-100 to 100), local_ToningHue (0 to 360, hue degrees for split-toning within the mask), local_ToningSaturation (0 to 100, intensity of local_ToningHue - only meaningful together with it), local_RefineSaturation (0 to 100, refines how tightly the AI selection follows color boundaries), local_Amount (0 to 200, default 100 = full strength; only include it if you deliberately want a partial-strength effect).
Never repeat the same "type" twice in the same response.

Example of the requested format (names/values are just an example, compute your own from the image):
{
  "Exposure2012": 0.35,
  "Highlights2012": -20,
  "Shadows2012": 35,
  "ParametricHighlights": -12,
  "ParametricShadows": 8,
  "Temperature": 5500,
  "Tint": 5,
  "Vibrance": 15,
  "Sharpness": 40,
  "SharpenRadius": 1.0,
  "SharpenDetail": 25,
  "CropAngle": -1.2,
  "CropLeft": 0.02,
  "CropTop": 0,
  "CropRight": 1,
  "CropBottom": 0.95,
  "PostCropVignetteAmount": -15,
  "PostCropVignetteMidpoint": 50,
  "PostCropVignetteFeather": 65,
  "PostCropVignetteStyle": 2,
  "ColorGradeShadowHue": 210,
  "ColorGradeShadowSat": 12,
  "ColorGradeShadowLum": -3,
  "ColorGradeBlending": 80,
  "HueAdjustmentGreen": -8,
  "SaturationAdjustmentGreen": 10,
  "LuminanceAdjustmentGreen": -5,
  "SaturationAdjustmentBlue": 12,
  "Masks": [
    { "type": "background", "local_Exposure": -0.3, "local_Clarity": -15, "local_Saturation": -10 }
  ]
}
(the "background" mask above is only an example of the FORMAT. Which regions to use, and how many, is your decision about this photograph: any of the six, in any combination, or none. Omit the "Masks" key entirely when you want no local work.)
(the example above is a COLOUR edit, which is the usual case. A black and white answer looks different: it carries "ConvertToGrayscale": true plus the GrayMixer<Color> channels that build the grey rendering - e.g. "GrayMixerBlue": -35, "GrayMixerOrange": 20 - it drops Vibrance, Saturation and the HSL saturation keys entirely, and it may use ColorGrade* as toning)
]]

-- Prompt for the image-generation model (Nano Banana): it must produce a
-- clearly professional reference, because the analysis model will use it as a
-- target to "reverse-engineer" into Lightroom parameters: the sharper the
-- reference, the more precise the analysis will be.
-- Deliberately genre-NEUTRAL: the model has to recognize what kind of
-- photograph it is looking at and then apply the treatment that genre actually
-- calls for. An earlier version hardcoded "editorial nature and wildlife
-- (National Geographic level)", which pushed every photo - portraits and
-- street scenes included - toward the same saturated, high-clarity,
-- HDR-leaning look that reads as dated.
function M.buildReferencePrompt()
    return [[
You are the photographer and colorist responsible for this photograph. You are given the frame; produce the finished version of it - the one you would put your name to.

Read the picture first: what it is of, what the light is doing, what a viewer should feel and where their eye should land. Then take the edit as far as that reading asks. Deep blacks, a colour cast kept because it is the mood, strong separation between subject and ground, a black and white conversion - all of it is yours to decide, provided the decision serves THIS photograph rather than a style applied to every photograph.

An edit too small to see is the same as no edit. Commit to a direction and carry it through the whole frame.

WHAT MAY NOT CHANGE - this image is used as a target to reverse-engineer into develop settings, so it must stay the same photograph:
- The same framing, the same subject, the same position of every element.
- No object added, removed, moved or invented; no change to composition, geometry or content.
- Fully photorealistic. It must read as a photograph that was developed, not as an illustration or a retouch.

Everything else - tone, colour, contrast, light, texture, mood - is yours.

Return only the finished image.
]]
end

-- Crop and angle are deliberately NOT reported to the model as current state:
-- they are the only parameters the model is asked to express RELATIVE to the
-- frame it is looking at, and the caller composes them with the previous
-- passes (priorCrop/priorAngle). Telling the model "CropRight is already
-- 0.95" would invite it to answer with absolute values, which would then get
-- composed a second time and shrink the frame pass after pass.
local SETTINGS_NOT_REPORTED = {
    CropLeft = true, CropTop = true, CropRight = true, CropBottom = true, CropAngle = true,
}

-- Reads the develop settings currently applied to the photo and formats the
-- ones we manage, so that passes after the first know where they are starting
-- from. Without this the model sees only pixels: shown an already-corrected
-- image and asked what it needs, the honest answer is "no exposure
-- correction" - i.e. Exposure2012 = 0 - which applyDevelopSettings then
-- writes over the +0.8 that made the image correct in the first place,
-- undoing the previous pass instead of refining it.
-- Only non-zero values are listed, and the prompt states that anything absent
-- is at zero: that avoids maintaining a table of per-key defaults while
-- staying accurate, since every key whose neutral value is not zero (e.g.
-- SharpenRadius = 1.0) is non-zero and therefore always listed.
-- Returns the formatted block (or nil) and whether the photo is in B&W.
function M.readCurrentSettings(photo)
    -- LrTasks.pcall, not Lua's pcall: reading the catalog can yield, and a
    -- function called through pcall - a C function - may not yield in Lua 5.1.
    -- With the wrong one this failed on EVERY pass ("Yielding is not allowed
    -- within a C or metamethod call"), so every pass after the first was told
    -- nothing about what the previous one had applied and re-proposed settings
    -- from scratch. The refinement loop was refining nothing.
    local ok, settings = LrTasks.pcall(function() return photo:getDevelopSettings() end)
    if not ok or type(settings) ~= "table" then
        log("Could not read the current develop settings: " .. tostring(settings))
        return nil, false
    end

    local isGrayscale = (settings.ConvertToGrayscale == true)

    local keys = {}
    for key in pairs(Parse.VALID_KEYS) do
        if not SETTINGS_NOT_REPORTED[key] then
            table.insert(keys, key)
        end
    end
    table.sort(keys)

    local lines = {}
    for _, key in ipairs(keys) do
        local value = settings[key]
        if type(value) == "number" and value ~= 0 then
            table.insert(lines, string.format("%s = %.4g", key, value))
        end
    end

    if isGrayscale then
        table.insert(lines, "ConvertToGrayscale = true")
    end
    for key in pairs(Parse.STRING_VALID_KEYS) do
        local value = settings[key]
        if type(value) == "string" and value ~= "" then
            table.insert(lines, string.format("%s = %s", key, value))
        end
    end

    if #lines == 0 then
        return nil, isGrayscale
    end
    return table.concat(lines, "\n"), isGrayscale
end

-- Single prompt used for every pass of the analysis/refinement loop. On pass
-- 1 the image is the original photo, paired with the generated reference when
-- the active provider declares that capability; from the following passes
-- onward it is the result of its own previous edit, reviewed with a critical
-- eye.
-- Formats the local corrections already sitting inside each mask, so a later
-- pass knows what it did rather than inventing a fresh treatment on top of a
-- mask that persists.
--
-- Without this the same sky mask went Temperature +25, then -50, then +40 over
-- three passes, and the values a pass did not repeat stayed underneath from an
-- earlier one: the finished region carried three contradictory intentions at
-- once. The global half of this problem is readCurrentSettings above; this is
-- the local half.
--
-- Sorted, because pairs() order is undefined in Lua and a block whose lines
-- shuffle between passes reads to the model as a change that never happened.
function M.formatAppliedMasks(appliedByType)
    if type(appliedByType) ~= "table" then return nil end

    local types = {}
    for maskType in pairs(appliedByType) do
        table.insert(types, maskType)
    end
    if #types == 0 then return nil end
    table.sort(types)

    local lines = {}
    for _, maskType in ipairs(types) do
        local params = appliedByType[maskType] or {}
        local keys = {}
        for key in pairs(params) do table.insert(keys, key) end
        table.sort(keys)
        if #keys > 0 then
            table.insert(lines, string.format('- mask "%s":', maskType))
            for _, key in ipairs(keys) do
                table.insert(lines, string.format("    %s = %.4g", key, params[key]))
            end
        end
    end

    if #lines == 0 then return nil end
    return table.concat(lines, "\n")
end

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

function M.buildAnalysisPrompt(pass, totalPasses, hasReference, currentSettingsBlock, appliedMasksByType)
    local intro
    if pass == 1 then
        intro = "This is the ORIGINAL photo, with no development changes applied yet."
    else
        intro = string.format(
            "This is the photo with the edit YOU YOURSELF applied in the previous pass (pass %d of %d). Look at it with the critical eye of a senior editor reviewing their own work before final publication: identify what is still genuinely wrong and correct that, but do NOT undo what already works well, and do NOT add further correction merely to have something to change. If a parameter is already right, leave it alone - an image that is already there needs no further pass.",
            pass, totalPasses)
    end

    local settingsBlock = ""
    if currentSettingsBlock then
        settingsBlock = "\nThese are the develop settings CURRENTLY applied to the photo - they are what produced the image you are looking at. Any managed parameter not listed here is at zero / not applied:\n\n"
            .. currentSettingsBlock
            .. [[

Read them as information about where you are, not as something to repeat. They tell you how far each slider has already travelled, and which units Temperature is in on this file.
]]
    end

    local maskBlock = M.formatAppliedMasks(appliedMasksByType)
    if maskBlock then
        settingsBlock = settingsBlock
            .. "\nThese local corrections are ALREADY applied inside the masks you created in earlier passes. The masks themselves still exist on the photograph and are reused, not recreated:\n\n"
            .. maskBlock
            .. [[

Your local values are movements too: added to what the mask already carries, then clamped at the ends. 0, or a key you leave out, leaves that local correction exactly as it is. Do not reverse a region's treatment from one pass to the next unless you can say what about the image made you change your mind.
]]
    end

    local referenceBlock = ""
    if hasReference then
        referenceBlock = "\nYou are also given a SECOND IMAGE: a professional reference version generated by another AI tool, useful ONLY to understand how tone, color, contrast, mood and light should look. It is NOT reliable for composition/content: never infer crop, geometry, horizon or content from the second image, only from the first one.\n"
    end

    return [[
You are the photographer and colorist responsible for this photograph, working in Adobe Lightroom Classic. The edit is yours to author, and you are free to take it wherever you believe the picture is strongest.

Decide first what this photograph is FOR - what it is about, what a viewer should feel and where their eye should land - and then build an edit that serves that reading. Post-production is interpretation, not repair: two editors given this frame should reasonably arrive at different images, and the one you return should be recognisably YOUR reading of it.

So commit. Pick a direction and take it far enough to be visible. A correction too small to see is the same as no correction, and an edit that could have been anyone's is a missed opportunity, not a safe one. Where the picture asks for a dramatic decision - deep blacks, a strong colour cast kept because it is the mood, heavy separation between subject and ground, a black-and-white conversion - make it and follow it through the whole frame. Where it asks for restraint, restraint is also a decision, made for this photograph rather than as a default.

The only failure is an edit that is not deliberate: values placed near zero because nothing forced you to move them, or a treatment applied out of habit rather than because you looked at this frame. Be able to say, for every value you return, what in THIS image it is doing.

]] .. intro .. "\n" .. referenceBlock .. settingsBlock .. [[

Reason internally through these steps (do not write the reasoning in the final answer):
0. READ THE PHOTOGRAPH: what kind of picture is this, and what is it about? Name the genre from what you actually see in THIS frame - portrait or people, landscape, wildlife, macro, street or documentary, still life, architecture, night or low-light - and, more importantly, name the subject and the quality of light that make it worth looking at. Then decide the treatment this particular photograph asks for. The genre tells you which materials are in play (skin, fur, foliage, stone, water, neon); what to do with them is your judgement about this image, not a house style you apply to every photo of that kind.
0b. COLOUR OR BLACK AND WHITE: decide which this photograph is, and say so with ConvertToGrayscale. It is an authorial decision, so make it as one: black and white when the picture is carried by light, shape, gesture, texture or contrast; colour when hue is doing real work. If you choose black and white, commit to it and BUILD the grey rendering with GrayMixer<Color> - that mixer is how each original colour becomes a grey, and it is your main tool for separating subject from ground once colour no longer does it. A merely desaturated image is not a black and white photograph. In black and white, Vibrance, Saturation and the HSL saturation keys stop meaning anything; ColorGrade* remains available as toning. Then, separately, consider CameraProfile.
1. HORIZON/LINES: identify the single most reliable horizontal or vertical reference line in THIS image (natural horizon, waterline, tree trunk, building edge, an animal's back/legs when standing on visibly flat ground, etc.) and mentally note which one you used. Estimate its tilt angle from true horizontal/vertical as precisely as you can -> CropAngle. Only use CropAngle = 0 if you actually found such a reference line AND measured it to be within 0.3 degrees of level. Do NOT use 0 merely because you are unsure or found no obvious reference - in that case pick the best available approximate reference and still report a small non-zero correction if any visible tilt remains.
2. EXPOSURE AND TONE: read the tonal distribution as if reading the histogram - what is blocked, what is clipped, where the midtones sit - and then decide where you WANT them. This is the shape of the picture, not just a correction: how dense the blacks are, how the highlights roll off, how much air is in the shadows, how much contrast the subject needs to read. Use Exposure, Highlights, Whites, Shadows, Blacks and Contrast together, and use the parametric curve when you want the boundaries between tonal regions to move rather than the whole range.
3. COLOUR AND MOOD: set Temperature and Tint to the colour of light you want this photograph to have - the neutral reading is one option among several, and keeping or pushing a cast is legitimate when the cast IS the mood. Then use the three-way colour grading (shadows / midtones / highlights, plus global) to give the image a colour identity rather than only a correct one.
4. THE COLOUR MIXER: work the channels that carry this image - Hue, Saturation and Luminance on any of Red, Orange, Yellow, Green, Aqua, Blue, Purple, Magenta. All three dimensions are yours: Hue moves a colour to a different one, Saturation sets its intensity, Luminance sets how light or dark that colour renders, which is what separates a subject from a background of similar brightness. Go through the colours that actually appear in the frame and decide each one.
5. DETAIL: sharpening, noise reduction and grain, judged on the material you named in step 0 and on how you want the picture to feel. Grain is a style choice as much as a repair, and both a clean rendering and a filmic one are legitimate answers.
6. VIGNETTE: shape where the eye settles. Use it when you want the frame to close in on the subject, and leave it at 0 when the composition already does that work.
7. COMPOSITION: propose a crop if it improves the ACTUAL framing of this image (distracting elements at the edges, excessive negative space, rule of thirds), ALWAYS keeping the original aspect ratio.
8. LOCAL WORK WITH MASKS: go through the distinct regions that are actually visible in THIS frame - any of subject, people, objects, sky, landscape, background - and decide what each one needs on its own. This is where an edit stops being a filter over the whole picture and starts being photography: a subject brought forward, a background pushed back, a sky given its own light, a face treated differently from the scene around it. Use as many of the six regions as the photograph genuinely has; there is no quota, in either direction. The one hard rule is that the region must be really there - see the Masks section below.
9. SELF-CHECK: before answering, re-verify every value you are about to output: your Temperature movement must be in the units the current value is reported in; the crop, if any, must keep the original aspect ratio and stay within 0-1; every movement must be plausible as a movement rather than a value copied from the ranges listed below; each Masks entry's "type" must be one of the allowed values, with no duplicate types; the three parametric split points, if present, must be strictly increasing; ConvertToGrayscale must be an unquoted boolean and GrayMixer<Color> must appear only alongside ConvertToGrayscale = true; CameraProfile, if present, must match one of the allowed strings exactly. Also confirm that every number you are returning is a MOVEMENT from the current value and not the value itself, except for the keys listed as positions. Silently fix anything that violates these constraints before producing the final JSON.

]] .. PARAM_RULES .. deltaRuleBlock() .. [[

For CropAngle: this is the RESIDUAL rotation needed looking at THIS image (not a cumulative total across previous passes). If already straight, use 0.
For CropLeft/CropTop/CropRight/CropBottom: normalized 0-1 fractions of THIS image (0,0 = top-left corner, 1,1 = bottom-right corner). ALWAYS subtractive. If the framing is already fine: 0, 0, 1, 1.

Final reminder: your entire response must be a single valid JSON object as described above and nothing else - no markdown fences, no explanation, no text before or after the braces.
]]
end

return M
