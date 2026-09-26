--[[----------------------------------------------------------------------------

VenzAILog.lua
Shared logging for the VenzAI plug-in.

Replaces the previous hand-rolled `io.open(<plugin folder>/debug.log, "a")`.
Writing inside the plug-in bundle is not portable: on macOS a .lrplugin is a
package and may live in a read-only location, and on Windows the plug-in can
sit under Program Files. In both cases io.open() returns nil and the log
silently disappears - exactly when it is needed.

LrLogger writes to the location Adobe defines per platform:
  macOS:   ~/Library/Logs/Adobe/Lightroom/LrClassicLogs/VenzAI.log
  Windows: %LOCALAPPDATA%\Adobe\Lightroom\Logs\LrClassicLogs\VenzAI.log
No conditional path code is needed - the SDK picks the right one.

------------------------------------------------------------------------------]]

local LrLogger = import 'LrLogger'
local LrPathUtils = import 'LrPathUtils'

local LOGGER_NAME = "VenzAI"

local logger = LrLogger(LOGGER_NAME)
logger:enable("logfile")

local M = {}

-- Prefix used to tell apart lines coming from the settings panel and lines
-- coming from a processing run, now that both share one log file.
function M.scoped(prefix)
    local tag = prefix and ("[" .. prefix .. "] ") or ""
    return function(msg)
        logger:info(tag .. tostring(msg))
    end
end

M.log = M.scoped(nil)

-- Joins path segments one at a time through LrPathUtils.child, which is the
-- only separator-agnostic way to build a path: hardcoding "/" or "\\" is
-- exactly the kind of thing that works on one platform and breaks on the other.
local function join(base, ...)
    local path = base
    for _, segment in ipairs({ ... }) do
        path = LrPathUtils.child(path, segment)
    end
    return path
end

-- Best-effort path of the folder LrLogger writes into, for the "Show log"
-- button in the settings panel. LrLogger does not expose its own path, so it
-- is reconstructed from the locations Adobe documents for enable("logfile").
-- Returns nil rather than a wrong path if the platform globals are absent.
function M.logFolderPath()
    if MAC_ENV then
        local home = LrPathUtils.getStandardFilePath('home')
        if not home then return nil end
        return join(home, "Library", "Logs", "Adobe", "Lightroom", "LrClassicLogs")
    end

    if WIN_ENV then
        local localAppData = os.getenv("LOCALAPPDATA")
        if not localAppData then return nil end
        return join(localAppData, "Adobe", "Lightroom", "Logs", "LrClassicLogs")
    end

    return nil
end

function M.logFilePath()
    local folder = M.logFolderPath()
    if not folder then return nil end
    return LrPathUtils.child(folder, LOGGER_NAME .. ".log")
end

return M
