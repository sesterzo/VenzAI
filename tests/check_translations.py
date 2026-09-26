"""Compares the LOC keys used in the bundle against each translation file.

A key in the source but not in a translation degrades to English, which is
correct behaviour but silent. A key in a translation but not in the source is
dead weight that hides a rename. Both are reported; only the first fails.

Usage: python tests/check_translations.py
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUNDLE = ROOT / "VenzAI.lrdevplugin"

# A LOC key as it appears in Lua source: "$$$/Path/To/Key=default text"
SOURCE_KEY = re.compile(r'"\$\$\$/([^"=]+)=')
# A line of a TranslatedStrings file: "$$$/Path/To/Key=translated text"
TRANSLATION_KEY = re.compile(r'^"\$\$\$/([^"=]+)=')


def keys_in_source():
    keys = set()
    for path in sorted(BUNDLE.glob("*.lua")):
        keys |= set(SOURCE_KEY.findall(path.read_text(encoding="utf-8")))
    return keys


def keys_in_translation(path):
    keys = set()
    for line in path.read_text(encoding="utf-8").splitlines():
        found = TRANSLATION_KEY.match(line.strip())
        if found:
            keys.add(found.group(1))
    return keys


def main():
    source = keys_in_source()
    print("%d keys used in the source" % len(source))

    failed = False
    for path in sorted(BUNDLE.glob("TranslatedStrings_*.txt")):
        translated = keys_in_translation(path)
        missing = sorted(source - translated)
        orphaned = sorted(translated - source)

        print("\n%s: %d keys" % (path.name, len(translated)))
        if missing:
            failed = True
            print("  MISSING (%d) - these degrade to English:" % len(missing))
            for key in missing:
                print("    %s" % key)
        if orphaned:
            print("  ORPHANED (%d) - no longer used in the source:" % len(orphaned))
            for key in orphaned:
                print("    %s" % key)
        if not missing and not orphaned:
            print("  complete")

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
