-- tests/test_parse.lua
local Parse = require 'VenzAIParse'

return {
    --------------------------------------------------------------------------
    -- What Lightroom actually kept
    --------------------------------------------------------------------------
    -- The log used to say only "global parameters applied", which means "the
    -- call returned", not "Lightroom kept these values". A setting Lightroom
    -- silently overrides - the classic one is Temperature while WhiteBalance
    -- is still As Shot - looked identical to one that worked, and the only way
    -- to tell was to stare at the sliders.
    { "a setting Lightroom kept is not reported", function()
        local missed = Parse.settingsNotKept({ Exposure2012 = 0.5 }, { Exposure2012 = 0.5 })
        assert(#missed == 0, "a value that took was reported as missed")
    end },

    { "a setting Lightroom overrode is reported with both values", function()
        local missed = Parse.settingsNotKept(
            { Temperature = 5100 }, { Temperature = 5500 })
        assert(#missed == 1, "got " .. #missed)
        assert(missed[1].key == "Temperature", missed[1].key)
        assert(missed[1].asked == 5100 and missed[1].got == 5500,
            "both values must be carried, for the log to be worth reading")
    end },

    { "a setting that vanished entirely is reported too", function()
        local missed = Parse.settingsNotKept({ HueAdjustmentGreen = 8 }, {})
        assert(#missed == 1 and missed[1].got == nil, "a dropped key must be named")
    end },

    { "tiny float differences are not reported", function()
        -- Crop bounds and SharpenRadius come back rounded; reporting that as a
        -- failure would bury the real ones in noise.
        local missed = Parse.settingsNotKept(
            { CropLeft = 0.10000001, SharpenRadius = 1.2 },
            { CropLeft = 0.1, SharpenRadius = 1.2000001 })
        assert(#missed == 0, "rounding was reported as a miss")
    end },

    { "a non-numeric setting is compared too", function()
        local missed = Parse.settingsNotKept(
            { CameraProfile = "Adobe Landscape", ConvertToGrayscale = true },
            { CameraProfile = "Adobe Color", ConvertToGrayscale = true })
        assert(#missed == 1 and missed[1].key == "CameraProfile", "got " .. #missed)
    end },

    { "a plain JSON answer yields the settings", function()
        local s = Parse.parseModelSettings('{"Exposure2012": -0.25, "Contrast2012": 15}', false)
        assert(s.Exposure2012 == -0.25 and s.Contrast2012 == 15)
    end },

    { "a movement is no longer range-checked against the absolute scale", function()
        -- This test was written for the Temperature=8 defect, when the model
        -- answered absolutes and 8 Kelvin was impossible. Under delta semantics
        -- 8 is an ordinary movement - 8 K warmer - and dropping it here threw
        -- away every white-balance correction, since Temperature's absolute
        -- range starts at 2000. The defence did not disappear: VenzAIDelta
        -- rejects a movement large enough to be an absolute, and clamps the sum.
        local s = Parse.parseModelSettings('{"Temperature": 8, "Exposure2012": 0.5}', false)
        assert(s.Temperature == 8, "a small movement must survive the parser")
        assert(s.Exposure2012 == 0.5, "a valid neighbour must survive")

        local Delta = require 'VenzAIDelta'
        local absolute = Delta.apply({ Temperature = 5200 }, s)
        assert(absolute.Temperature == 5208, "got " .. tostring(absolute.Temperature))
    end },

    { "a position is still range-checked in the parser", function()
        -- PostCropVignetteStyle is an enumeration, so it never became a
        -- movement and the old guard still applies to it.
        local s = Parse.parseModelSettings('{"PostCropVignetteStyle": 9, "Exposure2012": 0.5}', false)
        assert(s.PostCropVignetteStyle == nil, "an impossible style must be dropped")
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

    -- There is no arbitrary cap any more. The ceiling is the mechanism itself:
    -- createNewMask("aiSelection", type) knows six regions, and a second mask
    -- of a type already used would select the same pixels, so it is rejected
    -- as a duplicate. Six is what the photograph can actually carry.
    { "all six region types may be used in one pass", function()
        local masks = Parse.parseMasks('{"Masks": [' ..
            '{"type": "sky", "local_Exposure": -0.4},' ..
            '{"type": "subject", "local_Exposure": 0.3},' ..
            '{"type": "background", "local_Exposure": 0.1},' ..
            '{"type": "people", "local_Texture": -10},' ..
            '{"type": "landscape", "local_Clarity": 12},' ..
            '{"type": "objects", "local_Saturation": 8}]}')
        assert(#masks == 6, "expected all six, got " .. #masks)
    end },

    { "no arbitrary per-pass cap is declared any more", function()
        assert(Parse.MAX_MASKS_PER_PASS == nil,
            "a fixed number is back; the type set is the only ceiling")
    end },

    { "no Masks key at all is an empty list, not an error", function()
        assert(#Parse.parseMasks('{"Exposure2012": 0.1}') == 0)
    end },
}
