--[[----------------------------------------------------------------------------

Info.lua
Plug-in manifest for VenzAI.

------------------------------------------------------------------------------]]

return {
    -- SDK this plug-in is developed and tested against.
    LrSdkVersion = 15.3,

    -- The masking API this plug-in depends on (LrDevelopController.createNewMask,
    -- selectMask, getAllMasks, getSelectedMask and the local_* parameter
    -- vocabulary) is documented as "first supported in version 11.0 of the
    -- Lightroom SDK". The previous value of 6.0 was wrong: the plug-in loaded
    -- on older versions and then failed inside pcall with no explanation.
    -- Note that some aiSelection subtypes used here ("people", "landscape",
    -- "objects") arrived after 11.0; VenzAIProcess checks for the masking API
    -- at run time and simply skips local corrections when it is unavailable,
    -- so a host between 11.0 and the subtype's real minimum degrades to
    -- global-only editing instead of breaking.
    LrSdkMinimumVersion = 11.0,

    -- Kept as-is on purpose. It is a placeholder identifier rather than a
    -- reverse-DNS name on a domain we own, which is what Adobe asks for, but
    -- LrPrefs and LrPasswords are both keyed on it: changing it orphans every
    -- saved setting and the stored API key. If it is ever changed, the new
    -- version has to migrate both stores before the old ID is dropped.
    LrToolkitIdentifier = 'com.user.geminiautoedit',

    LrPluginName = LOC "$$$/VenzAI/PluginName=VenzAI",

    VERSION = { major = 1, minor = 4, revision = 0, build = 60 },

    LrPluginInfoProvider = "PluginInfoProvider.lua",

    LrLibraryMenuItems = {
        {
            title = LOC "$$$/VenzAI/Menu/AnalyzeAndDevelop=Analyze and develop with VenzAI",
            file = "VenzAIProcess.lua",
        },
        -- Touches no photo: it checks every registered driver against the
        -- contract, its configuration, and whether its service answers. Not in
        -- LrExportMenuItems, which is for acting on photos. This is the only
        -- manifest change the driver design needs, and adding a provider later
        -- does not touch this file.
        {
            title = LOC "$$$/VenzAI/Menu/TestProviders=Test VenzAI providers",
            file = "VenzAISelfTest.lua",
        },
    },

    LrExportMenuItems = {
        {
            title = LOC "$$$/VenzAI/Menu/AnalyzeAndDevelop=Analyze and develop with VenzAI",
            file = "VenzAIProcess.lua",
        },
    },
}
