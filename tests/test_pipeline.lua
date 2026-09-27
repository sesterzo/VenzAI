-- tests/test_pipeline.lua
--
-- The seam the other suites do not cross. test_delta.lua feeds Delta.apply by
-- hand and test_parse.lua checks the parser alone, so a model answer never
-- travelled the real route - parseModelSettings, then Delta.apply - and a
-- whole class of defect lived in between with 215 tests green.
--
-- What lived there: the parser's range guard was written for ABSOLUTE values
-- and discarded anything outside a parameter's range. Under delta semantics
-- that silently threw away every white-balance movement (Temperature's range
-- starts at 2000) and every negative movement on the 27 keys whose range
-- starts at zero. The photograph came back half-edited and nothing failed.

local Parse = require 'VenzAIParse'
local Delta = require 'VenzAIDelta'

-- One realistic delta answer, of the shape the prompt now asks for.
local ANSWER = [[{
  "Temperature": 300,
  "Tint": 5,
  "Exposure2012": 0.2,
  "Clarity2012": -5,
  "Sharpness": -20,
  "SharpenRadius": 0.4,
  "GrainAmount": -10,
  "LuminanceSmoothing": -15,
  "ColorGradeShadowSat": -10,
  "DefringePurpleAmount": -5,
  "Masks": [
    { "type": "sky", "local_Exposure": -0.3, "local_ToningSaturation": -10 }
  ]
}]]

return {
    { "a white-balance movement survives the parser", function()
        -- Temperature's absolute range is 2000..50000, so every plausible
        -- movement is below it. Discarding them made the design's headline
        -- gain - "300 K warmer" instead of a guessed absolute - impossible.
        local settings = Parse.parseModelSettings(ANSWER, false)
        assert(settings.Temperature == 300,
            "the movement was discarded: " .. tostring(settings.Temperature))
    end },

    { "a negative movement survives on a key whose range starts at zero", function()
        local settings = Parse.parseModelSettings(ANSWER, false)
        for _, key in ipairs({ "Sharpness", "GrainAmount", "LuminanceSmoothing",
                               "ColorGradeShadowSat", "DefringePurpleAmount" }) do
            assert(settings[key] and settings[key] < 0,
                key .. " lost its negative movement: " .. tostring(settings[key]))
        end
    end },

    { "a small movement survives on a slider whose neutral is not zero", function()
        local settings = Parse.parseModelSettings(ANSWER, false)
        assert(settings.SharpenRadius == 0.4,
            "got " .. tostring(settings.SharpenRadius))
    end },

    { "a local movement outside the absolute range survives too", function()
        local masks = Parse.parseMasks(ANSWER)
        assert(#masks == 1, "the mask was lost")
        assert(masks[1].params.local_ToningSaturation == -10,
            "got " .. tostring(masks[1].params.local_ToningSaturation))
    end },

    { "the whole route: parse, then accumulate, lands where it should", function()
        local settings = Parse.parseModelSettings(ANSWER, false)
        local state = { Temperature = 5200, Exposure2012 = 0.35, Sharpness = 40 }
        local absolute = Delta.apply(state, settings)
        assert(absolute.Temperature == 5500, "got " .. tostring(absolute.Temperature))
        assert(math.abs(absolute.Exposure2012 - 0.55) < 1e-9,
            "got " .. tostring(absolute.Exposure2012))
        assert(absolute.Sharpness == 20, "got " .. tostring(absolute.Sharpness))
    end },

    { "an absolute Temperature travels the whole route and is honoured", function()
        -- Written when an absolute was dropped. A real run showed the cost: the
        -- model cooled the photograph, noticed, asked for the temperature it
        -- wanted, and was refused. It is now read as a target - and the parser
        -- still has to let it through for the accumulator to see it at all.
        local settings = Parse.parseModelSettings('{ "Temperature": 5400 }', false)
        assert(settings.Temperature == 5400, "the parser swallowed it")
        local absolute = Delta.apply({ Temperature = 5200 }, settings, "kelvin")
        assert(absolute.Temperature == 5400,
            "the target was not honoured: " .. tostring(absolute.Temperature))
    end },

    { "an answer whose every value is rejected is NOT an arrival", function()
        -- Compounding failure found in review: an answer emptied by the guard
        -- produced an empty report, which read as convergence, and the run
        -- stopped one pass in saying the photograph had arrived - untouched.
        local settings = Parse.parseModelSettings('{ "Temperature": 5400 }', false)
        assert(settings, "the answer should still parse")
        local _, report = Delta.apply({ Temperature = 5200 }, settings)
        assert(not Delta.hasConverged(report, {}),
            "a rejected answer must not be read as an arrival")
    end },
}
