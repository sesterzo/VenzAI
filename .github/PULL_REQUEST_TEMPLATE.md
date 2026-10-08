## What this does

A short description of the change and the problem it solves.

## Why it is shaped this way

The reasoning behind the approach — the Lightroom constraint, the run that
exposed the defect, or the trade-off that ruled out the alternative.

## Checklist

- [ ] There is an issue that was opened and discussed before this PR.
- [ ] The fix comes with a test that fails without it (reintroduce the bug
      and watch the test go red).
- [ ] Every suite passes: `python tests/run.py`
- [ ] Any new `LOC` key has its Italian line in `TranslatedStrings_it.txt`:
      `python tests/check_translations.py`
- [ ] Commits carry a `Signed-off-by:` line (`git commit -s`), as required
      by [CONTRIBUTING.md](../CONTRIBUTING.md).
