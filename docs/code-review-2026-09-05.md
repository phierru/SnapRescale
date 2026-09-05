# SnapRescale code review and requirements check

Reviewed 2026-09-05 against commit `47e0a73` plus the existing uncommitted `ControlsPanel.swift` change, README, and PRD v0.8. Application code was not changed.

The solver has good evidence behind its current behavior. The app builds, but numeric validation, format retention and preview fidelity remain open issues. The README's description of an early M1/M3 vertical slice is accurate.

**Revised after owner feedback, 2026-09-05.** This is a quick Open With utility for conforming images to input requirements, including AI image workflows. That clarified intent takes precedence over older PRD requirements. Findings 1 and 7 are accepted behavior; finding 2 is deferred functionality; findings 3, 5 and 6 are confirmed issues. Finding 4 is narrowed after a focused rerun. Finding 8 remains an unbenchmarked static concern and was not addressed in the feedback. Original numbering is retained for discussion.

## Findings and disposition after feedback

### 1. Accepted — Numbered saves and explicit replacement confirmation

[Session.swift:241](/Users/francescolardieri/Projects/MyProjects/Rescale/SnapRescale/Sources/SnapRescale/Session.swift:241), [Renderer.swift:120](/Users/francescolardieri/Projects/MyProjects/Rescale/RescaleKit/Sources/RescaleKit/Renderer.swift:120)

**Owner comment:** Save As suggests increasing filename counters; explicitly choosing an existing name brings up the standard macOS overwrite confirmation. This is the desired behavior.

**Recheck:** Both Save and Save As use `OutputNaming.url`, which checks existing names and advances the counter. Save As passes that suggestion to `NSSavePanel` and writes only after the panel returns OK. The earlier runtime check verified sequential numbered saves. The native confirmation is supplied by the panel, so it need not appear as a custom alert in application code. Its observed presentation is owner-verified; this review did not independently drive the dialog.

**Revised assessment:** Withdraw the P1 defect classification and the recommendation to forbid selecting the source. The earlier report acknowledged confirmation but assigned excessive severity based on the PRD's absolute “original is never modified” wording. Explicitly confirmed replacement is accepted under the clarified product intent. Update PRD §§8 and 11 to say that default saves create a separate, collision-numbered output and Save As may replace an existing file after confirmation.

The earlier existence-check/write race is only a theoretical concurrent-writer concern, not reproduced in the intended one-shot workflow. It is not a release blocker or part of the accepted overwrite finding.

### 2. Deferred — First-frame loading is accepted for now

[SourceImage.swift:33](/Users/francescolardieri/Projects/MyProjects/Rescale/RescaleKit/Sources/RescaleKit/SourceImage.swift:33)

**Owner comment:** Current behavior is acceptable; frame selection from GIF, video and other media can be added later.

**Evidence retained:** The loader reads properties and pixels at index 0. A generated two-frame GIF loaded successfully as a single 64×32 image, with no frame-selection step. The code observation remains correct and does not need a new runtime reproduction to incorporate the scope decision.

**Revised assessment:** Remove the P1 classification and the recommendation to reject animated inputs now. Record first-frame import as the accepted current behavior and frame selection as future work. PRD §15.4 currently forbids silently using frame 1 and should be aligned with this decision. Video import is a future feature, not an existing capability established by this test. Format fallback remains a separate issue in finding 5.

### 3. P2 — Confirmed: invalid numeric input crashes instead of producing an error

[main.swift:68](/Users/francescolardieri/Projects/MyProjects/Rescale/RescaleKit/Sources/rescale/main.swift:68), [Session.swift:77](/Users/francescolardieri/Projects/MyProjects/Rescale/SnapRescale/Sources/SnapRescale/Session.swift:77), [Solver.swift:143](/Users/francescolardieri/Projects/MyProjects/Rescale/RescaleKit/Sources/RescaleKit/Solver.swift:143)

**Owner comment:** Agreed that this is an issue. The original runtime reproductions remain applicable; no relevant code changed.

The CLI accepts zero/negative sizes and non-finite Doubles. These reach square roots, divisions and trapping Double-to-Int conversions. Each of these commands terminated with signal 5 and a conversion fatal error:

```sh
RescaleKit/.build/debug/rescale --mp -1 --source 6000x4000
RescaleKit/.build/debug/rescale --mp inf --source 6000x4000
RescaleKit/.build/debug/rescale --width 0 --multiple 16 --source 6000x4000
```

The app also converts an unbounded Double text-field value to Int, and its launch parser accepts nonpositive aspect components. Validate positive, finite, representable values before solving, with overflow-safe pixel-count and output-allocation limits. Return an actionable error. Runtime reproduction covered the CLI; the app paths were inspected statically.

### 4. Narrowed P2 — Switching units rounds the input and can change the active constraint

[Session.swift:190](/Users/francescolardieri/Projects/MyProjects/Rescale/SnapRescale/Sources/SnapRescale/Session.swift:190)

**Owner comment:** Dimensions must adjust to multiples of 8 or 16, and those expected deviations are displayed in the info panel.

**Agreed:** Snapping a requested size to the selected multiple is intentional, not a solver defect. ControlsPanel displays `Solution.adjustments`, including the ideal and actual dimensions forced by the multiple. The original report should have made this existing explanation more prominent.

**Focused rerun:** Production RescaleKit was called with the same conversions as `switchSizeKind`, using a 6000×4000 source, aspect 16:9, and width 1920. No size value or multiple was manually changed between the Width and MP calculations.

| Multiple | Width result | MP value fed back by view switch | Result after switch | Snapping notes returned |
|---|---|---|---|---|
| 1 | 1920×1080 | 2.07 | 1918×1079 | None |
| 8 | 1920×1080 | 2.07 | 1920×1080 | Width 1918→1920; height 1079→1080 |
| 16 | 1920×1088 | 2.09 | 1936×1088 | Width 1928→1936; height 1084→1088 |

Two effects are involved:

- **Precision loss on switching units:** the app rounds the MP value to two decimals and stores that as a new request. With multiple 1, the exact value 2.0736 MP is replaced by 2.07 MP. The result changes even with 8/16 snapping disabled. Passing the exact MP value preserves 1920×1080 in this case. No multiple-adjustment message is emitted because there is no multiple adjustment to report.
- **Changing which value controls the solver:** Width holds one axis fixed; Megapixels frees both axes. At multiple 16, even passing the exact current pixel count (2.08896 MP) gives 1936×1088. Both the original and new dimensions already satisfy multiple 16; the new size is selected for the new optimization objective, not because the old size became invalid. The info panel does correctly explain snapping relative to that new MP request.

**Revised assessment:** The remaining P2 is the loss of precision from merely selecting another unit, independently reproduced with multiple 1. The multiple-16 behavior is a product-contract distinction: if selecting MP intentionally makes MP the new controlling input, its re-solve can be accepted and the comment “the number on screen never jumps” should be corrected. It should not be reported as broken modulo arithmetic. If the selector is meant only to change the displayed unit, preserve the controlling request until the user edits the value. In either interpretation, retain full precision internally and round only the displayed text.

This rerun exercises the production solver with the inspected session conversion logic; it is not a click-through UI test. The tests confirm numerical behavior, not an owner decision about whether selecting a view should change the controlling input.

### 5. P2 — Confirmed: “Keep original” can convert formats

[OutputFormat.swift:25](/Users/francescolardieri/Projects/MyProjects/Rescale/RescaleKit/Sources/RescaleKit/OutputFormat.swift:25)

**Owner comment:** Agreed that this is an issue. Existing code inspection and the GIF fallback probe remain sufficient; no relevant implementation changed.

Only JPEG, PNG, HEIC and TIFF are retained. Other source types fall back to JPEG, including formats beyond those four that the PRD lists as ImageIO-writable. The GIF probe confirmed `keepOriginal` resolving to `public.jpeg`. The app labels the result “Keep original (JPG),” but never explains that it is a conversion; the API provides no fallback warning.

Separate retaining the format from choosing a fallback. Disable retention when unsupported and ask the user to choose a supported output, or expose the conversion explicitly. This is independent of whether animated inputs are refused.

### 6. P2 — Confirmed: transparent padding preview does not match JPEG output

[PreviewView.swift:77](/Users/francescolardieri/Projects/MyProjects/Rescale/SnapRescale/Sources/SnapRescale/PreviewView.swift:77), [Renderer.swift:82](/Users/francescolardieri/Projects/MyProjects/Rescale/RescaleKit/Sources/RescaleKit/Renderer.swift:82)

**Owner comment:** Agreed that this is an issue. The unchanged preview and renderer paths establish the mismatch; this remains a static finding rather than a newly performed UI test.

In Pad mode the preview always shows a checkerboard under translucent padding, regardless of the selected format. The renderer composites that padding over white for JPEG. For translucent custom colors the preview and output colors also differ. The warning in ControlsPanel explains the fallback, but the main preview still depicts transparency that will not exist in the file, contrary to PRD §7's exact-preview promise.

Share the effective background/compositing policy between preview and renderer. This discrepancy is established by the two code paths; no visual UI session was performed.

### 7. Accepted — Replacing an image does not prompt to save edits

[Session.swift:144](/Users/francescolardieri/Projects/MyProjects/Rescale/SnapRescale/Sources/SnapRescale/Session.swift:144)

**Owner comment:** This is a quick right-click/Open With utility for conforming images to an expected input, including AI processing workflows. A document-style dirty check is unnecessary.

**Evidence retained:** `load` replaces the source, recenters the anchor, resets the size and clears `lastSaved`. Unsaved session settings are not retained, but opening another image does not itself write over the previous source file.

**Revised assessment:** Withdraw the P2 classification and the recommendation to add a dirty-state prompt. Immediate replacement matches the intended utility workflow. The issue is now outdated wording in PRD §8, which explicitly requests a dirty check. Remove that requirement and describe the disposable single-image session. No rerun is needed for this scope clarification.

### 8. P2 — Superseded encodes continue consuming full-resolution resources

[Session.swift:220](/Users/francescolardieri/Projects/MyProjects/Rescale/SnapRescale/Sources/SnapRescale/Session.swift:220)

Cancellation stops the task waiting for the result, but its detached `Renderer.produce` task is unstructured and continues. When encoding takes longer than changes spaced more than 120 ms apart, multiple obsolete full-size renders can run concurrently. Each allocates a target bitmap and encoded data. Cancellation correctly prevents stale results from being displayed, but does not bound resource usage.

Use a serialized latest-request-wins worker with at most one active render and one replaceable pending request. ImageIO work may not be interruptible, so cancelling task handles alone is insufficient. Separately, `load` and `write` decode/render synchronously on the main actor; large images can block the window. The concurrency issue is established statically; no memory or responsiveness benchmark was run.

## Implementation versus the PRD

These are completion gaps or contract decisions, not all regressions. The README already acknowledges several as unfinished. Owner decisions above supersede conflicting PRD text; accepted behavior is not counted as a missing implementation.

| Requirement | Current implementation | Assessment |
|---|---|---|
| Aspect presets, decimal MP, pin-respecting snapping (§§5–6) | Correct preset list; 1 MP = 1,000,000 pixels; fixture and property tests pass | Strong coverage for valid solver inputs |
| Four size views (§5) | One selected editable field plus four readouts | Expected snapping is explained in the info panel. Unit-switch precision loss remains; whether selection changes the controlling input needs an explicit contract (finding 4) |
| Log slider, detents, keyboard nudges, editable ladder (§5/M2) | Five pixel quick picks and multiple-sized steppers with Shift ×10; no size slider/preferences/detent shortcuts | M2 incomplete, as README acknowledges |
| Never upscale and dim unavailable detents (§§5, 7) | Warning only; no prevention setting; `ladderExceedsSource` is unused by the current picker | Missing. Any future availability calculation must use solved dimensions and fit policy, not just source width/height |
| Original means no crop or pad (§5) | Multiple snapping can change the aspect; renderer then crops/pads normally | Reproduced: 6000×4000 → 2048×1368 at multiple 8 discards about 0.195%. `aspect.reframes` is false, so the crop percentage is hidden and the caption can say “Whole image.” Clarify the rounding exception and report actual geometry |
| Live crop/pad preview, drag and recenter (§7) | Shared geometry and direct dragging implemented | Format-dependent padding preview differs; see finding 6 |
| One-image entry (§8) | Single Window, Open With registration, drop, Open; multiple URL drops refused | No dirty check by accepted design; PRD needs updating. No Services/Quick Action registration |
| Controls beneath preview (§8) | Controls are a right sidebar in `EditorView` | Documentation/layout mismatch; decide which design is authoritative |
| Full read list (§9) | ImageIO-only loader and `public.image` gate/open-panel filter | PDF is not supported by this path despite being listed. SVG and the full RAW list were not tested; the PRD's platform-wide list is not an app-level compatibility guarantee |
| Full write list and encoder options (§9/M4) | Four output formats; JPEG/HEIC quality; fixed 8-bit sRGB CGContext and high interpolation quality | No WebP/AVIF/GIF/JP2/BMP/PDF output selection, lossless/effort/progressive/subsampling/interlace/bit-depth controls, or selectable resampling |
| Metadata/GPS/ICC controls (§10/M1) | No metadata dictionaries retained for export; renderer always uses 8-bit sRGB; orientation transform requested during decode | Metadata/color policies incomplete, as README acknowledges. Orientation handling exists, but full orientation/color corpus coverage is absent |
| Collision counters and source protection (§11) | Default naming adds counters; Save reveals in Finder | Numbered suggestions verified; owner confirms native replacement dialog. Explicit replacement is accepted; PRD absolute protection wording is stale |
| Presets and target bytes (§12/M4–M5) | No preset persistence/editor or target-file-size search | Planned work; v1 inclusion is inconsistent in the PRD |
| CLI/Shortcuts/headless batch (§13) | Throwaway CLI with `--write`; no presets/JSON/batch/Shortcuts | Acceptable as deferred v2 scope. Current CLI is not the future interface shown in §13 |

## README and PRD inconsistencies

**Additional alignment required after feedback:** revise §§8/11 to allow explicitly confirmed Save As replacement, revise §15.4 to accept first-frame import until frame selection is implemented, and remove the §8 dirty-check requirement. For §5, distinguish expected lattice snapping from rounding on unit selection and specify whether selection changes the controlling input. These documentation changes are recommendations here; the PRD itself has not been edited.

1. **README contradicts itself about writing files.** [README:45](/Users/francescolardieri/Projects/MyProjects/Rescale/README.md:45) says the CLI cannot write pixels; its status section says it can. The code and runtime checks confirm writing with `--write`. Document the flag and provide a writing example; keep the distinction that the default invocation only reports a solve.
2. **README version is stale.** [README:63](/Users/francescolardieri/Projects/MyProjects/Rescale/README.md:63) says PRD v0.7; the PRD is v0.8. [PRD:4](/Users/francescolardieri/Projects/MyProjects/Rescale/docs/PRD.md:4) also says the bundle ID is still to be minted, although Info.plist declares `com.phierru.SnapRescale`.
3. **The v1 boundary is contradictory.** [PRD:348](/Users/francescolardieri/Projects/MyProjects/Rescale/docs/PRD.md:348) promises WebP in v1, but [PRD:433](/Users/francescolardieri/Projects/MyProjects/Rescale/docs/PRD.md:433) defines v1 as M0–M3 and places WebP in M4. Presets and byte-target presets are described as shipped defaults but depend on M4/M5. Choose one release checklist before treating these as v1 acceptance failures.
4. **Five detents still have four-detent prose and shortcuts.** [PRD:148](/Users/francescolardieri/Projects/MyProjects/Rescale/docs/PRD.md:148) lists five; nearby prose says four and specifies only ⌘1–⌘4. Assign the fifth shortcut and update the counts.
5. **The milestone still requires the removed anchor grid.** [PRD:266](/Users/francescolardieri/Projects/MyProjects/Rescale/docs/PRD.md:266) explicitly removes it; M3 at line 429 still includes it. The code follows the newer dragging-only decision.
6. **The byte-target cross-reference is broken.** [PRD:316](/Users/francescolardieri/Projects/MyProjects/Rescale/docs/PRD.md:316) references a target-file-size control in §5, which does not define one. Specify it under output encoding and align it with M4.
7. **The solver objective is described incorrectly.** [PRD:179](/Users/francescolardieri/Projects/MyProjects/Rescale/docs/PRD.md:179) says pixel-count deviation only breaks aspect-error ties. `Solver.snap` minimizes a weighted sum of squared log errors with a nonzero pixel weight, so pixel error can change the winner without an aspect tie. The prototype agrees with the implementation. Update the prose rather than claiming the parity fixture verifies the stated tie-breaking contract.
8. **The future CLI example is incompatible with the prototype CLI.** [PRD:413](/Users/francescolardieri/Projects/MyProjects/Rescale/docs/PRD.md:413) uses quality 80, a glob and preset flags; current quality is 0–1, writing requires `--write`, and repeated positional paths overwrite `imagePath` so only the last is used. Since §13 explicitly defers the shipped CLI to v2, label the example as proposed syntax rather than current usage.

The v1 window-opening Services entry in §8 and the v2 headless preset Quick Action in §13 are distinct features, so those paragraphs need not contradict each other. Only the former is currently an unmet v1 entry requirement.

## Verification and limits

**Follow-up verification:** re-read `saveAs`, `OutputNaming`, `switchSizeKind`, and the ControlsPanel adjustment rendering. Ran `swift test --package-path /tmp/rescale-review-20260905 --filter reconsiderSizeViews`: passed, with the multiple 1/8/16 results and exact-MP comparison recorded in finding 4. The earlier broad build/test results below were not rerun because the product code had not changed. The owner's observed native replacement confirmation is attributed to their UI check.

- `swift test --package-path RescaleKit`: **20 tests passed**, including the 5,940-case parity fixture and property checks over 20,000 generated samples.
- Regenerated the Python fixture in memory and compared parsed JSON: **identical** to the committed fixture.
- `swift build --package-path SnapRescale` and the RescaleKit build: **passed**.
- Disposable Swift tests generated PNG/GIF inputs and exercised production RescaleKit. They confirmed animation flattening, Keep-original fallback, size-view drift, and the small Original-aspect crop.
- Transparent PNG → JPEG corner samples were white for Crop, Pad and Stretch on this machine. A suspected black-background defect was therefore excluded.
- Two CLI `--write` runs produced `alpha_32x16.png` and `alpha_32x16_2.png`, verifying real encoding and sequential collision counters.
- Invalid-size CLI crash reproductions are listed above. Temporary probes and fixtures are under `/tmp/rescale-review-20260905`; they were not added to the product test suite.

Swift compilation and ImageIO fixture operations required execution outside the workspace sandbox; the approved retries passed. The review did not launch the UI, overwrite a source, benchmark large-image workloads, test notarisation/installation, or run a full RAW/CMYK/wide-gamut/EXIF-orientation corpus. Static findings are identified as such. Existing repository tests cover solver behavior, not the image/session defects above.

**Revised action order:** fix numeric validation (3), misleading format retention (5), and padding preview fidelity (6); retain full precision during unit switching (4). Clarify the selector contract before changing its multiple-16 behavior. Findings 1 and 7 require documentation alignment, not added restrictions or prompts. Finding 2 belongs in future frame-selection work. Finding 8 remains unchanged pending workload measurement. No product fixes were made during this review update.

---

## Resolution log (coding assistant, 2026-09-05)

Fixed against the revised action order; verified by the kit suite (25 tests) and by launching the app.

| Finding | Status | Where |
|---|---|---|
| 1 Numbered saves, explicit replacement | Accepted; PRD §§8, 11 reworded | `docs/PRD.md` |
| 2 First-frame import | Deferred; PRD §15.4 records the decision | `docs/PRD.md` |
| 3 Invalid numeric input traps | **Fixed.** `Limits`, `SizeParameter.validate/clamped`, `ResizeRequest.validate(for:)` checking the unclamped ideal; solver never traps; CLI and app report | `RescaleKit/Sources/RescaleKit/Validation.swift`, `Solver.swift`, `rescale/main.swift`, `Session.swift` |
| 4 Unit switch precision | **Fixed.** Full-precision carry-over; selection contract stated in PRD §5 and in code comments | `Session.switchSizeKind`, `docs/PRD.md` |
| 5 Keep original converts | **Fixed.** `resolvedType` is optional; menu item disabled with reason; fallback to PNG/JPEG with a warning; CLI refuses | `OutputFormat.swift`, `Renderer.swift`, `ControlsPanel.swift`, `Session.load` |
| 6 Pad preview vs output | **Fixed.** `RenderSpec.padNeedsAlpha(sourceType:)` shared by renderer and preview | `Renderer.swift`, `PreviewView.swift` |
| 7 No dirty check | Accepted; PRD §8 reworded | `docs/PRD.md` |
| 8 Superseded encodes | **Fixed.** Latest-wins worker, one render in flight; decode moved off the main actor | `Session.scheduleEncode`, `Session.load` |
| Original + multiple sliver crop | **Fixed.** `reframes` now derives from solved geometry, so the crop % shows | `Session.reframes` |
| Unused `ladderExceedsSource` | Removed | `Session.swift` |
| README / PRD inconsistencies 1–8 | **Fixed** (README v0.10, CLI `--write` documented; PRD: bundle ID, five detents ⌘1–⌘5, M3 without anchor grid, target-file-size defined in §11, solver objective prose, CLI example labelled proposed, WebP moved to M4) | `README.md`, `docs/PRD.md` |

Not addressed in this batch: Services/Quick Action registration (§8), "Never upscale" setting, encoder options, metadata/colour (§10) — all still open milestone work.
