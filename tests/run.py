"""Runs the VenzAI Lua test suites on a real Lua 5.1 interpreter.

Lightroom runs Lua 5.1 and ships no interpreter we can drive, and Adobe's
luac.exe is not installed here - it comes with the downloadable SDK, not with
the application. lupa embeds several Lua runtimes; lua51 is the one whose
dialect matches Lightroom, so a test that passes here is a test written in
the language the plug-in actually runs.

Usage:
    python tests/run.py                # every suite
    python tests/run.py contract json  # only suites whose name matches
"""

import glob
import sys
from pathlib import Path

from lupa import lua51

ROOT = Path(__file__).resolve().parent.parent
BUNDLE = ROOT / "VenzAI.lrdevplugin"
HARNESS = ROOT / "tests" / "harness.lua"


def run_suite(path):
    """Runs one suite file in its own runtime. Returns (passed, failed)."""
    runtime = lua51.LuaRuntime(unpack_returned_tuples=True)
    runtime.globals()["VENZAI_BUNDLE"] = BUNDLE.as_posix()
    runtime.execute(HARNESS.read_text(encoding="utf-8"))

    # A suite file can raise while it is still loading - a top-level require of
    # a module that does not exist yet is the normal RED of the first step of
    # every task. That is one suite failing, not a reason to abandon the run and
    # leave the remaining suites unreported.
    try:
        suite = runtime.execute(path.read_text(encoding="utf-8"))
    except Exception as exc:
        print("  ERROR  %s did not load" % path.name)
        for line in str(exc).strip().splitlines()[:6]:
            print("          %s" % line)
        return 0, 1

    if suite is None:
        print("  ERROR  %s returned nothing; a suite must return an array of cases"
              % path.name)
        return 0, 1

    passed = failed = 0
    for index in range(1, len(suite) + 1):
        case = suite[index]
        name, body = case[1], case[2]
        try:
            body()
        except Exception as exc:  # a Lua assert arrives as a LuaError
            print("  FAIL  %s" % name)
            for line in str(exc).strip().splitlines():
                print("          %s" % line)
            failed += 1
        else:
            print("  PASS  %s" % name)
            passed += 1
    return passed, failed


def main():
    files = sorted(Path(p) for p in glob.glob(str(ROOT / "tests" / "test_*.lua")))
    if len(sys.argv) > 1:
        wanted = sys.argv[1:]
        files = [f for f in files if any(w in f.name for w in wanted)]
    if not files:
        print("no suites matched")
        return 1

    total_passed = total_failed = 0
    for path in files:
        print(path.name)
        passed, failed = run_suite(path)
        total_passed += passed
        total_failed += failed

    print("\n%d passed, %d failed" % (total_passed, total_failed))
    return 1 if total_failed else 0


if __name__ == "__main__":
    sys.exit(main())
