-- tests/test_delta.lua
local Delta = require 'VenzAIDelta'
local Parse = require 'VenzAIParse'

return {
    { "an absolute Kelvin is read as a target, not thrown away", function()
        -- What the log showed: the model cooled the photograph by 500 K, saw
        -- the mistake, and asked for 6150 - an absolute. The guard dropped it,
        -- so the correction never happened and the run ended colder than it
        -- started while the reference was warmer. The intent was unambiguous;
        -- refusing it served nobody. A number that can only be an absolute
        -- temperature is now taken as the temperature to go to.
        local absolute, report = Delta.apply({ Temperature = 5900 },
                                             { Temperature = 6150 }, "kelvin")
        assert(absolute.Temperature == 6150,
            "the target was not honoured: " .. tostring(absolute.Temperature))
        local row
        for _, r in ipairs(report) do if r.key == "Temperature" then row = r end end
        assert(row.outcome == "absolute", "got " .. row.outcome)
    end },

    { "a movement is still a movement", function()
        local absolute = Delta.apply({ Temperature = 5900 }, { Temperature = 300 }, "kelvin")
        assert(absolute.Temperature == 6200, "got " .. tostring(absolute.Temperature))
    end },

    { "an absolute target still cannot leave the valid range", function()
        local absolute = Delta.apply({ Temperature = 5900 }, { Temperature = 90000 }, "kelvin")
        assert(absolute.Temperature == 50000, "got " .. tostring(absolute.Temperature))
    end },

    { "on the relative scale nothing is read as a target", function()
        -- There every plausible movement is also a plausible absolute, so the
        -- two cannot be told apart and the movement reading stands.
        local absolute = Delta.apply({ Temperature = 20 }, { Temperature = 30 }, "relative")
        assert(absolute.Temperature == 50, "got " .. tostring(absolute.Temperature))
    end },

    { "an amount is a delta", function()
        for _, key in ipairs({ "Exposure2012", "Contrast2012", "Vibrance",
                               "Temperature", "Tint", "GrainAmount",
                               "SaturationAdjustmentGreen", "GrayMixerBlue",
                               "ColorGradeShadowSat", "ColorGradeShadowLum",
                               "local_Exposure", "local_Saturation" }) do
            assert(Delta.isDelta(key), key .. " should be a movement")
        end
    end },

    { "the shape of the vignette is a position, not a movement", function()
        for _, key in ipairs({ "PostCropVignetteMidpoint", "PostCropVignetteFeather",
                               "PostCropVignetteRoundness", "PostCropVignetteHighlightContrast" }) do
            assert(not Delta.isDelta(key), key .. " must not accumulate")
        end
        -- The real run: 50 + 45 became 95, and the vignette never reached the
        -- frame. PostCropVignetteAmount is the one that IS an amount.
        local after = Delta.apply({ PostCropVignetteMidpoint = 50, PostCropVignetteFeather = 50 },
                                  { PostCropVignetteMidpoint = 45, PostCropVignetteFeather = 70 })
        assert(after.PostCropVignetteMidpoint == 45, "got " .. tostring(after.PostCropVignetteMidpoint))
        assert(after.PostCropVignetteFeather == 70, "got " .. tostring(after.PostCropVignetteFeather))
        assert(Delta.isDelta("PostCropVignetteAmount"), "the strength is still a movement")
    end },

    { "a refused temperature movement is handed back, not just flagged", function()
        -- Without the amount the caller can unlock the white balance but not
        -- carry out the movement that needed unlocking.
        local _, report = Delta.apply({}, { Temperature = 350 }, "kelvin")
        assert(Delta.needsWhiteBalanceUnlock(report), "the unlock is still needed")
        assert(Delta.refusedTemperatureMove(report) == 350,
            "got " .. tostring(Delta.refusedTemperatureMove(report)))
    end },

    { "nothing is handed back when no movement was refused", function()
        local _, report = Delta.apply({ Temperature = 5500 }, { Temperature = 350 }, "kelvin")
        assert(Delta.refusedTemperatureMove(report) == nil, "a movement that worked came back")
        assert(not Delta.needsWhiteBalanceUnlock(report))
    end },

    { "the grading blend is a position, not a movement", function()
        assert(not Delta.isDelta("ColorGradeBlending"),
            "asking for 70 twice would otherwise reach all-highlights")
        local after = Delta.apply({ ColorGradeBlending = 50 }, { ColorGradeBlending = 70 })
        assert(after.ColorGradeBlending == 70, "got " .. tostring(after.ColorGradeBlending))
    end },

    { "a position, a name or a state is not a delta", function()
        for _, key in ipairs({ "ColorGradeShadowHue", "ColorGradeHighlightHue",
                               "ColorGradeMidtoneHue", "ColorGradeGlobalHue",
                               "ParametricShadowSplit", "ParametricMidtoneSplit",
                               "ParametricHighlightSplit", "PostCropVignetteStyle",
                               "CameraProfile", "ConvertToGrayscale",
                               "CropLeft", "CropTop", "CropRight", "CropBottom",
                               "CropAngle", "local_ToningHue" }) do
            assert(not Delta.isDelta(key), key .. " must stay absolute")
        end
    end },

    { "local_ToningSaturation stays a delta although its companion does not", function()
        assert(Delta.isDelta("local_ToningSaturation"))
        assert(not Delta.isDelta("local_ToningHue"))
    end },

    { "a key the parser does not manage is not a delta", function()
        assert(not Delta.isDelta("Nonsense"))
        assert(not Delta.isDelta(nil))
    end },

    { "every managed numeric key is classified one way or the other", function()
        -- The guard against a key added to the parser and forgotten here: it
        -- would silently be treated as absolute and overwrite the photograph.
        for key in pairs(Parse.VALID_KEYS) do
            local classified = Delta.isDelta(key) or Delta.ABSOLUTE_KEYS[key]
            assert(classified, key .. " is in neither list")
        end
    end },

    { "the neutral value is 0 except where the slider does not start there", function()
        assert(Delta.neutralFor("Exposure2012") == 0)
        assert(Delta.neutralFor("SharpenRadius") == 1.0,
            "got " .. tostring(Delta.neutralFor("SharpenRadius")))
        assert(Delta.neutralFor("local_Amount") == 100,
            "got " .. tostring(Delta.neutralFor("local_Amount")))
        assert(Delta.neutralFor("Nonsense") == 0)
    end },
    --------------------------------------------------------------------------
    -- Accumulation
    --------------------------------------------------------------------------
    { "a movement is added to what the photo carries", function()
        local absolute = Delta.apply({ Exposure2012 = 0.35 }, { Exposure2012 = 0.2 })
        assert(math.abs(absolute.Exposure2012 - 0.55) < 1e-9,
            "got " .. tostring(absolute.Exposure2012))
    end },

    { "the example from the design: -10 then +5 lands on -5", function()
        local after1 = Delta.apply({}, { Contrast2012 = -10 })
        assert(after1.Contrast2012 == -10, "got " .. tostring(after1.Contrast2012))
        local after2 = Delta.apply(after1, { Contrast2012 = 5 })
        assert(after2.Contrast2012 == -5, "got " .. tostring(after2.Contrast2012))
    end },

    { "zero means leave it alone", function()
        local absolute = Delta.apply({ Exposure2012 = 0.35 }, { Exposure2012 = 0 })
        assert(absolute.Exposure2012 == 0.35,
            "zero destroyed the value: " .. tostring(absolute.Exposure2012))
    end },

    { "a key the photo does not report starts from neutral", function()
        -- Review Focus 1: nil + delta raises in Lua.
        local absolute = Delta.apply({}, { Clarity2012 = 12 })
        assert(absolute.Clarity2012 == 12, "got " .. tostring(absolute.Clarity2012))
    end },

    { "a slider whose neutral is not zero starts from its own neutral", function()
        -- Review Focus 3: SharpenRadius is 0.5..3.0, neutral 1.0.
        local absolute = Delta.apply({}, { SharpenRadius = 0.4 })
        assert(math.abs(absolute.SharpenRadius - 1.4) < 1e-9,
            "got " .. tostring(absolute.SharpenRadius))
    end },

    { "the sum is clamped at the end of the range, not discarded", function()
        local absolute, report = Delta.apply({ Clarity2012 = 80 }, { Clarity2012 = 40 })
        assert(absolute.Clarity2012 == 100, "got " .. tostring(absolute.Clarity2012))
        local found
        for _, row in ipairs(report) do
            if row.key == "Clarity2012" then found = row end
        end
        assert(found and found.outcome == "clamped", "the clamp must be reported")
        assert(found.from == 80 and found.to == 100, "the report must carry both ends")
    end },

    { "clamping works at the bottom too", function()
        local absolute = Delta.apply({ Shadows2012 = -90 }, { Shadows2012 = -40 })
        assert(absolute.Shadows2012 == -100, "got " .. tostring(absolute.Shadows2012))
    end },

    { "an absolute key passes through untouched", function()
        local absolute = Delta.apply({ ColorGradeShadowHue = 200 },
                                     { ColorGradeShadowHue = 35 })
        assert(absolute.ColorGradeShadowHue == 35,
            "an angle must be taken as given, got " .. tostring(absolute.ColorGradeShadowHue))
    end },

    { "a string and a boolean pass through untouched", function()
        local absolute = Delta.apply({}, { CameraProfile = "Adobe Portrait",
                                           ConvertToGrayscale = true })
        assert(absolute.CameraProfile == "Adobe Portrait")
        assert(absolute.ConvertToGrayscale == true)
    end },

    { "a movement larger than the whole range is the model reverting to absolutes", function()
        -- Review Focus 4, rewritten. It used to assert that an absolute
        -- Temperature was DROPPED. A real run showed what that cost: the model
        -- cooled a photograph, noticed, asked for 6150 to climb back, and was
        -- refused - the run ended colder than it started while its target was
        -- warmer. A number that can only be an absolute temperature is now
        -- honoured as one. The guard still stands where the two readings are
        -- genuinely ambiguous, which is every other parameter.
        local absolute, report = Delta.apply({ Temperature = 5200 }, {
            Temperature = 5400,
            Contrast2012 = 15,
        }, "kelvin")
        assert(absolute.Temperature == 5400,
            "the target should be honoured: " .. tostring(absolute.Temperature))
        assert(absolute.Contrast2012 == 15, "the rest of the answer must still apply")

        -- A parameter where an absolute and a movement cannot be told apart is
        -- still dropped when the number is impossible as a movement.
        local other = Delta.apply({ Contrast2012 = 10 }, { Contrast2012 = 500 })
        assert(other.Contrast2012 == 10, "got " .. tostring(other.Contrast2012))
    end },

    { "Temperature on a JPEG uses the -100..100 scale", function()
        -- Review Focus 2: the range check assumes Kelvin and is wrong for JPEG.
        local absolute = Delta.apply({ Temperature = 20 }, { Temperature = 30 })
        assert(absolute.Temperature == 50, "got " .. tostring(absolute.Temperature))
    end },

    { "Temperature on a raw stays on the Kelvin scale", function()
        local absolute = Delta.apply({ Temperature = 5200 }, { Temperature = 300 })
        assert(absolute.Temperature == 5500, "got " .. tostring(absolute.Temperature))
    end },

    { "a key with no range is passed through without clamping", function()
        local absolute = Delta.apply({}, { CropLeft = 0.02 })
        assert(absolute.CropLeft == 0.02)
    end },

    { "a position repeating what is already there is reported as unchanged", function()
        -- The model returns the crop bounds and the vignette style in nearly
        -- every response, at their neutral values, because the prompt asks for
        -- them. Convergence has to be able to tell that apart from a decision.
        local _, report = Delta.apply(
            { CropLeft = 0, CropRight = 1, PostCropVignetteStyle = 2 },
            { CropLeft = 0, CropRight = 1, PostCropVignetteStyle = 2 })
        for _, row in ipairs(report) do
            assert(row.outcome == "unchanged",
                row.key .. " reported " .. row.outcome .. ", expected unchanged")
        end
    end },

    { "a position that really changes is reported as a decision", function()
        local _, report = Delta.apply({ PostCropVignetteStyle = 2 },
                                      { PostCropVignetteStyle = 1 })
        assert(report[1].outcome == "absolute", "got " .. report[1].outcome)
    end },

    { "a negligible movement is applied but marked as such", function()
        local absolute, report = Delta.apply({ Contrast2012 = 15 }, { Contrast2012 = 1 })
        assert(absolute.Contrast2012 == 16, "it must still be applied")
        assert(report[1].outcome == "negligible", "got " .. report[1].outcome)
    end },
    --------------------------------------------------------------------------
    -- Convergence
    --------------------------------------------------------------------------
    { "an answer of all zeros has converged", function()
        local _, report = Delta.apply({ Exposure2012 = 0.3 },
                                      { Exposure2012 = 0, Contrast2012 = 0 })
        assert(Delta.hasConverged(report, {}))
    end },

    { "an empty answer has converged", function()
        local _, report = Delta.apply({}, {})
        assert(Delta.hasConverged(report, {}))
    end },

    { "a negligible movement has converged", function()
        -- 1% of Contrast2012's span of 200 is 2.
        local _, report = Delta.apply({ Contrast2012 = 15 }, { Contrast2012 = 1 })
        assert(Delta.hasConverged(report, {}))
    end },

    { "one real value among zeros has NOT converged", function()
        local _, report = Delta.apply({}, { Exposure2012 = 0, Contrast2012 = 25 })
        assert(not Delta.hasConverged(report, {}))
    end },

    { "a mask that asks for something means there is still work to do", function()
        -- Written when hasConverged took the masks themselves and refused to
        -- converge whenever one existed. The review found that made the early
        -- exit unreachable on any photograph using a mask, so it now takes each
        -- mask's REPORT and asks the same question it asks of the globals.
        local _, report = Delta.apply({}, {})
        local _, maskReport = Delta.apply({ local_Exposure = 0 }, { local_Exposure = -0.4 })
        assert(not Delta.hasConverged(report, { maskReport }))
    end },

    { "the crop keys the model always returns do not block convergence", function()
        -- The model returns CropLeft/Top/Right/Bottom, CropAngle and
        -- PostCropVignetteStyle in nearly every response because the prompt
        -- asks for them. At their neutral values they are not a decision, and
        -- treating them as one would make the early exit unreachable.
        local current = { CropLeft = 0, CropTop = 0, CropRight = 1, CropBottom = 1,
                          CropAngle = 0, PostCropVignetteStyle = 2 }
        local _, report = Delta.apply(current, {
            CropLeft = 0, CropTop = 0, CropRight = 1, CropBottom = 1,
            CropAngle = 0, PostCropVignetteStyle = 2, Exposure2012 = 0,
        })
        assert(Delta.hasConverged(report, {}), "the early exit would never fire")
    end },

    { "a real crop IS a decision", function()
        local _, report = Delta.apply({ CropLeft = 0 }, { CropLeft = 0.08 })
        assert(not Delta.hasConverged(report, {}))
    end },

    { "a conversion or a profile change is a decision", function()
        local _, r1 = Delta.apply({}, { ConvertToGrayscale = true })
        assert(not Delta.hasConverged(r1, {}))
        local _, r2 = Delta.apply({ CameraProfile = "Adobe Color" },
                                  { CameraProfile = "Adobe Portrait" })
        assert(not Delta.hasConverged(r2, {}))
    end },
    --------------------------------------------------------------------------
    -- Masks
    --------------------------------------------------------------------------
    { "a mask accumulates its own movements", function()
        local onMask = { local_Exposure = -0.5, local_Temperature = 25 }
        local after = Delta.apply(onMask, { local_Exposure = 0.2 })
        assert(math.abs(after.local_Exposure - (-0.3)) < 1e-9,
            "got " .. tostring(after.local_Exposure))
    end },

    { "a mask key an earlier pass set and this one did not mention survives", function()
        -- Review Focus 5: setValue writes only the keys it is given, so the
        -- value is still on the mask. Absence is not zero.
        local onMask = { local_Exposure = -0.5, local_Highlights = -30 }
        local after = Delta.apply(onMask, { local_Exposure = 0.2 })
        assert(after.local_Highlights == -30,
            "an untouched mask value was lost: " .. tostring(after.local_Highlights))
    end },

    { "a local movement is clamped against the local range", function()
        -- local_Exposure is -4..4, not -5..5 like the global one.
        local after = Delta.apply({ local_Exposure = 3.8 }, { local_Exposure = 1 })
        assert(after.local_Exposure == 4, "got " .. tostring(after.local_Exposure))
    end },
    --------------------------------------------------------------------------
    -- Findings from the whole-branch review
    --------------------------------------------------------------------------
    -- The prompt describes local_Amount as "0 to 200, default 100 = full
    -- strength", which is a POSITION. A model asking for 60% strength returns
    -- 60, and as a movement that became 100 + 60 = 160: the mask applied at
    -- 1.6x the intended strength, and the log made it look deliberate. Mask
    -- strength and selection refinement are properties of the mask mechanism,
    -- not corrections to the photograph, so they are positions.
    { "mask strength and refinement are positions, not movements", function()
        assert(not Delta.isDelta("local_Amount"), "local_Amount must be absolute")
        assert(not Delta.isDelta("local_RefineSaturation"),
            "local_RefineSaturation must be absolute")
        local after = Delta.apply({ local_Amount = 100 }, { local_Amount = 60 })
        assert(after.local_Amount == 60,
            "a strength must be taken as given, got " .. tostring(after.local_Amount))
    end },

    -- Temperature's Kelvin span is 48,000, so one percent of it is 480 K - a
    -- plainly visible shift that was being called "nothing left to do" and
    -- ending the run.
    { "a visible white-balance movement is not negligible", function()
        local _, report = Delta.apply({ Temperature = 5200 }, { Temperature = 450 })
        assert(report[1].outcome == "applied",
            "450 K was called " .. report[1].outcome)
        assert(not Delta.hasConverged(report, {}), "the run would have stopped here")
    end },

    { "a genuinely tiny white-balance movement still is negligible", function()
        local _, report = Delta.apply({ Temperature = 5200 }, { Temperature = 10 })
        assert(report[1].outcome == "negligible", "got " .. report[1].outcome)
    end },

    -- hasConverged refused to fire whenever any mask was present, which is the
    -- same defect the plan caught for the crop keys: a settled run keeps naming
    -- sky and subject with zero movements, so the early exit could never fire
    -- on a photograph that uses a mask at all.
    { "masks that ask for nothing do not block the arrival", function()
        local _, maskReport = Delta.apply({ local_Exposure = -0.5 },
                                          { local_Exposure = 0 })
        assert(Delta.hasConverged({}, { maskReport }),
            "a mask asking for nothing must not keep the run going")
    end },

    { "a mask that asks for something does keep the run going", function()
        local _, maskReport = Delta.apply({ local_Exposure = -0.5 },
                                          { local_Exposure = -0.4 })
        assert(not Delta.hasConverged({}, { maskReport }))
    end },

    --------------------------------------------------------------------------
    -- The Temperature scale comes from the FILE, not from the value
    --------------------------------------------------------------------------
    -- Found on a real NEF: the photograph had its white balance on "As Shot",
    -- so getDevelopSettings reported no usable Temperature and the current
    -- value read as 0. The scale was inferred from that 0 as the -100..100
    -- JPEG scale, the model's +18 movement was written as an absolute 18, and
    -- Lightroom - which reads Kelvin for a raw file - clamped it to its
    -- minimum of 2000 K. The photograph came out solid blue.
    --
    -- Worse, the loop could not recover: the next pass correctly asked for
    -- +4500 to climb back out, and the implausibility guard dropped it as "an
    -- absolute sent by habit". The guard was right about the number and wrong
    -- about the situation, because the situation should never have arisen.
    --
    -- A file format is knowable. A missing value is not evidence of a scale.
    { "a raw file is on the Kelvin scale whatever the photo reports", function()
        assert(Delta.temperatureScale("RAW") == "kelvin")
        assert(Delta.temperatureScale("DNG") == "kelvin")
    end },

    { "a rendered file is on the -100..100 scale", function()
        assert(Delta.temperatureScale("JPG") == "relative")
        assert(Delta.temperatureScale("TIFF") == "relative")
        assert(Delta.temperatureScale("PSD") == "relative")
    end },

    { "an unknown format is treated as raw, the safer mistake", function()
        -- Writing a small number as Kelvin ruins the photograph; writing a
        -- Kelvin movement on a relative scale only overshoots and clamps.
        assert(Delta.temperatureScale(nil) == "kelvin")
        assert(Delta.temperatureScale("SOMETHING_NEW") == "kelvin")
    end },

    { "a Kelvin movement is refused when the photo reports no Kelvin", function()
        -- The exact failure: from = 0 on a raw. There is no absolute to add to,
        -- so the movement is skipped and named rather than written as nonsense.
        local absolute, report = Delta.apply({}, { Temperature = 18 }, "kelvin")
        assert(absolute.Temperature == nil,
            "a Temperature was invented: " .. tostring(absolute.Temperature))
        local found
        for _, row in ipairs(report) do
            if row.key == "Temperature" then found = row end
        end
        assert(found and found.outcome == "unknown_scale",
            "it must be reported, got " .. tostring(found and found.outcome))
    end },

    { "a Kelvin movement applies normally once the photo reports Kelvin", function()
        local absolute = Delta.apply({ Temperature = 5200 }, { Temperature = 300 }, "kelvin")
        assert(absolute.Temperature == 5500, "got " .. tostring(absolute.Temperature))
    end },

    { "on a rendered file the same +18 is an ordinary movement", function()
        local absolute = Delta.apply({ Temperature = 0 }, { Temperature = 18 }, "relative")
        assert(absolute.Temperature == 18, "got " .. tostring(absolute.Temperature))
    end },

    { "a refused movement is not an arrival", function()
        local _, report = Delta.apply({}, { Temperature = 18 }, "kelvin")
        assert(not Delta.hasConverged(report, {}),
            "a refused movement must keep the run going")
    end },

    { "a refused Kelvin movement asks for the white balance to be unlocked", function()
        -- Refusing is safe but permanent: on a raw left at "As Shot" the
        -- photograph never reports a Kelvin, so Temperature would be dead for
        -- the whole run. Switching the white balance to Custom is what makes
        -- Lightroom fill in the as-shot Kelvin, giving the NEXT pass something
        -- to move from. One pass of delay instead of a dead parameter.
        local _, report = Delta.apply({}, { Temperature = 18 }, "kelvin")
        assert(Delta.needsWhiteBalanceUnlock(report),
            "the engine is never told to unlock the white balance")

        local _, ok = Delta.apply({ Temperature = 5200 }, { Temperature = 18 }, "kelvin")
        assert(not Delta.needsWhiteBalanceUnlock(ok),
            "a photograph that already reports Kelvin must not be touched")
    end },

}
