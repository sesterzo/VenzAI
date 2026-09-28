-- tests/test_runlock.lua
--
-- One run at a time.
--
-- Nothing used to stop a second run from starting, and two runs nineteen
-- seconds apart produced a log in which neither reference image could be
-- attributed with certainty. They shared more than the log: the same export
-- path with overwrite-on-collision, the same working folder, and - the one
-- that can spoil a photograph - the same Develop module and the same SELECTED
-- mask, which is what LrDevelopController.setValue writes into.
--
-- The guard has to survive Lightroom loading VenzAIProcess.lua afresh on every
-- invocation, so a flag local to a module is not enough: it is a file in the
-- working folder holding the time the run began.
--
-- And a guard that can wedge is worse than no guard. A lock left behind by a
-- crash - or by Lightroom being killed, where no cleanup handler ever runs -
-- must expire on its own. That decision is a pure function, and it is what
-- this file spends most of its time on.

local Lock = require 'VenzAIRunLock'

return {
    { "a free lock can be taken", function()
        assert(Lock.decide(nil, 1000) == true, "nothing holds it")
    end },

    { "a lock held by a live run is refused", function()
        local mayTake, heldSince = Lock.decide(1000, 1060)
        assert(mayTake == false, "a second run must not start")
        assert(heldSince == 1000, "the caller must be able to say since when")
    end },

    { "a lock older than the staleness window is taken anyway", function()
        -- Lightroom killed, the machine restarted, a crash below Lua: no
        -- cleanup handler ever ran and the file is still there. After this
        -- long it cannot belong to a run that is still going.
        local old = 1000
        local now = old + Lock.STALE_AFTER_SECONDS + 1
        assert(Lock.decide(old, now) == true, "the plug-in would be wedged until someone deleted a file")
    end },

    { "the window is longer than any plausible run", function()
        -- Five passes, a slow provider, a reference that takes a minute and a
        -- half: a real three-pass run measured 4 minutes 20. The window has to
        -- clear that by a wide margin, or a slow run locks itself out.
        assert(Lock.STALE_AFTER_SECONDS >= 20 * 60,
            "got " .. Lock.STALE_AFTER_SECONDS .. " seconds")
        assert(Lock.decide(1000, 1000 + 19 * 60) == false,
            "a run 19 minutes in is slow, not dead")
    end },

    { "a lock from the future is not trusted", function()
        -- A clock change, or a file copied from elsewhere. Treating it as
        -- live would wedge the plug-in for as long as the skew lasts; the run
        -- in front of the user is the one that is certainly real.
        assert(Lock.decide(5000, 1000) == true, "a timestamp ahead of now cannot hold the lock")
    end },

    { "a lock whose contents make no sense is not a lock", function()
        for _, nonsense in ipairs({ "", "   ", "not a number", "12abc" }) do
            assert(Lock.decide(Lock.parse(nonsense), 1000) == true,
                "refused to start because of an unreadable lock file: '" .. nonsense .. "'")
        end
    end },

    { "a timestamp is read back out of what was written", function()
        local written = Lock.serialise(1727550000)
        assert(type(written) == "string", "it has to be writable to a file")
        assert(Lock.parse(written) == 1727550000, "got " .. tostring(Lock.parse(written)))
        -- Trailing newline, spaces: a file is not a variable.
        assert(Lock.parse(written .. "\n") == 1727550000)
        assert(Lock.parse(" " .. written .. "  \r\n") == 1727550000)
    end },

    { "how long it has been held is reported in minutes", function()
        -- The message the user sees says how long, because "a run is already
        -- in progress" and "a run has been in progress for 3 minutes" lead to
        -- different decisions.
        assert(Lock.minutesHeld(1000, 1000 + 180) == 3, "got " .. Lock.minutesHeld(1000, 1000 + 180))
        assert(Lock.minutesHeld(1000, 1000 + 30) == 0, "under a minute rounds down")
        assert(Lock.minutesHeld(nil, 1000) == 0, "nothing held it")
    end },

    { "the lock lives in the working folder, and is ours", function()
        local path = Lock.path()
        assert(type(path) == "string" and path ~= "", "no path")
        assert(path:find("venzai", 1, true), "a file with no name of ours in a shared temp folder")
        assert(path:find("lock", 1, true), "its name should say what it is")
    end },
}
