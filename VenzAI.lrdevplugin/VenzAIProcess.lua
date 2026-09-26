--[[----------------------------------------------------------------------------

VenzAIProcess.lua
Analyzes the selected photo with the active AI provider and applies the
resulting develop settings, over a configurable number of refinement passes.

This file is the ENGINE. It owns the photography: the pass loop, the cumulative
crop, the snapshots, the progress bar and cancellation. It owns no protocol and
names no provider. Every call to a provider goes through Contract.call, which
returns a well-formed Response whatever the driver does, so a failing provider
cannot abort a run halfway and leave the photo in an intermediate state.

Where the rest of it went: the prompts to VenzAIPrompts, the parameter
vocabulary and the parsing to VenzAIParse, the mask application to VenzAIMasks,
the JSON escaping to VenzAIJson, and the two HTTP functions to the drivers.

Configuration lives in VenzAISettings and is edited from
File > Plug-in Manager > VenzAI. Logging goes through VenzAILog.

------------------------------------------------------------------------------]]

local LrApplication = import 'LrApplication'
local LrTasks = import 'LrTasks'
local LrExportSession = import 'LrExportSession'
local LrPathUtils = import 'LrPathUtils'
local LrFileUtils = import 'LrFileUtils'
local LrStringUtils = import 'LrStringUtils'
local LrProgressScope = import 'LrProgressScope'
local LrFunctionContext = import 'LrFunctionContext'
local LrDialogs = import 'LrDialogs'

local VenzAILog = require 'VenzAILog'
local Settings = require 'VenzAISettings'
local Registry = require 'VenzAIProviderRegistry'
local Contract = require 'VenzAIProviderContract'
local Messages = require 'VenzAIMessages'
local Prompts = require 'VenzAIPrompts'
local Parse = require 'VenzAIParse'
local Delta = require 'VenzAIDelta'
local Masks = require 'VenzAIMasks'

local log = VenzAILog.log

-- Working files go to the OS temp folder, never inside the plug-in bundle.
-- On macOS a .lrplugin is a package and on Windows it may sit under
-- Program Files; in both cases the bundle is effectively read-only once
-- installed, and writing there fails silently. LrPathUtils resolves the
-- right per-platform location with no conditional code.
local WORK_DIR = LrPathUtils.child(LrPathUtils.getStandardFilePath('temp'), "VenzAI")
-- Named after what it is, not after the model that made it: any provider
-- declaring generateReference writes here.
local REFERENCE_IMAGE_BASE_PATH = LrPathUtils.child(WORK_DIR, "venzai_reference")

local function ensureWorkDir()
    if not LrFileUtils.exists(WORK_DIR) then
        local ok, err = pcall(function() LrFileUtils.createAllDirectories(WORK_DIR) end)
        if not ok then
            log("Could not create the working directory " .. WORK_DIR .. ": " .. tostring(err))
            return false
        end
    end
    return true
end

-- Reports a fatal condition to the user instead of only to the log. Every
-- early return in the run below used to be silent: from the user's side
-- "nothing happened" was indistinguishable between a missing API key, an
-- unreachable server and a crash.
local function failToUser(title, detail)
    log(string.format("ABORT: %s - %s", tostring(title), tostring(detail)))
    LrDialogs.message(title, detail, "critical")
end

-- Writes the reference beside the working files so it can be inspected after a
-- run. Best effort only: the image is held in memory for the rest of the run,
-- so a failed write costs nothing but a file to look at afterwards.
local function saveReferenceToWorkDir(image)
    if not ensureWorkDir() then return end
    local extension = image.mimeType and image.mimeType:match("image/(%w+)") or "png"
    local path = REFERENCE_IMAGE_BASE_PATH .. "." .. extension
    local file = io.open(path, "wb")
    if not file then
        log("Could not write the reference image to " .. path ..
            " (continuing, it is kept in memory for this run).")
        return
    end
    file:write(LrStringUtils.decodeBase64(image.data))
    file:close()
    log("Reference saved to: " .. path)
end

-- Exports the CURRENT state of the photo (already including the development
-- from previous passes, if any) to a temporary JPEG for analysis.
-- The export goes into VenzAI's own subfolder of the OS temp directory rather
-- than the temp root, so a leftover file after a crash is identifiable and
-- cannot collide with another plug-in's export of the same filename.
local function exportCurrentPhoto(photo)
    if not ensureWorkDir() then
        return nil, "could not create the working directory " .. WORK_DIR
    end

    local exportSettings = {
        LR_format = "JPEG",
        LR_export_colorSpace = "sRGB",
        LR_jpeg_quality = 0.85,
        LR_size_doConstrain = true,
        -- Not the largest the photo allows: vision models resize an image to
        -- their own tiles before looking at it, so past a point the extra
        -- pixels only cost export time, upload time and tokens without telling
        -- the model anything more. 2048 keeps enough detail for the judgements
        -- we ask for - tonal separation, colour cast, noise, halos - while
        -- roughly quartering the bytes of a 4096px export.
        LR_size_maxDimension = 2048,
        LR_export_destinationType = "specificFolder",
        LR_export_destinationPathPrefix = WORK_DIR,
        LR_export_useSubfolder = false,
        LR_collisionHandling = "overwrite",
    }

    local exportSession = LrExportSession({ photosToExport = { photo }, exportSettings = exportSettings })
    local tempPath = nil

    for _, rendition in exportSession:renditions() do
        local success, pathOrMessage = rendition:waitForRender()
        if success then
            tempPath = pathOrMessage
        else
            return nil, pathOrMessage
        end
    end

    return tempPath
end

local function encodeFileBase64(path)
    local file = io.open(path, "rb")
    if not file then
        return nil
    end
    local fileData = file:read("*all")
    file:close()
    return LrStringUtils.encodeBase64(fileData)
end

LrTasks.startAsyncTask(function()
    LrFunctionContext.callWithContext("VenzAIProcess", function(context)
    -- The progress scope is declared before the failure handler so the handler
    -- can close it: an unhandled error used to leave the progress bar spinning
    -- in the top-left corner until Lightroom was restarted.
    local progressScope

    context:addFailureHandler(function(ctx, message)
        log("UNHANDLED ERROR: " .. tostring(message))
        if progressScope then
            pcall(function() progressScope:done() end)
        end
        LrDialogs.message(
            LOC "$$$/VenzAI/Error/UnexpectedTitle=VenzAI stopped unexpectedly",
            LOC("$$$/VenzAI/Error/UnexpectedBody=^1\n\nThe photo keeps whatever was applied up to this point; the 'VenzAI - Original' snapshot restores the state from before the run.", tostring(message)),
            "critical"
        )
    end)

    -- The provider and its configuration are resolved HERE, not at the top of
    -- the file, and once per run rather than per call. Here, because a
    -- configuration that a driver rejects has to reach the user as a localized
    -- message from the catalog like every other failure, and the failure handler
    -- and progress scope that do that exist only inside this context. Once,
    -- because a run spans minutes and several passes and must use one consistent
    -- configuration; editing the panel mid-run takes effect on the next run.
    local driver = Registry.active()
    if not driver then
        failToUser(Messages.forError("driver_fault", nil, nil))
        return
    end
    local config = Settings.providerConfig(driver.id, driver.settingsFields)
    local passes = Settings.getRefinementPasses()

    log(string.format("=== VenzAI start (provider=%s, model=%s, passes=%d) ===",
        driver.id, tostring(config.model), passes))

    local catalog = LrApplication.activeCatalog()
    local photo = catalog:getTargetPhoto()

    if not photo then
        failToUser(
            LOC "$$$/VenzAI/Error/NoPhotoTitle=No photo selected",
            LOC "$$$/VenzAI/Error/NoPhotoBody=Select a photo in the Library or Develop module, then run VenzAI again."
        )
        return
    end
    log("Selected photo: " .. tostring(photo:getRawMetadata("path")))

    -- Bound to the function context so the scope is torn down with it, rather
    -- than relying on every exit path remembering to call done().
    progressScope = LrProgressScope({
        title = LOC("$$$/VenzAI/Progress/Title=VenzAI processing with ^1...", LOC(driver.displayName)),
        caption = LOC "$$$/VenzAI/Progress/Preparing=Preparing image...",
        functionContext = context,
    })

    -- Snapshot of the ORIGINAL state before any change, so it's always
    -- possible to go back from Lightroom's History > Snapshots panel,
    -- regardless of how many passes are run.
    local originalSnapshotName = LOC("$$$/VenzAI/Snapshot/Original=VenzAI - Original (^1, ^2)",
        driver.id, os.date("%Y-%m-%d %H:%M:%S"))
    catalog:withWriteAccessDo("VenzAI snapshot (original)", function()
        photo:createDevelopSnapshot(originalSnapshotName, true)
    end)
    log("Created snapshot '" .. originalSnapshotName .. "' before any changes.")

    -- Refinement loop: on every pass the current state of the photo (already
    -- including previous passes' edits) is exported and analyzed again, to
    -- progressively refine the result. When the provider can generate one, the
    -- reference image is produced ONCE on the first pass and reused in all
    -- subsequent passes.
    local priorCrop = { cl = 0, ct = 0, cr = 1, cb = 1 }
    local priorAngle = 0

    -- The absolute state the photograph is in, which the model's movements are
    -- added to. Seeded from what the photo actually reports, so a file that
    -- arrives already edited is a starting point rather than a surprise.
    -- Which scale this file puts Temperature on. Read from the FILE, never
    -- inferred from the value: a raw whose white balance is still "As Shot"
    -- reports no Kelvin, and reading that absence as the -100..100 scale wrote
    -- an 18 K white balance onto a NEF and turned the photograph solid blue.
    local okFormat, fileFormat = LrTasks.pcall(function()
        return photo:getRawMetadata("fileFormat")
    end)
    local temperatureScale = Delta.temperatureScale(okFormat and fileFormat or nil)
    log(string.format("File format %s: Temperature is on the %s scale.",
        tostring(okFormat and fileFormat or "unknown"), temperatureScale))

    local absoluteState = {}
    local okSeed, seeded = LrTasks.pcall(function() return photo:getDevelopSettings() end)
    if okSeed and type(seeded) == "table" then
        for key in pairs(Parse.VALID_KEYS) do
            if type(seeded[key]) == "number" then
                absoluteState[key] = seeded[key]
            end
        end
        log("Absolute state seeded from the photograph.")
    else
        log("Could not read the photograph's settings to seed the state; " ..
            "movements will start from each parameter's neutral value.")
    end
    local completedPasses = 0
    local referenceImage = nil
    -- Tracks, per region "type" (sky, subject, ...), the ID of the mask
    -- created for it in an earlier pass, so later passes UPDATE that same
    -- mask instead of stacking a new one on top - see VenzAIMasks.
    local maskIDsByType = {}

    -- What each mask is currently carrying, accumulated across passes exactly
    -- the way Lightroom accumulates it: a value a later pass does not mention
    -- stays. Reported back to the model each pass, so it refines its own local
    -- work instead of re-inventing it on a mask that is still there.
    local appliedMasksByType = {}

    -- Every failure inside the loop resolves the same way, so the decision
    -- lives in one place: if no pass has been applied yet there is nothing to
    -- salvage, so close the progress bar, tell the user why and let the caller
    -- return (true). If at least one pass succeeded the photo is already
    -- improved and snapshotted, so keep that and end the loop quietly (false)
    -- rather than interrupting the user with a dialog about a bonus pass.
    local function passFailure(pass, title, detail)
        log(string.format("Pass %d failed.", pass))
        if completedPasses == 0 then
            pcall(function() progressScope:done() end)
            failToUser(title, detail)
            return true
        end
        log("Stopping the refinement loop at the passes already completed: " .. tostring(detail))
        return false
    end

    for pass = 1, passes do
        if progressScope:isCanceled() then
            log("Cancelled before pass " .. pass .. ".")
            break
        end

        progressScope:setPortionComplete((pass - 1) / passes)
        progressScope:setCaption(LOC("$$$/VenzAI/Progress/PassExporting=Pass ^1/^2: exporting...", tostring(pass), tostring(passes)))

        local tempPath, exportErr = exportCurrentPhoto(photo)
        if not tempPath then
            if passFailure(pass,
                LOC "$$$/VenzAI/Error/ExportTitle=Could not export the photo",
                LOC("$$$/VenzAI/Error/ExportBody=Lightroom could not render a temporary copy for analysis:\n\n^1", tostring(exportErr)))
            then
                return
            end
            break
        end
        log(string.format("Pass %d: export completed: %s", pass, tostring(tempPath)))

        local currentBase64 = encodeFileBase64(tempPath)
        LrFileUtils.delete(tempPath)

        if not currentBase64 then
            log(string.format("Error reading the exported file on pass %d.", pass))
            break
        end
        log(string.format("Pass %d: image encoded, base64 length: %d", pass, #currentBase64))

        if progressScope:isCanceled() then
            log("Cancelled after exporting pass " .. pass .. ".")
            break
        end

        -- Reported on EVERY pass, pass 1 included. Under delta semantics this
        -- block is no longer only "what you already did": it is where the model
        -- learns which scale each slider is on - above all whether this file
        -- reports Temperature in Kelvin or on the -100..100 scale, which decides
        -- the units of the movement it is about to ask for. Pass 1 makes the
        -- largest corrections, and it was the one pass told nothing.
        local currentSettingsBlock, isGrayscale = Prompts.readCurrentSettings(photo)
        if currentSettingsBlock then
            log(string.format("Pass %d: current settings reported to the model:\n%s", pass, currentSettingsBlock))
        else
            log(string.format("Pass %d: no current settings to report.", pass))
        end

        -- The reference image is a declared CAPABILITY, not a provider. A driver
        -- that offers it gets asked once, on the first pass; one that does not is
        -- simply never asked, and the run proceeds on the plain photo. This is
        -- the last place the engine used to test for one particular provider.
        if driver.capabilities.generateReference and pass == 1 then
            progressScope:setCaption(LOC "$$$/VenzAI/Progress/GeneratingReference=Generating a professional reference...")

            local response = Contract.call(driver, "generateReference", {
                parts = {
                    { text = Prompts.buildReferencePrompt() },
                    { image = { mimeType = "image/jpeg", data = currentBase64 } },
                },
                timeout = driver.defaultTimeout,
            }, config)

            if response.ok then
                referenceImage = response.image
                log(string.format("Reference image obtained: mime=%s, base64 length=%d",
                    tostring(referenceImage.mimeType), #referenceImage.data))
                saveReferenceToWorkDir(referenceImage)
            else
                -- A missing reference is not a reason to stop: analysis on the
                -- plain photo is the path a provider without the capability
                -- takes anyway.
                log(string.format("No reference image (%s: %s): continuing with the refinement loop on the plain photo only.",
                    tostring(response.errorKind), tostring(response.errorDetail)))
            end
        end

        if progressScope:isCanceled() then
            log("Cancelled after the reference step on pass " .. pass .. ".")
            break
        end

        -- ONE analysis call, for every provider. No branch on who is answering.
        progressScope:setCaption(LOC("$$$/VenzAI/Progress/PassAnalyzing=Pass ^1/^2: analyzing with ^3...",
            tostring(pass), tostring(passes), LOC(driver.displayName)))

        local parts = {
            { text = "IMAGE 1:" },
            { image = { mimeType = "image/jpeg", data = currentBase64 } },
        }
        if referenceImage then
            table.insert(parts, { text = "IMAGE 2 (AI-generated reference):" })
            table.insert(parts, { image = referenceImage })
        end
        table.insert(parts, { text = Prompts.buildAnalysisPrompt(
            pass, passes, referenceImage ~= nil, currentSettingsBlock, appliedMasksByType) })

        log(string.format("Pass %d: sending the analysis request to %s (%s)...",
            pass, driver.id, tostring(config.model)))
        local response = Contract.call(driver, "analyze", {
            parts = parts,
            wantsJson = true,
            timeout = driver.defaultTimeout,
        }, config)

        if progressScope:isCanceled() then
            log("Cancelled after the analysis request on pass " .. pass .. ".")
            break
        end

        -- One failure branch for every way a provider can fail: the driver has
        -- already classified no-response, a bad status, an empty answer and its
        -- own faults into one errorKind, and the catalog turns that into a
        -- localized message naming the provider and the model.
        if not response.ok then
            log(string.format("Pass %d: %s (%s)", pass,
                tostring(response.errorKind), tostring(response.errorDetail)))
            local title, body = Messages.forError(response.errorKind,
                driver.displayName, config.model, response.reasonKey)
            if passFailure(pass, title, body .. Messages.technicalSection(response.errorDetail)) then
                return
            end
            break
        end

        -- The answer itself, not just its length. The pre-driver engine logged
        -- the whole raw HTTP body every pass, and that was the working tool for
        -- prompt iteration: on an answer that succeeds but is WRONG there is
        -- otherwise no record of what the model actually said, and errorDetail
        -- only exists on failure. Truncated because a body can be long, and kept
        -- because losing it costs more than the log lines.
        log(string.format("Pass %d: answer received (%d characters): %s",
            pass, #response.text, response.text:sub(1, 4000)))

        -- A truncated answer looks exactly like the model choosing not to
        -- include something, so say so loudly rather than letting it be misread
        -- as a deliberate omission.
        if response.truncated then
            log(string.format("Pass %d: WARNING - the answer was TRUNCATED. Whatever follows the cutoff point, including any Masks, was never generated rather than deliberately omitted.", pass))
        end

        local developSettings, parseErr = Parse.parseModelSettings(response.text, isGrayscale)
        if not developSettings then
            local detail = LOC("$$$/VenzAI/Error/ParseBody=The model's answer contained no usable develop setting.\n\n^1", tostring(parseErr))
            if passFailure(pass, LOC "$$$/VenzAI/Error/ParseTitle=Unreadable answer from the model", detail) then
                return
            end
            break
        end

        -- Composes the relative crop (referring to the frame seen in THIS
        -- pass) with the absolute crop already applied in previous passes.
        if developSettings.CropLeft or developSettings.CropTop or developSettings.CropRight or developSettings.CropBottom then
            local rl = developSettings.CropLeft or 0
            local rt = developSettings.CropTop or 0
            local rr = developSettings.CropRight or 1
            local rb = developSettings.CropBottom or 1

            local priorW = priorCrop.cr - priorCrop.cl
            local priorH = priorCrop.cb - priorCrop.ct

            local absCl = priorCrop.cl + rl * priorW
            local absCt = priorCrop.ct + rt * priorH
            local absCr = priorCrop.cl + rr * priorW
            local absCb = priorCrop.ct + rb * priorH

            developSettings.CropLeft, developSettings.CropTop = absCl, absCt
            developSettings.CropRight, developSettings.CropBottom = absCr, absCb

            priorCrop = { cl = absCl, ct = absCt, cr = absCr, cb = absCb }
            log(string.format("Pass %d: composed crop -> Left=%.4f Top=%.4f Right=%.4f Bottom=%.4f", pass, absCl, absCt, absCr, absCb))
        end

        -- Composes the residual angle proposed in this pass with the one
        -- already applied in previous passes (cumulative absolute angle).
        if developSettings.CropAngle then
            local absAngle = priorAngle + developSettings.CropAngle
            if absAngle < -45 then absAngle = -45 end
            if absAngle > 45 then absAngle = 45 end
            developSettings.CropAngle = absAngle
            priorAngle = absAngle
            log(string.format("Pass %d: composed CropAngle -> %.3f", pass, absAngle))
        end

        if priorAngle ~= 0 then
            developSettings.CropConstrainToWarp = true
        end

        local masks = Parse.parseMasks(response.text)
        -- One report per mask, so convergence can ask whether a mask actually
        -- requested anything instead of whether one was merely named.
        local maskReports = {}

        -- The model answered with MOVEMENTS. Lightroom only accepts absolutes,
        -- so the sum happens here and the log says what each one did.
        local absolute, report = Delta.apply(absoluteState, developSettings, temperatureScale)
        absoluteState = absolute

        for _, row in ipairs(report) do
            if row.outcome == "clamped" then
                log(string.format("Pass %d: %s asked %+.4g from %.4g, clamped to %.4g.",
                    pass, row.key, row.asked, row.from, row.to))
            elseif row.outcome == "implausible" then
                log(string.format("Pass %d: %s asked %+.4g, larger than its whole range: dropped.",
                    pass, row.key, row.asked))
            end
        end

        -- A raw left at "As Shot" exposes no Kelvin, so a Temperature
        -- movement had nothing to move from and was refused. Switching the
        -- white balance to Custom makes Lightroom fill in the as-shot value,
        -- so the next pass can move it. Done once, only when it is needed.
        if Delta.needsWhiteBalanceUnlock(report) then
            absolute.WhiteBalance = "Custom"
            log(string.format("Pass %d: white balance set to Custom so that the next " ..
                "pass has a Kelvin value to move from.", pass))
        end

        catalog:withWriteAccessDo("VenzAI develop (pass " .. pass .. ")", function()
            photo:applyDevelopSettings(absolute)
        end)
        log(string.format("Pass %d: global parameters applied.", pass))

        -- "Applied" above means the call returned, not that Lightroom kept the
        -- values. Reading them straight back is the only way to tell a setting
        -- the model never proposed from one Lightroom silently overrode, and
        -- the difference is invisible in the photograph unless you know which
        -- slider to go and look at.
        local readOk, applied = LrTasks.pcall(function() return photo:getDevelopSettings() end)
        if not readOk then
            log(string.format("Pass %d: could not read the settings back to check them: %s",
                pass, tostring(applied)))
        else
            -- Every pass of a real run reported ColorGradeShadowHue/Sat and
            -- ColorGradeHighlightHue/Sat as "photo now reports nil": the key is
            -- not merely refused, it is absent from the settings table. That
            -- says Lightroom stores colour grading under names we are not
            -- using, so on the first pass print the ones it DOES report and let
            -- the log name them, instead of guessing at the spelling.
            if pass == 1 then
                local seen = {}
                for key in pairs(applied) do
                    if key:find("ColorGrade") or key:find("SplitToning") then
                        table.insert(seen, key .. " = " .. tostring(applied[key]))
                    end
                end
                table.sort(seen)
                if #seen == 0 then
                    log("Colour grading: the photo reports no ColorGrade* or SplitToning* key at all.")
                else
                    log("Colour grading: the keys this photo actually reports are:")
                    for _, line in ipairs(seen) do log("    " .. line) end
                end
            end

            -- `absolute`, not `developSettings`: the model answered movements,
            -- and what we asked Lightroom for is the sum. Comparing a movement
            -- against what the photo reports would call every applied value a
            -- failure.
            local missed = Parse.settingsNotKept(absolute, applied)
            if #missed == 0 then
                log(string.format("Pass %d: every requested setting was kept.", pass))
            else
                log(string.format("Pass %d: %d requested setting(s) did NOT take:", pass, #missed))
                for _, miss in ipairs(missed) do
                    log(string.format("    %s: asked %s, photo now reports %s",
                        miss.key, tostring(miss.asked), tostring(miss.got)))
                end
            end
        end

        -- Local (masked) corrections use a completely different write path
        -- (LrDevelopController, which requires the Develop module to be
        -- active) than the global settings above, so they must happen
        -- OUTSIDE the catalog:withWriteAccessDo gate, after it completes.
        if #masks > 0 then
            progressScope:setCaption(LOC("$$$/VenzAI/Progress/PassMasking=Pass ^1/^2: applying local mask corrections...", tostring(pass), tostring(passes)))

            -- The model's local values are movements too. Sum them onto what
            -- the mask already carries BEFORE writing: setValue writes a
            -- position, not an offset, and a key this pass did not mention is
            -- still on the mask, so absence is not zero.
            local pendingByType = {}
            for _, mask in ipairs(masks) do
                local carried = appliedMasksByType[mask.type] or {}
                local absoluteParams, maskReport = Delta.apply(carried, mask.params, "relative")
                for _, row in ipairs(maskReport) do
                    if row.outcome == "clamped" or row.outcome == "implausible" then
                        log(string.format("Pass %d: mask '%s' %s asked %+.4g -> %s.",
                            pass, mask.type, row.key, row.asked, row.outcome))
                    end
                end
                mask.params = absoluteParams
                pendingByType[mask.type] = absoluteParams
                table.insert(maskReports, maskReport)
            end

            local appliedMasks, writtenTypes = Masks.applyMasksToPhoto(photo, masks, maskIDsByType)
            log(string.format("Pass %d: %d/%d local mask(s) applied.", pass, appliedMasks, #masks))

            -- Recorded only for the masks Lightroom really wrote. A mask whose
            -- region the detector never found, or whose selection landed
            -- elsewhere, carries nothing - and telling the next pass otherwise
            -- would have it believe a region was handled while it stayed wrong.
            for maskType, params in pairs(pendingByType) do
                if writtenTypes and writtenTypes[maskType] then
                    appliedMasksByType[maskType] = params
                else
                    log(string.format("Pass %d: mask '%s' was not written, so its values " ..
                        "are not recorded as applied.", pass, maskType))
                end
            end
        end



        local snapshotName = LOC("$$$/VenzAI/Snapshot/Pass=VenzAI - Pass ^1 (^2, ^3)",
            tostring(pass), driver.id, os.date("%Y-%m-%d %H:%M:%S"))
        catalog:withWriteAccessDo("VenzAI snapshot (pass " .. pass .. ")", function()
            photo:createDevelopSnapshot(snapshotName, true)
        end)
        completedPasses = pass
        log(string.format("Pass %d: parameters applied successfully, snapshot '%s' created.", pass, snapshotName))

        -- Placed after the snapshot rather than before it, as the plan had it:
        -- this pass DID apply something, so it earns its snapshot like any
        -- other, and breaking earlier would have meant duplicating that block.
        -- `report` is the one from Delta.apply on the global settings above.
        if Delta.hasConverged(report, maskReports) then
            log(string.format("Pass %d: the model asked for nothing that moved the " ..
                "photograph; it has arrived. Skipping the remaining %d pass(es).",
                pass, passes - pass))
            break
        end

    end

    progressScope:setPortionComplete(1.0)
    progressScope:done()

    if completedPasses == 0 then
        log("No pass was completed.")
    else
        log(string.format("Development applied successfully! (%d/%d refinement passes completed)", completedPasses, passes))
    end
    end)
end)
