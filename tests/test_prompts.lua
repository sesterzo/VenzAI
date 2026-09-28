-- tests/test_prompts.lua
local Prompts = require 'VenzAIPrompts'

local function fakePhoto(settings)
    return { getDevelopSettings = function() return settings end }
end

return {
    { "the model is told its own neutral is not a cast", function()
        -- The defect this pins cost several ruined photographs. A raw arrives
        -- with Temperature 8100 - the white balance the camera calculated so
        -- THIS scene renders neutral. The model read 8100 as "very warm" and
        -- cooled by 1200 K, which does not remove a cast: it adds one. Quoting
        -- the 2000-50000 range invited exactly that reasoning, so the range is
        -- gone and the meaning of the number is stated instead.
        local prompt = Prompts.buildAnalysisPrompt(2, 3, false, "Temperature = 8100", nil)
        assert(prompt:find("neutral", 1, true), "the word the whole thing turns on is missing")
        assert(prompt:lower():find("adds a cast", 1, true),
            "the model must be told which direction the mistake goes")
        assert(not prompt:find("2000 and 50000", 1, true),
            "the absolute range invites reasoning from daylight instead of from the file")
    end },

    --------------------------------------------------------------------------
    -- What the masks already carry
    --------------------------------------------------------------------------
    -- Found in a real run: the sky mask went Temperature +25, then -50, then
    -- +40 across three passes, Dehaze +20 then -20, Exposure -0.5 then +0.3.
    -- The model was told the GLOBAL settings it had applied and nothing about
    -- the masks, so it re-invented the local treatment from scratch each pass
    -- while the mask itself persisted and accumulated. Values a later pass did
    -- not repeat (Highlights -30, Tint +15) stayed underneath, so the finished
    -- sky was a mixture of three contradictory intentions.
    { "the local values already applied are reported back", function()
        local block = Prompts.formatAppliedMasks({
            sky = { local_Exposure = -0.5, local_Temperature = 25 },
            subject = { local_Clarity = 15 },
        })
        assert(block, "nothing came back")
        assert(block:find("sky", 1, true), "the region must be named")
        assert(block:find("local_Exposure = -0.5", 1, true), "got:\n" .. block)
        assert(block:find("local_Temperature = 25", 1, true), "got:\n" .. block)
        assert(block:find("subject", 1, true), "every region in play must appear")
    end },

    { "no masks yet means no block at all", function()
        assert(Prompts.formatAppliedMasks({}) == nil, "an empty table must produce nothing")
        assert(Prompts.formatAppliedMasks(nil) == nil, "nil must produce nothing")
    end },

    { "the regions are listed in a stable order", function()
        -- pairs() order is undefined in Lua, and a block whose lines shuffle
        -- between passes reads to the model as a change that did not happen.
        local applied = { sky = { local_Exposure = 1 }, background = { local_Exposure = 2 },
                          subject = { local_Exposure = 3 } }
        assert(Prompts.formatAppliedMasks(applied) == Prompts.formatAppliedMasks(applied))
        -- The first REGION NAME, not the first word: the line reads `- mask "x":`.
        local first = Prompts.formatAppliedMasks(applied):match('mask "([%a]+)"')
        assert(first == "background", "expected alphabetical, got " .. tostring(first))
    end },

    { "the mask block reaches the prompt with the movement rule", function()
        -- Written under the absolute contract, where a local value REPLACED
        -- the current one. Under delta semantics saying that would be the
        -- opposite of the truth, so the assertion is inverted along with it.
        local prompt = Prompts.buildAnalysisPrompt(2, 3, false, "Exposure2012 = 0.2",
            { sky = { local_Exposure = -0.5 } })
        assert(prompt:find("local_Exposure = -0.5", 1, true),
            "the local state never reached the prompt")
        assert(prompt:find("Your local values are movements too", 1, true),
            "the model must be told local values are movements")
        assert(not prompt:find("REPLACES the one listed", 1, true),
            "the old replacement rule survived in the mask block")
    end },

    { "pass 1 has no mask state to report", function()
        local prompt = Prompts.buildAnalysisPrompt(1, 3, false, nil, nil)
        assert(not prompt:find("local_Exposure =", 1, true), "pass 1 invented a mask history")
    end },

    --------------------------------------------------------------------------
    -- The format contract, and the taste that is no longer prescribed
    --------------------------------------------------------------------------
    -- Two different kinds of rule live in this prompt and they are easy to
    -- confuse. The FORMAT contract is what Lightroom and the parser require: a
    -- key outside the closed list is dropped, a Temperature in the wrong unit
    -- is discarded, a crop outside 0-1 is meaningless. Loosening those does not
    -- free the model, it silently applies less to the photograph.
    --
    -- The TASTE rules were something else: a list of prohibitions that defined
    -- the target by what to avoid. A model scored against prohibitions returns
    -- small numbers, because a small number breaks no rule - which is exactly
    -- what the log showed (Exposure clustered at 0.15-0.20, Saturation at 0).
    -- Those are gone; the author decides.
    { "the format contract survives the rewrite", function()
        local prompt = Prompts.buildAnalysisPrompt(1, 3, false, nil)
        local required = {
            "Exposure2012", "HueAdjustment", "GrayMixer", "ConvertToGrayscale",
            "CameraProfile", "local_Exposure",
            "Kelvin",                     -- the model must know which scale it is on
            "strictly increasing",        -- the parametric split points
            "JSON",
        }
        for _, needle in ipairs(required) do
            assert(prompt:find(needle, 1, true),
                "the format contract lost: " .. needle)
        end
    end },

    { "the prohibitions that made the edit timid are gone", function()
        local prompt = Prompts.buildAnalysisPrompt(1, 3, false, nil)
        local banished = {
            "AT MOST 2 masks",
            "late 2010s",
            "barely perceptible",
            "prefer Vibrance over Saturation",
            "keep Clarity low",
        }
        for _, needle in ipairs(banished) do
            assert(not prompt:find(needle, 1, true),
                "still prescribing taste: " .. needle)
        end
    end },

    { "the reference prompt is freed too", function()
        -- It sets the target the analysis reverse-engineers, so a cautious
        -- reference can only produce a cautious analysis.
        local prompt = Prompts.buildReferencePrompt()
        for _, needle in ipairs({ "Never push", "restrained" }) do
            assert(not prompt:find(needle, 1, true),
                "the reference target is still hedged: " .. needle)
        end
    end },

    { "no mask count is prescribed", function()
        local prompt = Prompts.buildAnalysisPrompt(1, 3, false, nil)
        -- Case-insensitive: the self-check step repeated the cap in lower case
        -- and a literal search for the shouted form walked straight past it.
        assert(not prompt:lower():find("most 2 masks", 1, true), "a mask cap is back in the prompt")
        assert(not prompt:lower():find("at most", 1, true), "a quota is back in the prompt")
        -- The one mask rule that is not taste: asking to isolate a region that
        -- is not in the frame produces a wrong selection, not a bold edit.
        assert(prompt:find("actually visible", 1, true) or prompt:find("genuinely visible", 1, true),
            "the region must still be required to exist in the photograph")
    end },

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

    --------------------------------------------------------------------------
    -- The brief that makes the target
    --------------------------------------------------------------------------
    { "the reference brief no longer orders a dark, loaded look", function()
        local brief = Prompts.buildReferencePrompt()
        -- These were ours, not the model's, and they came back in every
        -- reference: a little dark, colours well loaded, the same everywhere.
        assert(not brief:find("Deep blacks", 1, true),
            "we were asking for the darkness we then complained about")
        assert(not brief:find("too small to see is the same as no edit", 1, true),
            "we were asking for the loudness we then complained about")
        assert(not brief:find("Commit to a direction", 1, true))
    end },

    { "the reference brief asks for open light and believable colour", function()
        local brief = Prompts.buildReferencePrompt()
        assert(brief:find("OPEN, NATURAL LIGHT", 1, true), "the light is not specified")
        assert(brief:find("err on the side of the brighter", 1, true),
            "the tie-break has to point away from dark")
        assert(brief:find("BELIEVABLE COLOUR", 1, true))
        assert(brief:find("Saturation is the last resort", 1, true),
            "loaded colour needs to be named as the failure it is")
        assert(brief:find("does not announce itself", 1, true),
            "the standard of the trade is the whole point")
    end },

    { "the reference brief still protects the photograph", function()
        -- The target is reverse-engineered into develop settings, so it has to
        -- remain the same photograph however it is treated.
        local brief = Prompts.buildReferencePrompt()
        assert(brief:find("The same framing, the same subject", 1, true))
        assert(brief:find("No object added, removed, moved or invented", 1, true))
        assert(brief:find("Fully photorealistic", 1, true))
    end },

    --------------------------------------------------------------------------
    -- Two jobs, two prompts
    --------------------------------------------------------------------------
    { "with a reference the model is an instrument, not the author", function()
        local prompt = Prompts.buildAnalysisPrompt(1, 3, true, nil, nil)
        assert(prompt:find("measuring instrument", 1, true), "the job is not stated")
        assert(prompt:find("NOT the author", 1, true), "the model is still being given the edit to author")
        assert(not prompt:find("The edit is yours to author", 1, true),
            "the authorial framing is what made every photograph get the same numbers")
    end },

    { "without a reference the model must still be the author", function()
        -- There is no target to measure against, so the older prompt is the
        -- only one that can work - it is kept whole for exactly this case.
        local prompt = Prompts.buildAnalysisPrompt(1, 3, false, nil, nil)
        assert(prompt:find("The edit is yours to author", 1, true),
            "with nothing to measure against, the model has to decide")
        assert(not prompt:find("measuring instrument", 1, true),
            "there is nothing to measure")
    end },

    { "the reference is named as the target, not as mood", function()
        local prompt = Prompts.buildAnalysisPrompt(1, 3, true, nil, nil)
        assert(prompt:find("IMAGE 2 is the TARGET", 1, true), "the reference is not named as the target")
        assert(not prompt:find("useful ONLY to understand", 1, true),
            "demoting the target to inspiration is how it got ignored")
        -- And what it must never be trusted for. It is a re-render at a
        -- fraction of the photograph's resolution: its tone and colour are
        -- decisions, its texture is an artefact of how it was made.
        assert(prompt:find("Never take crop, geometry, horizon", 1, true),
            "geometry must still come from the photograph itself")
        assert(prompt:find("reliable for TONE, COLOUR, CONTRAST and LIGHT and for nothing else", 1, true),
            "the target is presented as reliable for more than it is")
        assert(prompt:find("JUDGED ON IMAGE 1 ALONE", 1, true),
            "detail measured against a generative re-render measures the artefact")
    end },

    { "silence must mean compared, not skipped", function()
        -- A run answered with 11 keys and no masks at all: the rule that an
        -- unseen difference is omitted had been read as "be brief".
        local prompt = Prompts.buildAnalysisPrompt(1, 3, true, nil, nil)
        assert(prompt:find('never "I did not look"', 1, true),
            "omission has to be a finding, not a shortcut")
        assert(prompt:find("GO THROUGH ALL SIX REGIONS, ONE AT A TIME", 1, true),
            "the regions have to be a roll call or they get skipped wholesale")
        assert(prompt:find("separates a photograph from a filter", 1, true))
    end },

    { "composition is the one step the instrument still authors", function()
        -- Rewriting every step as a comparison left composition with no owner:
        -- the target is explicitly unreliable for geometry, so "no difference
        -- to report" swallowed the crop. Not one crop key came back in four
        -- runs, including a frame with the subject hard against one edge.
        local prompt = Prompts.buildAnalysisPrompt(1, 3, true, nil, nil)
        assert(prompt:find("THE ONE STEP WHERE YOU ARE THE AUTHOR", 1, true),
            "composition has to be handed back to the model explicitly")
        assert(prompt:find('"no difference to report" is not an available answer', 1, true),
            "silence must not be a way out of the one step that is not measured")
        assert(prompt:find("Cutting 30-50% of the frame away is an ordinary decision", 1, true),
            "a crop that never dares to be large is the same as no crop")
    end },

    { "the example crop is a real crop, and keeps the aspect ratio", function()
        -- The example used to trim 2% off one side while the instructions
        -- called a timid trim almost never right. A model imitates what it is
        -- shown, so the two have to agree.
        local prompt = Prompts.buildAnalysisPrompt(1, 3, true, nil, nil)
        local example = prompt:match('requested format(.-)%(the "background"')
        assert(example, "the example block moved")
        local left = tonumber(example:match('"CropLeft":%s*([%d%.]+)'))
        local right = tonumber(example:match('"CropRight":%s*([%d%.]+)'))
        local top = tonumber(example:match('"CropTop":%s*([%d%.]+)'))
        local bottom = tonumber(example:match('"CropBottom":%s*([%d%.]+)'))
        assert(left and right and top and bottom, "the example lost its crop")
        local width, height = right - left, bottom - top
        assert(math.abs(width - height) < 0.005,
            string.format("the example crop changes the aspect ratio: %.2f wide, %.2f tall", width, height))
        assert(width < 0.8, "an example that trims 2% teaches trimming 2%")
    end },

    { "a real horizon must be measured, not judged", function()
        local prompt = Prompts.buildAnalysisPrompt(1, 3, true, nil, nil)
        assert(prompt:find("A TRUE HORIZON IS NOT OPTIONAL", 1, true),
            "a crooked horizon is the one error that cannot be left to taste")
        -- And how to measure it, because "estimate the tilt" is not a method.
        assert(prompt:find("where it meets the left edge", 1, true),
            "the model needs a procedure, not an instruction to estimate")
        assert(prompt:find("CropAngle", 1, true))
    end },

    { "a measuring pass may undo its own overshoot", function()
        local prompt = Prompts.buildAnalysisPrompt(2, 3, true, "Tint = 8", nil)
        assert(not prompt:find("do NOT undo what already works well", 1, true),
            "the brake left 13 points of magenta on a photograph and corrected it by 4")
        assert(prompt:lower():find("overshoot", 1, true), "coming back must be allowed explicitly")
    end },

    { "every step of a measuring pass is a comparison", function()
        local prompt = Prompts.buildAnalysisPrompt(1, 3, true, nil, nil)
        assert(prompt:find("Every one of them is a COMPARISON", 1, true))
        -- Say the difference in words before reaching for a number.
        assert(prompt:find("SAY THE DIFFERENCE IN PLAIN WORDS FIRST", 1, true))
        -- And the way out of reciting a preset.
        assert(prompt:find("A parameter you cannot see a difference in is a parameter you leave out", 1, true),
            "silence must be a valid answer, or the preset comes back")
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
    --------------------------------------------------------------------------
    -- Delta semantics
    --------------------------------------------------------------------------
    { "the prompt says the numbers are movements", function()
        local prompt = Prompts.buildAnalysisPrompt(2, 3, true, "Exposure2012 = 0.35", nil)
        assert(prompt:lower():find("movement", 1, true) or prompt:lower():find("move", 1, true),
            "the delta rule is not stated")
        assert(prompt:find("0 means", 1, true) or prompt:lower():find("zero means", 1, true),
            "the model must be told what 0 means now")
    end },

    { "the destructive-zero warning is gone", function()
        -- It existed only because 0 overwrote under absolute semantics.
        local prompt = Prompts.buildAnalysisPrompt(2, 3, true, "Exposure2012 = 0.35", nil)
        assert(not prompt:find("would DESTROY", 1, true),
            "the old warning contradicts the new rule")
        assert(not prompt:find("REPLACES the one above", 1, true),
            "the old replacement rule is still in the prompt")
    end },

    { "every absolute key is named to the model, from the one list", function()
        -- Measured against the EXCEPTIONS block, not the whole prompt: these
        -- key names also appear in the parameter vocabulary, so a search over
        -- the whole text passes whether or not the exception list exists.
        local Delta = require 'VenzAIDelta'
        local prompt = Prompts.buildAnalysisPrompt(1, 3, false, nil, nil)
        local exceptions = prompt:match("THE EXCEPTIONS(.*)$")
        assert(exceptions, "the prompt has no exceptions block")
        for key in pairs(Delta.ABSOLUTE_KEYS) do
            -- The crop keys are described in their own section already.
            if not key:find("^Crop") then
                assert(exceptions:find(key, 1, true),
                    "the model is not told that " .. key .. " is absolute")
            end
        end
    end },
}
