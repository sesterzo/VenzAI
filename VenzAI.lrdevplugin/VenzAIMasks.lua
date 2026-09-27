--[[----------------------------------------------------------------------------

VenzAIMasks.lua
Applying local (masked) corrections through LrDevelopController.

Moved out of VenzAIProcess verbatim. This is the one module whose real
behaviour cannot be checked outside Lightroom: LrDevelopController only exists
inside the application, and whether a mask lands on the mask it names is a
question only a real run answers. What IS checked here is the graceful
degradation - a host that does not expose the masking API must fall back to
global-only editing rather than break the run.

------------------------------------------------------------------------------]]

local LrApplicationView = import 'LrApplicationView'
local LrDevelopController = import 'LrDevelopController'
local LrTasks = import 'LrTasks'

local VenzAILog = require 'VenzAILog'
local log = VenzAILog.log

local M = {}

-- Applies parsed local mask corrections to `photo` through LrDevelopController.
--
-- Call order matters and is dictated by the SDK: selectMask and getSelectedMask
-- are documented as requiring "the Develop module active AND the masking tool
-- open", so goToMasking() is called once up front, before any mask is created
-- or selected. The previous version called selectMask before goToMasking.
--
-- Deliberately resilient: any single failure (mask not detected in time, a
-- parameter that fails to set) is logged and skipped rather than aborting the
-- pass, since the global corrections have already been applied by then.
--
-- `maskIDsByType` persists across passes (owned by the caller, one table for
-- the whole refinement run): each region type gets AT MOST one real mask
-- across all passes. Without this, every pass would create another mask for
-- the same type and the corrections would compound instead of being replaced.
-- setValue() always writes an ABSOLUTE value, so reusing the same mask ID and
-- calling it again with this pass's numbers correctly REPLACES the previous
-- correction, consistent with how the global settings behave.

-- 14 attempts at half a second was 7 seconds, and the log shows the people
-- detector missing a walking figure inside it on a 7600px raw. 30 attempts was
-- 15 seconds, and a 8050x5448 coastline lost its 'landscape' mask to it on
-- both passes that asked for one: seven local corrections - the whole treatment
-- of the ground - silently never written, on a photograph where the sky mask
-- next to it had arrived in four seconds. The wait costs nothing when the mask
-- appears quickly, because the loop stops as soon as it does; it only costs on
-- the failure it is there to avoid.
local MASK_DETECT_ATTEMPTS = 90
local MASK_DETECT_INTERVAL = 0.5

-- True when this Lightroom version exposes the masking API at all. The
-- manifest requires SDK 11.0, but the aiSelection subtypes used here landed
-- later, so rather than guessing a version number we check the functions and
-- degrade to global-only editing when they are missing.
function M.maskingApiAvailable()
    return type(LrDevelopController.createNewMask) == "function"
        and type(LrDevelopController.getAllMasks) == "function"
        and type(LrDevelopController.selectMask) == "function"
end

-- Set of the IDs currently on the photo, used to tell an existing mask from
-- one createNewMask has just added.
local function currentMaskIDs()
    local ok, masks = pcall(function() return LrDevelopController.getAllMasks() end)
    local ids = {}
    if ok and masks then
        for _, m in ipairs(masks) do
            if m and m.ID then ids[m.ID] = true end
        end
    end
    return ids
end

-- Returns the ID of the mask created by the createNewMask call that just ran,
-- or nil if detection never completed.
--
-- This is the fix for a real defect: the previous version took
-- getAllMasks()[#getAllMasks()] - the LAST entry in the list - and broke out
-- of its polling loop as soon as ANY mask existed. With two mask types in one
-- pass, the second createNewMask returned the FIRST mask's ID, so "background"
-- wrote its local_* values onto the "subject" mask and silently overwrote it,
-- while the log happily reported "2/2 masks applied".
--
-- Two independent signals are used instead:
--  1. getSelectedMask(), documented to return the ID of the selected mask -
--     Lightroom selects a newly created mask - accepted only when the ID was
--     not already present before the call;
--  2. otherwise, a diff of getAllMasks() against `idsBefore`, which does not
--     depend on list ordering.
-- AI region detection is asynchronous and its duration varies with image
-- content, so both are polled rather than read once after a fixed sleep.
local function waitForNewMaskID(idsBefore)
    for _ = 1, MASK_DETECT_ATTEMPTS do
        LrTasks.sleep(MASK_DETECT_INTERVAL)

        if type(LrDevelopController.getSelectedMask) == "function" then
            local ok, selectedID = pcall(function() return LrDevelopController.getSelectedMask() end)
            if ok and selectedID and not idsBefore[selectedID] then
                return selectedID
            end
        end

        local ok, masks = pcall(function() return LrDevelopController.getAllMasks() end)
        if ok and masks then
            for _, m in ipairs(masks) do
                if m and m.ID and not idsBefore[m.ID] then
                    return m.ID
                end
            end
        end
    end
    return nil
end

local function maskStillExists(maskID)
    return currentMaskIDs()[maskID] == true
end

-- Puts the Develop panel back where the user had it. Entering masking is this
-- module's doing - goToMasking() is required before selectMask - so leaving it
-- is this module's job too. Without this the run ended with the Masking panel
-- open and the last mask still selected, so the next thing the user did landed
-- inside that mask instead of on the photograph.
--
-- Deselect first, then move the panel: a mask left selected is what makes the
-- panel reopen on it. Both are best-effort - a host without goToBasic simply
-- keeps the panel where it is, which is not worth failing a finished edit for.
local function leaveMasking()
    local okDeselect = pcall(function() LrDevelopController.selectMask(nil) end)
    if not okDeselect then
        log("Could not deselect the last mask; the Masking panel may stay open.")
    end

    if type(LrDevelopController.goToBasic) == "function" then
        local okBasic = pcall(function() LrDevelopController.goToBasic() end)
        if not okBasic then
            log("Could not return to the Basic panel; the Masking panel may stay open.")
        end
    else
        log("This Lightroom version exposes no goToBasic; leaving the panel as it is.")
    end
end

-- Returns the number of masks written AND the set of region types that were
-- really written, `{ [type] = true }`. The second value exists because the
-- caller records what each mask carries for the next pass, and five paths
-- through this function skip a mask without writing anything. Recording a
-- correction the mask never received told the next pass a region was handled
-- when it was not, and the region stayed wrong for the rest of the run.
function M.applyMasksToPhoto(photo, masks, maskIDsByType)
    local writtenTypes = {}

    if not masks or #masks == 0 then
        return 0, writtenTypes
    end

    if not M.maskingApiAvailable() then
        log("This Lightroom version does not expose the masking API: skipping local corrections, global settings are unaffected.")
        return 0, writtenTypes
    end

    local okSwitch = pcall(function() LrApplicationView.switchToModule("develop") end)
    if not okSwitch then
        log("Could not switch to the Develop module, skipping local mask corrections.")
        return 0, writtenTypes
    end
    LrTasks.sleep(1.0)

    -- Required before any selectMask/getSelectedMask call, per the SDK docs.
    local okMasking = pcall(function() LrDevelopController.goToMasking() end)
    if not okMasking then
        log("Could not open the masking panel, skipping local mask corrections.")
        return 0, writtenTypes
    end
    LrTasks.sleep(0.5)

    local appliedCount = 0

    for _, mask in ipairs(masks) do
        local maskID = nil

        -- Reuse the mask already created for this type in an earlier pass,
        -- if it is still present on the photo (the user may have deleted it).
        local existingID = maskIDsByType[mask.type]
        if existingID then
            if maskStillExists(existingID) then
                maskID = existingID
                log(string.format("Mask '%s': reusing existing mask (%s) from an earlier pass.", mask.type, maskID))
            else
                log(string.format("Mask '%s': previously tracked mask (%s) no longer exists, will recreate.", mask.type, tostring(existingID)))
                maskIDsByType[mask.type] = nil
            end
        end

        if not maskID then
            local idsBefore = currentMaskIDs()

            local okCreate = pcall(function()
                return LrDevelopController.createNewMask("aiSelection", mask.type)
            end)

            if not okCreate then
                log(string.format("createNewMask failed for type '%s', skipping this mask.", mask.type))
            else
                maskID = waitForNewMaskID(idsBefore)
                if not maskID then
                    log(string.format("Mask '%s' was not detected within the timeout (%.0fs), skipping.",
                        mask.type, MASK_DETECT_ATTEMPTS * MASK_DETECT_INTERVAL))
                    -- Which of the two it was is not guessable from here, and
                    -- the difference decides the fix: a mask Lightroom never
                    -- built (this region is not in this photograph) is not the
                    -- same failure as one it built while we were looking for
                    -- it under another ID. So count them and let the log say.
                    local before, after = 0, 0
                    for _ in pairs(idsBefore) do before = before + 1 end
                    for _ in pairs(currentMaskIDs()) do after = after + 1 end
                    log(string.format("Mask '%s': the photo carried %d mask(s) before the " ..
                        "request and carries %d now - %s.", mask.type, before, after,
                        after > before and "one WAS created and we failed to recognise it"
                                        or "none was created"))
                else
                    maskIDsByType[mask.type] = maskID
                    log(string.format("Mask '%s': created (%s).", mask.type, maskID))
                end
            end
        end

        if maskID then
            local okSelect = pcall(function() LrDevelopController.selectMask(maskID) end)
            LrTasks.sleep(0.3)

            -- Verify the write is actually aimed at the mask we think it is.
            -- setValue writes to whatever is selected, so a silently failed
            -- select would once again dump this type's values onto another
            -- mask - the exact failure this rewrite exists to prevent.
            local targetConfirmed = true
            if type(LrDevelopController.getSelectedMask) == "function" then
                local okGet, selectedID = pcall(function() return LrDevelopController.getSelectedMask() end)
                if okGet and selectedID and selectedID ~= maskID then
                    targetConfirmed = false
                    log(string.format("Mask '%s': selection landed on %s instead of %s, skipping to avoid writing onto the wrong mask.",
                        mask.type, tostring(selectedID), tostring(maskID)))
                end
            end

            if okSelect and targetConfirmed then
                local anySet = false
                for key, value in pairs(mask.params) do
                    pcall(function() LrDevelopController.startTracking(key) end)
                    local okSet = pcall(function() LrDevelopController.setValue(key, value) end)
                    pcall(function() LrDevelopController.stopTracking(true) end)
                    if okSet then
                        anySet = true
                        log(string.format("Mask '%s' (%s): %s = %s applied.", mask.type, maskID, key, tostring(value)))
                    else
                        log(string.format("Mask '%s' (%s): failed to set %s.", mask.type, maskID, key))
                    end
                end

                if anySet then
                    appliedCount = appliedCount + 1
                    writtenTypes[mask.type] = true
                end
            elseif not okSelect then
                log(string.format("Mask '%s': selectMask(%s) failed, skipping.", mask.type, tostring(maskID)))
            end
        end
    end

    leaveMasking()

    return appliedCount, writtenTypes
end

return M
