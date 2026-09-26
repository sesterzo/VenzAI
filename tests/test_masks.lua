-- tests/test_masks.lua

-- A LrDevelopController that records the order of the calls made on it and
-- behaves enough like the real one for a mask to be created and written to.
local function recordingController(calls)
    local masks = {}
    local selected = nil
    return {
        createNewMask = function(kind, subtype)
            table.insert(calls, "createNewMask:" .. tostring(subtype))
            -- The real getAllMasks returns mask OBJECTS carrying .ID, not bare
            -- strings, and VenzAIMasks reads m.ID to spot a new one.
            local id = "ID-" .. (#masks + 1)
            table.insert(masks, { ID = id })
            selected = id
        end,
        getAllMasks = function()
            -- A COPY: the real one returns a fresh list each call, and handing
            -- back the live table made "the ids before" and "the ids after"
            -- the same object, so a new mask could never be detected.
            local copy = {}
            for i, mask in ipairs(masks) do copy[i] = { ID = mask.ID } end
            return copy
        end,
        selectMask = function(id)
            selected = id
            table.insert(calls, "selectMask:" .. tostring(id))
        end,
        getSelectedMask = function() return selected end,
        goToMasking = function() table.insert(calls, "goToMasking") end,
        goToBasic = function() table.insert(calls, "goToBasic") end,
        startTracking = function() end,
        stopTracking = function() end,
        setValue = function(key, value)
            table.insert(calls, "setValue:" .. tostring(key))
        end,
    }
end

return {
    -- The engine records what each mask carries so a later pass can refine it.
    -- It recorded the values BEFORE writing them, and applyMasksToPhoto has
    -- five paths that skip a mask without writing anything - no masking API, a
    -- module switch that fails, a detector that times out, a selection that
    -- lands elsewhere. The memory then told the next pass a correction was on
    -- the photograph when it was not, the model saw a region that still needed
    -- work and was told it was already handled, and the region stayed wrong.
    { "the caller is told which masks were actually written", function()
        harness.reset()
        harness.stub("LrDevelopController", {})   -- no masking API at all
        harness.stub("LrApplicationView", { switchToModule = function() end })
        local Masks = require 'VenzAIMasks'
        local applied, writtenTypes = Masks.applyMasksToPhoto({},
            { { type = "sky", params = { local_Exposure = -0.4 } } }, {})
        assert(applied == 0, "nothing can be written without the API")
        assert(type(writtenTypes) == "table", "a second return value is required")
        assert(writtenTypes.sky == nil,
            "a mask that was never written must not be reported as written")
    end },

    { "a mask that was written is reported by type", function()
        harness.reset()
        local calls = {}
        harness.stub("LrDevelopController", recordingController(calls))
        harness.stub("LrApplicationView", { switchToModule = function() end })
        local Masks = require 'VenzAIMasks'
        local applied, writtenTypes = Masks.applyMasksToPhoto({},
            { { type = "sky", params = { local_Exposure = -0.4 } } }, {})
        assert(applied == 1, "got " .. tostring(applied))
        assert(writtenTypes.sky == true, "the written type must be named")
    end },

    -- Reported from Lightroom: after a run the Masking panel was still open
    -- with the last mask selected, so the photo was left in a state the user
    -- had to leave by hand before doing anything else. Entering masking is our
    -- doing; leaving it is ours too.
    { "the masking panel is left the way it was found", function()
        harness.reset()
        local calls = {}
        harness.stub("LrDevelopController", recordingController(calls))
        harness.stub("LrApplicationView", {
            switchToModule = function(m) table.insert(calls, "switchToModule:" .. tostring(m)) end,
        })
        local Masks = require 'VenzAIMasks'
        Masks.applyMasksToPhoto({}, { { type = "sky", params = { local_Exposure = -0.4 } } }, {})

        local joined = table.concat(calls, ",")
        local entered = joined:find("goToMasking", 1, true)
        assert(entered, "it never entered masking: " .. joined)
        local left = joined:find("goToBasic", 1, true)
        assert(left, "it never left masking: " .. joined)
        assert(left > entered, "it left masking before entering it: " .. joined)
    end },

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
