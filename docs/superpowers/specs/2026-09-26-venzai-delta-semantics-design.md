# VenzAI: the model returns deltas, not absolutes

**Status:** design, awaiting review
**Date:** 2026-09-26
**Changes:** what the numbers in the model's JSON mean. The driver contract,
the error model and the settings layer are untouched; this is a change between
the model and the engine, not between the engine and a provider.

## The problem this fixes

VenzAI runs a loop: Nano Banana generates a retouched reference from the
photograph once, then each refinement pass shows the model the current
semi-processed photo plus that reference and asks what develop settings it
needs. The model answers with **absolute** slider values, which
`applyDevelopSettings` writes over whatever was there.

Two things follow from that contract, and both were observed in real runs.

**A vision model cannot observe an absolute.** Looking at a photograph it can
judge "this is still half a stop dark". It cannot read "Exposure2012 is
currently 0.35" off the pixels, because that number is not in the image. We
ask for a quantity the model has no way to measure, and it estimates one from
the block of text we pass it. The historical `Temperature = 8` defect — the
model answering a small delta where absolute Kelvin was required, which the
parser still guards against — is this mismatch surfacing.

**Zero is the destructive answer.** Shown an already-corrected photograph and
asked what it needs, the honest reply is "no exposure correction", i.e.
`Exposure2012: 0`, which erases the +0.35 that made it correct. The prompt
carries a paragraph of warnings against exactly this, and the warnings do not
always hold. A log of one run shows the sky mask taking Temperature +25, then
−50, then +40 across three passes, Dehaze +20 then −20, Exposure −0.5 then
+0.3, while values a later pass did not repeat (Highlights −30, Tint +15)
stayed underneath from pass 1. The finished region carried three contradictory
intentions at once.

Under a delta contract both problems dissolve. The model reports the remaining
distance to a fixed target, which is what it can actually see, and zero means
"leave it alone" — the safe answer instead of the catastrophic one.

## What this is, structurally

The reference image is generated **once**, at pass 1, and reused unchanged. So
the loop is a control loop with a fixed setpoint: each pass measures the error,
the plug-in integrates it. Under the absolute contract nothing made the passes
converge; under deltas the correction shrinks as the photograph approaches the
target, and convergence becomes measurable for the first time.

Part of the system already works this way. `CropAngle` and the crop bounds are
already relative — the prompt asks for the *residual* rotation and
`VenzAIProcess` composes it with the angle already applied. This design extends
an existing rule rather than inventing one.

## The contract

The JSON shape does not change. The same keys, flat, one object. What changes
is what a number **means**, and the prompt states it once, plainly: a value is
how much to MOVE a setting, not where to put it.

### Deltas

Every parameter that is a quantity:

| Group | Keys |
|---|---|
| Global tone | `Exposure2012`, `Highlights2012`, `Shadows2012`, `Whites2012`, `Blacks2012`, `Contrast2012`, `Texture`, `Clarity2012`, `Dehaze` |
| Base colour | `Temperature`, `Tint`, `Vibrance`, `Saturation` |
| Parametric amounts | `ParametricShadows`, `ParametricDarks`, `ParametricLights`, `ParametricHighlights` |
| Colour mixer | `HueAdjustment<C>`, `SaturationAdjustment<C>`, `LuminanceAdjustment<C>` for all 8 colours |
| B&W mixer | `GrayMixer<C>` for all 8 colours |
| Colour grading amounts | `ColorGrade*Sat`, `ColorGrade*Lum`, `ColorGradeBlending` |
| Detail | `Sharpness`, `SharpenRadius`, `SharpenDetail`, `SharpenEdgeMasking`, the four noise-reduction keys and their two refinements, `DefringePurpleAmount`, `DefringeGreenAmount` |
| Grain | `GrainAmount`, `GrainSize`, `GrainFrequency` |
| Vignette | `PostCropVignetteAmount`, `Midpoint`, `Feather`, `Roundness`, `HighlightContrast` |
| Local | every `local_*` inside a mask except `local_ToningHue` |

`Temperature` and `Tint` are the largest gain: "300 K warmer" is a judgement
the model can make from an image; "5,400 K" is not.

### Absolutes, and why each one

| Key | Reason |
|---|---|
| `ColorGrade*Hue` | An angle on a wheel: a position, and adding degrees needs wrap-around at 360. |
| `ParametricShadowSplit`, `ParametricMidtoneSplit`, `ParametricHighlightSplit` | Region boundaries, not amounts, and they must stay strictly increasing — a rule that is checkable on absolutes and awkward on deltas. |
| `PostCropVignetteStyle` | An enumeration (1, 2, 3). |
| `CameraProfile` | A string from a closed list. |
| `ConvertToGrayscale` | A boolean. |
| `local_ToningHue` | An angle on a wheel, for the same reason as `ColorGrade*Hue`. Its companion `local_ToningSaturation` is an amount and stays a delta. |
| `CropLeft/Top/Right/Bottom`, `CropAngle` | Already relative and already composed. Unchanged by this design. |

This list lives in **one** place in the code and is read both by the parser and
by the prompt builder. Two copies that drift apart is the most likely defect of
this whole design, and a test pins them together.

### The unit question for Temperature

On a raw file Lightroom reports `Temperature` in Kelvin (roughly 2,000–50,000);
on a JPEG it is a −100…100 scale. The current range check assumes Kelvin and is
therefore already wrong for JPEGs.

**Resolution, corrected after the first real run.** The original design
inferred the scale from the photo's current `Temperature`: above 1,000 meant
Kelvin. That is wrong, and it ruined a photograph. A raw whose white balance is
still "As Shot" reports no usable Temperature at all, so the current value read
as 0, the −100…100 scale was chosen, and the model's +18 movement was written
as an absolute 18 — which Lightroom, reading Kelvin for a raw, clamped to its
2,000 K minimum. The frame came out solid blue, and the next pass's correct
+4,500 request was then dropped by the implausibility guard, so the loop could
not climb back out.

The scale comes from the **file**, through `getRawMetadata("fileFormat")`: a
rendered format (JPG, TIFF, PSD, PNG) is the −100…100 scale, everything else is
Kelvin. An unrecognised format is treated as Kelvin, because the two mistakes
are not equal — a small number written as Kelvin destroys the picture, while a
Kelvin-sized movement on a relative scale merely overshoots and clamps.

A movement still needs something to move from. When the file is on the Kelvin
scale and the photograph reports no Kelvin, the movement is refused and named
in the log rather than written, and the plug-in sets `WhiteBalance` to
`"Custom"` so Lightroom fills in the as-shot value: one pass of delay instead
of a dead parameter or a ruined frame. Mask-local `local_Temperature` is always
on the −100…100 scale, whatever the file is.

## Accumulation

The plug-in holds the absolute state, seeded at pass 1 from what the photograph
actually reports, and writes absolutes to Lightroom — `applyDevelopSettings`
accepts nothing else.

```
new = clamp(current + delta, range(key))
```

**Clamped, never discarded.** Today a value outside its range is thrown away.
Under deltas that would be a serious bug: Clarity at 80 plus a requested +40 is
100, not "out of range, dropped". Every clamp is logged with what was asked,
where it started and where it landed.

**Implausibility guard.** A delta whose magnitude exceeds the full span of its
parameter means the model has fallen back to absolutes out of habit — a
`Temperature: 5400` where the span of a sane correction is hundreds of degrees.
That key is dropped, the log names it, and the rest of the response still
applies. This does not prevent the failure; it detects it, which is the most
that can be done from this side.

## Masks

The same rule applies to `local_*`: accumulate per region type, clamp against
`LOCAL_RANGES`, write the absolute through `setValue`.

The mask memory added earlier today changes role. It stops being "what we asked
for" and becomes the authoritative record of what each mask carries, because
`setValue` writes only the keys it is given and a parameter an earlier pass set
is still on the mask. It is reported to the model each pass as state, exactly
like the global block.

## Convergence and early exit

A pass has converged when every returned delta is zero or negligible — within
1% of that parameter's span — and no new mask is proposed.

On convergence the run stops: remaining passes are skipped, the log records the
pass number at which the photograph arrived, and the snapshot is taken as
usual. The user chose this over completing all passes regardless.

The 1% threshold is a starting value, in one named constant, expected to be
tuned once there are real runs to look at.

## Prompt changes

- The defensive paragraph about returning 0 is deleted. It exists only because
  0 is destructive under the absolute contract.
- One statement of the delta rule, and the explicit list of absolute
  exceptions, generated from the same table the parser uses.
- The current state is still reported, as information: where the settings
  stand, so the model knows when it is near a limit and which unit scale
  `Temperature` is on. It is no longer something the model must echo back.
- The self-check step gains one line: values are movements, not positions.

## Testing

Everything below runs outside Lightroom on the Lua 5.1 harness.

- Accumulation: current + delta, across two and three passes.
- Clamping at both ends, and that a clamp is not a discard.
- The implausibility guard drops only the offending key.
- Absolute keys pass through untouched by accumulation.
- `Temperature` on both unit scales.
- Mask accumulation per region type, including a key set by an earlier pass
  and not repeated.
- Convergence detection: all-zero, all-negligible, and one real value among
  zeros (which is not convergence).
- The parser's absolute-key list and the list rendered into the prompt are the
  same list.

Not testable outside Lightroom, and therefore to be checked by hand: that three
passes on one photograph now move in one direction instead of reversing, and
that a converged run stops early.

## Risks

**The model returns absolutes anyway.** The prompt is an instruction, not a
constraint. Detected by the implausibility guard and by the log; not
preventable. If it turns out to be frequent, the fallback is approach B from
the design discussion — separate `Deltas` and `Absolute` objects in the JSON —
at the cost of a nested structure that models get wrong more often.

**Oscillation.** A model that consistently overshoots could swing around the
target instead of settling. Deltas make this visible in the log for the first
time; the early-exit threshold limits the damage. No damping is designed in
now: it would be tuning a loop nobody has yet watched run.

**Drift between the two lists.** Mitigated by a single source and a test.

## Out of scope

No new settings field. No per-parameter gain or damping. No change to the
number of passes. No change to the crop and angle composition, which already
works this way. The colour-grading key mismatch found today
(`ColorGradeShadowHue` and friends reported as absent by the photograph) is a
separate defect under investigation and is not addressed here.
