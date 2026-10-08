# Changelog

What changes for you between releases. Newest first.

---

## 1.2.1

Documentation, community files, and one behaviour fix in the reference image
dialog.

### New

- **Code of conduct, security policy, issue templates, and a PR template.**
  The repository now has the full set of GitHub community files: a code of
  conduct, a security policy with the responsible disclosure address, a bug
  report template that asks for the build number and the relevant log lines,
  a feature request template that points to the architecture document, and a
  pull request template with the checklist from `CONTRIBUTING.md`.

### Fixed

- **The reference image dialog now fits the screen.** Without a size
  constraint the picture control rendered at the image's full resolution —
  typically larger than the display — and the caption, the question, and the
  buttons scrolled off the bottom. The image is now capped at 700 × 480 px;
  Lightroom scales it to fit while keeping the aspect ratio.
- **The "Continue or stop?" question is now asked.** When "Show the reference
  image during a run" is on, the dialog now shows "Do you want to continue
  with the processing?" with two buttons: **Continue** and **Stop the run**.
  Stopping cancels the run cleanly before any analysis is sent. The question
  was the reason the setting exists — without it a bad reference and a bad
  reading of a good one look the same — and it was missing from the first
  implementation.

### Changed

- The Italian label for the checkbox reads "Mostra l'immagine di riferimento
  durante la run" (was "durante una corsa").

### Documentation

- Installing now leads with the release zip rather than "clone the
  repository"; cloning is for developers.
- Each provider section lists the models that have been tested end-to-end,
  so a user trying an untested model knows what they are doing.
- A new section explains the API token cost structure: two images per pass
  when a reference is generated, six images for a typical three-pass run.
- The "When something goes wrong" section now covers API key recovery through
  Keychain Access (macOS) and Credential Manager (Windows).
- The Ollama section explains that the URL field accepts any address,
  including a remote machine on the local network.
- `CONTRIBUTING.md` now says to keep a GitHub fork private or delete it
  after the PR closes, because the default public fork is redistribution the
  licence does not permit on its own.

VenzAI reports a version as `major.minor.revision.build`. The first three
numbers are the release, and they are what this file is organised by. The
build counter moves on every change to the plug-in and says which code is
running; it does not mean anything on its own.

---

## 1.2.0

The release that decided what the plug-in guarantees, and under what terms it
is published.

### New

- **The upload carries pixels and nothing else.** The exported JPEG used to go
  to the provider with everything Lightroom writes into it: camera body and
  serial number, lens, date and time, GPS coordinates, artist and copyright,
  keywords, face regions with people's names, and the XMP block. The export now
  asks for the least metadata Lightroom offers and the file is then opened and
  stripped of every metadata segment regardless, keeping only the JFIF header
  and the ICC colour profile. What was removed is named in the log. If the
  strip fails the run stops rather than uploading a file whose contents are
  unknown.

- **One run at a time.** Starting a run while another is in progress is now
  refused, with a message saying how long the other has been going. Two runs
  shared the exported file, the working folder and the selected mask, so local
  corrections from one could land on the other's mask and neither result could
  be trusted. The lock is released when a run finishes, is cancelled or fails,
  and expires by itself after 30 minutes so a crash cannot wedge the plug-in.
- **A button that releases the run lock**, in the settings panel, for the case
  the expiry is meant to cover but half an hour too slowly. It says who holds
  the lock and for how long before offering, and asks for confirmation:
  releasing a lock while its run is still going lets a second run start on top
  of it, which is the thing the lock exists to prevent. Emptying the working
  folder clears it too.

- **A licence.** The plug-in is now published under the PolyForm Strict License
  1.0.0: free for any noncommercial use, with redistribution, modified versions
  and commercial use reserved to the author. It is source-available, not open
  source, and the difference is deliberate.
- **Contributions are open**, through a permission granted alongside the
  licence rather than by loosening it: you may copy and modify VenzAI for the
  sole purpose of preparing a contribution, and nothing else. What you grant in
  return, and what a contribution has to carry, are in `CONTRIBUTING.md`.

### Fixed

- **A lock could outlive the run that took it.** The release deleted through
  `os.remove`, which in Lightroom's Lua left the file where it was — and
  because the release runs from a cleanup handler, the failure was swallowed
  silently. A run that finished cleanly went on refusing the next run for half
  an hour. Deletion now goes through the SDK like every other deletion in the
  plug-in, and a release says in the log whether it worked: silence used to be
  indistinguishable from a handler that never ran.

### Changed behaviour

- **A crooked horizon is measured, not judged.** When a photograph contains a
  true horizon, whether it is level is a measurement, and the prompt now says
  how to take it: compare the height of the line at the left edge of the frame
  with its height at the right.
- **Crops can be large.** Composition is the one decision the model still
  makes on its own - the reference image is not reliable for geometry - and
  silence there is no longer an available answer. Cutting a third to a half of
  the frame is described as ordinary when the picture needs it.
- **The settings panel's diagnostics are three rows, not one.** The buttons ran
  off the edge of the dialog in Italian, where the labels are longer. The lock
  button has a row of its own because it is not a diagnostic: the others open
  something to look at, that one changes the plug-in's state.
- **OpenAI generates the reference by default.** It shipped switched off, when
  its request format came from documentation rather than from a call anyone had
  made. Without a reference the analysis has no target and goes back to
  deciding the edit itself, so the switch now starts on, as Gemini's already
  did.

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
