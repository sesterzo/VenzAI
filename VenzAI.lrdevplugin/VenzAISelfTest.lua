-- VenzAISelfTest.lua
local LrDialogs = import 'LrDialogs'
local LrTasks = import 'LrTasks'

local Registry = require 'VenzAIProviderRegistry'
local Contract = require 'VenzAIProviderContract'
local Settings = require 'VenzAISettings'
local VenzAILog = require 'VenzAILog'
local log = VenzAILog.scoped("SelfTest")

LrTasks.startAsyncTask(function()
    local lines = {}
    local function report(line)
        table.insert(lines, line)
        log(line)
    end

    local problems = Registry.problems()
    if #problems > 0 then
        report(LOC("$$$/VenzAI/SelfTest/Rejected=^1 driver(s) were rejected at load:", tostring(#problems)))
        for _, problem in ipairs(problems) do report("  " .. problem) end
    end

    report(LOC("$$$/VenzAI/SelfTest/Active=Active provider: ^1", Registry.active() and LOC(Registry.active().displayName) or "none"))

    for _, driver in ipairs(Registry.all()) do
        report("")
        report(LOC(driver.displayName))

        local contractOk, contractProblem = Contract.validateDriver(driver)
        report("  contract: " .. (contractOk and "ok" or tostring(contractProblem)))

        local config = Settings.providerConfig(driver.id, driver.settingsFields)
        local valid, reasonKey = driver.validate(config)
        report("  settings: " .. (valid and "ok" or ("rejected (" .. tostring(reasonKey) .. ")")))

        if not driver.capabilities.listModels then
            report("  models: this provider does not offer a model list")
        elseif not valid then
            report("  models: not attempted, the settings are incomplete")
        else
            local names, errorKind, errorDetail = Contract.listModels(driver, config)
            if not names then
                report("  models: " .. tostring(errorKind) .. " - " .. tostring(errorDetail))
            elseif #names == 0 then
                report("  models: reachable, none installed")
            else
                report(string.format("  models: %d found, e.g. %s", #names, names[1]))
            end
        end
    end

    LrDialogs.message(
        LOC "$$$/VenzAI/SelfTest/Title=VenzAI provider self-test",
        table.concat(lines, "\n"),
        "info")
end)
