-- tests/test_prompts.lua
local Prompts = require 'VenzAIPrompts'

local function fakePhoto(settings)
    return { getDevelopSettings = function() return settings end }
end

return {
    -- Regression, found in a real run: reading the develop settings raised
    -- "Yielding is not allowed within a C or metamethod call" on every pass,
    -- six times out of six, so passes 2 and 3 were told nothing about what
    -- pass 1 had already applied. The refinement loop stopped refining and
    -- started re-proposing from scratch, overwriting its own earlier work -
    -- which is what "the results are poor" looked like from outside.
    --
    -- The catalog call can yield, exactly like an HTTP call, so it may not be
    -- protected by Lua's pcall. Driven here the way Lightroom drives a task.
    { "reading the settings survives a catalog call that yields", function()
        local yielding = { getDevelopSettings = function()
            coroutine.yield()
            return { Exposure2012 = 0.8 }
        end }

        local co = coroutine.create(function()
            return Prompts.readCurrentSettings(yielding)
        end)
        local block
        while coroutine.status(co) ~= "dead" do
            local resumed = { coroutine.resume(co) }
            assert(resumed[1], "readCurrentSettings raised: " .. tostring(resumed[2]))
            block = resumed[2]
        end
        assert(block, "the settings came back empty, so the pass would run blind")
        assert(block:find("Exposure2012", 1, true), "got " .. tostring(block))
    end },

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
