#!/usr/bin/env bash
# Increments VERSION.build in Info.lua whenever a .lua file in the plug-in
# bundle has changed since the last bump.
#
# Not driven by which file the tool reported: edits arrive through Edit, Write
# and Bash alike, and only some of those name a path. Instead the hook hashes
# the bundle's .lua files - Info.lua excluded, or bumping the build would
# itself look like a change and bump again forever - and compares that with the
# hash recorded at the last bump. No change, no bump, so reopening the panel or
# running the tests never moves the number.
set -u

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
bundle="$repo/VenzAI.lrdevplugin"
info="$bundle/Info.lua"
stamp="$repo/.claude/.build-stamp"

[ -f "$info" ] || exit 0

current="$(find "$bundle" -name '*.lua' ! -name 'Info.lua' -type f -exec sha1sum {} + \
    | sort | sha1sum | cut -d' ' -f1)"

[ -f "$stamp" ] && [ "$(cat "$stamp")" = "$current" ] && exit 0

build="$(sed -n 's/.*build = \([0-9]\+\).*/\1/p' "$info" | head -1)"
if [ -z "$build" ]; then
    echo "bump-build: no VERSION.build found in Info.lua" >&2
    exit 0
fi

next=$((build + 1))
# The VERSION line only, so a build number elsewhere in the file is untouched.
sed -i "s/\(VERSION = {[^}]*build = \)$build\( *}\)/\1$next\2/" "$info"

printf '%s' "$current" > "$stamp"

version="$(sed -n 's/.*VERSION = { *major = \([0-9]\+\), *minor = \([0-9]\+\), *revision = \([0-9]\+\), *build = \([0-9]\+\).*/\1.\2.\3.\4/p' "$info")"
printf '{"systemMessage": "VenzAI build bumped to %s"}\n' "$version"
