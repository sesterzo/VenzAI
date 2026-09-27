# Changelog

What changes for you between releases. Newest first.

VenzAI reports a version as `major.minor.revision.build`. The first three
numbers are the release, and they are what this file is organised by. The
build counter moves on every change to the plug-in and says which code is
running; it does not mean anything on its own.

---

## 1.1.1

Nothing in the plug-in behaves differently from 1.1. This release marks the
state that was run end to end on real photographs - a concert indoors and
birds at a reserve - and judged good: a version number to come back to.

### For anyone working on the code

- There is no longer a continuous integration workflow. Run the suite yourself
  before committing, with `python tests/run.py`.

---

## 1.1 — the model measures the edit instead of authoring it

The release that changed what the plug-in asks the vision model to do.

Until now the model was told the edit was its to author, and the AI-generated
reference image was introduced as something "useful only to understand mood".
It answered accordingly. A run on a midday coastline and a run on an indoor
concert came back with the same numbers: of 45 parameters both asked for, 10
were identical and 13 more were within a fifth of each other, tone curves
included. That is a model reciting one good edit, not reading a photograph.

### New

- **The point tone curve.** `ToneCurvePV2012` and the three channel curves are
  now part of the vocabulary, so the model can shape the tonality itself
  rather than only move levels. A curve that Lightroom would refuse — an odd
  number of values, fewer than two points, more than sixteen, x that does not
  climb, a curve that does not span 0 to 255 — is discarded rather than
  repaired.
- **Camera calibration.** The primaries themselves, which is where a
  photograph gets a colour signature rather than a colour correction.
- **A working folder that tidies itself.** The reference images are kept in
  one place, the ten most recent survive, and the settings panel has a button
  that empties it.

### Changed behaviour

- **The reference image is the target, not inspiration.** The model is asked
  how far the photograph has to move to reach it, step by step, and a
  parameter it sees no difference in is a parameter it leaves out. Where there
  is no reference image — a provider that does not generate one, or one whose
  generation is switched off — the older prompt is used unchanged, because
  with no target there is nothing to measure and the model has to decide.
- **Later passes may undo what earlier passes did.** They used to be told not
  to, which left a magenta cast of 13 points on a photograph and corrected it
  by 4. Movements now halve from pass to pass and change sign: a run converges
  instead of piling up.
- **The reference is asked for differently.** The brief used to say "deep
  blacks" and "an edit too small to see is the same as no edit", to every
  photograph alike, and the references came back exactly as ordered — a little
  dark, colours well loaded, the same treatment everywhere. It now asks for
  work that does not announce itself: open light, shadows and highlights that
  keep detail, colour where a good print would put it, saturation as a last
  resort.
- **Higher quality references.** The image is requested at high quality, and
  only the one parameter the endpoint actually refuses is dropped before
  asking again — read from the name in the error's own `param` field.
- **AI masks get 45 seconds to appear** instead of 15. An 8050×5448 coastline
  lost its entire ground treatment to the old limit, twice, while the sky mask
  beside it arrived in four seconds. When a mask still fails, the log now says
  whether Lightroom never created it or created one we failed to recognise.

### Fixed

- **A white balance movement is no longer thrown away.** On a raw still at "As
  Shot" the photograph reports no Kelvin, so the first movement the model asked
  for had nothing to move from and was refused. The white balance is now
  unlocked, the Kelvin read back, and the movement carried out in the same
  pass.
- **The vignette reaches the frame again.** Its midpoint, feather, roundness
  and highlight contrast are positions, not movements; accumulated, a midpoint
  of 50 plus a request for 45 became 95 and the vignette never arrived.
- **The colour grading blend likewise.** Asking twice for 70 reached
  all-highlights.
- **Colour grading is written at all.** Lightroom stores four of its values
  under the legacy split-toning names, and writing the name that does not exist
  is how the model's warm highlight grading vanished on every pass of every
  run.

---

## 1.0

The first release: a Lightroom Classic plug-in that sends a photograph to a
vision model and applies real develop settings from what comes back.

### What it does

- **Three providers, one engine.** Gemini, OpenAI and Ollama are drivers behind
  a single contract; the engine never names one. The settings panel is built
  from what each driver declares about itself, so a provider's fields, its
  models and its capabilities come from the driver rather than from the panel.
- **A reference image.** Providers that can generate one are asked for a
  finished version of the photograph, which the analysis then reverse-engineers
  into develop settings.
- **Refinement passes.** The photograph is exported, analysed, developed, and
  the result analysed again, up to the number of passes you choose.
- **Local corrections.** The AI-detected regions Lightroom can find on its own
  — subject, people, objects, sky, landscape, background — are created and
  given their own treatment.
- **Snapshots.** One before anything is touched, one per pass, so every step
  is reversible from Lightroom's own history.
- **The numbers are movements.** The model reports how far to move each slider
  rather than where to put it; the plug-in accumulates and clamps at the ends.
