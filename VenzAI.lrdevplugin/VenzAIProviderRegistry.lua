--[[----------------------------------------------------------------------------

VenzAIProviderRegistry.lua
The hand-written list of provider drivers.

Deliberately not discovered at run time: a table that a person edits is a
table a person can read, and the order here is the order the settings panel
shows. Adding a provider is one line.

------------------------------------------------------------------------------]]

local Contract = require 'VenzAIProviderContract'
local Settings = require 'VenzAISettings'
local VenzAILog = require 'VenzAILog'
local log = VenzAILog.scoped("Registry")

local declared = {
    require 'VenzAIProviderGemini',
    require 'VenzAIProviderOpenAI',
    require 'VenzAIProviderOllama',
}

local M = {}

-- Validated once, at load: a malformed driver is named precisely here instead
-- of failing obscurely halfway through a photograph.
local drivers = {}
local problems = {}
local byId = {}

for index, driver in ipairs(declared) do
    local ok, problem = Contract.validateDriver(driver)
    if not ok then
        local message = string.format("driver #%d rejected: %s", index, tostring(problem))
        log(message)
        table.insert(problems, message)
    elseif byId[driver.id] then
        local message = string.format("driver #%d rejected: duplicate id '%s'", index, driver.id)
        log(message)
        table.insert(problems, message)
    else
        table.insert(drivers, driver)
        byId[driver.id] = driver
    end
end

log(string.format("%d driver(s) registered, %d rejected.", #drivers, #problems))

function M.all() return drivers end
function M.byId(id) return byId[id] end
function M.problems() return problems end

-- The first line of the list above is the default provider: this is the only
-- file that names one, so a different default is a reordering here.
--
-- Two different situations both land on that first driver. Nothing chosen yet
-- (a fresh install) is ordinary and silent. A pref naming a driver that is no
-- longer here - what a removed or renamed driver leaves behind - is worth a
-- line in the log, and the plug-in keeps working with a provider the user can
-- see and change rather than failing at load over a stale string.
function M.active()
    local id = Settings.getActiveProviderId()
    local driver = id and byId[id]
    if driver then return driver end

    local fallback = drivers[1]
    if not fallback then
        log("No driver is registered at all.")
    elseif id then
        log(string.format("activeProvider is '%s', which is not registered; falling back to '%s'.",
            id, fallback.id))
    end
    return fallback
end

return M
