--[[----------------------------------------------------------------------------

PluginInfoProvider.lua
The VenzAI section shown in File > Plug-in Manager.

Rendered from declarations, not from a layout. It iterates the driver registry,
emits one group box per driver and one row per field that driver declares, and
enables the box bound to activeProvider. Adding a provider does not touch this
file - which is the point, and the reason Ollama declaring no API key at all is
worth checking by eye.

Defaults and the reading and writing of every setting live in VenzAISettings,
shared with VenzAIProcess. Logging goes through VenzAILog, which writes to
Lightroom's own per-platform log folder rather than into the plug-in bundle
(which is not writable once the plug-in is installed for real).

------------------------------------------------------------------------------]]

local LrView = import 'LrView'
local LrTasks = import 'LrTasks'
local LrDialogs = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrBinding = import 'LrBinding'
local LrShell = import 'LrShell'
local LrFileUtils = import 'LrFileUtils'

local VenzAILog = require 'VenzAILog'
local Settings = require 'VenzAISettings'
local Registry = require 'VenzAIProviderRegistry'
local Contract = require 'VenzAIProviderContract'
local Messages = require 'VenzAIMessages'

local log = VenzAILog.scoped("Settings")

log("=== PluginInfoProvider module loaded ===")
Settings.applyDefaults()
Settings.purgeLegacyPlainTextKey()

-- Property-table keys are namespaced exactly as the prefs are, so two drivers
-- declaring a field called "model" do not collide in the binding either.
local function propertyKey(driverId, fieldKey)
    return string.format("provider.%s.%s", driverId, fieldKey)
end

-- Forward declaration: groupForDriver closes over this, and it is defined below.
-- Without the declaration the closure would capture a global instead and the
-- button would silently do nothing.
local detectModelsAction

-- The popup that chooses the active provider is built from the registry, so a
-- new driver appears here with no edit to this file.
local function providerItems()
    local items = {}
    for _, driver in ipairs(Registry.all()) do
        table.insert(items, { title = LOC(driver.displayName), value = driver.id })
    end
    return items
end

-- One group box per driver, one row per declared field. The role picks the
-- control: a secret gets a password_field, everything else an edit_field. A
-- field with role "model" also gets the Detect button, but only when its driver
-- declares the listModels capability.
--
-- "bind_to_object = propertyTable" is explicit on the group box: without it,
-- controls nested inside group_box/row do not resolve the binding and the fields
-- render empty even when propertyTable holds the right value. "enabled" stays on
-- individual controls, not on the group box.
local function groupForDriver(f, propertyTable, driver)
    local function enabledForThisDriver()
        return LrView.bind {
            key = "activeProvider",
            transform = function(value) return value == driver.id end,
        }
    end

    local rows = {
        bind_to_object = propertyTable,
        title = LOC(driver.displayName),
        fill_horizontal = 1,
    }

    for _, field in ipairs(driver.settingsFields) do
        local key = propertyKey(driver.id, field.key)

        local control
        if field.role == "secret" then
            control = f:password_field {
                value = LrView.bind(key),
                width_in_chars = 30,
                enabled = enabledForThisDriver(),
            }
        else
            control = f:edit_field {
                value = LrView.bind(key),
                width_in_chars = 30,
                enabled = enabledForThisDriver(),
            }
        end

        local row = {
            spacing = f:control_spacing(),
            f:static_text {
                title = LOC(field.label),
                width = LrView.share "venzai_label_width",
                enabled = enabledForThisDriver(),
            },
            control,
        }

        if field.role == "model" and driver.capabilities.listModels then
            table.insert(row, f:push_button {
                title = LOC "$$$/VenzAI/Settings/DetectModels=Detect models",
                enabled = enabledForThisDriver(),
                action = function() detectModelsAction(propertyTable, driver, field) end,
            })
        end

        table.insert(rows, f:row(row))

        if field.role == "secret" then
            table.insert(rows, f:row { f:static_text {
                title = LOC "$$$/VenzAI/Settings/SecretNote=The value is stored encrypted in the system keychain, not in the preferences file.",
                enabled = enabledForThisDriver(),
            } })
        end
    end

    if #driver.settingsFields == 0 then
        table.insert(rows, f:row { f:static_text {
            title = LOC "$$$/VenzAI/Settings/NoSettings=This provider needs no settings.",
        } })
    end

    return f:group_box(rows)
end

-- Works for any driver declaring listModels: there is no Ollama-specific button
-- any more. Must run inside an async task, because LrHttp yields and a button
-- callback may not.
function detectModelsAction(propertyTable, driver, field)
    log(string.format("'Detect models' clicked for %s.", driver.id))
    LrTasks.startAsyncTask(function()
        LrFunctionContext.callWithContext("VenzAI_DetectModels", function(context)
            -- Read the config from the panel's live values rather than from
            -- prefs: the user may have just typed a new URL.
            local config = {}
            for _, declared in ipairs(driver.settingsFields) do
                config[declared.key] = propertyTable[propertyKey(driver.id, declared.key)]
            end

            -- Through the funnel, not straight at the driver: this is the one
            -- place that used to skip validation, so an empty API key produced a
            -- round trip that came back "the credentials were rejected" instead
            -- of "the API key is empty". The funnel also pcalls the driver, so a
            -- field arriving nil cannot surface as a raw Lua error dialog.
            local names, errorKind, errorDetail, reasonKey = Contract.listModels(driver, config)

            if not names then
                log(string.format("Detect models failed for %s: %s (%s)",
                    driver.id, tostring(errorKind), tostring(errorDetail)))
                local title, body = Messages.forError(errorKind or "unknown",
                    driver.displayName, config[field.key], reasonKey)
                LrDialogs.message(title, body .. Messages.technicalSection(errorDetail), "warning")
                return
            end

            -- Reachable but empty is NOT a failure, and saying so sends the user
            -- to the right place: install a model, rather than hunt for a network
            -- problem that is not there.
            if #names == 0 then
                log(string.format("%s is reachable but has no model installed.", driver.id))
                LrDialogs.message(
                    LOC "$$$/VenzAI/Settings/NoModelsTitle=No models are installed",
                    LOC("$$$/VenzAI/Settings/NoModelsBody=^1 answered, but has no model installed yet.\n\nInstall one on that service, then detect again.",
                        LOC(driver.displayName)),
                    "info")
                return
            end

            if #names == 1 then
                log("Only one model detected, auto-selecting: " .. names[1])
                propertyTable[propertyKey(driver.id, field.key)] = names[1]
                return
            end

            log(string.format("%d models detected, showing picker.", #names))
            local pickerProps = LrBinding.makePropertyTable(context)
            pickerProps.selected = names[1]
            local items = {}
            for _, name in ipairs(names) do
                table.insert(items, { title = name, value = name })
            end

            local viewFactory = LrView.osFactory()
            local result = LrDialogs.presentModalDialog {
                title = LOC "$$$/VenzAI/Settings/PickModelTitle=Select a model",
                contents = viewFactory:popup_menu {
                    bind_to_object = pickerProps,
                    value = LrView.bind "selected",
                    items = items,
                    width_in_chars = 30,
                },
            }

            if result == "ok" then
                log("User picked model: " .. tostring(pickerProps.selected))
                propertyTable[propertyKey(driver.id, field.key)] = pickerProps.selected
            end
        end)
    end)
end

-- Opens the folder LrLogger writes into, in Explorer or the Finder. The log no
-- longer sits next to the plug-in, so without this the user has no realistic way
-- to find it.
local function showLogAction()
    local folder = VenzAILog.logFolderPath()
    local file = VenzAILog.logFilePath()

    -- Reveal the file itself when it exists so the right one is highlighted;
    -- fall back to the folder before the first run has created it.
    local target = (file and LrFileUtils.exists(file)) and file or folder

    if not target or not LrFileUtils.exists(target) then
        LrDialogs.message(
            LOC "$$$/VenzAI/Settings/Log/NotFoundTitle=Log file not found",
            LOC("$$$/VenzAI/Settings/Log/NotFoundBody=Expected location:\n^1\n\nThe file is created the first time VenzAI runs.", tostring(file or folder or "unknown")),
            "info"
        )
        return
    end

    LrShell.revealInShell(target)
end

local function sectionsForTopOfDialog(f, propertyTable)
    local bind = LrView.bind
    local share = LrView.share

    log("sectionsForTopOfDialog called (panel opened/redrawn).")

    -- Reapply defaults every time the panel opens, not just on the module's
    -- first load: if something had left a value empty it self-heals here.
    Settings.applyDefaults()
    Settings.purgeLegacyPlainTextKey()

    local problems = Registry.problems()
    if #problems > 0 then
        log(string.format("%d driver(s) were rejected at load; see the lines above.", #problems))
    end

    -- Seeded from Registry.active(), not from the raw pref: when the pref names
    -- a driver that no longer exists the engine falls back to the first
    -- registered one, and the panel has to show THAT, or the popup renders empty
    -- with every group box disabled while a different provider is what actually
    -- runs. The observer below then writes the healed value back.
    local activeDriver = Registry.active()
    propertyTable.activeProvider = activeDriver and activeDriver.id or Settings.getActiveProviderId()
    if activeDriver and activeDriver.id ~= Settings.getActiveProviderId() then
        log(string.format("activeProvider pref was '%s', which is not registered; the panel shows '%s'.",
            tostring(Settings.getActiveProviderId()), activeDriver.id))
        Settings.setActiveProviderId(activeDriver.id)
    end
    propertyTable:addObserver("activeProvider", function()
        Settings.setActiveProviderId(propertyTable.activeProvider)
        log("User changed activeProvider -> '" .. tostring(propertyTable.activeProvider) .. "'")
    end)

    propertyTable.refinementPasses = Settings.get("refinementPasses")
    propertyTable:addObserver("refinementPasses", function()
        Settings.set("refinementPasses", propertyTable.refinementPasses)
        log("User changed refinementPasses -> '" .. tostring(propertyTable.refinementPasses) .. "'")
    end)

    -- Every declared field of every driver, mirrored in and written straight
    -- back so a change is saved immediately. A secret is never logged, not even
    -- as a length.
    for _, driver in ipairs(Registry.all()) do
        for _, field in ipairs(driver.settingsFields) do
            local key = propertyKey(driver.id, field.key)
            propertyTable[key] = Settings.getProviderField(driver.id, field)
            propertyTable:addObserver(key, function()
                Settings.setProviderField(driver.id, field, propertyTable[key])
                if field.role == "secret" then
                    log(string.format("User changed %s (value hidden).", key))
                else
                    log(string.format("User changed %s -> '%s'", key, tostring(propertyTable[key])))
                end
            end)
        end
    end

    local section = {
        title = LOC "$$$/VenzAI/Settings/SectionTitle=VenzAI Settings",

        f:row {
            bind_to_object = propertyTable,
            spacing = f:control_spacing(),
            f:static_text {
                title = LOC "$$$/VenzAI/Settings/Provider/Label=AI provider:",
                width = share "venzai_label_width",
            },
            f:popup_menu {
                value = bind "activeProvider",
                width_in_chars = 26,
                items = providerItems(),
            },
        },
    }

    for _, driver in ipairs(Registry.all()) do
        table.insert(section, groupForDriver(f, propertyTable, driver))
    end

    table.insert(section, f:row {
        bind_to_object = propertyTable,
        spacing = f:control_spacing(),
        f:static_text {
            title = LOC "$$$/VenzAI/Settings/PassesLabel=Refinement passes (1-5):",
            width = share "venzai_label_width",
        },
        f:edit_field {
            value = bind "refinementPasses",
            width_in_chars = 4,
            precision = 0,
            min = Settings.MIN_PASSES,
            max = Settings.MAX_PASSES,
        },
    })

    table.insert(section, f:row {
        spacing = f:control_spacing(),
        f:static_text {
            title = LOC "$$$/VenzAI/Settings/Log/Label=Diagnostics:",
            width = share "venzai_label_width",
        },
        f:push_button {
            title = LOC "$$$/VenzAI/Settings/Log/ShowButton=Show log file",
            action = showLogAction,
        },
    })

    return { section }
end

return {
    sectionsForTopOfDialog = sectionsForTopOfDialog,
}
