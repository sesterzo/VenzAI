-- tests/test_curve.lua
--
-- The point tone curve. Lightroom stores it as a FLAT list of alternating x
-- and y values from 0 to 255 - the shape probe on a real photograph answered
--
--   ToneCurvePV2012 is a table, 4 entries, #=4: [1]=0 [2]=0 [3]=255 [4]=255
--
-- which is the identity curve: the two corners and nothing between them. The
-- parametric curve the plug-in already used shapes four fixed regions; this is
-- where a photograph gets a character that four sliders cannot reach, and the
-- references we are chasing lean on it heavily.
--
-- A curve is a SHAPE, not an amount, so it is absolute: the model sends the
-- whole curve it wants, and nothing is accumulated.

local Parse = require 'VenzAIParse'
local Delta = require 'VenzAIDelta'

return {
    { "the current curve is reported back, or it cannot be refined", function()
        local Prompts = require 'VenzAIPrompts'
        local photo = { getDevelopSettings = function()
            return { Exposure2012 = 0.3,
                     ToneCurvePV2012 = { 0, 0, 64, 48, 255, 255 },
                     ToneCurvePV2012Blue = { 0, 0, 255, 255 } }
        end }
        local block = Prompts.readCurrentSettings(photo)
        assert(block, "nothing came back")
        assert(block:find("ToneCurvePV2012", 1, true),
            "the model cannot refine a curve it is not shown: " .. block)
        assert(block:find("64", 1, true), "the points are missing: " .. block)
        -- The identity curve is the same as no curve: reporting it is noise.
        assert(not block:find("ToneCurvePV2012Blue", 1, true),
            "a straight line is not worth a line of prompt")
    end },

    { "the example answer shows what a curve looks like", function()
        local Prompts = require 'VenzAIPrompts'
        local prompt = Prompts.buildAnalysisPrompt(1, 3, false, nil, nil)
        -- Only the JSON block: the list of absolute keys further down also
        -- names the curve, and matching that would pass without an example.
        local example = prompt:match('requested format(.-)%(the "background"')
        assert(example and example:find("ToneCurvePV2012", 1, true),
            "the one value that is a list is not shown in the example")
    end },

    { "a curve is parsed out of the answer as a list of numbers", function()
        local s = Parse.parseModelSettings(
            '{"Exposure2012": 0.2, "ToneCurvePV2012": [0, 0, 64, 48, 192, 208, 255, 255]}', false)
        local curve = s.ToneCurvePV2012
        assert(type(curve) == "table", "got " .. type(curve))
        assert(#curve == 8, "got " .. #curve .. " values")
        assert(curve[1] == 0 and curve[4] == 48 and curve[8] == 255,
            "the values are in the wrong places: " .. table.concat(curve, ","))
        assert(s.Exposure2012 == 0.2, "its neighbour must be unharmed")
    end },

    { "the three channel curves are parsed too", function()
        local s = Parse.parseModelSettings(
            '{"ToneCurvePV2012Red": [0,0,255,255], "ToneCurvePV2012Green": [0,4,255,255],' ..
            ' "ToneCurvePV2012Blue": [0,0,255,250]}', false)
        assert(#s.ToneCurvePV2012Red == 4)
        assert(s.ToneCurvePV2012Green[2] == 4, "got " .. tostring(s.ToneCurvePV2012Green[2]))
        assert(s.ToneCurvePV2012Blue[4] == 250)
    end },

    --------------------------------------------------------------------------
    -- What Lightroom will not accept
    --------------------------------------------------------------------------
    { "an odd number of values is not a curve", function()
        local s = Parse.parseModelSettings('{"Exposure2012": 0.1, "ToneCurvePV2012": [0, 0, 128]}', false)
        assert(s.ToneCurvePV2012 == nil, "half a point got through")
        assert(s.Exposure2012 == 0.1, "the rest of the answer must survive")
    end },

    { "fewer than two points is not a curve", function()
        local s = Parse.parseModelSettings('{"Exposure2012": 0.1, "ToneCurvePV2012": [0, 0]}', false)
        assert(s.ToneCurvePV2012 == nil, "a single point is not a curve")
        assert(s.Exposure2012 == 0.1, "the rest of the answer must survive")
    end },

    { "x must climb, or the curve doubles back on itself", function()
        local s = Parse.parseModelSettings('{"Exposure2012": 0.1, "ToneCurvePV2012": [0,0, 128,100, 64,200, 255,255]}', false)
        assert(s.ToneCurvePV2012 == nil, "a curve that goes backwards got through")
        assert(s.Exposure2012 == 0.1, "the rest of the answer must survive")
    end },

    { "values outside 0-255 are not on the grid", function()
        local s = Parse.parseModelSettings('{"Exposure2012": 0.1, "ToneCurvePV2012": [0,0, 128,300, 255,255]}', false)
        assert(s.ToneCurvePV2012 == nil, "a y of 300 got through")
        assert(s.Exposure2012 == 0.1, "the rest of the answer must survive")
        local t = Parse.parseModelSettings('{"Exposure2012": 0.1, "ToneCurvePV2012": [-5,0, 255,255]}', false)
        assert(t.ToneCurvePV2012 == nil, "a negative x got through")
    end },

    { "a curve must start at x=0 and end at x=255", function()
        -- Lightroom's curve spans the whole tonal range; a curve that starts at
        -- 30 is not a partial curve, it is a malformed one.
        local s = Parse.parseModelSettings('{"Exposure2012": 0.1, "ToneCurvePV2012": [30,0, 255,255]}', false)
        assert(s.ToneCurvePV2012 == nil, "a curve that does not span the range got through")
        assert(s.Exposure2012 == 0.1, "the rest of the answer must survive")
    end },

    { "an absurd number of points is refused", function()
        local values = {}
        for i = 0, 100 do
            table.insert(values, tostring(math.floor(i * 255 / 100)))
            table.insert(values, tostring(math.floor(i * 255 / 100)))
        end
        local s = Parse.parseModelSettings(
            '{"Exposure2012": 0.1, "ToneCurvePV2012": [' .. table.concat(values, ",") .. ']}', false)
        assert(s.ToneCurvePV2012 == nil, "101 points is a drawing, not a curve")
        assert(s.Exposure2012 == 0.1, "the rest of the answer must survive")
    end },

    --------------------------------------------------------------------------
    -- A shape, not an amount
    --------------------------------------------------------------------------
    { "a curve is absolute: it is never added to the one already there", function()
        assert(not Delta.isDelta("ToneCurvePV2012"), "a curve is a shape, not a movement")
        assert(not Delta.isDelta("ToneCurvePV2012Red"))

        local current = { ToneCurvePV2012 = { 0, 0, 255, 255 } }
        local wanted = { 0, 0, 64, 40, 255, 255 }
        local after = Delta.apply(current, { ToneCurvePV2012 = wanted })
        assert(after.ToneCurvePV2012 == wanted, "the curve was not taken as given")
    end },

    { "a curve that repeats the current one is not a change", function()
        -- Convergence has to be able to tell "the same curve again" from "a new
        -- curve", or a run can never arrive.
        local same = { 0, 0, 255, 255 }
        local _, report = Delta.apply({ ToneCurvePV2012 = same },
                                      { ToneCurvePV2012 = { 0, 0, 255, 255 } })
        assert(report[1].outcome == "unchanged", "got " .. report[1].outcome)
        assert(Delta.hasConverged(report, {}), "an identical curve must not block the exit")
    end },

    { "a different curve IS a change", function()
        local _, report = Delta.apply({ ToneCurvePV2012 = { 0, 0, 255, 255 } },
                                      { ToneCurvePV2012 = { 0, 0, 128, 140, 255, 255 } })
        assert(report[1].outcome == "absolute", "got " .. report[1].outcome)
        assert(not Delta.hasConverged(report, {}))
    end },

    --------------------------------------------------------------------------
    { "the prompt tells the model how to write one", function()
        local Prompts = require 'VenzAIPrompts'
        local prompt = Prompts.buildAnalysisPrompt(1, 3, false, nil, nil)
        assert(prompt:find("ToneCurvePV2012", 1, true), "the curve is not offered")
        assert(prompt:find("255", 1, true), "the grid it is drawn on is not stated")
    end },
}
