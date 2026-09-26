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
function M.buildReferencePrompt()
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
function M.buildAnalysisPrompt(pass, totalPasses, hasReference, currentSettingsBlock)
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

return M
