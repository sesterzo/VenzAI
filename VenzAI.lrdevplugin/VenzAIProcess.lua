--[[----------------------------------------------------------------------------

VenzAIProcess.lua
Analyzes the selected photo with an AI engine (Gemini in the cloud, or a
local Ollama server) and applies the resulting develop settings, over a
configurable number of refinement passes.

Configuration lives in VenzAISettings.lua and is edited from
File > Plug-in Manager > VenzAI. Logging goes through VenzAILog.lua.

------------------------------------------------------------------------------]]

local LrApplication = import 'LrApplication'
local LrApplicationView = import 'LrApplicationView'
local LrDevelopController = import 'LrDevelopController'
local LrTasks = import 'LrTasks'
local LrHttp = import 'LrHttp'
local LrExportSession = import 'LrExportSession'
local LrPathUtils = import 'LrPathUtils'
local LrFileUtils = import 'LrFileUtils'
local LrStringUtils = import 'LrStringUtils'
local LrProgressScope = import 'LrProgressScope'
local LrFunctionContext = import 'LrFunctionContext'
local LrDialogs = import 'LrDialogs'

local VenzAILog = require 'VenzAILog'
local Settings = require 'VenzAISettings'

local log = VenzAILog.log

local config = Settings.snapshot()
local ENGINE = config.engine
local GEMINI_API_KEY = config.geminiApiKey
local GEMINI_ANALYSIS_MODEL = config.geminiAnalysisModel
local GEMINI_IMAGE_MODEL = config.geminiImageModel
local OLLAMA_BASE_URL = config.ollamaBaseUrl
local OLLAMA_MODEL = config.ollamaModel
local REFINEMENT_PASSES = config.refinementPasses

-- HTTP timeouts, in seconds. LrHttp's default has no upper bound we control,
-- and every one of these calls can legitimately run for minutes: a reasoning
-- model spends a while before emitting a token, and a local model on CPU is
-- slower still. Without a timeout a stalled connection leaves the progress
-- bar spinning with no way out except restarting Lightroom.
local GEMINI_TIMEOUT = 300
local OLLAMA_TIMEOUT = 900

-- Working files go to the OS temp folder, never inside the plug-in bundle.
-- On macOS a .lrplugin is a package and on Windows it may sit under
-- Program Files; in both cases the bundle is effectively read-only once
-- installed, and writing there fails silently. LrPathUtils resolves the
-- right per-platform location with no conditional code.
local WORK_DIR = LrPathUtils.child(LrPathUtils.getStandardFilePath('temp'), "VenzAI")
local REFERENCE_IMAGE_BASE_PATH = LrPathUtils.child(WORK_DIR, "nano_banana_reference")

local function ensureWorkDir()
    if not LrFileUtils.exists(WORK_DIR) then
        local ok, err = pcall(function() LrFileUtils.createAllDirectories(WORK_DIR) end)
        if not ok then
            log("Could not create the working directory " .. WORK_DIR .. ": " .. tostring(err))
            return false
        end
    end
    return true
end

-- Reports a fatal condition to the user instead of only to the log. Every
-- early return in the run below used to be silent: from the user's side
-- "nothing happened" was indistinguishable between a missing API key, an
-- unreachable server and a crash.
local function failToUser(title, detail)
    log(string.format("ABORT: %s - %s", tostring(title), tostring(detail)))
    LrDialogs.message(title, detail, "critical")
end

local HSL_COLORS = { "Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta" }
local COLOR_GRADE_ZONES = { "Shadow", "Midtone", "Highlight", "Global" }

local VALID_KEYS = {
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
    VALID_KEYS["HueAdjustment" .. color] = true
    VALID_KEYS["SaturationAdjustment" .. color] = true
    VALID_KEYS["LuminanceAdjustment" .. color] = true
    -- B&W channel mixer: how each original color maps to a grey tone. Only
    -- meaningful together with ConvertToGrayscale.
    VALID_KEYS["GrayMixer" .. color] = true
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
local STRING_VALID_KEYS = {
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
-- parameter namespace from the global VALID_KEYS/RANGES above: it exists
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
local MASK_SUBJECT_TYPES = {
    subject = true, sky = true, background = true, people = true, landscape = true, objects = true,
}
local MAX_MASKS_PER_PASS = 2

-- All text sent to the model (prompts) is in ENGLISH: models, including
-- Gemini, follow technical instructions more reliably in English, and it's
-- the language the Lightroom develop settings format is documented in.
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
- Temperature: an ABSOLUTE color temperature value in Kelvin degrees (NOT a delta), always between 2000 and 50000. For normal daylight the typical value is 4500-7500. Small values like 8 or 100 are ALWAYS wrong and produce an extreme blue cast: never use them.
- Tint: -150 to 150.
- Saturation vs Vibrance (per Adobe's own documentation): Saturation is an ABSOLUTE, uniform adjustment applied equally to every color in the image, including already-vivid colors and skin/fur tones - pushing it too far is what makes an image look oversaturated or plasticky. Vibrance is a RELATIVE, protective adjustment: it boosts weaker/muted colors more than already-strong ones and largely spares orange/red/yellow tones (skin, fur, feathers). For nearly all color enhancement, prefer Vibrance over Saturation. Reserve Saturation for a deliberate, moderate, uniform intensity change, and never use it to compensate for an area that is simply too bright or too dark (fix that with tone, not color).
- Texture vs Clarity: Texture affects only medium-sized detail (increase for fur/feather/foliage texture, decrease to smooth skin/surfaces) with minimal effect on color. Clarity adds broader midtone edge contrast over a wider radius and, per Adobe, noticeably affects luminance and saturation too - do not use Clarity as a substitute for Texture, and keep Clarity moderate to avoid unintentionally shifting color/tone.
- PostCropVignetteAmount: -100 (darkens the corners, typical for a natural look) to 100. Use moderate negative values (-5 to -25) for a subtle vignette; use 0 if not needed.
- PostCropVignetteMidpoint: 0-100 (how far it extends toward the center, typical 40-60).
- PostCropVignetteFeather: 0-100 (edge softness, typical 50-80 for a natural effect).
- PostCropVignetteRoundness: -100 to 100 (typical 0).
- PostCropVignetteStyle: integer 1 (Highlight Priority), 2 (Color Priority), or 3 (Paint Overlay). Per Adobe, Highlight Priority can cause color shifts in the darkened corners and is meant for photos with bright/near-clipped highlights there (e.g. sky); Color Priority minimizes those color shifts but cannot recover highlights. Default to 2 (Color Priority) in most scenes; use 1 only when the corners contain bright highlights that need recovery.
- PostCropVignetteHighlightContrast: 0-100 (typical 0-20).
- ColorGrade*Hue: 0-360. ColorGrade*Sat: 0-100. ColorGrade*Lum: -100 to 100. ColorGradeBlending: 0-100 (typical 50-100).
- HueAdjustment<Color>, SaturationAdjustment<Color>, LuminanceAdjustment<Color>: -100 to 100 each.
- SharpenRadius: 0.5-3.0. SharpenDetail: 0-100. SharpenEdgeMasking: 0-100.
- PARAMETRIC TONE CURVE: ParametricShadows, ParametricDarks, ParametricLights, ParametricHighlights are -100 to 100 each and act on four adjoining tonal regions, from darkest to brightest. This is the precise tool for the shape of the tonality, and it is what you should reach for to get highlights that roll off smoothly (a moderate negative ParametricHighlights) or blacks with density that are not crushed (a measured ParametricShadows) - it is gentler and more controllable than pushing Contrast2012 or Blacks2012 hard. The three split points are 0-100 and define where those regions meet: they MUST stay strictly increasing (ParametricShadowSplit < ParametricMidtoneSplit < ParametricHighlightSplit); their defaults are 25, 50 and 75, and you should only move them when a specific image genuinely needs the boundaries shifted. Out-of-order splits are discarded.
- LuminanceNoiseReductionDetail / LuminanceNoiseReductionContrast: 0-100, refine LuminanceSmoothing and are meaningless without it. ColorNoiseReductionDetail / ColorNoiseReductionSmoothness: 0-100, likewise refine ColorNoiseReduction. Only include them when you are actually applying noise reduction.
- DefringePurpleAmount / DefringeGreenAmount: 0-20, remove purple/green colour fringing on high-contrast edges. Use them only if you can actually see fringing; 0 otherwise.
- GRAIN: GrainAmount 0-100 is the master control and the other two do nothing without it (GrainSize 0-100, typical 20-30; GrainFrequency 0-100, typical 50). Grain is a deliberate stylistic choice, not a correction: use a restrained amount (10-25) when it genuinely suits the image - to unify noise in a high-ISO or night frame, or for an intentionally filmic, documentary or monochrome look - and omit it entirely otherwise. Never use grain to mask noise you should have reduced properly, and keep it well clear of clean, high-detail work (wildlife feather detail, product, architecture) where it only destroys resolution.
- BLACK AND WHITE: ConvertToGrayscale is a JSON boolean (true or false, never a number or a quoted string). Setting it true converts the photo to black and white, and this is a genuine authorial decision about the photograph, so treat it as one - see the dedicated step in the reasoning list above. When and ONLY when you set it true, GrayMixer<Color> (-100 to 100 for each of the 8 colors) becomes your main creative tool: it sets how each ORIGINAL colour is mapped to a grey tone, which is how you separate subject from background once colour no longer does that for you (e.g. GrayMixerBlue negative darkens a sky dramatically; GrayMixerOrange positive lifts skin or fur). GrayMixer values are ignored, and discarded, if the photo is not being converted. In a black and white image, Vibrance, Saturation and the HSL Saturation/Hue adjustments become pointless - do not return them; ColorGrade* on the other hand remains useful and legitimate, as toning (a subtle single-hue tone, or a split tone, with low Sat values).
- CameraProfile: a string, and ONLY one of exactly these values: "Adobe Color", "Adobe Landscape", "Adobe Portrait", "Adobe Neutral", "Adobe Standard", "Adobe Vivid", "Adobe Monochrome". Anything else is discarded. This is the starting rendering of the file and therefore a broad lever, so change it only with a reason: "Adobe Portrait" for gentler skin rendering, "Adobe Landscape" for more assertive colour in a scenic frame, "Adobe Neutral" as a flatter base when you plan strong grading of your own, "Adobe Monochrome" together with ConvertToGrayscale = true. Omit the key entirely to keep whatever profile the photo already uses, which is the right choice in most cases.

LOCAL (MASKED) CORRECTIONS - you have the ability to select a specific REGION of the photo with an automatic AI-detected mask and apply settings to ONLY that region, independently of the rest of the image. The six available region types are equally valid options - "subject", "people" and "objects" isolate the main subject(s); "sky" and "landscape" isolate the environment; "background" isolates everything behind the subject. Pick whichever type(s) genuinely match a real, localized problem in THIS image - do not default to "sky" out of habit just because it is a common example: in a huge number of photos (close-up portraits, subjects filling the frame, indoor/studio shots, scenes with no visible sky at all) the sky is not even the right tool, and a different region - or none - is what the image actually needs. Example situations (any of the six types can apply, not just sky):
- one region is correctly exposed but another is blown out or too dark (sky vs. subject, subject vs. background, foreground vs. landscape, etc.) -> mask the problem region and correct its local_Highlights/local_Exposure/local_Shadows there only.
- the main subject (or the people in it) would benefit from extra local_Clarity/local_Sharpness/local_Dehaze that would be too strong applied to the whole frame -> mask "subject"/"people"/"objects" and push just that.
- the background is distracting, too saturated/warm, or needs to recede visually so the subject stands out -> mask "background" and reduce local_Saturation/local_Clarity/local_Exposure there.
- a landscape's sky and ground need clearly different white balance or contrast treatment that a single global value can't reconcile -> mask "sky" and/or "landscape" separately, only when the frame actually contains that much sky/landscape.
Still use this selectively: most photos are fine with global settings alone, so only add a mask when you can point to a concrete, specific reason a single global value would compromise one region to fix another. Never use a mask merely to duplicate what a GLOBAL TONE/BASE COLOR value could already do for the whole image, and never reach for "sky" as a default choice - choose the type that actually matches the problem you see.
CRITICAL: only propose a mask "type" for a region that is actually visible as a substantial part of THIS specific image - look at the picture and confirm it before writing the mask. Never propose "sky" if no sky is visible in the frame, never propose "people" if there are no people, never propose "subject" if there is no clearly distinct main subject separate from its surroundings, etc. The AI region-detector this later runs on the real photo, and asking it to isolate a region that isn't there produces a wrong or garbage selection and a ruined edit - this check is yours to make from what you see, not something that gets validated afterwards.
If used, add a top-level "Masks" array. Each element is an object with:
- "type": exactly one of these AI-detectable region names (string, no other value allowed): "subject", "sky", "background", "people", "landscape", "objects".
- one or more LOCAL parameters, same meaning as their global counterparts but affecting ONLY the masked region: local_Exposure (-4 to 4), local_Contrast (-100 to 100), local_Highlights (-100 to 100), local_Shadows (-100 to 100), local_Whites (-100 to 100), local_Blacks (-100 to 100), local_Clarity (-100 to 100), local_Texture (-100 to 100), local_Dehaze (-100 to 100), local_Saturation (-100 to 100), local_Temperature (-100 to 100), local_Tint (-100 to 100), local_Sharpness (-100 to 100), local_Hue (-180 to 180), local_LuminanceNoise (-100 to 100), local_Moire (-100 to 100), local_Defringe (-100 to 100), local_Grain (-100 to 100), local_ToningHue (0 to 360, hue degrees for split-toning within the mask), local_ToningSaturation (0 to 100, intensity of local_ToningHue - only meaningful together with it), local_RefineSaturation (0 to 100, refines how tightly the AI selection follows color boundaries), local_Amount (0 to 200, default 100 = full strength; only include it if you deliberately want a partial-strength effect).
Use AT MOST 2 masks per pass, never repeat the same "type" twice in the same response.

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
(this "background" mask is just ONE example of the format - the correct type(s) to use, if any, depend entirely on what THIS image actually needs: it could be "subject", "sky", "landscape", "people", "objects", "background", any combination of two, or none at all. The "Masks" array is OPTIONAL and should be omitted completely - no "Masks" key at all - for the majority of photos that don't need any localized treatment)
(the example above is a COLOUR edit, which is the usual case. A black and white answer looks different: it carries "ConvertToGrayscale": true plus the GrayMixer<Color> channels that build the grey rendering - e.g. "GrayMixerBlue": -35, "GrayMixerOrange": 20 - it drops Vibrance, Saturation and the HSL saturation keys entirely, and it may use ColorGrade* at a low Sat as toning)
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
local function buildNanoBananaPrompt()
    return [[
You are a senior photographer and colorist working in contemporary, current-day post-production, equally at home across genres (portrait, landscape, wildlife and nature, street and documentary, macro, still life, architecture, low-light). You are given a photograph. Generate a retouched version of the EXACT SAME photograph: same framing, same subject, same position of every element, no object added or removed, no structural or compositional change.

FIRST identify what kind of photograph this is, and let that decide the treatment - do not apply one house style to everything:
- Portrait / people: believable skin above all else, soft highlight roll-off on the face, restrained texture on skin while keeping real detail in eyes, hair and clothing. Never push saturation or clarity on skin.
- Landscape / nature: tonal separation between planes and a coherent light rather than maximum color. Restrained, differentiated greens, never one uniform electric green.
- Wildlife / macro: genuine texture in fur, feathers, scales, wings - resolved by real detail, not by edge halos or exaggerated micro-contrast.
- Street / documentary: a more graphic, contrasted read is welcome, and color may stay imperfect and characterful rather than corrected into neutrality.
- Night / low-light: protect the mood. Do not lift the whole frame toward grey; keep the darkness intentional and clean.

Every correction must be INTENTIONAL and justifiable: apply it because this specific image needs it, not to play safe and not to look impressive. Leaving a real, visible flaw uncorrected is equally unintentional - a blown highlight, a blocked shadow, an obvious color cast or a crooked horizon must be addressed.

What "contemporary" means here, concretely:
- Blacks have density but are not crushed to pure black; shadows keep readable detail and a hint of air.
- Highlights roll off smoothly instead of clipping flat; speculars may stay bright but retain gradation.
- Color is coherent across the scene rather than maximized per channel: a believable, unified light, not a postcard.
- Detail is resolved and clean, with no sharpening halos and no global micro-contrast crunch.
- Any vignette is barely perceptible and used only where it genuinely helps the eye; it must never read as an applied effect.

Explicitly AVOID the over-processed look of the late 2010s: HDR-style tone mapping, heavy global clarity, postcard saturation, orange-and-teal grading applied by reflex, crunchy over-sharpening, heavy dark vignettes.

The result must be visibly better resolved and more coherent than the original while remaining 100% photorealistic, and must still read as a photograph rather than as a retouch.

Return only the retouched image.
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
local function readCurrentSettings(photo)
    local ok, settings = pcall(function() return photo:getDevelopSettings() end)
    if not ok or type(settings) ~= "table" then
        log("Could not read the current develop settings: " .. tostring(settings))
        return nil, false
    end

    local isGrayscale = (settings.ConvertToGrayscale == true)

    local keys = {}
    for key in pairs(VALID_KEYS) do
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
    for key in pairs(STRING_VALID_KEYS) do
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
-- 1 the image is the original photo (or, in the Gemini pipeline, it is paired
-- with the Nano Banana reference); from the following passes onward it is
-- the result of its own previous edit, reviewed with a critical eye.
local function buildAnalysisPrompt(pass, totalPasses, hasReference, currentSettingsBlock)
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

Read them as your own starting point, not as a suggestion. Every value you return REPLACES the one above, it is not added to it, so:
- To keep a correction that already works, repeat its current value unchanged, or omit the key entirely. Both keep it; returning 0 would DESTROY it.
- Return a different number only where you can see, in the image, that the current one is wrong.
- Never return 0 for a parameter merely because the image now looks correct in that respect: it looks correct BECAUSE of the value listed above.
]]
    end

    local referenceBlock = ""
    if hasReference then
        referenceBlock = "\nYou are also given a SECOND IMAGE: a professional reference version generated by another AI tool, useful ONLY to understand how tone, color, contrast, mood and light should look. It is NOT reliable for composition/content: never infer crop, geometry, horizon or content from the second image, only from the first one.\n"
    end

    return [[
You are a senior photographer and colorist working in contemporary, current-day post-production, equally at home across genres (portrait, landscape, wildlife and nature, street and documentary, macro, still life, architecture, low-light), and an expert in Adobe Lightroom Classic.

Every value you return must be INTENTIONAL and justifiable: you must be able to name the specific thing in THIS image that it fixes. This cuts in both directions - do not return near-zero values "to be safe" when the image has a real, visible problem, and do not inflate values to make the edit look impressive. Leaving a blown highlight, a blocked shadow, an obvious color cast or a crooked horizon uncorrected is a failure exactly as much as overcooking the image is.

What "contemporary" means here, concretely - aim for this:
- Blacks with density but not crushed: shadows keep readable detail and a hint of air (prefer a measured Blacks2012/Shadows2012 balance over slamming Blacks down).
- Highlights that roll off smoothly instead of clipping flat: use Highlights2012/Whites2012 to preserve gradation, not to maximize brightness.
- Color coherent across the whole scene rather than maximized per channel: prefer Vibrance and targeted HSL work over global Saturation, and keep the light believable and unified.
- Detail resolved and clean: no sharpening halos, no global micro-contrast crunch. Prefer Texture over Clarity, and keep Clarity low.
- Vignette barely perceptible, used only when it genuinely helps the eye - never as a visible applied effect.

Explicitly AVOID the over-processed look of the late 2010s: HDR-style tone mapping, heavy global Clarity, postcard Saturation, orange-and-teal grading applied by reflex, crunchy over-sharpening, heavy dark vignettes.

]] .. intro .. "\n" .. referenceBlock .. settingsBlock .. [[

Reason internally through these steps (do not write the reasoning in the final answer):
0. GENRE AND STYLE TARGET: identify what kind of photograph this actually is - portrait or people, landscape, wildlife, macro, street or documentary, still life, architecture, night or low-light, and so on. Judge this from what you genuinely see in THIS frame: do not assume a genre out of habit, and in particular do not treat every photo as a nature/wildlife shot. This classification sets both the technical choices AND the aesthetic target for every step that follows:
   - Portrait / people: believable skin is the priority. Soft highlight roll-off on the face, restrained Texture on skin, real detail kept in eyes and hair. Never push Saturation or Clarity on skin tones; if smoothing is needed use negative Texture rather than heavy Clarity.
   - Landscape: build tonal separation between planes and a coherent light rather than maximum color. Differentiate greens through HSL instead of raising global Saturation.
   - Wildlife / macro: real texture in fur, feathers, scales or wings, via moderate Sharpness with a small SharpenRadius and meaningful SharpenEdgeMasking - never via global Clarity. Small subjects (birds, insects) need more restrained sharpening than large mammals.
   - Street / documentary: a more graphic, contrasted read is legitimate, and color may stay characterful rather than corrected to neutrality.
   - Night / low-light / high-ISO: protect the mood - do not lift the whole frame toward grey. Be more careful with LuminanceSmoothing and ColorNoiseReduction, and keep the darkness intentional.
0b. COLOUR OR BLACK AND WHITE: decide whether this photograph is stronger in colour or in black and white, and say so with ConvertToGrayscale. Judge it on whether monochrome would make the image genuinely more compelling - not on whether it is merely acceptable in grey. Black and white earns its place when the picture is carried by light, shape, gesture, texture or contrast rather than by hue; when the colour present is drab, muddy, or a distraction competing with the subject; when mixed or clashing light sources make a believable colour balance impossible; or when the frame is already near-monochrome in practice. Keep colour when hue is doing real work in the image - the reason the photo exists is a colour relationship, a light quality, a plumage or a landscape palette - and remember that colour is the right answer for the clear majority of photographs. Do not convert to black and white to rescue a picture whose real problem is exposure or white balance: fix that instead. This decision governs everything that follows: in black and white the whole burden of separation moves onto tone, so GrayMixer<Color> becomes your principal colour tool, tonal contrast and the parametric curve matter more, and Vibrance/Saturation/HSL saturation stop meaning anything. If you choose black and white, commit to it fully and build the grey rendering deliberately instead of returning a merely desaturated image. Then, separately and only if there is a reason, consider CameraProfile.
1. HORIZON/LINES: identify the single most reliable horizontal or vertical reference line in THIS image (natural horizon, waterline, tree trunk, building edge, an animal's back/legs when standing on visibly flat ground, etc.) and mentally note which one you used. Estimate its tilt angle from true horizontal/vertical as precisely as you can -> CropAngle. Only use CropAngle = 0 if you actually found such a reference line AND measured it to be within 0.3 degrees of level. Do NOT use 0 merely because you are unsure or found no obvious reference - in that case pick the best available approximate reference and still report a small non-zero correction if any visible tilt remains.
2. EXPOSURE AND TONE: mentally assess the tonal distribution of the image (as if reading its histogram) - roughly what proportion looks near-black/blocked shadows, near-white/clipped highlights, and midtone. If a meaningful part of the image is too bright or washed out, prioritize reducing Highlights, Whites and/or Exposure there. Saturation and Vibrance control color intensity, NOT brightness: never use them as a substitute for a tonal/exposure correction. A subject that looks dull only because it is overexposed will often regain natural color once exposure/highlights are corrected, without needing extra saturation.
3. COLOR BALANCE: temperature, tint, then three-way color grading (shadows/midtones/highlights) for a coherent, natural mood.
4. SELECTIVE COLOR PER CHANNEL: Hue/Saturation/Luminance adjustments on whichever channels actually matter in THIS image (skin tones, vegetation, sky or water, clothing, painted or built surfaces). Prefer this targeted work over a global Saturation move.
5. DETAIL: sharpening and noise reduction appropriate for the subject identified in step 0.
6. VIGNETTE: only if it genuinely helps the eye settle on the subject, a post-crop vignette so subtle it cannot be identified as an applied effect. Use 0 when the framing already holds attention on its own.
7. COMPOSITION: propose a crop if it improves the ACTUAL framing of this image (distracting elements at the edges, excessive negative space, rule of thirds), ALWAYS keeping the original aspect ratio.
8. LOCAL/MASKED CORRECTIONS: explicitly check the distinct regions actually present in THIS image (whichever of subject/people/objects, sky, landscape, background genuinely appear in the frame) for a tonal or color mismatch that a single global value cannot resolve without compromising one region to fix another. Base this purely on what you see in this specific photo - do not assume a sky is present or reach for it as a default; many photos (portraits, close-ups, indoor/studio shots, frame-filling subjects) have no sky at all, and the region that actually needs isolating is often the subject or the background instead. If you find a genuine mismatch, use a mask (see the Masks section below for the exact mechanism and parameter list); if the regions are already tonally consistent, skip this step.
9. SELF-CHECK: before answering, re-verify every value you are about to output: Temperature must be an absolute Kelvin value (2000-50000, never a small delta like 8 or 100); the crop, if any, must keep the original aspect ratio and stay within 0-1; every other value, including every local_* value inside Masks, must be within the ranges listed below; each Masks entry's "type" must be one of the allowed values, at most 2 masks, no duplicate types; the three parametric split points, if present, must be strictly increasing; ConvertToGrayscale must be an unquoted boolean and GrayMixer<Color> must appear only alongside ConvertToGrayscale = true; CameraProfile, if present, must match one of the allowed strings exactly. Silently fix anything that violates these constraints before producing the final JSON.

]] .. PARAM_RULES .. [[

For CropAngle: this is the RESIDUAL rotation needed looking at THIS image (not a cumulative total across previous passes). If already straight, use 0.
For CropLeft/CropTop/CropRight/CropBottom: normalized 0-1 fractions of THIS image (0,0 = top-left corner, 1,1 = bottom-right corner). ALWAYS subtractive. If the framing is already fine: 0, 0, 1, 1.

Final reminder: your entire response must be a single valid JSON object as described above and nothing else - no markdown fences, no explanation, no text before or after the braces.
]]
end

-- Extracts the base64 data and mime-type of the returned image from an
-- image-generation model's response (Gemini responses use camelCase keys
-- like "inlineData"/"mimeType" even when the request used snake_case, so we
-- look for the "data" field filtering only valid base64 characters,
-- regardless of the container's name).
local function extractInlineImage(responseBody)
    local base64Data = responseBody:match('"data"%s*:%s*"([A-Za-z0-9+/=]+)"')
    local mimeType = responseBody:match('"mime[Tt]ype"%s*:%s*"([^"]+)"') or "image/png"
    return base64Data, mimeType
end

-- Extracts and validates the develop settings from the model's JSON response.
-- CropLeft/Top/Right/Bottom and CropAngle remain RELATIVE to the frame seen in
-- this pass: composing them with previous passes happens outside this function.
local function parseModelSettings(responseBody, currentlyGrayscale)
    -- The model's text may arrive with escaped quotes (\"Exposure2012\") if
    -- it's wrapped inside a JSON string field, so we "unwrap" them first.
    local unescapedBody = responseBody:gsub('\\"', '"')

    local developSettings = {}
    for key, val in unescapedBody:gmatch('"([%w_]+)"%s*:%s*(%-?%d+%.?%d*)') do
        if VALID_KEYS[key] then
            developSettings[key] = tonumber(val)
            log("Extracted parameter: " .. key .. " = " .. tostring(val))
        end
    end

    -- Booleans need their own pass: the numeric pattern above stops at the
    -- first non-digit, so "ConvertToGrayscale": true never matches it. %a+
    -- deliberately matches only bare words, so a quoted string value (which
    -- starts with '"') is left to the string pass below.
    for key, val in unescapedBody:gmatch('"([%w_]+)"%s*:%s*(%a+)') do
        if BOOLEAN_VALID_KEYS[key] and (val == "true" or val == "false") then
            developSettings[key] = (val == "true")
            log("Extracted boolean parameter: " .. key .. " = " .. val)
        end
    end

    for key, val in unescapedBody:gmatch('"([%w_]+)"%s*:%s*"([^"]*)"') do
        local allowedValues = STRING_VALID_KEYS[key]
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
local function parseMasks(responseBody)
    local unescapedBody = responseBody:gsub('\\"', '"')
    local blocks = extractMaskBlocks(unescapedBody)

    local masks = {}
    local seenTypes = {}
    for _, block in ipairs(blocks) do
        local maskType = block:match('"type"%s*:%s*"([%a_]+)"')
        if not maskType then
            log("Mask block without a valid 'type' field, discarded.")
        elseif not MASK_SUBJECT_TYPES[maskType] then
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

    if #masks > MAX_MASKS_PER_PASS then
        log(string.format("%d masks proposed, capping to %d.", #masks, MAX_MASKS_PER_PASS))
        for i = #masks, MAX_MASKS_PER_PASS + 1, -1 do
            table.remove(masks, i)
        end
    end

    return masks
end

-- Applies parsed local mask corrections to `photo` through LrDevelopController.
--
-- Call order matters and is dictated by the SDK: selectMask and getSelectedMask
-- are documented as requiring "the Develop module active AND the masking tool
-- open", so goToMasking() is called once up front, before any mask is created
-- or selected. The previous version called selectMask before goToMasking.
--
-- Deliberately resilient: any single failure (mask not detected in time, a
-- parameter that fails to set) is logged and skipped rather than aborting the
-- pass, since the global corrections have already been applied by then.
--
-- `maskIDsByType` persists across passes (owned by the caller, one table for
-- the whole refinement run): each region type gets AT MOST one real mask
-- across all passes. Without this, every pass would create another mask for
-- the same type and the corrections would compound instead of being replaced.
-- setValue() always writes an ABSOLUTE value, so reusing the same mask ID and
-- calling it again with this pass's numbers correctly REPLACES the previous
-- correction, consistent with how the global settings behave.

local MASK_DETECT_ATTEMPTS = 14
local MASK_DETECT_INTERVAL = 0.5

-- True when this Lightroom version exposes the masking API at all. The
-- manifest requires SDK 11.0, but the aiSelection subtypes used here landed
-- later, so rather than guessing a version number we check the functions and
-- degrade to global-only editing when they are missing.
local function maskingApiAvailable()
    return type(LrDevelopController.createNewMask) == "function"
        and type(LrDevelopController.getAllMasks) == "function"
        and type(LrDevelopController.selectMask) == "function"
end

-- Set of the IDs currently on the photo, used to tell an existing mask from
-- one createNewMask has just added.
local function currentMaskIDs()
    local ok, masks = pcall(function() return LrDevelopController.getAllMasks() end)
    local ids = {}
    if ok and masks then
        for _, m in ipairs(masks) do
            if m and m.ID then ids[m.ID] = true end
        end
    end
    return ids
end

-- Returns the ID of the mask created by the createNewMask call that just ran,
-- or nil if detection never completed.
--
-- This is the fix for a real defect: the previous version took
-- getAllMasks()[#getAllMasks()] - the LAST entry in the list - and broke out
-- of its polling loop as soon as ANY mask existed. With two mask types in one
-- pass, the second createNewMask returned the FIRST mask's ID, so "background"
-- wrote its local_* values onto the "subject" mask and silently overwrote it,
-- while the log happily reported "2/2 masks applied".
--
-- Two independent signals are used instead:
--  1. getSelectedMask(), documented to return the ID of the selected mask -
--     Lightroom selects a newly created mask - accepted only when the ID was
--     not already present before the call;
--  2. otherwise, a diff of getAllMasks() against `idsBefore`, which does not
--     depend on list ordering.
-- AI region detection is asynchronous and its duration varies with image
-- content, so both are polled rather than read once after a fixed sleep.
local function waitForNewMaskID(idsBefore)
    for _ = 1, MASK_DETECT_ATTEMPTS do
        LrTasks.sleep(MASK_DETECT_INTERVAL)

        if type(LrDevelopController.getSelectedMask) == "function" then
            local ok, selectedID = pcall(function() return LrDevelopController.getSelectedMask() end)
            if ok and selectedID and not idsBefore[selectedID] then
                return selectedID
            end
        end

        local ok, masks = pcall(function() return LrDevelopController.getAllMasks() end)
        if ok and masks then
            for _, m in ipairs(masks) do
                if m and m.ID and not idsBefore[m.ID] then
                    return m.ID
                end
            end
        end
    end
    return nil
end

local function maskStillExists(maskID)
    return currentMaskIDs()[maskID] == true
end

local function applyMasksToPhoto(photo, masks, maskIDsByType)
    if not masks or #masks == 0 then
        return 0
    end

    if not maskingApiAvailable() then
        log("This Lightroom version does not expose the masking API: skipping local corrections, global settings are unaffected.")
        return 0
    end

    local okSwitch = pcall(function() LrApplicationView.switchToModule("develop") end)
    if not okSwitch then
        log("Could not switch to the Develop module, skipping local mask corrections.")
        return 0
    end
    LrTasks.sleep(1.0)

    -- Required before any selectMask/getSelectedMask call, per the SDK docs.
    local okMasking = pcall(function() LrDevelopController.goToMasking() end)
    if not okMasking then
        log("Could not open the masking panel, skipping local mask corrections.")
        return 0
    end
    LrTasks.sleep(0.5)

    local appliedCount = 0

    for _, mask in ipairs(masks) do
        local maskID = nil

        -- Reuse the mask already created for this type in an earlier pass,
        -- if it is still present on the photo (the user may have deleted it).
        local existingID = maskIDsByType[mask.type]
        if existingID then
            if maskStillExists(existingID) then
                maskID = existingID
                log(string.format("Mask '%s': reusing existing mask (%s) from an earlier pass.", mask.type, maskID))
            else
                log(string.format("Mask '%s': previously tracked mask (%s) no longer exists, will recreate.", mask.type, tostring(existingID)))
                maskIDsByType[mask.type] = nil
            end
        end

        if not maskID then
            local idsBefore = currentMaskIDs()

            local okCreate = pcall(function()
                return LrDevelopController.createNewMask("aiSelection", mask.type)
            end)

            if not okCreate then
                log(string.format("createNewMask failed for type '%s', skipping this mask.", mask.type))
            else
                maskID = waitForNewMaskID(idsBefore)
                if not maskID then
                    log(string.format("Mask '%s' was not detected within the timeout (%.0fs), skipping.",
                        mask.type, MASK_DETECT_ATTEMPTS * MASK_DETECT_INTERVAL))
                else
                    maskIDsByType[mask.type] = maskID
                    log(string.format("Mask '%s': created (%s).", mask.type, maskID))
                end
            end
        end

        if maskID then
            local okSelect = pcall(function() LrDevelopController.selectMask(maskID) end)
            LrTasks.sleep(0.3)

            -- Verify the write is actually aimed at the mask we think it is.
            -- setValue writes to whatever is selected, so a silently failed
            -- select would once again dump this type's values onto another
            -- mask - the exact failure this rewrite exists to prevent.
            local targetConfirmed = true
            if type(LrDevelopController.getSelectedMask) == "function" then
                local okGet, selectedID = pcall(function() return LrDevelopController.getSelectedMask() end)
                if okGet and selectedID and selectedID ~= maskID then
                    targetConfirmed = false
                    log(string.format("Mask '%s': selection landed on %s instead of %s, skipping to avoid writing onto the wrong mask.",
                        mask.type, tostring(selectedID), tostring(maskID)))
                end
            end

            if okSelect and targetConfirmed then
                local anySet = false
                for key, value in pairs(mask.params) do
                    pcall(function() LrDevelopController.startTracking(key) end)
                    local okSet = pcall(function() LrDevelopController.setValue(key, value) end)
                    pcall(function() LrDevelopController.stopTracking(true) end)
                    if okSet then
                        anySet = true
                        log(string.format("Mask '%s' (%s): %s = %s applied.", mask.type, maskID, key, tostring(value)))
                    else
                        log(string.format("Mask '%s' (%s): failed to set %s.", mask.type, maskID, key))
                    end
                end

                if anySet then
                    appliedCount = appliedCount + 1
                end
            elseif not okSelect then
                log(string.format("Mask '%s': selectMask(%s) failed, skipping.", mask.type, tostring(maskID)))
            end
        end
    end

    return appliedCount
end

-- Exports the CURRENT state of the photo (already including the development
-- from previous passes, if any) to a temporary JPEG for analysis.
-- The export goes into VenzAI's own subfolder of the OS temp directory rather
-- than the temp root, so a leftover file after a crash is identifiable and
-- cannot collide with another plug-in's export of the same filename.
local function exportCurrentPhoto(photo)
    if not ensureWorkDir() then
        return nil, "could not create the working directory " .. WORK_DIR
    end

    local exportSettings = {
        LR_format = "JPEG",
        LR_export_colorSpace = "sRGB",
        LR_jpeg_quality = 0.85,
        LR_size_doConstrain = true,
        LR_size_maxDimension = 4096,
        LR_export_destinationType = "specificFolder",
        LR_export_destinationPathPrefix = WORK_DIR,
        LR_export_useSubfolder = false,
        LR_collisionHandling = "overwrite",
    }

    local exportSession = LrExportSession({ photosToExport = { photo }, exportSettings = exportSettings })
    local tempPath = nil

    for _, rendition in exportSession:renditions() do
        local success, pathOrMessage = rendition:waitForRender()
        if success then
            tempPath = pathOrMessage
        else
            return nil, pathOrMessage
        end
    end

    return tempPath
end

local function encodeFileBase64(path)
    local file = io.open(path, "rb")
    if not file then
        return nil
    end
    local fileData = file:read("*all")
    file:close()
    return LrStringUtils.encodeBase64(fileData)
end

-- Lua's string.format("%q", ...) does NOT produce a valid JSON escape: it
-- turns a newline into a backslash + a REAL line-break character, not into
-- the two-character sequence "\n" required by the JSON standard. Google
-- tolerates it, but Ollama's (Go) JSON parser rejects it with a 400 error.
-- A hand-written JSON escaper is needed, used by both engines.
local function jsonEscape(s)
    local escaped = s:gsub('[%z\1-\31\\"]', function(c)
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

-- A connection that never got off the ground (wrong host, server down, TLS
-- failure, timeout) comes back with no body and no status, which reads in the
-- log exactly like a server that answered with nothing. The SDK documents
-- only the success shape of the headers table, but in practice it carries an
-- `error` entry in that case; reading it is guarded so that if it ever stops
-- being provided we simply fall back to the generic message.
local function transportError(responseHeaders)
    if responseHeaders and responseHeaders.error then
        local e = responseHeaders.error
        return tostring(e.name or e.errorCode or "connection failed")
    end
    return nil
end

local function callGeminiAPI(model, contentParts, generationConfig)
    local partsJson = {}
    for _, part in ipairs(contentParts) do
        if part.text then
            table.insert(partsJson, string.format('{ "text": %s }', jsonEscape(part.text)))
        elseif part.image then
            table.insert(partsJson, string.format(
                '{ "inline_data": { "mime_type": %s, "data": %s } }',
                jsonEscape(part.image.mimeType),
                jsonEscape(part.image.data)
            ))
        end
    end

    local jsonPayload = string.format(
        '{ "contents": [{ "parts": [%s] }], "generationConfig": %s }',
        table.concat(partsJson, ","),
        generationConfig
    )

    -- The key travels in the x-goog-api-key header rather than in the query
    -- string: a URL is the part most likely to end up copied into a log line,
    -- a proxy access log or a bug report.
    local responseBody, responseHeaders = LrHttp.post(
        "https://generativelanguage.googleapis.com/v1beta/models/" .. model .. ":generateContent",
        jsonPayload,
        {
            { field = "Content-Type", value = "application/json" },
            { field = "x-goog-api-key", value = GEMINI_API_KEY },
        },
        "POST",
        GEMINI_TIMEOUT
    )

    local status = responseHeaders and responseHeaders.status
    return responseBody, status, transportError(responseHeaders)
end

-- Calls the local Ollama server (endpoint /api/generate) with text + image.
-- "format": "json" asks the model to return only valid JSON (supported by
-- recent Ollama versions); "stream": false waits for the full response in a
-- single call instead of having to reassemble it in chunks.
-- num_ctx/num_predict are set explicitly and generously: Ollama's default
-- context window (often 4096 tokens) was observed to silently truncate the
-- response mid-JSON ("done_reason":"length") once the prompt (which now
-- includes the Masks instructions) plus a "thinking" model's full reasoning
-- chain plus the JSON answer no longer fit together - a truncated response
-- looks like "the model chose not to propose X" but is actually just cut off.
-- num_ctx was raised from 16384 to 32768 when the parameter vocabulary grew
-- (parametric curve, grain, B&W mixer, profile) and the prompt along with it,
-- plus the current-settings block sent from the second pass onward. Note this
-- costs local RAM/VRAM for the KV cache roughly in proportion: on a constrained
-- machine, lowering it back is the first thing to try, watching the log for the
-- truncation warning below.
local function callOllamaAPI(promptText, base64Image)
    local jsonPayload = string.format(
        '{ "model": %s, "prompt": %s, "images": [%s], "format": "json", "stream": false, "options": { "temperature": 0.9, "num_ctx": 32768, "num_predict": 4096 } }',
        jsonEscape(OLLAMA_MODEL),
        jsonEscape(promptText),
        jsonEscape(base64Image)
    )

    local responseBody, responseHeaders = LrHttp.post(
        OLLAMA_BASE_URL .. "/api/generate",
        jsonPayload,
        { { field = "Content-Type", value = "application/json" } },
        "POST",
        OLLAMA_TIMEOUT
    )

    local status = responseHeaders and responseHeaders.status
    return responseBody, status, transportError(responseHeaders)
end

LrTasks.startAsyncTask(function()
    LrFunctionContext.callWithContext("VenzAIProcess", function(context)
    -- The progress scope is declared before the failure handler so the handler
    -- can close it: an unhandled error used to leave the progress bar spinning
    -- in the top-left corner until Lightroom was restarted.
    local progressScope

    context:addFailureHandler(function(ctx, message)
        log("UNHANDLED ERROR: " .. tostring(message))
        if progressScope then
            pcall(function() progressScope:done() end)
        end
        LrDialogs.message(
            LOC "$$$/VenzAI/Error/UnexpectedTitle=VenzAI stopped unexpectedly",
            LOC("$$$/VenzAI/Error/UnexpectedBody=^1\n\nThe photo keeps whatever was applied up to this point; the 'VenzAI - Original' snapshot restores the state from before the run.", tostring(message)),
            "critical"
        )
    end)

    log("=== VenzAI start (engine=" .. ENGINE .. ") ===")

    local catalog = LrApplication.activeCatalog()
    local photo = catalog:getTargetPhoto()

    if not photo then
        failToUser(
            LOC "$$$/VenzAI/Error/NoPhotoTitle=No photo selected",
            LOC "$$$/VenzAI/Error/NoPhotoBody=Select a photo in the Library or Develop module, then run VenzAI again."
        )
        return
    end
    log("Selected photo: " .. tostring(photo:getRawMetadata("path")))

    if ENGINE == "gemini" and (GEMINI_API_KEY == nil or GEMINI_API_KEY == "") then
        failToUser(
            LOC "$$$/VenzAI/Error/NoApiKeyTitle=Gemini API key missing",
            LOC "$$$/VenzAI/Error/NoApiKeyBody=Enter your Gemini API key in File > Plug-in Manager > VenzAI, or switch the engine to Local (Ollama)."
        )
        return
    end

    -- Bound to the function context so the scope is torn down with it, rather
    -- than relying on every exit path remembering to call done().
    progressScope = LrProgressScope({
        title = (ENGINE == "gemini")
            and LOC "$$$/VenzAI/Progress/TitleGemini=VenzAI processing in progress..."
            or LOC "$$$/VenzAI/Progress/TitleLocal=VenzAI local processing (Ollama) in progress...",
        caption = LOC "$$$/VenzAI/Progress/Preparing=Preparing image...",
        functionContext = context,
    })

    -- Snapshot of the ORIGINAL state before any change, so it's always
    -- possible to go back from Lightroom's History > Snapshots panel,
    -- regardless of how many passes are run.
    local originalSnapshotName = LOC("$$$/VenzAI/Snapshot/Original=VenzAI - Original (^1, ^2)", ENGINE, os.date("%Y-%m-%d %H:%M:%S"))
    catalog:withWriteAccessDo("VenzAI snapshot (original)", function()
        photo:createDevelopSnapshot(originalSnapshotName, true)
    end)
    log("Created snapshot '" .. originalSnapshotName .. "' before any changes.")

    -- Refinement loop: on every pass the current state of the photo (already
    -- including previous passes' edits) is exported and analyzed again, to
    -- progressively refine the result. In the Gemini pipeline, the Nano
    -- Banana reference is also generated ONCE on the first pass and reused
    -- in all subsequent passes.
    local priorCrop = { cl = 0, ct = 0, cr = 1, cb = 1 }
    local priorAngle = 0
    local completedPasses = 0
    local referenceBase64, referenceMime = nil, nil
    -- Tracks, per region "type" (sky, subject, ...), the ID of the mask
    -- created for it in an earlier pass, so later passes UPDATE that same
    -- mask instead of stacking a new one on top - see applyMasksToPhoto.
    local maskIDsByType = {}

    -- Every failure inside the loop resolves the same way, so the decision
    -- lives in one place: if no pass has been applied yet there is nothing to
    -- salvage, so close the progress bar, tell the user why and let the caller
    -- return (true). If at least one pass succeeded the photo is already
    -- improved and snapshotted, so keep that and end the loop quietly (false)
    -- rather than interrupting the user with a dialog about a bonus pass.
    local function passFailure(pass, title, detail)
        log(string.format("Pass %d failed.", pass))
        if completedPasses == 0 then
            pcall(function() progressScope:done() end)
            failToUser(title, detail)
            return true
        end
        log("Stopping the refinement loop at the passes already completed: " .. tostring(detail))
        return false
    end

    for pass = 1, REFINEMENT_PASSES do
        if progressScope:isCanceled() then
            log("Cancelled before pass " .. pass .. ".")
            break
        end

        progressScope:setPortionComplete((pass - 1) / REFINEMENT_PASSES)
        progressScope:setCaption(LOC("$$$/VenzAI/Progress/PassExporting=Pass ^1/^2: exporting...", tostring(pass), tostring(REFINEMENT_PASSES)))

        local tempPath, exportErr = exportCurrentPhoto(photo)
        if not tempPath then
            if passFailure(pass,
                LOC "$$$/VenzAI/Error/ExportTitle=Could not export the photo",
                LOC("$$$/VenzAI/Error/ExportBody=Lightroom could not render a temporary copy for analysis:\n\n^1", tostring(exportErr)))
            then
                return
            end
            break
        end
        log(string.format("Pass %d: export completed: %s", pass, tostring(tempPath)))

        local currentBase64 = encodeFileBase64(tempPath)
        LrFileUtils.delete(tempPath)

        if not currentBase64 then
            log(string.format("Error reading the exported file on pass %d.", pass))
            break
        end
        log(string.format("Pass %d: image encoded, base64 length: %d", pass, #currentBase64))

        if progressScope:isCanceled() then
            log("Cancelled after exporting pass " .. pass .. ".")
            break
        end

        -- From the second pass onward the model is told which settings produced
        -- the image it is about to look at, so that "this looks right now"
        -- becomes "keep this value" instead of "this parameter is not needed",
        -- which applyDevelopSettings would write back as a reset. On pass 1
        -- there is nothing applied yet, so the block is omitted entirely.
        local currentSettingsBlock, isGrayscale = nil, false
        if pass > 1 then
            currentSettingsBlock, isGrayscale = readCurrentSettings(photo)
            if currentSettingsBlock then
                log(string.format("Pass %d: current settings reported to the model:\n%s", pass, currentSettingsBlock))
            else
                log(string.format("Pass %d: no current settings to report.", pass))
            end
        end

        -- Generates the Nano Banana reference only once (on the first pass,
        -- Gemini engine only) and reuses it on every subsequent pass.
        if ENGINE == "gemini" and pass == 1 then
            progressScope:setCaption(LOC "$$$/VenzAI/Progress/GeneratingReference=Generating professional reference (Nano Banana)...")

            log("Sending generation request to " .. GEMINI_IMAGE_MODEL .. "...")
            local nanoResponseBody, nanoStatus = callGeminiAPI(
                GEMINI_IMAGE_MODEL,
                {
                    { text = buildNanoBananaPrompt() },
                    { image = { mimeType = "image/jpeg", data = currentBase64 } },
                },
                '{ "responseModalities": ["TEXT", "IMAGE"] }'
            )
            log("Nano Banana: HTTP status " .. tostring(nanoStatus))
            log("Nano Banana: response received (raw, truncated to 2000 chars): " .. tostring(nanoResponseBody):sub(1, 2000))

            if nanoResponseBody and nanoStatus == 200 then
                referenceBase64, referenceMime = extractInlineImage(nanoResponseBody)
            end

            if referenceBase64 then
                log(string.format("Nano Banana reference extracted: mime=%s, base64 length=%d", tostring(referenceMime), #referenceBase64))
                local ext = referenceMime and referenceMime:match("image/(%w+)") or "png"
                local refPath = REFERENCE_IMAGE_BASE_PATH .. "." .. ext
                local decoded = LrStringUtils.decodeBase64(referenceBase64)
                -- Best effort only: the reference is already held in memory
                -- for the rest of the run, so a failed write costs nothing
                -- but a missing file to inspect afterwards.
                local refFile = ensureWorkDir() and io.open(refPath, "wb") or nil
                if refFile then
                    refFile:write(decoded)
                    refFile:close()
                    log("Reference saved to: " .. refPath)
                else
                    log("Could not write the reference image to " .. refPath .. " (continuing, it is kept in memory for this run).")
                end
            else
                log("No reference image obtained from Nano Banana: continuing with the refinement loop on the plain photo only.")
            end
        end

        if progressScope:isCanceled() then
            log("Cancelled after the Nano Banana step on pass " .. pass .. ".")
            break
        end

        local responseBody, status, reqError

        if ENGINE == "gemini" then
            progressScope:setCaption(LOC("$$$/VenzAI/Progress/PassAnalyzingGemini=Pass ^1/^2: analyzing with Gemini AI...", tostring(pass), tostring(REFINEMENT_PASSES)))

            local analysisParts = {
                { text = "IMAGE 1:" },
                { image = { mimeType = "image/jpeg", data = currentBase64 } },
            }
            if referenceBase64 then
                table.insert(analysisParts, { text = "IMAGE 2 (AI-generated reference):" })
                table.insert(analysisParts, { image = { mimeType = referenceMime, data = referenceBase64 } })
            end
            table.insert(analysisParts, { text = buildAnalysisPrompt(pass, REFINEMENT_PASSES, referenceBase64 ~= nil, currentSettingsBlock) })

            log(string.format("Pass %d: sending analysis request to %s...", pass, GEMINI_ANALYSIS_MODEL))
            responseBody, status, reqError = callGeminiAPI(
                GEMINI_ANALYSIS_MODEL,
                analysisParts,
                '{ "response_mime_type": "application/json", "temperature": 0.9 }'
            )
        else
            progressScope:setCaption(LOC("$$$/VenzAI/Progress/PassAnalyzingOllama=Pass ^1/^2: analyzing with Ollama (^3)...", tostring(pass), tostring(REFINEMENT_PASSES), OLLAMA_MODEL))

            local promptText = buildAnalysisPrompt(pass, REFINEMENT_PASSES, false, currentSettingsBlock)
            log(string.format("Pass %d: sending request to Ollama (%s/api/generate)...", pass, OLLAMA_BASE_URL))
            responseBody, status, reqError = callOllamaAPI(promptText, currentBase64)
        end

        log(string.format("Pass %d: HTTP status %s", pass, tostring(status)))
        log(string.format("Pass %d: response received (raw): %s", pass, tostring(responseBody)))

        -- Ollama reports why generation stopped in "done_reason". If it's
        -- "length" instead of "stop", the response was cut off mid-JSON by
        -- the context/prediction limit - this looks exactly like "the model
        -- chose not to include X" but is actually truncation. Flag it loudly
        -- so this isn't misread as a deliberate model decision again.
        if ENGINE == "local" and responseBody and responseBody:find('"done_reason"%s*:%s*"length"') then
            log(string.format("Pass %d: WARNING - Ollama response was TRUNCATED (done_reason=length). The JSON is incomplete; whatever fields come after the cutoff point (including any Masks) were never generated, not deliberately omitted.", pass))
        end

        if progressScope:isCanceled() then
            log("Cancelled after the HTTP request on pass " .. pass .. ".")
            break
        end

        if not responseBody then
            local detail
            if ENGINE == "local" then
                detail = LOC("$$$/VenzAI/Error/NoResponseLocalBody=No response from the Ollama server at ^1 (model '^2').\n\n^3\n\nCheck that Ollama is running and that the URL in the plug-in settings is correct.",
                    OLLAMA_BASE_URL, OLLAMA_MODEL, tostring(reqError or "no further detail"))
            else
                detail = LOC("$$$/VenzAI/Error/NoResponseCloudBody=No response from the Gemini API.\n\n^1\n\nCheck your network connection.",
                    tostring(reqError or "no further detail"))
            end
            if passFailure(pass, LOC "$$$/VenzAI/Error/NoResponseTitle=No response from the server", detail) then
                return
            end
            break
        end

        if status and status ~= 200 then
            -- The body of an error response carries the reason (bad key,
            -- quota exhausted, unknown model). Truncated because an error
            -- body can still be long, but kept: without it the user only
            -- learns a status number.
            local detail = LOC("$$$/VenzAI/Error/HttpBody=The server answered with HTTP ^1.\n\n^2",
                tostring(status), tostring(responseBody):sub(1, 600))
            if passFailure(pass, LOC "$$$/VenzAI/Error/HttpTitle=The AI service returned an error", detail) then
                return
            end
            break
        end

        local developSettings, parseErr = parseModelSettings(responseBody, isGrayscale)
        if not developSettings then
            local detail = LOC("$$$/VenzAI/Error/ParseBody=The model's answer contained no usable develop setting.\n\n^1", tostring(parseErr))
            if passFailure(pass, LOC "$$$/VenzAI/Error/ParseTitle=Unreadable answer from the model", detail) then
                return
            end
            break
        end

        -- Composes the relative crop (referring to the frame seen in THIS
        -- pass) with the absolute crop already applied in previous passes.
        if developSettings.CropLeft or developSettings.CropTop or developSettings.CropRight or developSettings.CropBottom then
            local rl = developSettings.CropLeft or 0
            local rt = developSettings.CropTop or 0
            local rr = developSettings.CropRight or 1
            local rb = developSettings.CropBottom or 1

            local priorW = priorCrop.cr - priorCrop.cl
            local priorH = priorCrop.cb - priorCrop.ct

            local absCl = priorCrop.cl + rl * priorW
            local absCt = priorCrop.ct + rt * priorH
            local absCr = priorCrop.cl + rr * priorW
            local absCb = priorCrop.ct + rb * priorH

            developSettings.CropLeft, developSettings.CropTop = absCl, absCt
            developSettings.CropRight, developSettings.CropBottom = absCr, absCb

            priorCrop = { cl = absCl, ct = absCt, cr = absCr, cb = absCb }
            log(string.format("Pass %d: composed crop -> Left=%.4f Top=%.4f Right=%.4f Bottom=%.4f", pass, absCl, absCt, absCr, absCb))
        end

        -- Composes the residual angle proposed in this pass with the one
        -- already applied in previous passes (cumulative absolute angle).
        if developSettings.CropAngle then
            local absAngle = priorAngle + developSettings.CropAngle
            if absAngle < -45 then absAngle = -45 end
            if absAngle > 45 then absAngle = 45 end
            developSettings.CropAngle = absAngle
            priorAngle = absAngle
            log(string.format("Pass %d: composed CropAngle -> %.3f", pass, absAngle))
        end

        if priorAngle ~= 0 then
            developSettings.CropConstrainToWarp = true
        end

        local masks = parseMasks(responseBody)

        catalog:withWriteAccessDo("VenzAI develop (pass " .. pass .. ")", function()
            photo:applyDevelopSettings(developSettings)
        end)
        log(string.format("Pass %d: global parameters applied.", pass))

        -- Local (masked) corrections use a completely different write path
        -- (LrDevelopController, which requires the Develop module to be
        -- active) than the global settings above, so they must happen
        -- OUTSIDE the catalog:withWriteAccessDo gate, after it completes.
        if #masks > 0 then
            progressScope:setCaption(LOC("$$$/VenzAI/Progress/PassMasking=Pass ^1/^2: applying local mask corrections...", tostring(pass), tostring(REFINEMENT_PASSES)))
            local appliedMasks = applyMasksToPhoto(photo, masks, maskIDsByType)
            log(string.format("Pass %d: %d/%d local mask(s) applied.", pass, appliedMasks, #masks))
        end

        local snapshotName = LOC("$$$/VenzAI/Snapshot/Pass=VenzAI - Pass ^1 (^2, ^3)", tostring(pass), ENGINE, os.date("%Y-%m-%d %H:%M:%S"))
        catalog:withWriteAccessDo("VenzAI snapshot (pass " .. pass .. ")", function()
            photo:createDevelopSnapshot(snapshotName, true)
        end)
        completedPasses = pass
        log(string.format("Pass %d: parameters applied successfully, snapshot '%s' created.", pass, snapshotName))

    end

    progressScope:setPortionComplete(1.0)
    progressScope:done()

    if completedPasses == 0 then
        log("No pass was completed.")
    else
        log(string.format("Development applied successfully! (%d/%d refinement passes completed)", completedPasses, REFINEMENT_PASSES))
    end
    end)
end)
