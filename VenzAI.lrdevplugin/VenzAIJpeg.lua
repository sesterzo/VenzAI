--[[----------------------------------------------------------------------------

VenzAIJpeg.lua
Removes the metadata from a JPEG before it leaves this machine.

The photograph is uploaded to a service the photographer does not control, and
a JPEG exported from Lightroom carries far more than pixels: the camera body
and its serial number, the lens, the date and time to the second, the GPS
coordinates of where the person stood, the artist and copyright fields, the
keywords, the face regions with people's names, and an XMP block that includes
the catalog's own identifiers.

None of that helps a model judge exposure, and all of it is the photographer's
to give away deliberately or not at all. The export settings ask Lightroom for
the least metadata its own interface offers; this module is what turns that
request into a guarantee, by opening the file afterwards and cutting the
segments out whatever Lightroom decided to write.

Two segments are kept on purpose:
  APP0  the JFIF header - structure, not information about anyone.
  APP2  the ICC colour profile - remove it and the colours the model is asked
        to measure stop being the colours we exported.

A JPEG is a sequence of segments: 0xFFD8 (start of image), then for each
segment a 0xFF byte, a marker byte, and a two-byte big-endian length that
counts itself. At 0xFFDA (start of scan) the entropy-coded image data begins
and runs to the end, so everything from there is copied untouched.

------------------------------------------------------------------------------]]

local M = {}

-- Kept: the JFIF header and the ICC colour profile.
local KEEP = { [0xE0] = true, [0xE2] = true }

-- Removed: every other application segment, and the comment segment. APP3 to
-- APP15 are not ours to interpret - APP4 is known to carry camera information
-- in some makes - and a segment nobody here can read is not a segment to send
-- to a third party.
local function isMetadata(marker)
    if marker == 0xFE then return true end                      -- COM
    if marker >= 0xE0 and marker <= 0xEF then return not KEEP[marker] end
    return false
end

local function markerName(marker)
    if marker == 0xFE then return "COM" end
    return string.format("APP%d", marker - 0xE0)
end

-- Walks the segments and calls `onSegment(marker, startPos, nextPos)` for each
-- one before the scan data. Returns the position where the scan begins, or nil
-- and a reason when the file is not one we can read confidently.
local function walk(data, onSegment)
    if type(data) ~= "string" or #data < 4 then return nil, "too short to be a JPEG" end
    if data:byte(1) ~= 0xFF or data:byte(2) ~= 0xD8 then return nil, "no start-of-image marker" end

    local pos = 3
    while pos + 3 <= #data do
        if data:byte(pos) ~= 0xFF then
            return nil, string.format("expected a marker at byte %d", pos)
        end

        local marker = data:byte(pos + 1)

        -- Start of scan: the image data follows and runs to the end.
        if marker == 0xDA then return pos end
        -- End of image, or a standalone marker that carries no length.
        if marker == 0xD9 then return pos end
        if marker >= 0xD0 and marker <= 0xD8 then
            pos = pos + 2
        else
            local length = data:byte(pos + 2) * 256 + data:byte(pos + 3)
            if length < 2 then
                return nil, string.format("a segment at byte %d declares length %d", pos, length)
            end

            local nextPos = pos + 2 + length
            -- A length that runs past the end is a damaged file or our own
            -- misreading. Either way, do not build a JPEG out of it.
            if nextPos > #data + 1 then
                return nil, string.format("a segment at byte %d runs past the end of the file", pos)
            end

            if onSegment then onSegment(marker, pos, nextPos) end
            pos = nextPos
        end
    end

    return nil, "the file ends before the image data begins"
end

-- Returns the names of the metadata segments present, without changing
-- anything, so a run can say in its log what it found. An unreadable file
-- lists nothing rather than raising: this is a probe, not a gate.
function M.metadataSegments(data)
    local found = {}
    walk(data, function(marker)
        if isMetadata(marker) then table.insert(found, markerName(marker)) end
    end)
    return found
end

-- Returns the stripped data and the list of what was removed, or nil and a
-- reason. A file with nothing to remove is returned unchanged and identical,
-- so the caller can skip writing it.
function M.stripMetadata(data)
    local kept = {}
    local removed = {}
    local last = 1

    local scanAt, why = walk(data, function(marker, startPos, nextPos)
        if isMetadata(marker) then
            table.insert(kept, data:sub(last, startPos - 1))
            table.insert(removed, markerName(marker))
            last = nextPos
        end
    end)

    if not scanAt then return nil, why end
    if #removed == 0 then return data, removed end

    table.insert(kept, data:sub(last))
    return table.concat(kept), removed
end

-- Reads the file, strips it, writes it back. Returns the list of what was
-- removed, or nil and a reason. The file is only rewritten when there is
-- something to take out of it.
function M.stripFile(path)
    local handle, openErr = io.open(path, "rb")
    if not handle then return nil, tostring(openErr) end
    local data = handle:read("*a")
    handle:close()
    if not data or data == "" then return nil, "the file is empty" end

    local stripped, removed = M.stripMetadata(data)
    if not stripped then return nil, removed end
    if #removed == 0 then return removed end

    local out, writeErr = io.open(path, "wb")
    if not out then return nil, tostring(writeErr) end
    out:write(stripped)
    out:close()
    return removed
end

return M
