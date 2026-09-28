--[[----------------------------------------------------------------------------

VenzAIRunLock.lua
One run at a time.

Nothing used to stop a second run from starting, and two runs nineteen seconds
apart produced a log in which neither reference image could be attributed with
certainty. They shared more than the log: the same export path with
overwrite-on-collision, the same working folder, and - the one that can spoil a
photograph - the same Develop module and the same SELECTED mask, which is what
LrDevelopController.setValue writes into. Every local value of one run could
have landed on the other run's mask.

Why a file rather than a variable: Lightroom loads VenzAIProcess.lua afresh
every time the menu command is chosen, so a flag local to a module cannot be
relied on to be the same flag.

Why it expires: a guard that can wedge is worse than no guard. The normal
release is a cleanup handler on the run's function context, which runs on a
clean finish and on an error alike - but not when Lightroom is killed or the
machine restarts. So the file carries the time the run began, and a lock older
than the staleness window is taken over rather than obeyed. The working
folder's "empty it" button removes it too, which is the manual way out.

The decision is a pure function, `decide`, so it can be tested without a
filesystem or a clock.

------------------------------------------------------------------------------]]

local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'

local Work = require 'VenzAIWorkFolder'
local VenzAILog = require 'VenzAILog'

local log = VenzAILog.scoped("Lock")

local M = {}

M.NAME = "venzai_run.lock"

-- Long enough that no real run reaches it: a three-pass run measured 4 minutes
-- 20 seconds, and five passes against a slow provider with a reference image
-- to generate is the worst case. Short enough that a crash does not make the
-- plug-in useless for the rest of the day.
M.STALE_AFTER_SECONDS = 30 * 60

-- Through LrPathUtils.child, like everywhere else: hardcoding a separator is
-- the kind of thing that works on one platform and breaks on the other.
function M.path()
    return LrPathUtils.child(Work.path(), M.NAME)
end

-- What goes in the file, and what comes back out of it. A file is not a
-- variable: it arrives with whatever whitespace the writer left behind.
function M.serialise(startedAt)
    return tostring(math.floor(startedAt))
end

function M.parse(text)
    if type(text) ~= "string" then return nil end
    local trimmed = text:match("^%s*(.-)%s*$")
    -- Anchored: "12abc" is not a timestamp, it is a damaged file.
    if not trimmed:match("^%d+$") then return nil end
    return tonumber(trimmed)
end

-- May this run take the lock? Returns true, or false and the time the current
-- holder started. Everything that decides is here, and it decides with two
-- numbers.
function M.decide(heldSince, now)
    if type(heldSince) ~= "number" then return true end

    -- A timestamp ahead of the clock means a clock change or a file from
    -- somewhere else. Obeying it would wedge the plug-in for as long as the
    -- skew lasts, and the run in front of the user is the one certainly real.
    if heldSince > now then return true end

    if now - heldSince >= M.STALE_AFTER_SECONDS then return true end

    return false, heldSince
end

function M.minutesHeld(heldSince, now)
    if type(heldSince) ~= "number" or heldSince > now then return 0 end
    return math.floor((now - heldSince) / 60)
end

local function readHolder()
    local handle = io.open(M.path(), "rb")
    if not handle then return nil end
    local text = handle:read("*a")
    handle:close()
    return M.parse(text)
end

-- Returns true when the lock is now ours, or false and the number of minutes
-- the other run has been going.
--
-- Not atomic, and it does not need to be: the two runs it separates are two
-- menu commands chosen by one person seconds apart, not a race between
-- processes. Lua in Lightroom is single-threaded and cooperative, and nothing
-- between the read and the write below yields.
-- When the current lock was taken, or nil if there is none. Public because the
-- settings panel needs to say who holds it before offering to take it away,
-- and "release it" without "a run really is going" is a button that breaks a
-- photograph.
--
-- Below readHolder, not above it: a local is only in scope after its
-- declaration, so the same function written twelve lines earlier would have
-- called a nil global at run time and never at load time.
function M.heldSince()
    return readHolder()
end

function M.acquire(now)
    now = now or os.time()
    if not Work.ensure() then
        -- Without a folder there is nowhere to put a lock. Do not let that
        -- stop the run: the export will fail immediately afterwards with a
        -- message that says what is actually wrong.
        log("The working folder could not be created; running without a lock.")
        return true
    end

    local heldSince = readHolder()
    local mayTake, holder = M.decide(heldSince, now)
    if not mayTake then
        log(string.format("A run started %d minute(s) ago still holds the lock.",
            M.minutesHeld(holder, now)))
        return false, M.minutesHeld(holder, now)
    end

    if heldSince then
        log(string.format("Taking over a lock left behind %d minute(s) ago.",
            M.minutesHeld(heldSince, now)))
    end

    local handle, err = io.open(M.path(), "wb")
    if not handle then
        log("The lock file could not be written (" .. tostring(err) .. "); running without one.")
        return true
    end
    handle:write(M.serialise(now))
    handle:close()
    return true
end

-- Safe to call when the lock was never taken, and safe to call twice: this
-- runs from a cleanup handler, which is exactly where a second failure is
-- least welcome, so nothing in here may raise.
--
-- Through LrFileUtils, like every other deletion in the plug-in. The first
-- version used os.remove, which in Lightroom's Lua did not delete the file -
-- and because it ran inside a cleanup handler the error was swallowed. A run
-- finished cleanly at 20:38 and the lock from 20:31 was still there, blocking
-- the next run with a message about a run that had ended.
--
-- And it says so on the way out. A release that logs nothing when it works
-- makes silence ambiguous: there was no way to tell "released" from "never
-- ran" in the log that had to be read to find this.
function M.release()
    local path = M.path()

    local existed = false
    pcall(function() existed = LrFileUtils.exists(path) and true or false end)
    if not existed then return end

    local ok = pcall(function() LrFileUtils.delete(path) end)

    local stillThere = false
    pcall(function() stillThere = LrFileUtils.exists(path) and true or false end)

    if ok and not stillThere then
        log("Lock released.")
    else
        log("THE LOCK FILE COULD NOT BE REMOVED: " .. tostring(path) ..
            " - the next run will be refused until it goes stale. " ..
            "Emptying the working folder from the settings panel clears it.")
    end
end

return M
