# Contributing

Contributions are welcome. This file is the permission that makes them
possible, because the licence on its own does not.

VenzAI is published under the [PolyForm Strict License 1.0.0](LICENSE.md),
which does not allow modified versions or redistribution. Writing a patch means
making a modified version, so without the permission below, sending one would
not be something you were allowed to do. This file grants it.

## The permission

The author grants you, in addition to the licence:

**A licence to copy and modify VenzAI for the sole purpose of preparing a
contribution to this repository, and to send that contribution to the author.**

It covers a private working copy and a fork made in order to open a pull
request. It does not extend to publishing a modified version, distributing your
changed copy to anyone else, or keeping a fork alive as a separate plug-in —
whether your contribution is accepted or not.

GitHub's **Fork** button creates a public copy by default, which is a form of
redistribution. To stay within the permission, either make your fork private
in the repository settings immediately after forking, or delete it once your
pull request is closed.

## What you give when you send one

By opening a pull request, or sending code in any other form, you agree that:

1. **The work is yours to give.** You wrote it, or you have the right to
   contribute it, and it is not covered by an obligation to an employer or
   anyone else that would prevent that.
2. **You grant the author a perpetual, worldwide, irrevocable, royalty-free
   licence** to use, modify, publish, sublicense and distribute your
   contribution, under any terms, including commercial ones.
3. **You keep your copyright.** This is a licence, not an assignment: the
   contribution stays yours, and you may use it elsewhere however you like.

Point 2 matters and is worth reading twice. VenzAI is noncommercial for
everyone else, but the author reserves commercial use. If a contribution could
not be relicensed, a single accepted patch would make that impossible for the
whole project, and the contribution would have to be refused for a reason that
has nothing to do with its quality.

Add a `Signed-off-by:` line to your commits to say you agree:

```bash
git commit -s -m "..."
```

## Before you write code

**Open an issue first.** Not ceremony: acceptance is the author's judgement,
and a patch that arrives unannounced can be right in every technical respect
and still not fit the design. An issue costs you ten minutes and can save you
an afternoon.

Good things to send, roughly in order of how likely they are to be accepted:

- A bug with a run that reproduces it, and the relevant lines of the log.
- A fix with a test that fails without it.
- A new provider driver — the design is built for it: one new file and one
  line in the registry. Read
  [ARCHITECTURE.md](ARCHITECTURE.md) first.
- A translation into another language.

## What a contribution has to carry

- **Tests.** The suite runs outside Lightroom:

  ```bash
  pip install -r tests/requirements.txt
  python tests/run.py
  ```

  A fix arrives with a test that fails without it — reintroduce the bug and
  watch the test go red, because a test that has never failed has never been
  verified.

- **Green, all of it.** Every suite, not the one you touched.

- **Complete translations.** Any new `LOC` key needs its Italian line in
  `TranslatedStrings_it.txt`; `python tests/check_translations.py` checks.

- **The reason, in the code.** This codebase says *why* in comments and commit
  messages, not *what* — the Lightroom trap that cost a day, the run that
  exposed the defect. Match that.

## What is not a contribution

Requests to relicense the project, to add a commercial use, or to permit forks.
The terms are a deliberate decision rather than an oversight; see the
[licence section of the README](README.md#licence).
