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
Return ONLY a valid JSON object (no markdown fences, no ```json) containing only the keys actually needed, from these categories. Values are numbers, except ConvertToGrayscale which is a JSON boolean:

GLOBAL TONE: Exposure2012, Highlights2012, Shadows2012, Whites2012, Blacks2012, Contrast2012, Texture, Clarity2012, Dehaze.
BASE COLOR: Temperature, Tint, Vibrance, Saturation.
CAMERA CALIBRATION: ShadowTint, RedHue, RedSaturation, GreenHue, GreenSaturation, BlueHue, BlueSaturation.
POINT TONE CURVE: ToneCurvePV2012, and the three channel curves ToneCurvePV2012Red, ToneCurvePV2012Green, ToneCurvePV2012Blue. These are the one value here that is a LIST rather than a number - see the rules below.
PARAMETRIC TONE CURVE: ParametricShadows, ParametricDarks, ParametricLights, ParametricHighlights, plus the three region boundaries ParametricShadowSplit, ParametricMidtoneSplit, ParametricHighlightSplit.
DETAIL: Sharpness, SharpenRadius, SharpenDetail, SharpenEdgeMasking, LuminanceSmoothing, LuminanceNoiseReductionDetail, LuminanceNoiseReductionContrast, ColorNoiseReduction, ColorNoiseReductionDetail, ColorNoiseReductionSmoothness, DefringePurpleAmount, DefringeGreenAmount.
GRAIN: GrainAmount, GrainSize, GrainFrequency.
BLACK AND WHITE: ConvertToGrayscale (boolean), GrayMixer<Color> for the same 8 colors.
GEOMETRY: CropAngle, CropLeft, CropTop, CropRight, CropBottom.
POST-CROP VIGNETTE: PostCropVignetteAmount, PostCropVignetteMidpoint, PostCropVignetteFeather, PostCropVignetteRoundness, PostCropVignetteStyle, PostCropVignetteHighlightContrast.
THREE-WAY COLOR GRADING: ColorGradeShadowHue, ColorGradeShadowSat, ColorGradeShadowLum, ColorGradeMidtoneHue, ColorGradeMidtoneSat, ColorGradeMidtoneLum, ColorGradeHighlightHue, ColorGradeHighlightSat, ColorGradeHighlightLum, ColorGradeGlobalHue, ColorGradeGlobalSat, ColorGradeGlobalLum, ColorGradeBlending.
SELECTIVE COLOR PER CHANNEL (HSL mixer, one or more of these 8 colors: Red, Orange, Yellow, Green, Aqua, Blue, Purple, Magenta): HueAdjustment<Color>, SaturationAdjustment<Color>, LuminanceAdjustment<Color> (e.g. HueAdjustmentGreen, SaturationAdjustmentBlue, LuminanceAdjustmentOrange).

Rules on ranges and meaning of values (always respect these, they are technical constraints of the Lightroom format):
- Temperature and Tint: READ THE CURRENT VALUE BEFORE YOU MOVE EITHER. On a raw file they are measured in Kelvin, and the values you are shown are not a cast to be corrected - they are the white balance the camera calculated so that THIS scene renders neutral, and they differ from file to file. A raw whose current Temperature is 8100 is not a warm photograph: 8100 is its neutral. Moving away from that number ADDS a cast rather than removing one, and a movement of 1000 K or more is a deliberate, strong stylistic decision, not a correction. Do not reason from daylight sitting around 5500: that rule is about light, and this number is about a file. On a rendered file (JPEG, TIFF) the scale is -100 to 100 instead, where 0 is that file's neutral and the same logic applies. Your movement is in whichever units the current value is reported in.
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
- CAMERA CALIBRATION: ShadowTint, RedHue, RedSaturation, GreenHue, GreenSaturation, BlueHue, BlueSaturation, -100 to 100 each. These act on the three primaries before any other colour control, so they change how the file renders colour rather than correcting colour that is already rendered. A small move here reaches every part of the frame at once and is what gives a photograph a colour signature; the HSL mixer, by contrast, adjusts one band of colour that is already there. ShadowTint moves the shadows between green and magenta.
- SharpenRadius: 0.5-3.0. SharpenDetail: 0-100. SharpenEdgeMasking: 0-100.
- POINT TONE CURVE: a flat JSON list of alternating x and y values on a 0-255 grid, for example [0,0, 64,48, 192,208, 255,255]. x is the input tone, y is what it becomes: a point above the diagonal lightens that tone, below it darkens. The list must start at x=0 and end at x=255, x must always climb, every value must sit between 0 and 255, and there is a limit of 16 points - a curve with fifty points is a drawing, not a decision. [0,0, 255,255] is the straight line, which changes nothing.
  This is where a photograph gets a character the four parametric sliders cannot reach: the shoulder that holds a highlight, the toe that gives blacks their density, the exact placement of a midtone. Use it when the shape of the tonality IS the decision.
  ToneCurvePV2012Red, Green and Blue do the same to one channel each, which is how a colour cast is placed into shadows or highlights independently of any grading.
  A curve is a SHAPE, not a movement: send the whole curve you want, not a change to the one already there. Omit the key to leave it alone.
- PARAMETRIC TONE CURVE: ParametricShadows, ParametricDarks, ParametricLights, ParametricHighlights are -100 to 100 each and act on four adjoining tonal regions, from darkest to brightest - the tool for shaping tonality region by region rather than moving the whole range. The three split points are 0-100 and define where those regions meet; their defaults are 25, 50 and 75, and moving them moves the boundaries themselves. They MUST stay strictly increasing (ParametricShadowSplit < ParametricMidtoneSplit < ParametricHighlightSplit) - out-of-order splits are discarded.
- LuminanceNoiseReductionDetail / LuminanceNoiseReductionContrast: 0-100, refine LuminanceSmoothing and do nothing without it. ColorNoiseReductionDetail / ColorNoiseReductionSmoothness: 0-100, likewise refine ColorNoiseReduction.
- DefringePurpleAmount / DefringeGreenAmount: 0-20, remove purple/green colour fringing on high-contrast edges.
- GRAIN: GrainAmount 0-100 is the master control and the other two do nothing without it (GrainSize 0-100, GrainFrequency 0-100). Grain is a style decision: it unifies noise in a high-ISO frame and gives a filmic or documentary rendering, and it costs fine resolution.
- BLACK AND WHITE: ConvertToGrayscale is a JSON boolean (true or false, never a number or a quoted string). GrayMixer<Color> (-100 to 100 for each of the 8 colours) sets how each ORIGINAL colour maps to a grey tone - GrayMixerBlue negative darkens a sky, GrayMixerOrange positive lifts skin or fur - and it applies ONLY when ConvertToGrayscale is true; on a colour photo those values are discarded. In black and white, Vibrance, Saturation and the HSL Saturation/Hue keys do nothing, so do not return them. ColorGrade* still works, as toning.

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
  "Temperature": -250,
  "Tint": 5,
  "ToneCurvePV2012": [0,0, 32,22, 128,134, 255,250],
  "Vibrance": 15,
  "Sharpness": 40,
  "SharpenRadius": 1.0,
  "SharpenDetail": 25,
  "CropAngle": -1.2,
  "CropLeft": 0.05,
  "CropTop": 0.18,
  "CropRight": 0.72,
  "CropBottom": 0.85,
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
--
-- And then we asked for that look back in other words. This prompt used to say
-- "Deep blacks" and "an edit too small to see is the same as no edit - commit
-- to a direction and carry it through the whole frame", to every photograph
-- alike. The references came back exactly as ordered: a little dark, colours
-- well loaded, the same treatment on a coastline and on a concert. That is not
-- how work at this level looks, and the model was not the one who decided it.
function M.buildReferencePrompt()
    return [[
You are the photographer and colorist responsible for this photograph. You are given the frame; produce the finished version of it - the one you would deliver to the client.

Work to the standard of high-end professional post-production, and the mark of that standard is that it does not announce itself. The picture should look as though the light was simply that good and someone knew how to keep it: nothing about the finished frame should read as "edited". A viewer notices the photograph, not the grade.

Concretely, that means:
- OPEN, NATURAL LIGHT. Expose for the subject and let the image breathe. Shadows keep detail instead of being crushed to black; highlights keep detail instead of being clipped. If you are unsure, err on the side of the brighter, more open rendering - a dark, heavy frame reads as a mood filter, not as finished work.
- BELIEVABLE COLOUR. Colour stays where a good print would put it: skin looks like skin, whites stay white, foliage and sky keep their real hue. Saturation is the last resort, not the first move - if a colour looks flat, it is nearly always the light on it that needs work, not its intensity.
- RESTRAINT AS THE DEFAULT. Contrast, clarity and structure serve the subject; used for their own sake they make a photograph look processed and dated. A strong decision - a deliberate cast kept because it IS the mood, deep blacks because the picture is about darkness, a black and white conversion - is legitimate, but it has to be this photograph asking for it, not a habit.

READ THIS FRAME BEFORE YOU DECIDE ANYTHING. What is it of, what is the light doing, where should the eye land, what is it for? Two photographs that differ should come back differently treated. Applying one house look to everything is the failure this brief exists to prevent - if your treatment of this image would be the same as your treatment of any other image, you have not looked at it.

WHAT MAY NOT CHANGE - this image is used as a target to reverse-engineer into develop settings, so it must stay the same photograph:
- The same framing, the same subject, the same position of every element.
- No object added, removed, moved or invented; no change to composition, geometry or content.
- Fully photorealistic. It must read as a photograph that was developed, not as an illustration or a retouch.

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
    local ok, raw = LrTasks.pcall(function() return photo:getDevelopSettings() end)
    -- Translated into the vocabulary the prompt documents: the model is told
    -- ColorGradeHighlightHue, so that is what it must read back here too.
    local settings = ok and Parse.fromLightroomSettings(raw) or raw
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

    -- The curves are the one value that is a list, so the numeric loop above
    -- cannot see them - and a curve the model is not shown is a curve it can
    -- only replace blindly. The identity curve is skipped: a straight line
    -- changes nothing, and it is not worth a line of prompt.
    local curveKeys = {}
    for key in pairs(Parse.CURVE_KEYS) do table.insert(curveKeys, key) end
    table.sort(curveKeys)
    for _, key in ipairs(curveKeys) do
        local curve = settings[key]
        if type(curve) == "table" and #curve >= 4 then
            local identity = (#curve == 4 and curve[1] == 0 and curve[2] == 0
                              and curve[3] == 255 and curve[4] == 255)
            if not identity then
                local points = {}
                for i = 1, #curve, 2 do
                    table.insert(points, string.format("%d,%d", curve[i], curve[i + 1]))
                end
                table.insert(lines, string.format("%s = [%s]", key, table.concat(points, " ")))
            end
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

-- Two jobs, two prompts. With a reference image the model is an INSTRUMENT: the
-- edit exists already and the only question is how far this photograph is from
-- it. Without one there is no target, so the model has to be the AUTHOR - which
-- is the older prompt, kept whole for exactly that case.
--
-- They were one prompt, and it asked the model to author an edit while glancing
-- at the reference "to understand mood". A run on a midday coastline and a run
-- on an indoor concert then answered with the SAME numbers: of 45 parameters
-- both asked for, 10 were identical and 13 more within a fifth of each other,
-- curves included. That is not a model measuring a photograph, it is a model
-- reciting a preset - and it was reciting it because that is what we asked for.
local MEASURE_OPENING = [[
You are a measuring instrument, working in Adobe Lightroom Classic. You are NOT the author of this edit.

The edit has already been made. IMAGE 2 is the finished photograph - the result someone else arrived at from this frame - and your entire job is to say how far IMAGE 1 has to move to become it. The decision about what this picture should look like is taken, and it is in front of you.

So your own taste is the one thing that must stay out of the answer. If you would have edited this photograph differently, that is not relevant here: report the difference that is actually in front of you, including where it goes against what you would have chosen. An edit you find too dark, too warm or too restrained is still the edit you must measure.

Work by comparison. Hold the two images side by side and, for each thing you can see, ask two questions in this order: WHICH WAY does IMAGE 1 have to move, and HOW FAR. Name the direction before you reach for a number - "the blacks are denser in IMAGE 2", "the background is a stop darker", "the wall is warmer" - and only then choose the value that carries it.

A parameter you cannot see a difference in is a parameter you leave out. There is no credit for a full answer. Returning a value because it is what a good edit usually carries is the one failure that matters here: it is how every photograph ends up with the same numbers, whatever was actually in front of you.

But silence has to mean "I compared these two images and they do not differ here" - never "I did not look". A short answer is right when little differs and wrong when you stopped early. The comparisons easiest to skip, because leaving them out makes the answer shorter, are the colour of the shadows against the colour of the highlights, each hue band on its own, the SHAPE of the tonality rather than its level, and the six regions one at a time. Make those four, whatever you end up reporting.

]]

local AUTHOR_OPENING = [[
You are the photographer and colorist responsible for this photograph, working in Adobe Lightroom Classic. The edit is yours to author, and you are free to take it wherever you believe the picture is strongest.

Decide first what this photograph is FOR - what it is about, what a viewer should feel and where their eye should land - and then build an edit that serves that reading. Post-production is interpretation, not repair: two editors given this frame should reasonably arrive at different images, and the one you return should be recognisably YOUR reading of it.

So commit. Pick a direction and take it far enough to be visible. A correction too small to see is the same as no correction, and an edit that could have been anyone's is a missed opportunity, not a safe one. Where the picture asks for a dramatic decision - deep blacks, a strong colour cast kept because it is the mood, heavy separation between subject and ground, a black-and-white conversion - make it and follow it through the whole frame. Where it asks for restraint, restraint is also a decision, made for this photograph rather than as a default.

The only failure is an edit that is not deliberate: values placed near zero because nothing forced you to move them, or a treatment applied out of habit rather than because you looked at this frame. Be able to say, for every value you return, what in THIS image it is doing.

]]

local MEASURE_STEPS = [[
Reason internally through these steps (do not write the reasoning in the final answer). Every one of them is a COMPARISON between the two images:
0. SAY THE DIFFERENCE IN PLAIN WORDS FIRST, before any number: what was done to IMAGE 1 to arrive at IMAGE 2? One or two sentences - "darker overall, blacks closed right down, the warmth taken out of the wall, the background pushed away from the subject". Everything below is that sentence turned into values. If you cannot say the sentence, you are not ready to give numbers.
0b. COLOUR OR BLACK AND WHITE: is IMAGE 2 in colour or in black and white? Answer with ConvertToGrayscale only if it differs from IMAGE 1. If IMAGE 2 is a black and white rendering, look at which ORIGINAL colours became light greys and which became dark ones, and build that with GrayMixer<Color>.
1. TONE, ZONE BY ZONE: find the brightest thing and the darkest thing in each image and compare them. Then the midtones - a face, a wall, the ground. Is IMAGE 2 brighter or darker overall (Exposure)? Are its highlights held back or opened (Highlights, Whites)? Are its shadows more open or more closed (Shadows, Blacks)? Is the distance between dark and light greater or smaller (Contrast)? When the difference is not a level but a SHAPE - the blacks crushed while the midtones stay put, a highlight that rolls off instead of clipping - that is the point curve, and it is the right tool for exactly that.
2. WHITE BALANCE: find something that should be neutral - paper, a white shirt, stone, grey cloth - and compare its colour in the two images. Which way has it moved, blue/yellow (Temperature) and green/magenta (Tint)? State the direction before the amount. The current value you are shown is this file's own neutral, so your movement is a departure from it, not a correction of it: a small difference you can barely see is a small number, not a hundred.
3. WHERE THE COLOUR LIVES: compare the colour of the SHADOWS in the two images, then the colour of the HIGHLIGHTS, then the midtones. A difference that lives in one tonal zone is colour grading. A difference that lives in one hue band wherever it appears is the mixer, in step 4. A difference that touches every colour in the frame at once is the camera calibration - the primaries themselves.
4. THE MIXER, COLOUR BY COLOUR: go through the hues that are actually in this frame - Red, Orange, Yellow, Green, Aqua, Blue, Purple, Magenta - and for each one compare it between the two images on all three dimensions: is it a different hue, is it more or less intense, is it lighter or darker? A colour that looks the same in both images gets no key.
5. DETAIL - JUDGED ON IMAGE 1 ALONE, NOT AGAINST THE TARGET: sharpening, noise reduction and grain are decided by looking at IMAGE 1 and at the material in it - skin, fur, foliage, stone, fabric. IMAGE 2 was re-rendered at a fraction of this photograph's resolution, so its texture and micro-detail are an artefact of how it was made, not a decision anyone took: measuring sharpness or grain against it measures the artefact. When in doubt here, leave detail alone.
6. VIGNETTE: are the corners of IMAGE 2 darker or brighter than the corners of IMAGE 1, relative to the centre? If they are the same, leave the vignette alone.
7. HORIZON AND FRAMING - THE ONE STEP WHERE YOU ARE THE AUTHOR, NOT THE INSTRUMENT: everything else in this answer is measured against IMAGE 2. Composition is not, because IMAGE 2 is not reliable for it - so here, and only here, the decision is yours, and "no difference to report" is not an available answer. Look at IMAGE 1 and decide.
   TILT: identify the single most reliable horizontal or vertical reference line (natural horizon, waterline, tree trunk, building edge) and estimate its tilt -> CropAngle. Use 0 only if you found such a line AND measured it within 0.3 degrees of level, not merely because you are unsure.
   CROP: ask where the subject sits in the frame and how much of the frame is doing nothing. A subject pushed hard to one side with a large empty expanse opposite it, a subject small in the middle of a wide scene, a distracting edge - these are the cases a crop exists for, and the crop that fixes them is usually a LARGE one. Cutting 30-50% of the frame away is an ordinary decision when that is what the picture needs; a timid 2% trim is almost never the right answer, and leaving the frame untouched because the crop would be big is the wrong reason to leave it untouched. Keep the original aspect ratio, and keep the subject whole - never cut through it, and leave the space it is moving or looking into. If after all that the framing genuinely is right, say so with 0, 0, 1, 1.
8. WHAT MOVED MORE THAN THE REST - GO THROUGH ALL SIX REGIONS, ONE AT A TIME: subject, people, objects, sky, landscape, background. For each one that is actually present in this frame, ask the same question: does it differ between the two images BY MORE THAN the global movements you have just described? A subject brought forward while everything else stayed, a sky given its own light, a background pushed down and away. That excess is what a mask is for, and the local values are the excess ONLY, not the whole difference. This is the step that separates a photograph from a filter laid over one, and it is the step most easily skipped because the answer is shorter without it. A finished edit almost always treats its subject and its ground differently: if you conclude that no region does, you must be able to say that you compared all six and found each one moving exactly with the frame.
9. SELF-CHECK: for every value you are about to return, be able to point at what you saw in the two images that produced it. Delete any value you cannot point at - especially the ones that feel like part of a good edit. Then the technical checks: your Temperature movement is in the units the current value is reported in; the crop, if any, keeps the original aspect ratio and stays within 0-1; each Masks entry's "type" is one of the allowed values, with no duplicate types; the three parametric split points, if present, are strictly increasing; ConvertToGrayscale is an unquoted boolean and GrayMixer<Color> appears only alongside ConvertToGrayscale = true; every number is a MOVEMENT from the current value, except the keys listed as positions. Silently fix anything that violates these before producing the final JSON.
]]

local AUTHOR_STEPS = [[
Reason internally through these steps (do not write the reasoning in the final answer):
0. READ THE PHOTOGRAPH: what kind of picture is this, and what is it about? Name the genre from what you actually see in THIS frame - portrait or people, landscape, wildlife, macro, street or documentary, still life, architecture, night or low-light - and, more importantly, name the subject and the quality of light that make it worth looking at. Then decide the treatment this particular photograph asks for. The genre tells you which materials are in play (skin, fur, foliage, stone, water, neon); what to do with them is your judgement about this image, not a house style you apply to every photo of that kind.
0b. COLOUR OR BLACK AND WHITE: decide which this photograph is, and say so with ConvertToGrayscale. It is an authorial decision, so make it as one: black and white when the picture is carried by light, shape, gesture, texture or contrast; colour when hue is doing real work. If you choose black and white, commit to it and BUILD the grey rendering with GrayMixer<Color> - that mixer is how each original colour becomes a grey, and it is your main tool for separating subject from ground once colour no longer does it. A merely desaturated image is not a black and white photograph. In black and white, Vibrance, Saturation and the HSL saturation keys stop meaning anything; ColorGrade* remains available as toning.
1. HORIZON/LINES: identify the single most reliable horizontal or vertical reference line in THIS image (natural horizon, waterline, tree trunk, building edge, an animal's back/legs when standing on visibly flat ground, etc.) and mentally note which one you used. Estimate its tilt angle from true horizontal/vertical as precisely as you can -> CropAngle. Only use CropAngle = 0 if you actually found such a reference line AND measured it to be within 0.3 degrees of level. Do NOT use 0 merely because you are unsure or found no obvious reference - in that case pick the best available approximate reference and still report a small non-zero correction if any visible tilt remains.
2. EXPOSURE AND TONE: read the tonal distribution as if reading the histogram - what is blocked, what is clipped, where the midtones sit - and then decide where you WANT them. This is the shape of the picture, not just a correction: how dense the blacks are, how the highlights roll off, how much air is in the shadows, how much contrast the subject needs to read. Use Exposure, Highlights, Whites, Shadows, Blacks and Contrast together, use the parametric curve when you want the boundaries between tonal regions to move rather than the whole range, and the POINT curve when the shape of the tonality is itself the decision - a shoulder that holds the highlights, a toe that gives the blacks density.
3. COLOUR AND MOOD: set Temperature and Tint to the colour of light you want this photograph to have - the neutral reading is one option among several, and keeping or pushing a cast is legitimate when the cast IS the mood. Then use the three-way colour grading (shadows / midtones / highlights, plus global) to give the image a colour identity rather than only a correct one.
3b. COLOUR CHARACTER: if the photograph wants a rendering of colour rather than a correction of it, use the camera calibration - the primaries themselves. It is the deepest colour control there is and it touches the whole frame, so it is the place for a signature rather than for a fix.
4. THE COLOUR MIXER: work the channels that carry this image - Hue, Saturation and Luminance on any of Red, Orange, Yellow, Green, Aqua, Blue, Purple, Magenta. All three dimensions are yours: Hue moves a colour to a different one, Saturation sets its intensity, Luminance sets how light or dark that colour renders, which is what separates a subject from a background of similar brightness. Go through the colours that actually appear in the frame and decide each one.
5. DETAIL: sharpening, noise reduction and grain, judged on the material you named in step 0 and on how you want the picture to feel. Grain is a style choice as much as a repair, and both a clean rendering and a filmic one are legitimate answers.
6. VIGNETTE: shape where the eye settles. Use it when you want the frame to close in on the subject, and leave it at 0 when the composition already does that work.
7. COMPOSITION: propose a crop if it improves the ACTUAL framing of this image (distracting elements at the edges, excessive negative space, rule of thirds), ALWAYS keeping the original aspect ratio.
8. LOCAL WORK WITH MASKS: go through the distinct regions that are actually visible in THIS frame - any of subject, people, objects, sky, landscape, background - and decide what each one needs on its own. This is where an edit stops being a filter over the whole picture and starts being photography: a subject brought forward, a background pushed back, a sky given its own light, a face treated differently from the scene around it. Use as many of the six regions as the photograph genuinely has; there is no quota, in either direction. The one hard rule is that the region must be really there - see the Masks section below.
9. SELF-CHECK: before answering, re-verify every value you are about to output: your Temperature movement must be in the units the current value is reported in; the crop, if any, must keep the original aspect ratio and stay within 0-1; every movement must be plausible as a movement rather than a value copied from the ranges listed below; each Masks entry's "type" must be one of the allowed values, with no duplicate types; the three parametric split points, if present, must be strictly increasing; ConvertToGrayscale must be an unquoted boolean and GrayMixer<Color> must appear only alongside ConvertToGrayscale = true; Also confirm that every number you are returning is a MOVEMENT from the current value and not the value itself, except for the keys listed as positions. Silently fix anything that violates these constraints before producing the final JSON.

]]

function M.buildAnalysisPrompt(pass, totalPasses, hasReference, currentSettingsBlock, appliedMasksByType)
    local intro
    if hasReference then
        -- Measuring. The brake the authorial version carries ("do not undo what
        -- already works") is gone on purpose: a pass that overshot must be able
        -- to come back, and a run where the first pass put 13 points of magenta
        -- into a warm interior answered that with -4 because it had been told
        -- not to undo itself.
        if pass == 1 then
            intro = "IMAGE 1 is that photograph as it stands, with no development applied yet."
        else
            intro = string.format(
                "IMAGE 1 is the same photograph with the movements you reported in the previous pass (pass %d of %d) already applied to it. It should now be closer to IMAGE 2 than it was. Measure the two again and report what STILL differs. If something you moved went too far, say so and move it back - undoing your own overshoot is a correct answer, not a contradiction. If nothing you can see differs any more, return an empty object: arriving is the point.",
                pass - 1, totalPasses)
        end
    elseif pass == 1 then
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

Read them as information about where you are, not as something to repeat. They tell you how far each slider has already travelled, and which units Temperature is in on this file. Temperature and Tint are the exception to "how far it has travelled": before any pass has moved them they are this file's own neutral, which is where a correction starts from rather than something to correct.
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
        -- The reference used to be introduced as mood inspiration. It is not:
        -- it is the target, and calling it anything softer is what let the
        -- model answer with its own house style instead of with a measurement.
        referenceBlock = "\nIMAGE 2 is the TARGET: the finished version of this same photograph. It is what IMAGE 1 has to become, and every value you return exists to close the distance between the two. Where IMAGE 2 is darker, warmer, flatter or more restrained than you would have made it, that is the answer anyway.\n\nWhat IMAGE 2 is NOT: it was re-rendered by an image model at a fraction of this photograph's resolution, so it is reliable for TONE, COLOUR, CONTRAST and LIGHT and for nothing else. Never take crop, geometry, horizon or anything about the content of the frame from it. Never judge sharpness, texture, noise or grain from it either - its detail is an artefact of the way it was made. Where it looks soft, plastic or invented, that is not a decision to reproduce. Those things come from IMAGE 1 alone.\n"
    end

    local opening = hasReference and MEASURE_OPENING or AUTHOR_OPENING
    local steps = hasReference and MEASURE_STEPS or AUTHOR_STEPS

    -- Target first, then where the photograph stands against it: the second
    -- sentence only means something once the first has been read.
    return opening .. referenceBlock .. intro .. "\n" .. settingsBlock .. steps
        .. PARAM_RULES .. deltaRuleBlock() .. [[

For CropAngle: this is the RESIDUAL rotation needed looking at THIS image (not a cumulative total across previous passes). If already straight, use 0.
For CropLeft/CropTop/CropRight/CropBottom: normalized 0-1 fractions of THIS image (0,0 = top-left corner, 1,1 = bottom-right corner). ALWAYS subtractive. If the framing is already fine: 0, 0, 1, 1.
To keep the original aspect ratio, the width you keep and the height you keep must be the SAME fraction: (CropRight - CropLeft) = (CropBottom - CropTop). The crop in the example above keeps 0.67 of each, which is half the area of the frame - that is what a real crop looks like, and the numbers there are an example of the SCALE as much as of the format.

Final reminder: your entire response must be a single valid JSON object as described above and nothing else - no markdown fences, no explanation, no text before or after the braces.
]]
end

return M
