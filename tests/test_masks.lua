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
}
