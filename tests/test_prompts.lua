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
