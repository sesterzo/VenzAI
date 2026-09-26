--[[----------------------------------------------------------------------------

PluginInfoProvider.lua
The VenzAI section shown in File > Plug-in Manager.

Defaults and the reading/writing of every setting live in VenzAISettings.lua,
shared with VenzAIProcess.lua. Logging goes through VenzAILog.lua, which
writes to Lightroom's own per-platform log folder instead of into the plug-in
bundle (which is not writable once the plug-in is installed for real).

------------------------------------------------------------------------------]]

local LrView = import 'LrView'
local LrHttp = import 'LrHttp'
local LrTasks = import 'LrTasks'
local LrDialogs = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrBinding = import 'LrBinding'
local LrShell = import 'LrShell'
local LrFileUtils = import 'LrFileUtils'

local VenzAILog = require 'VenzAILog'
local Settings = require 'VenzAISettings'

local log = VenzAILog.scoped("Settings")

-- Seconds to wait on the Ollama /api/tags call. Short on purpose: this is a
-- "is the server there?" probe and the user is staring at a dialog.
local DETECT_TIMEOUT = 10

log("=== PluginInfoProvider module loaded ===")
Settings.applyDefaults()
Settings.migrateApiKeyFromPrefs()

local function isGeminiTransform(value)
    return value == "gemini"
end

local function isLocalTransform(value)
    return value == "local"
end

-- Queries Ollama's native /api/tags endpoint to list the models already
-- pulled on the server at baseUrl. Returns an array of names (e.g.
-- "qwen2.5vl:latest") or nil + an error message.
local function detectOllamaModels(baseUrl)
    local url = baseUrl .. "/api/tags"
    log("detectOllamaModels: GET " .. url)

    local body, headers = LrHttp.get(url, nil, DETECT_TIMEOUT)
    local status = headers and headers.status

    -- On a connection failure LrHttp returns no body and no status. The SDK
    -- docs only describe the success shape, but in practice the second return
    -- value carries an `error` table with the transport failure reason.
    -- Reading it is guarded and purely additive: if a future version stops
    -- providing it we fall through to the generic "HTTP nil" message below.
    if headers and headers.error then
        local reason = headers.error.name or headers.error.errorCode or "connection failed"
        log("detectOllamaModels: transport error: " .. tostring(reason))
        return nil, string.format("%s (%s)", tostring(reason), url)
    end

    log(string.format("detectOllamaModels: status=%s", tostring(status)))

    if not body or status ~= 200 then
        return nil, string.format("HTTP %s contacting %s", tostring(status), url)
    end

    local models = {}
    for name in body:gmatch('"name"%s*:%s*"([^"]+)"') do
        table.insert(models, name)
    end

    log(string.format("detectOllamaModels: found %d model(s): %s", #models, table.concat(models, ", ")))

    if #models == 0 then
        return nil, "No models found (server reachable but no models are pulled yet)."
    end

    return models
end

-- Action for the "Detect models" button: queries Ollama and updates
-- propertyTable.ollamaModel with the result (with a small picker if more
-- than one is found). Must run in an async task because LrHttp.get yields,
-- which isn't allowed directly inside a button callback.
local function detectModelsAction(propertyTable)
    log("Button 'Detect models' clicked.")
    LrTasks.startAsyncTask(function()
        LrFunctionContext.callWithContext("VenzAI_DetectOllamaModels", function(context)
            local baseUrl = propertyTable.ollamaBaseUrl
            if baseUrl == nil or baseUrl == "" then
                baseUrl = Settings.DEFAULTS.ollamaBaseUrl
                log("ollamaBaseUrl was empty, using default " .. baseUrl .. " for detection.")
            end

            local models, err = detectOllamaModels(baseUrl)

            if not models then
                log("Detect models failed: " .. tostring(err))
                LrDialogs.message(
                    LOC "$$$/VenzAI/Settings/Local/DetectErrorTitle=Could not detect Ollama models",
                    LOC("$$$/VenzAI/Settings/Local/DetectErrorBody=^1\n\nCheck that Ollama is running and reachable at ^2.", tostring(err), baseUrl),
                    "warning"
                )
                return
            end

            if #models == 1 then
                log("Only one model detected, auto-selecting: " .. models[1])
                propertyTable.ollamaModel = models[1]
                return
            end
            log(string.format("%d models detected, showing picker.", #models))

            -- Multiple models found: show a small picker instead of choosing one at random.
            local pickerProps = LrBinding.makePropertyTable(context)
            pickerProps.selectedModel = models[1]

            local f = LrView.osFactory()
            local items = {}
            for _, name in ipairs(models) do
                table.insert(items, { title = name, value = name })
            end

            local result = LrDialogs.presentModalDialog {
                title = LOC "$$$/VenzAI/Settings/Local/DetectPickerTitle=Select an Ollama model",
                contents = f:popup_menu {
                    bind_to_object = pickerProps,
                    value = LrView.bind "selectedModel",
                    items = items,
                    width_in_chars = 30,
                },
            }

            log("Picker dialog result: " .. tostring(result))
            if result == "ok" then
                log("User picked model: " .. tostring(pickerProps.selectedModel))
                propertyTable.ollamaModel = pickerProps.selectedModel
            end
        end)
    end)
end

-- Opens the folder LrLogger writes into, in Explorer or the Finder. The log
-- no longer sits next to the plug-in, so without this the user has no
-- realistic way to find it.
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
    Settings.migrateApiKeyFromPrefs()

    -- Mirror the persisted settings into the dialog's observable property
    -- table, and write any change straight back so it is saved immediately.
    local prefKeys = {
        "engine", "geminiAnalysisModel", "geminiImageModel",
        "ollamaBaseUrl", "ollamaModel", "refinementPasses",
    }
    for _, key in ipairs(prefKeys) do
        propertyTable[key] = Settings.get(key)
        log(string.format("Loaded into panel: %s = '%s' (type=%s)", key, tostring(propertyTable[key]), type(propertyTable[key])))
    end

    -- The API key is not a pref: it comes from and goes back to LrPasswords.
    propertyTable.geminiApiKey = Settings.getApiKey()
    log("Loaded into panel: geminiApiKey = " ..
        ((propertyTable.geminiApiKey ~= "") and "(set, hidden)" or "(empty)"))

    for _, key in ipairs(prefKeys) do
        propertyTable:addObserver(key, function()
            local newValue = propertyTable[key]
            Settings.set(key, newValue)
            log(string.format("User changed %s -> '%s'", key, tostring(newValue)))
        end)
    end

    propertyTable:addObserver("geminiApiKey", function()
        Settings.setApiKey(propertyTable.geminiApiKey)
        log("User changed geminiApiKey (value hidden in log, stored via LrPasswords).")
    end)

    return {
        {
            title = LOC "$$$/VenzAI/Settings/SectionTitle=VenzAI Settings",

            f:row {
                bind_to_object = propertyTable,
                spacing = f:control_spacing(),
                f:static_text {
                    title = LOC "$$$/VenzAI/Settings/Engine/Label=AI engine:",
                    width = share "venzai_label_width",
                },
                f:popup_menu {
                    value = bind "engine",
                    width_in_chars = 20,
                    items = {
                        { title = LOC "$$$/VenzAI/Settings/Engine/Gemini=Gemini (Cloud)", value = "gemini" },
                        { title = LOC "$$$/VenzAI/Settings/Engine/Local=Local (Ollama)", value = "local" },
                    },
                },
            },

            -- "bind_to_object = propertyTable" is explicit here: without it,
            -- controls nested inside group_box/row did not resolve the
            -- binding (the fields stayed empty even when the value in
            -- propertyTable was correct). "enabled" stays on individual
            -- controls, not on the group_box.
            f:group_box {
                bind_to_object = propertyTable,
                title = LOC "$$$/VenzAI/Settings/Gemini/GroupTitle=Gemini settings",
                fill_horizontal = 1,

                f:row {
                    spacing = f:control_spacing(),
                    f:static_text {
                        title = LOC "$$$/VenzAI/Settings/Gemini/ApiKeyLabel=API key:",
                        width = share "venzai_label_width",
                        enabled = bind { key = "engine", transform = isGeminiTransform },
                    },
                    f:password_field {
                        value = bind "geminiApiKey",
                        width_in_chars = 30,
                        enabled = bind { key = "engine", transform = isGeminiTransform },
                    },
                },
                f:row {
                    f:static_text {
                        title = LOC "$$$/VenzAI/Settings/Gemini/ApiKeyNote=The key is stored encrypted in the system keychain, not in the preferences file.",
                        enabled = bind { key = "engine", transform = isGeminiTransform },
                    },
                },
                f:row {
                    spacing = f:control_spacing(),
                    f:static_text {
                        title = LOC "$$$/VenzAI/Settings/Gemini/AnalysisModelLabel=Analysis model:",
                        width = share "venzai_label_width",
                        enabled = bind { key = "engine", transform = isGeminiTransform },
                    },
                    f:edit_field {
                        value = bind "geminiAnalysisModel",
                        width_in_chars = 30,
                        enabled = bind { key = "engine", transform = isGeminiTransform },
                    },
                },
                f:row {
                    spacing = f:control_spacing(),
                    f:static_text {
                        title = LOC "$$$/VenzAI/Settings/Gemini/ImageModelLabel=Reference image model (Nano Banana):",
                        width = share "venzai_label_width",
                        enabled = bind { key = "engine", transform = isGeminiTransform },
                    },
                    f:edit_field {
                        value = bind "geminiImageModel",
                        width_in_chars = 30,
                        enabled = bind { key = "engine", transform = isGeminiTransform },
                    },
                },
                f:row {
                    f:static_text {
                        title = LOC "$$$/VenzAI/Settings/Gemini/MethodNote=Method used: Nano Banana reference image + multi-pass Gemini refinement.",
                        enabled = bind { key = "engine", transform = isGeminiTransform },
                    },
                },
            },

            -- Local (Ollama) section (see the note above about bind_to_object and "enabled")
            f:group_box {
                bind_to_object = propertyTable,
                title = LOC "$$$/VenzAI/Settings/Local/GroupTitle=Local (Ollama) settings",
                fill_horizontal = 1,

                f:row {
                    spacing = f:control_spacing(),
                    f:static_text {
                        title = LOC "$$$/VenzAI/Settings/Local/BaseUrlLabel=Ollama server URL:",
                        width = share "venzai_label_width",
                        enabled = bind { key = "engine", transform = isLocalTransform },
                    },
                    f:edit_field {
                        value = bind "ollamaBaseUrl",
                        width_in_chars = 30,
                        enabled = bind { key = "engine", transform = isLocalTransform },
                    },
                },
                f:row {
                    spacing = f:control_spacing(),
                    f:static_text {
                        title = LOC "$$$/VenzAI/Settings/Local/ModelLabel=Ollama model:",
                        width = share "venzai_label_width",
                        enabled = bind { key = "engine", transform = isLocalTransform },
                    },
                    f:edit_field {
                        value = bind "ollamaModel",
                        width_in_chars = 30,
                        enabled = bind { key = "engine", transform = isLocalTransform },
                    },
                    f:push_button {
                        title = LOC "$$$/VenzAI/Settings/Local/DetectButton=Detect models",
                        enabled = bind { key = "engine", transform = isLocalTransform },
                        action = function()
                            detectModelsAction(propertyTable)
                        end,
                    },
                },
                f:row {
                    f:static_text {
                        title = LOC "$$$/VenzAI/Settings/Local/MethodNote=Method used: N local refinement passes (no reference image, fully offline).",
                        enabled = bind { key = "engine", transform = isLocalTransform },
                    },
                },
            },

            f:row {
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
            },

            f:row {
                spacing = f:control_spacing(),
                f:static_text {
                    title = LOC "$$$/VenzAI/Settings/Log/Label=Diagnostics:",
                    width = share "venzai_label_width",
                },
                f:push_button {
                    title = LOC "$$$/VenzAI/Settings/Log/ShowButton=Show log file",
                    action = showLogAction,
                },
            },
        },
    }
end

return {
    sectionsForTopOfDialog = sectionsForTopOfDialog,
}
