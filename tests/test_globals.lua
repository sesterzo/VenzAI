-- tests/test_globals.lua
--
-- Catches the one mistake this codebase has now made twice: calling a function
-- that does not exist, by a bare name.
--
--   VenzAIProcess.lua:144: attempt to call global 'ensureWorkDir' (a nil value)
--   VenzAIMasks.lua: applyMasksToPhoto called maskingApiAvailable as a global
--
-- Lua resolves a bare name at RUN time, so the file compiles, every other test
-- passes, and the failure arrives in the middle of developing a photograph -
-- which is the worst possible moment and the hardest place to read a stack
-- trace. Renaming a local function, or moving one into a module, leaves its old
-- call sites looking perfectly normal.
--
-- This is a small linter, not a Lua parser. It errs toward silence: a name it
-- cannot classify is left alone, because a guard that cries wolf gets deleted.

local KNOWN_GLOBALS = {
    -- Lua 5.1
    assert = true, error = true, ipairs = true, next = true, pairs = true,
    pcall = true, print = true, rawequal = true, rawget = true, rawset = true,
    require = true, select = true, setmetatable = true, getmetatable = true,
    tonumber = true, tostring = true, type = true, unpack = true, xpcall = true,
    setfenv = true, getfenv = true, loadstring = true, load = true, collectgarbage = true,
    -- Lightroom
    import = true, LOC = true,
}

-- `function(` and `if (` are not calls; they are the language. Without this the
-- linter reports every anonymous function in the bundle.
local KEYWORDS = {
    ["function"] = true, ["if"] = true, ["while"] = true, ["until"] = true,
    ["and"] = true, ["or"] = true, ["not"] = true, ["return"] = true,
    ["elseif"] = true, ["for"] = true, ["in"] = true, ["do"] = true,
    ["then"] = true, ["else"] = true, ["end"] = true, ["local"] = true,
}

-- Everything defined inside the file: locals, functions, and the parameters of
-- every function, since a parameter is called by its bare name too.
local function definedNames(source)
    local names = {}

    for name in source:gmatch("local%s+function%s+([%a_][%w_]*)") do names[name] = true end
    for name in source:gmatch("function%s+([%a_][%w_]*)%s*%(") do names[name] = true end
    for list in source:gmatch("local%s+([%a_][%w_,%s]*)=") do
        for name in list:gmatch("[%a_][%w_]*") do names[name] = true end
    end
    for list in source:gmatch("local%s+([%a_][%w_,%s]*)\n") do
        for name in list:gmatch("[%a_][%w_]*") do names[name] = true end
    end
    for params in source:gmatch("function%s*[%a_%.:]*%s*%(([^)]*)%)") do
        for name in params:gmatch("[%a_][%w_]*") do names[name] = true end
    end
    for name in source:gmatch("for%s+([%a_][%w_]*)") do names[name] = true end
    for list in source:gmatch("for%s+([%a_][%w_,%s]*)%s+in") do
        for name in list:gmatch("[%a_][%w_]*") do names[name] = true end
    end

    return names
end

-- Comments and strings hold prose full of words followed by brackets.
local function stripped(source)
    return source
        :gsub("%-%-%[%[.-%]%]", " ")
        :gsub("%-%-[^\n]*", " ")
        :gsub("%[=*%[.-%]=*%]", " ")
        :gsub('"[^"\n]*"', '""')
        :gsub("'[^'\n]*'", "''")
end

return {
    { "no file calls a function that does not exist", function()
        local bundle = VENZAI_BUNDLE
        local problems = {}

        for name in VENZAI_BUNDLE_FILES:gmatch("[^,]+") do
            local handle = io.open(bundle .. "/" .. name .. ".lua", "r")
            assert(handle, "could not read " .. name)
            local source = handle:read("*all")
            handle:close()

            local code = stripped(source)
            local defined = definedNames(source)

            -- A call by a bare name: not preceded by a dot or a colon, which
            -- would make it a field of something and none of our business.
            for prefix, called in code:gmatch("([%.:]?)([%a_][%w_]*)%s*%(") do
                if prefix == "" and not KEYWORDS[called]
                    and not defined[called] and not KNOWN_GLOBALS[called] then
                    table.insert(problems,
                        string.format("%s.lua calls '%s', which nothing defines", name, called))
                end
            end
        end

        assert(#problems == 0, "\n    " .. table.concat(problems, "\n    "))
    end },
}
