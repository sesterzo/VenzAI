-- tests/test_masks.lua
return {
    { "masking degrades instead of failing when the API is absent", function()
        -- A host between SDK 11.0 and the aiSelection subtypes' real minimum
        -- must fall back to global-only editing, not break the run.
        harness.reset()
        harness.stub('LrDevelopController', {})  -- no createNewMask, no getAllMasks
        local Masks = require 'VenzAIMasks'
        assert(Masks.maskingApiAvailable() == false)
    end },

    { "masking is reported available when every function is present", function()
        harness.reset()
        harness.stub('LrDevelopController', {
            createNewMask = function() end,
            getAllMasks = function() return {} end,
            selectMask = function() end,
        })
        local Masks = require 'VenzAIMasks'
        assert(Masks.maskingApiAvailable() == true)
    end },

    { "applying masks with the API absent returns 0 and does not raise", function()
        -- Regression: the extraction renamed maskingApiAvailable to
        -- M.maskingApiAvailable but left applyMasksToPhoto calling it bare, so the
        -- call resolved to a nil global and raised the moment a model proposed a
        -- mask on a host without the masking API. Neither the compile check nor a
        -- test of maskingApiAvailable alone could see it.
        harness.reset()
        harness.stub('LrDevelopController', {})
        local Masks = require 'VenzAIMasks'
        local photo = {}
        local applied = Masks.applyMasksToPhoto(photo,
            { { type = "sky", params = { local_Exposure = -0.4 } } }, {})
        assert(applied == 0, "expected 0 masks applied, got " .. tostring(applied))
    end },
}
