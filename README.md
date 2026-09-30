# VenzAI

**A vision model reads your photograph. Lightroom gets the sliders.**

![Lightroom Classic 11+](https://img.shields.io/badge/Lightroom%20Classic-11%2B-31a8ff)
![Windows and macOS](https://img.shields.io/badge/platform-Windows%20%7C%20macOS-lightgrey)
![Lua 5.1](https://img.shields.io/badge/Lua-5.1-000080)
![Gemini, OpenAI, Ollama](https://img.shields.io/badge/providers-Gemini%20%7C%20OpenAI%20%7C%20Ollama-4b8bbe)

VenzAI looks at a photograph with a vision model and translates what it sees
into real Adobe Lightroom Classic develop settings — exposure, tone curve,
white balance, the colour mixer, detail, grain, crop, vignette, and AI-detected
local masks.

### Your photograph is never rewritten

**No AI ever touches a pixel of your picture.** The model is not asked to
produce an image — it is asked what the sliders should say, and the answer
comes back as numbers. VenzAI then moves those sliders, exactly as your own
hand would.

So the photograph that comes out is the photograph you took:

- **Not a generated image.** No pixel is invented, repainted, upscaled,
  denoised by a model or re-encoded. Every detail in the final frame was on
  your sensor.
- **No watermark, no signature, no content credentials.** Nothing is stamped
  into the file, visibly or invisibly, because the file is not rewritten at
  all.
- **Your raw is untouched.** The develop settings live where Lightroom keeps
  them; the original file is not replaced, re-saved or converted.
- **Every change is a slider you can see.** Open the Basic panel and you will
  find ordinary numbers to adjust, undo, or throw away. A snapshot is taken
  before anything happens and after every step, so there is always a way back.

This is the whole design, not a reassurance. A model that returns an image
gives you its interpretation of your photograph. A model that returns numbers
gives you an edit — and an edit is yours to argue with.

It runs against Google Gemini, OpenAI, or entirely offline through a local
Ollama model.

**What is uploaded is a photograph and nothing else.** The file sent to a cloud
provider is stripped of every piece of metadata first — no camera serial, no
GPS, no names, no keywords. **With Ollama, nothing is uploaded at all.** See
[Your photographs and your privacy](#your-photographs-and-your-privacy).

- [Your photograph is never rewritten](#your-photograph-is-never-rewritten)
- [Two runs, start to finish](#two-runs-start-to-finish)
- [What a run actually does](#what-a-run-actually-does)
- [Requirements](#requirements)
- [Installing](#installing)
- [Setting up a provider](#setting-up-a-provider)
- [Your photographs and your privacy](#your-photographs-and-your-privacy)
- [Checking it works](#checking-it-works)
- [When something goes wrong](#when-something-goes-wrong)
- [What it does not do](#what-it-does-not-do)
- [For developers](#for-developers)
- [Licence](#licence)
- [Contributing](CONTRIBUTING.md)

---

## Two runs, start to finish

The photograph as it came off the card on the left, what VenzAI did to it on
the right. Both runs were made with OpenAI, on raw files, with no human
adjustment afterwards.

![A yellow-billed hornbill on a branch, before and after: the flat, hazy
original on the left, and on the right the same frame with a deep blue sky,
the bird's black-and-white plumage separated from the background, and warm
light on the wood.](samples/hornbill.png)

The sky in the original is almost white and the bird sits in it without
separation. On the right the sky has recovered its blue, the plumage has
regained its pattern against it, and the wood carries the warmth of the light
that was actually there — while the white of the head and the yellow of the
bill stay where they belong rather than being pushed.

![A view from Table Mountain over the Twelve Apostles and the Atlantic, before
and after: the original dark and flat in the rock face with a hazy sea, and on
the right the same frame with detail recovered in the rock, a graded sky, and
the sea reading turquoise where it meets the shore.](samples/cape-coastline.png)

Here the work is mostly in the shadows. The rock face on the left is a dark
mass; on the right it has its structure back without the picture turning grey,
the haze over the sea has cleared, and the sky carries a gradient from the
horizon upward. The ground keeps its green instead of drifting yellow.

Neither result is baked into pixels. Both are ordinary develop settings sitting
in the panels, with a snapshot before every step.

---

## What a run actually does

You select one photograph and choose **Analyze and develop with VenzAI**, from
either **Library ▸ Plug-in Extras** or **File ▸ Plug-in Extras**. Then:

1. **A snapshot is taken** — `VenzAI - Original`. This is your way back.
2. **The photo is exported** to a temporary JPEG, 2048 px, sRGB. Your original
   file is never touched or read by anything but Lightroom.
3. **A reference image is generated**, if you asked for one. The model
   produces a retouched version of the same frame, which becomes the target the
   analysis works toward. It is never applied to your photo; it is a goal, not
   a result — and you can look at it while the run happens (see Diagnostics).
4. **The photograph is analysed**, and the model answers with how far to
   MOVE each slider — not where to put it. It can see that a picture is still
   half a stop dark; it cannot see that Exposure is currently at 0.35, because
   that number is not in the pixels. So it reports what is still missing, the
   plug-in adds it to what is already there, and "nothing to change" is an
   ordinary answer rather than a destructive one.
5. **The settings are applied**, local masks included, and a snapshot is taken.
6. **Steps 2 to 5 repeat** for the number of refinement passes you set. Each
   pass sees the photograph as it now stands, is told what is already applied,
   and refines it. When a pass asks for nothing more, the run stops early.

A pass takes roughly 30 seconds, plus a couple of seconds for each local mask.

### Local masks

When the photograph genuinely calls for it, VenzAI asks Lightroom's own AI
selection for a region — subject, people, objects, sky, landscape, background —
and treats it separately from the rest of the frame. These arrive as real
masks in the Masking panel, each one editable and deletable like any mask you
would have drawn yourself.

---

## Requirements

- **Lightroom Classic 11 or newer.** The masking API this depends on arrived in
  SDK 11.0. Some AI mask regions (`people`, `landscape`, `objects`) came later;
  on an older host VenzAI detects this and quietly does global-only editing
  instead of failing.
- **An account with one of the three providers**, or a machine running Ollama.
- Windows or macOS. One code path serves both.

---

## Installing

1. Download or clone this repository.
2. In Lightroom Classic: **File ▸ Plug-in Manager ▸ Add**.
3. Select the `VenzAI.lrdevplugin` folder — the folder itself, not a file
   inside it.
4. The plug-in appears in the list as *VenzAI*, with its settings underneath.

To update later, replace the folder's contents and press **Reload Plug-in** in
the Plug-in Manager. Lightroom caches the code, so a change on disk does not
take effect until you do — the version number shown in the panel tells you
which build is actually loaded.

---

## Setting up a provider

Everything lives in **File ▸ Plug-in Manager ▸ VenzAI**. Pick the provider at
the top; the box for that provider becomes editable and the others grey out.

Every field has a **Detect models** button that asks the service which models
your account can actually reach. Use it rather than typing a name from memory —
a name that does not exist comes back as an error, and the list is the only
current answer.

### Gemini (Google, cloud)

| Field | What it is |
|---|---|
| API key | From Google AI Studio. Stored in the system keychain, never in the preferences file. |
| Analysis model | The model that reads the photograph and answers with settings. |
| Reference image model | The model that generates the target image. |
| Generate a reference image first | On by default. Turn it off to see what the reference is actually worth on a given photograph — same model, same photo, no target. |

### OpenAI (cloud)

| Field | What it is |
|---|---|
| API key | From the OpenAI platform. Stored in the system keychain. |
| Analysis model | Needs to read images and answer in JSON. |
| Reference image model | An image model, for the target image. |
| Generate a reference image first | Off by default. |
| API base URL | `https://api.openai.com/v1` by default. Change it only for a compatible gateway. |

**Detect models** offers a different list for each field, because the models
that can read a photograph and the models that can draw one are disjoint sets:
the analysis field hides speech, embedding, moderation and image models, and
the reference field shows only the families that generate pictures.

Ollama is the one provider with no reference image: it does not generate them.
There the analysis works from the photograph alone.

### Ollama (local, offline)

| Field | What it is |
|---|---|
| Server URL | `http://localhost:11434` by default. |
| Model | Any vision model you have pulled, for example `qwen2.5vl`. |

No API key, no account, no upload: **the maximum privacy this plug-in can
offer**, because there is no third party in the picture at all. Expect a lower
standard of judgement than the cloud models on a task this constrained — it is
the right choice when the photographs must not leave the computer, not when you
want the best result.

### Refinement passes

How many times the loop runs, from 1 to 5. Three is the default. More passes
mean a more considered edit and a longer wait; the run stops by itself when the
model stops asking for changes.

---

## Your photographs and your privacy

### If you use Ollama, nothing leaves your computer

The model runs on your own machine. No API key, no account, no upload, no
network call to anyone. If your photographs must not leave the building — work
under contract, people who have not consented to being processed by a third
party, anything you would not email — this is the answer, and it is the only
answer that does not depend on trusting someone else's terms of service.

The cost is honest: a local vision model judges a photograph less well than the
cloud models do. Choose it when that trade is the right one, not by default.

### If you use Gemini or OpenAI, this is exactly what is sent

Each pass uploads **one JPEG of the photograph you selected**, 2048 px on its
longest side, together with the text prompt. Nothing else — not the original
raw file, not your catalog, not the other photographs in the folder, not your
develop history.

**The JPEG is stripped of its metadata before it is uploaded.** A file exported
from Lightroom normally carries a great deal about you and the photograph:

| Normally in the file | Sent by VenzAI |
|---|---|
| Camera body and **serial number**, lens, settings | No |
| Date and time the photograph was taken | No |
| **GPS coordinates** of where you stood | No |
| Artist, copyright, contact details | No |
| Keywords and captions you wrote | No |
| **Face regions with the names you tagged** | No |
| XMP block, including your catalog's identifiers | No |
| Original file name | No |
| The pixels, and the colour profile that makes them mean something | Yes |

VenzAI both asks Lightroom to export with minimal metadata and then opens the
file and removes every metadata segment itself, because a setting a given
Lightroom version does not recognise is ignored in silence. Each pass writes
into the log what it removed, so you can check rather than take our word:

```
Export: 3 metadata segment(s) removed before upload: APP1, APP1, APP13.
```

**If the file cannot be cleaned, the run stops.** VenzAI will not upload a file
whose contents it could not verify.

### What the provider does with it

That is between you and them, and it is worth reading before you send client
work anywhere. Both Google and OpenAI publish terms for their paid APIs about
whether submitted content is used for training; those terms are theirs to
change, not ours. VenzAI adds no analytics, contacts no server of its own, and
sends nothing anywhere except the provider you configured.

### On this machine

The exported JPEG and the generated reference images live in a VenzAI folder
inside your system temp directory. The ten most recent references are kept and
the rest deleted automatically; the settings panel has a button that empties
the folder now. Your API key is stored in the operating system keychain, not in
a preferences file and never in plain text.

---

## Checking it works

**Library ▸ Plug-in Extras ▸ Test VenzAI providers** touches no photograph. It
checks every provider's configuration and asks each service whether it answers,
then reports what it found. Run it after setting up a key, before spending a
photograph on it.

---

## When something goes wrong

The settings panel has a **Diagnostics** row:

- **Show log file** — opens the folder the log is written to.
- **Show working folder** — opens where VenzAI keeps the JPEG it sends and the
  reference image that comes back.
- **Show the reference image during a run** — stops the run to show you the
  target the analysis is working toward. Off by default. It is the only picture
  in the pipeline nobody otherwise sees, and without it a bad target and a bad
  reading of a good one look exactly the same.

VenzAI writes a detailed log of every run. The file is `VenzAI.log`:

- **Windows** — `%LOCALAPPDATA%\Adobe\Lightroom\Logs\LrClassicLogs\`
- **macOS** — `~/Library/Logs/Adobe/Lightroom/LrClassicLogs/`

The first line of every run is the build number:

```
VenzAI 1.0.0 build 60
=== VenzAI start (provider=gemini, model=..., passes=3) ===
```

Check it before anything else. Lightroom caches plug-in code until you press
Reload Plug-in, so a change on disk can be absent from the plug-in that is
running — and the symptom is a log that has not changed, which reads as "the
fix did not work" rather than "the fix is not loaded".

The log names what was asked of the model, what it answered, what was applied,
and — importantly — what Lightroom refused to keep. A line reading
`did NOT take` means a setting was requested and the photograph came back
without it, which is the difference between a model that did not propose
something and one whose proposal was overridden.

Error messages in VenzAI say which of the two kinds of problem you have: one
you can fix in the settings (a missing key, a model name that does not exist, a
server that is not running), or a defect in the plug-in. If a dialog says it is
a defect, the technical detail underneath is what the service reported, and the
log has the rest.

### Getting a photograph back

Every run creates snapshots, visible in the Develop module's Snapshots panel:

- `VenzAI - Original (provider, timestamp)` — the state before VenzAI touched
  anything.
- `VenzAI - Pass N (provider, timestamp)` — after each refinement pass.

Click one to return to it. Lightroom's normal undo works too, and because
nothing is written into pixels, nothing is ever lost.

---

## What it does not do

- It edits **one photograph at a time**. There is no batch mode.
- It does not retouch: no healing, no cloning, no object removal, no sky
  replacement. It moves develop sliders, which is a smaller and more
  recoverable thing.
- The reference image is a target, never an output. It is generated so the
  analysis has something to measure against, it lives in a temporary folder,
  and not one of its pixels reaches your photograph. VenzAI will not hand you a
  generated picture, and will not put one in your catalog.
- With a cloud provider it sends a 2048 px JPEG of your photograph, stripped of
  its metadata, to the provider you chose. With Ollama it sends nothing
  anywhere. See [Your photographs and your
  privacy](#your-photographs-and-your-privacy).

---

## Languages

English and Italian. Lightroom picks the language automatically.

## What changed between versions

[CHANGELOG.md](CHANGELOG.md), newest release first.

---

## Licence

**[PolyForm Strict License 1.0.0](LICENSE.md)** — source-available, not open
source, and the difference is deliberate.

| | |
|---|---|
| Use it for anything noncommercial | **Yes** |
| Read the source | **Yes** |
| Redistribute it | **No** |
| Publish a modified version | **No** |
| Any commercial use | **No** — ask first |

A photographer editing their own work, a student, a hobbyist, a charity, a
school or a public research body may use it freely: the licence names those
cases explicitly. Selling it, bundling it into a paid product or a paid
service, or using it as part of commercial work is not covered — that needs a
separate agreement with the licensor, which is the author.

Forks and modified copies are not permitted as a way to ship your own version.
They are permitted for one thing only: preparing a contribution to send back
here — see [CONTRIBUTING.md](CONTRIBUTING.md).

The file is the unmodified text published by the
[PolyForm Project](https://polyformproject.org), a group of licensing lawyers
writing plain-language source-available licences. Nothing in it was rewritten
here.

---

## For developers

[ARCHITECTURE.md](ARCHITECTURE.md) is the map: which module owns what, the two
rules the design rests on, and the Lightroom constraints that are not ours to
choose.

Adding a provider is one new file and one line in the registry: the processing
engine never names a provider and the settings panel builds itself from what
each driver declares. The test suite runs outside Lightroom on a Lua 5.1
runtime:

```bash
pip install -r tests/requirements.txt
python tests/run.py            # every suite
python tests/run.py delta      # only suites whose name matches
```

**Contributions are welcome**, and they need a permission the licence does not
give on its own: writing a patch means making a modified version.
[CONTRIBUTING.md](CONTRIBUTING.md) grants it — a licence to copy and modify
VenzAI for the sole purpose of preparing a contribution — and says what you
grant in return, which is the right for the author to relicense your
contribution, commercial use included. Open an issue before you write code:
acceptance is a judgement about the design, not only about the patch.

The commit history is where the reasoning lives: each message says what was
wrong and why the fix is shaped the way it is.
