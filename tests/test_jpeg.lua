-- tests/test_jpeg.lua
--
-- The photograph leaves this machine. What leaves with it is a decision, not
-- an accident: a JPEG straight out of Lightroom can carry the camera body and
-- its serial number, the lens, the date and time to the second, the GPS
-- coordinates of where the photographer stood, the artist and copyright
-- fields, the keywords, the face regions with people's names, and the whole
-- XMP block including the catalog's own identifiers.
--
-- The export settings ask Lightroom for as little of that as its own UI
-- offers. This module is what makes it a guarantee instead of a request: the
-- file is opened afterwards and every metadata segment is cut out of it,
-- whatever Lightroom decided to write.
--
-- Two segments are deliberately kept. APP0 is the JFIF header, which is
-- structure rather than information about anyone, and APP2 carries the ICC
-- colour profile - remove that and the colours the model is asked to measure
-- are no longer the colours we exported.

local Jpeg = require 'VenzAIJpeg'

-- Builds a JPEG-shaped string: SOI, the given segments, SOS, scan data, EOI.
local function jpeg(segments, scan)
    local parts = { "\255\216" }
    for _, seg in ipairs(segments) do
        local marker, payload = seg[1], seg[2]
        local length = #payload + 2
        table.insert(parts, string.char(255, marker)
            .. string.char(math.floor(length / 256), length % 256) .. payload)
    end
    table.insert(parts, "\255\218\000\002")          -- SOS, empty header
    table.insert(parts, scan or "the pixels themselves")
    table.insert(parts, "\255\217")                  -- EOI
    return table.concat(parts)
end

local EXIF = { 0xE1, "Exif\0\0" .. string.rep("camera body, serial, GPS", 4) }
local XMP  = { 0xE1, "http://ns.adobe.com/xap/1.0/\0<x:xmpmeta>lens, catalog id</x:xmpmeta>" }
local IPTC = { 0xED, "Photoshop 3.0\0" .. string.rep("keywords, creator", 3) }
local JFIF = { 0xE0, "JFIF\0\1\1\0\0\1\0\1\0\0" }
local ICC  = { 0xE2, "ICC_PROFILE\0" .. string.rep("sRGB curve", 8) }

return {
    { "Exif is cut out, and the pixels survive", function()
        local before = jpeg({ JFIF, EXIF })
        local after, removed = Jpeg.stripMetadata(before)
        assert(after, "nothing came back")
        assert(not after:find("Exif", 1, true), "the camera and its serial are still in there")
        assert(not after:find("GPS", 1, true), "where the photographer stood is still in there")
        assert(after:find("the pixels themselves", 1, true), "the image data was damaged")
        assert(after:sub(1, 2) == "\255\216", "it is no longer a JPEG")
        assert(after:sub(-2) == "\255\217", "it lost its end marker")
        assert(#removed == 1, "got " .. #removed .. " removed segment(s)")
    end },

    { "XMP and IPTC go too", function()
        local after = Jpeg.stripMetadata(jpeg({ JFIF, EXIF, XMP, IPTC }))
        assert(not after:find("xmpmeta", 1, true), "the XMP block survived")
        assert(not after:find("catalog id", 1, true), "the catalog's own identifiers survived")
        assert(not after:find("Photoshop", 1, true), "the IPTC block survived")
        assert(not after:find("keywords", 1, true), "the keywords survived")
    end },

    { "the colour profile and the JFIF header are kept", function()
        -- Removing the ICC profile would change the colours the model is asked
        -- to measure, which is the one thing this file exists to protect.
        local after = Jpeg.stripMetadata(jpeg({ JFIF, ICC, EXIF }))
        assert(after:find("ICC_PROFILE", 1, true), "the colour profile was thrown away")
        assert(after:find("JFIF", 1, true), "the JFIF header was thrown away")
        assert(not after:find("Exif", 1, true), "and Exif should still be gone")
    end },

    { "a file with nothing to remove comes back unchanged", function()
        local before = jpeg({ JFIF, ICC })
        local after, removed = Jpeg.stripMetadata(before)
        assert(after == before, "a clean file must not be rewritten")
        assert(#removed == 0, "it removed something that was not metadata")
    end },

    { "every application segment but JFIF and ICC is removed", function()
        -- APP3 through APP12 are not ours to interpret, and at least one of
        -- them (APP4 "Meta") is known to carry camera information. Anything we
        -- cannot name is not something to send to a third party.
        local segments = { JFIF, ICC }
        for marker = 0xE3, 0xEF do
            table.insert(segments, { marker, "something nobody here can read" })
        end
        local after, removed = Jpeg.stripMetadata(jpeg(segments))
        assert(#removed == 13, "got " .. #removed)
        assert(not after:find("nobody here can read", 1, true), "an unknown segment survived")
        assert(after:find("ICC_PROFILE", 1, true) and after:find("JFIF", 1, true))
    end },

    { "a comment segment is not a place to leave notes", function()
        local after = Jpeg.stripMetadata(jpeg({ JFIF, { 0xFE, "created by someone, somewhere" } }))
        assert(not after:find("created by someone", 1, true), "the comment survived")
    end },

    --------------------------------------------------------------------------
    -- Refusing to guess
    --------------------------------------------------------------------------
    { "something that is not a JPEG is left alone", function()
        -- Rewriting a file we do not understand is worse than not stripping it:
        -- the caller is told nothing was done and can decide.
        local png = "\137PNG\r\n\26\n" .. string.rep("data", 20)
        local after, removed = Jpeg.stripMetadata(png)
        assert(after == nil, "it rewrote a file it does not understand")
        assert(type(removed) == "string", "it must say why")
    end },

    { "a truncated segment stops the scan instead of corrupting the file", function()
        -- A length that runs past the end of the data is either a damaged file
        -- or our own misreading. Either way, do not produce a JPEG from it.
        local broken = "\255\216" .. "\255\225" .. string.char(255, 255) .. "short"
        local after, why = Jpeg.stripMetadata(broken)
        assert(after == nil, "it produced a file from a length it could not trust")
        assert(type(why) == "string")
    end },

    --------------------------------------------------------------------------
    { "what is in a file can be listed without changing it", function()
        -- So a run can say in the log what it found, and the claim that the
        -- export carries no metadata is checkable rather than asserted.
        local found = Jpeg.metadataSegments(jpeg({ JFIF, EXIF, XMP, ICC }))
        assert(#found == 2, "got " .. #found)
        table.sort(found)
        assert(found[1]:find("APP1", 1, true), "got " .. found[1])
    end },

    { "a clean file lists nothing", function()
        local found = Jpeg.metadataSegments(jpeg({ JFIF, ICC }))
        assert(#found == 0, "got " .. #found .. ": " .. table.concat(found, ", "))
    end },
}
