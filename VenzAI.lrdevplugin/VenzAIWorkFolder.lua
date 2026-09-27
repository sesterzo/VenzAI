--[[----------------------------------------------------------------------------

VenzAIWorkFolder.lua
The folder VenzAI works in: where the JPEG it sends is exported and where the
reference images it receives are kept.

A module rather than a few lines inside VenzAIProcess, because two places need
it and only one of them can be a menu script. VenzAIProcess.lua runs when
Lightroom invokes the menu item, so the settings panel cannot require it -
doing so would start a run. The panel was rebuilding the path from the same two
SDK calls, which is a copy waiting to drift.

Reference images are named per run rather than overwritten. One fixed name was
fine until the diagnostics view displayed the file: Lightroom held the handle
open, Windows refused the next write, and the feature meant to let you see the
reference was what stopped it being saved. The folder is pruned to the most
recent few so that naming them does not turn the temp folder into an archive.

------------------------------------------------------------------------------]]

local LrPathUtils = import 'LrPathUtils'
local LrFileUtils = import 'LrFileUtils'

local VenzAILog = require 'VenzAILog'
local log = VenzAILog.scoped("Work")

local M = {}

-- What every reference image is called, so the prune can tell our files from
-- anything else that happens to be in a temp folder.
M.REFERENCE_PREFIX = "venzai_reference_"

-- How many to keep. Enough to compare a few runs, few enough that nobody has
-- to think about the disk.
M.KEEP_REFERENCES = 10

function M.path()
    return LrPathUtils.child(LrPathUtils.getStandardFilePath('temp'), "VenzAI")
end

function M.ensure()
    local folder = M.path()
    if not LrFileUtils.exists(folder) then
        local ok, err = pcall(function() LrFileUtils.createAllDirectories(folder) end)
        if not ok then
            log("Could not create the working directory " .. folder .. ": " .. tostring(err))
            return false
        end
    end
    return true
end

--------------------------------------------------------------------------------
-- Naming
--------------------------------------------------------------------------------

local counter = 0

-- A unique name for one reference image. The clock gives the ordering a person
-- reads; the counter keeps two references in the same second apart.
function M.referencePath(extension)
    -- An extension is letters and digits. Anything else came from a mime type
    -- we do not recognise, and a mime type must never become part of a path.
    local suffix = "png"
    if type(extension) == "string" and extension:match("^%w+$") then
        suffix = extension
    end

    counter = counter + 1
    local name = string.format("%s%s_%03d.%s",
        M.REFERENCE_PREFIX, os.date("%Y%m%d_%H%M%S"), counter, suffix)

    return LrPathUtils.child(M.path(), name)
end

--------------------------------------------------------------------------------
-- Pruning
--------------------------------------------------------------------------------

-- Given the file names in the folder, returns the reference images that should
-- go: the oldest, until only `keep` remain. Names carry the timestamp, so
-- sorting them sorts by age.
--
-- Pure, and separate from the deleting, because deciding what to destroy is
-- the part worth testing and the part that must never be guessed at.
function M.toPrune(names, keep)
    local ours = {}
    for _, name in ipairs(names or {}) do
        if type(name) == "string" and name:find(M.REFERENCE_PREFIX, 1, true) == 1 then
            table.insert(ours, name)
        end
    end

    table.sort(ours)

    local doomed = {}
    local excess = #ours - (keep or M.KEEP_REFERENCES)
    for i = 1, excess do
        table.insert(doomed, ours[i])
    end
    return doomed
end

-- Reads the folder and deletes what toPrune names. Best effort throughout: a
-- file that will not go is a file still open somewhere, which is exactly the
-- condition the per-run naming already works around.
function M.prune()
    local folder = M.path()
    if not LrFileUtils.exists(folder) then return 0 end

    local names = {}
    local ok = pcall(function()
        for filePath in LrFileUtils.files(folder) do
            table.insert(names, LrPathUtils.leafName(filePath))
        end
    end)
    if not ok then
        log("Could not read the working folder to prune it.")
        return 0
    end

    local removed = 0
    for _, name in ipairs(M.toPrune(names, M.KEEP_REFERENCES)) do
        if pcall(function() LrFileUtils.delete(LrPathUtils.child(folder, name)) end) then
            removed = removed + 1
        end
    end

    if removed > 0 then
        log(string.format("Pruned %d old reference image(s), keeping the %d most recent.",
            removed, M.KEEP_REFERENCES))
    end
    return removed
end

-- Empties the folder. Everything in it is ours and disposable: the exported
-- JPEG of a run in progress and the reference images it produced.
function M.clean()
    local folder = M.path()
    if not LrFileUtils.exists(folder) then return 0 end

    local removed, failed = 0, 0
    local ok = pcall(function()
        for filePath in LrFileUtils.files(folder) do
            if pcall(function() LrFileUtils.delete(filePath) end) then
                removed = removed + 1
            else
                failed = failed + 1
            end
        end
    end)
    if not ok then
        log("Could not read the working folder to clean it.")
        return 0, 0
    end

    log(string.format("Working folder cleaned: %d file(s) removed, %d could not be.",
        removed, failed))
    return removed, failed
end

return M
