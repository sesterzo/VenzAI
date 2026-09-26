-- tests/test_parse.lua
local Parse = require 'VenzAIParse'

return {
    { "a plain JSON answer yields the settings", function()
        local s = Parse.parseModelSettings('{"Exposure2012": -0.25, "Contrast2012": 15}', false)
        assert(s.Exposure2012 == -0.25 and s.Contrast2012 == 15)
    end },

    { "an out-of-range value is discarded, not clamped", function()
        -- The Temperature=8 case: the model confused an absolute value with a
        -- delta. Applying 8 Kelvin would be worse than applying nothing.
        local s = Parse.parseModelSettings('{"Temperature": 8, "Exposure2012": 0.5}', false)
        assert(s.Temperature == nil, "an impossible Temperature must be dropped")
        assert(s.Exposure2012 == 0.5, "a valid neighbour must survive")
    end },

    { "a key outside the whitelist is ignored", function()
        local s = Parse.parseModelSettings('{"Exposure2012": 0.5, "MakeItPretty": 99}', false)
        assert(s.MakeItPretty == nil)
    end },

    { "a boolean is extracted, which the numeric pass cannot see", function()
        local s = Parse.parseModelSettings('{"ConvertToGrayscale": true, "Exposure2012": 0.1}', false)
        assert(s.ConvertToGrayscale == true)
    end },

    { "a CameraProfile outside the closed list is discarded", function()
        local ok = Parse.parseModelSettings('{"CameraProfile": "Adobe Color", "Exposure2012": 0.1}', false)
        assert(ok.CameraProfile == "Adobe Color")
        local bad = Parse.parseModelSettings('{"CameraProfile": "Adobe Colour", "Exposure2012": 0.1}', false)
        assert(bad.CameraProfile == nil, "a typo must not be written through")
    end },

    { "the grey mixer is dropped on a colour photo and kept on a B&W one", function()
        local colour = Parse.parseModelSettings('{"GrayMixerRed": 20, "Exposure2012": 0.1}', false)
        assert(colour.GrayMixerRed == nil, "inert on a colour photo")
        local mono = Parse.parseModelSettings('{"GrayMixerRed": 20, "Exposure2012": 0.1}', true)
        assert(mono.GrayMixerRed == 20, "a pass after the conversion must keep refining the mixer")
    end },

    { "out-of-order curve splits are discarded and the region sliders survive", function()
        local s = Parse.parseModelSettings(
            '{"ParametricShadowSplit": 80, "ParametricMidtoneSplit": 20, "ParametricHighlightSplit": 90, "ParametricLights": 15}', false)
        assert(s.ParametricShadowSplit == nil and s.ParametricMidtoneSplit == nil)
        assert(s.ParametricLights == 15, "the sliders the splits delimit stay valid")
    end },

    { "a crop that would distort the aspect ratio is corrected, not discarded", function()
        local s = Parse.parseModelSettings(
            '{"CropLeft": 0, "CropTop": 0, "CropRight": 1, "CropBottom": 0.5, "Exposure2012": 0.1}', false)
        local width = s.CropRight - s.CropLeft
        local height = s.CropBottom - s.CropTop
        assert(math.abs(width - height) < 0.002,
            string.format("fractions still differ: %.4f vs %.4f", width, height))
    end },

    { "an inverted crop is discarded entirely", function()
        local s = Parse.parseModelSettings(
            '{"CropLeft": 0.9, "CropRight": 0.1, "Exposure2012": 0.1}', false)
        assert(s.CropLeft == nil and s.CropRight == nil)
    end },

    { "an answer with nothing usable returns nil and a reason", function()
        local s, reason = Parse.parseModelSettings('{"nothing": "here"}', false)
        assert(s == nil and type(reason) == "string" and reason ~= "")
    end },

    -- Review Focus: the gsub hack is gone, so a decoded text with real quotes
    -- must still parse, including the nested Masks array.
    { "masks parse from an already-decoded text", function()
        local masks = Parse.parseMasks(
            '{"Exposure2012": 0.1, "Masks": [{"type": "sky", "local_Exposure": -0.4}]}')
        assert(#masks == 1, "expected one mask, got " .. #masks)
        assert(masks[1].type == "sky")
        assert(masks[1].params.local_Exposure == -0.4)
    end },

    { "a mask type outside the allowed list is discarded", function()
        local masks = Parse.parseMasks('{"Masks": [{"type": "unicorn", "local_Exposure": -0.4}]}')
        assert(#masks == 0)
    end },

    { "a duplicate mask type in one pass is discarded", function()
        local masks = Parse.parseMasks(
            '{"Masks": [{"type": "sky", "local_Exposure": -0.4}, {"type": "sky", "local_Exposure": 0.2}]}')
        assert(#masks == 1)
    end },

    { "a mask with no valid local parameter is discarded", function()
        local masks = Parse.parseMasks('{"Masks": [{"type": "sky", "local_Nonsense": 5}]}')
        assert(#masks == 0)
    end },

    { "more masks than the per-pass cap are trimmed", function()
        local masks = Parse.parseMasks('{"Masks": [' ..
            '{"type": "sky", "local_Exposure": -0.4},' ..
            '{"type": "subject", "local_Exposure": 0.3},' ..
            '{"type": "background", "local_Exposure": 0.1}]}')
        assert(#masks == Parse.MAX_MASKS_PER_PASS, "expected " .. Parse.MAX_MASKS_PER_PASS)
    end },

    { "no Masks key at all is an empty list, not an error", function()
        assert(#Parse.parseMasks('{"Exposure2012": 0.1}') == 0)
    end },
}
