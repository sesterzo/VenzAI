-- tests/test_workfolder.lua
local Work = require 'VenzAIWorkFolder'

return {
    { "the folder is VenzAI's own, under the system temp", function()
        local path = Work.path()
        assert(path:find("VenzAI", 1, true), "got " .. tostring(path))
    end },

    --------------------------------------------------------------------------
    -- Naming
    --------------------------------------------------------------------------
    -- One fixed name meant every run overwrote the last. That was fine until
    -- the diagnostics view displayed the file: Lightroom held the handle open,
    -- Windows refused the next write, and the run that wanted to show you the
    -- reference was the very thing that stopped it being saved.
    { "two references in the same run do not collide", function()
        local a = Work.referencePath("png")
        local b = Work.referencePath("png")
        assert(a ~= b, "both runs would write to " .. a)
    end },

    { "the extension comes from the image, and nothing else does", function()
        assert(Work.referencePath("jpeg"):match("%.jpeg$"), Work.referencePath("jpeg"))
        assert(Work.referencePath("png"):match("%.png$"))
        -- A mime type we do not recognise must not become part of the path.
        assert(Work.referencePath(nil):match("%.png$"), "png is the fallback")
        assert(not Work.referencePath("../../etc/passwd"):find("%.%."),
            "an extension is letters, not a path")
    end },

    { "a reference is recognisable as one", function()
        local name = Work.referencePath("png")
        assert(name:find(Work.REFERENCE_PREFIX, 1, true),
            "the prune has to be able to tell our files from anything else")
    end },

    --------------------------------------------------------------------------
    -- Pruning
    --------------------------------------------------------------------------
    { "nothing is deleted while there is room", function()
        local names = {}
        for i = 1, 10 do names[i] = "venzai_reference_" .. i .. ".png" end
        assert(#Work.toPrune(names, 10) == 0, "it deleted inside the limit")
    end },

    { "the oldest go first, and exactly enough of them", function()
        -- The names carry the timestamp, so sorting them sorts by age.
        local names = {}
        for i = 1, 13 do names[i] = "venzai_reference_" .. string.format("%03d", i) .. ".png" end
        local doomed = Work.toPrune(names, 10)
        assert(#doomed == 3, "expected 3, got " .. #doomed)
        table.sort(doomed)
        assert(doomed[1]:find("001") and doomed[2]:find("002") and doomed[3]:find("003"),
            "it deleted the wrong three: " .. table.concat(doomed, ", "))
    end },

    { "files that are not ours are never touched", function()
        local doomed = Work.toPrune({
            "venzai_reference_001.png", "venzai_reference_002.png",
            "_DSC4030.jpg", "something the user put here.txt",
        }, 1)
        assert(#doomed == 1, "expected 1, got " .. #doomed)
        assert(doomed[1]:find("venzai_reference_", 1, true),
            "it went for a file that is not ours: " .. doomed[1])
    end },

    { "an empty folder prunes nothing", function()
        assert(#Work.toPrune({}, 10) == 0)
        assert(#Work.toPrune(nil, 10) == 0)
    end },
}
