# SnapRescale 1.0 — MVP release review

**Review by OpenAI Codex**  
**Date:** 2026-09-06  
**Baseline:** commit `1addb17`, version 1.0 (1), plus the existing uncommitted Roadmap edit.  
**Scope:** code correctness, public-source licensing/provenance, Mac App Store readiness, and README clarity.

This is a new review of the current MVP, not a repetition of the September 5 PRD-gap review. Unimplemented PRD requirements are deferred to the Roadmap. Confirmed Save As replacement, immediate replacement of the current image, first-frame import, and selecting a different controlling size input remain accepted product decisions.

## Assessment

The app builds and all **41 repository tests pass**. Several previous findings have been addressed: ordinary invalid numeric input is clamped/reported, size switching retains full precision, unsupported source formats receive an explicit fallback on load, and padding preview uses the renderer's alpha policy. The encoder now bounds concurrent preview renders, but its queue has a source-identity defect.

There are still release-relevant bugs in overlapping image loads, preview byte counts, and presets. These concern features already in the MVP, not missing Roadmap features. I recommend fixing C1–C6 below before promoting the release broadly. C7 is a smaller settings defect.

**Licensing conclusion:** I found no affirmative evidence of copied ComfyUI implementation code in the compared portions. The current dependency structure and materially different implementation support an MIT release. This is a qualified provenance assessment, **not a legal opinion or a worldwide non-infringement clearance**: authorship history, asset origins, trademarks and patents cannot be conclusively cleared from this repository. The wording “ported from ComfyUI” should be reconciled with the independent-implementation claim.

The README explains the central idea, but still reads like a development diary. It needs an end-user introduction, accurate release status, a clear limitations paragraph, and complete build prerequisites.

## A. Code findings

### C1 · P1 — Overlapping image loads can restore an older image

[Session.swift:236](/Users/francescolardieri/Projects/MyProjects/Rescale/SnapRescale/Sources/SnapRescale/Session.swift:236)

Every `load` starts an independent task. On completion it assigns `source`, preview, size and flags unconditionally. There is no load generation/token or check that this is still the most recently requested URL.

**Trigger:** open a large/slow image A, then open/drop a small image B while A is decoding. If B finishes first, the window shows B; when A finishes, it replaces B. Save can then export A even though B was the last image selected. One task can also clear `isLoading` while another still runs. Saves remain enabled for the previous source during a replacement load.

**Recommendation:** identify each load request; commit results, errors and loading state only for the current generation. Disable saving while replacement is pending, or define an explicit save snapshot. Cancellation alone does not stop synchronous ImageIO decoding.

**Evidence:** static control-flow finding. The completion-order race was not forced in a live UI test.

### C2 · P2 — Background byte count can belong to the previous image

[Session.swift:346](/Users/francescolardieri/Projects/MyProjects/Rescale/SnapRescale/Sources/SnapRescale/Session.swift:346)

The encoding worker captures `source` when first started, but the pending queue stores only `RenderSpec`. If B replaces A while that worker is running or in its 80 ms delay, B's new spec is rendered against captured source A. When the queue drains, those bytes are displayed as B's output size.

**Reproduced:** load a white PNG, then a patterned PNG within the delay. The current source was `pattern.png`; the UI-model byte count was **620**, matching the old white source. Rendering the current source/spec produced **832** bytes. This was repeated with copied, otherwise unchanged Session code in an isolated test package.

**Recommendation:** queue an immutable `(source, spec, generation)` job and publish a result only if its source and settings still match the current session. Keep the existing single-worker bound. Saving independently renders the current source, so this finding concerns the advertised real byte count, not evidence that the save encoder itself uses the old source.

### C3 · P2 — An editable preset can crash the preset menu

[Preset.swift:44](/Users/francescolardieri/Projects/MyProjects/Rescale/RescaleKit/Sources/RescaleKit/Preset.swift:44), [Preset.swift:66](/Users/francescolardieri/Projects/MyProjects/Rescale/RescaleKit/Sources/RescaleKit/Preset.swift:66)

Preset decoding checks JSON types but not semantic bounds. A file with `"quality": 1e100` is valid JSON and successfully decodes. `summary` converts `quality * 100` to Int without checking range; the preset menu evaluates this for its help text. Applying such a preset also exposes an unsafe quality readout in ControlsPanel.

**Reproduced:** decode a JPEG preset with that quality and evaluate `summary`. The isolated test process terminated with signal 5: Double-to-Int value greater than `Int.max`. This is not hypothetical NaN JSON; `1e100` is a finite, decodable number.

**Recommendation:** validate a preset before admitting it to the store: finite quality in 0…1, legal size/aspect, and supported app fit policy. Reject/report the offending file without losing other presets. Make display formatting non-trapping too. Hand editing/sharing JSON is an advertised MVP capability, so invalid files need a recoverable path.

### C4 · P2 — Different preset names silently overwrite each other

[Preset.swift:69](/Users/francescolardieri/Projects/MyProjects/Rescale/RescaleKit/Sources/RescaleKit/Preset.swift:69), [PresetStore.swift:36](/Users/francescolardieri/Projects/MyProjects/Rescale/SnapRescale/Sources/SnapRescale/PresetStore.swift:36)

Filename sanitization is many-to-one. Both `A:B` and `A/B` become `A-B.json`. Saving the second atomically replaces the first, even though the visible names differ and no replacement is requested.

**Reproduced:** save both names with different widths in an isolated store; only `A/B` remains. Case-only names can similarly collide on a typical case-insensitive Mac volume. A related issue is that delete derives a filename from the embedded name rather than retaining the loaded file URL, so hand-renaming the file/name independently can make delete ineffective or target another file.

**Recommendation:** use a stable identifier/unique filename and retain each file's actual URL. Handle intentional replacement by name explicitly; do not rely on a sanitized name as a unique key.

### C5 · P2 — Built-in presets can re-enable an unwritable “Keep original”

[Session.swift:36](/Users/francescolardieri/Projects/MyProjects/Rescale/SnapRescale/Sources/SnapRescale/Session.swift:36), [Session.swift:263](/Users/francescolardieri/Projects/MyProjects/Rescale/SnapRescale/Sources/SnapRescale/Session.swift:263)

Loading a GIF/WebP/RAW correctly selects a writable fallback. Applying a preset later assigns `preset.format` directly and does not run the same resolution logic. The shipped Thumbnail and Social 16:9 presets use Keep original. The format picker disables that option for unsupported sources, but programmatic preset application bypasses it.

**Reproduced:** import a still GIF, let loading select its fallback, then apply Thumbnail. `Renderer.produce` fails with “GIF cannot be written; choose JPEG, PNG, HEIC or TIFF.” This is unrelated to deferred animation support; the fixture has one frame.

**Recommendation:** resolve unsupported retention through one shared path used by both load and preset application, preserve an explicit fallback notice, and keep the UI selection valid. Update/clear that notice when a user later selects another format.

### C6 · P2 — Extreme aspect ratios can still crash the solver

[Solver.swift:111](/Users/francescolardieri/Projects/MyProjects/Rescale/RescaleKit/Sources/RescaleKit/Solver.swift:111), [Solver.swift:133](/Users/francescolardieri/Projects/MyProjects/Rescale/RescaleKit/Sources/RescaleKit/Solver.swift:133)

Limits are applied before the pinned axis is snapped. Snapping a tiny width upward can derive a height beyond the edge limit. `window` then filters out every candidate, but `snap` assumes `widths[0]` and `heights[0]` exist.

**Reproduced command:**

```sh
RescaleKit/.build/debug/rescale --width 1 --aspect 1:10000 --multiple 8 --source 100x100
```

It passed input parsing/validation and terminated with signal 5, “Index out of range.” The initial ideal is 1×10000; holding snapped width 8 derives height 80000, beyond 65536. A similarly thin source under Original or a hand-edited aspect preset can reach the same engine path; the preset picker itself does not offer that ratio.

**Recommendation:** validate feasibility after pinning and make candidate search total when the legal window is empty. Return a clear limit error or a documented legal result rather than indexing an empty array. Include this case in validation tests.

### C7 · P2 — “Defaults for a new image” do not apply to the next image

[Session.swift:20](/Users/francescolardieri/Projects/MyProjects/Rescale/SnapRescale/Sources/SnapRescale/Session.swift:20), [Session.swift:246](/Users/francescolardieri/Projects/MyProjects/Rescale/SnapRescale/Sources/SnapRescale/Session.swift:246)

Default multiple and quality are read once when the shared Session is created. Changing them in Settings and opening another image in the same app process does not apply them; `load` resets width/anchor but leaves multiple and quality unchanged. This conflicts with the Settings label “Defaults for a new image.”

**Recommendation:** apply defaults at the new-image boundary, with launch/preset overrides taking precedence, or label them honestly as defaults for the next app launch. Static finding; no preference values were changed during the review.

### Smaller risks to track

- **Save still blocks the main actor.** [Session.swift:394](/Users/francescolardieri/Projects/MyProjects/Rescale/SnapRescale/Sources/SnapRescale/Session.swift:394) synchronously re-renders and encodes. Large outputs can freeze the window, despite background preview encoding. No latency benchmark was performed; move production encoding off the main actor with visible saving state.
- **One-shot behavior uses a three-second timing heuristic.** [Session.swift:230](/Users/francescolardieri/Projects/MyProjects/Rescale/SnapRescale/Sources/SnapRescale/Session.swift:230) cannot reliably distinguish launch intent from a later external open. Slow cold launches may stay open; quickly opening externally after a normal launch may set quit-after-save. Use lifecycle intent rather than elapsed wall time.
- **The 500 MP limit is expensive, not a memory guarantee.** One target bitmap approaches 2 GB before source, intermediates and encoded data. Renderer itself accepts arbitrary RenderSpec dimensions; it does not enforce Limits. Keep this as robustness/performance work, not proof of a reproduced memory crash.

## B. Licensing, provenance and publication

### B1 — MIT fits the intended distribution, subject to ownership

The root [LICENSE](/Users/francescolardieri/Projects/MyProjects/Rescale/LICENSE) contains the standard MIT grant and Francesco Lardieri's copyright notice. MIT permits redistribution, modification and sale; it does not require you to charge for the app. It also permits other people to sell their copies. Preserve the notice and permission text in redistributed copies. A free App Store price does not remove third-party obligations. [MIT licence text](https://opensource.org/license/mit).

The Swift manifests declare only the local RescaleKit dependency. The inspected code uses Apple frameworks; no ComfyUI, PyTorch, libwebp or other bundled third-party runtime dependency was found. XcodeGen and `rsvg-convert` are invoked as build tools, not linked into the application. XcodeGen is MIT-licensed. Using a build tool is different from distributing that tool; do not describe the app as containing libwebp until it actually does. [XcodeGen licence](https://raw.githubusercontent.com/yonaskolb/XcodeGen/master/LICENSE).

The archive's Resources directory contains the icon and asset catalog, not an offline licence file. About links to the GitHub licence. Bundle the full licence for a self-contained release. Since the currently identified copyright is yours, I am not classifying omission of your own licence text from your binary as infringement of somebody else's rights; it is a clarity/distribution improvement, and becomes more important with contributions or dependencies.

### B2 — ComfyUI: no copying established, but “ported” is misleading

ComfyUI publishes GPLv3. I compared the local referenced `nodes_resolution.py` and relevant resize helpers in `nodes_post_processing.py` against the Python prototype, Swift solver and geometry/renderer. The inspected local upstream checkout is commit `7fd919f0caff66a52289ea5b19cb6eaca0da04ef`. [Upstream licence](https://raw.githubusercontent.com/comfyanonymous/ComfyUI/master/LICENSE), [resolution node](https://github.com/comfyanonymous/ComfyUI/blob/7fd919f0caff66a52289ea5b19cb6eaca0da04ef/comfy_extras/nodes_resolution.py), [resize helpers](https://github.com/comfyanonymous/ComfyUI/blob/7fd919f0caff66a52289ea5b19cb6eaca0da04ef/comfy_extras/nodes_post_processing.py).

The material differences matter: ComfyUI's resolution node directly rounds each dimension with 1024² pixels/MP; SnapRescale uses decimal MP, a pin-respecting weighted lattice search, and a separate ImageIO/CoreGraphics pipeline rather than tensor resize helpers. The Python prototype contains its own constraint selection and search structure. I did not identify a translated upstream function body in those comparisons. Shared aspect names and elementary geometric formulas are the principal visible overlap.

Copyright protects the expression of software, not merely its underlying ideas/algorithms. Both Swiss IPI guidance and the US Copyright Office draw that distinction. That supports reimplementing the resizing idea, but does not by itself prove every part of a program independently authored. [Swiss IPI](https://www.ige.ch/en/protecting-your-ip/copyright/the-basics), [US Copyright Office](https://www.copyright.gov/register/tx-programs.html).

A translation of protected GPL code into Swift would still raise GPL obligations; changing language or adding a credit would not make it MIT. The GNU FAQ explicitly treats code translation as modification. App Store distribution can introduce additional licence compatibility issues for copyleft components, as WIPO discusses; making the app free is not a workaround. [GNU translation FAQ](https://www.gnu.org/licenses/gpl-faq.en.html#TranslateCode), [WIPO mobile-app open-source guidance, §4.3.5](https://www.wipo.int/export/sites/www/mobile-apps/en/docs/wipo-tool-open-source.pdf).

**Recommended wording:** “Inspired by ComfyUI's Resize Image/Mask and Resolution Selector nodes. SnapRescale implements its own resizing solver and macOS image pipeline.” Retain factual acknowledgement. Reserve “ported from” for the Swift solver's relationship to this repository's own Python prototype. Keep a short provenance record of the upstream version examined and development history. If any source or generation history reveals direct code translation, obtain permission or specialist advice before representing that material as MIT; merely rewriting the attribution is not a licence fix.

The reference document says it quotes no code; it does quote short tooltip text and labels. That is not the same as copying a function, but a blanket claim that nothing expressive was reused is stronger than the evidence supports. Keep quotations attributed and the behavioural summary in your own words.

### B3 — No affirmative infringement finding; remaining clearance limits

The icon sources are simple SVG geometry and a gradient; the tracked tree contains no sample photographs, third-party logos or downloaded fonts. Nothing in the inspected files establishes an infringing asset. However, SVG shape inspection cannot establish who originally drew it. Keep an origin/permission record for the icon and any screenshots or photos added to the public listing. Verify your right to license contributions and any code created under employment/contract obligations; commit authorship alone is not proof of ownership.

“SnapRescale” and the generic aspect labels did not yield an established infringement claim in this review. **No formal trademark similarity search or patent freedom-to-operate search was completed.** Check relevant marks in your distribution markets if you need clearance; a GitHub name or an exact-name web search is insufficient. Swiss IPI expressly warns that similar spellings, sounds and designs can conflict and that a basic database search cannot conclusively exclude those conflicts. [Swissreg search limitations](https://www.ige.ch/en/services/digital-resources/databases-and-directories/swissreg/trade-mark-database).

Referencing ComfyUI, Apple and Parallels to explain compatibility/inspiration is not, by itself, evidence of infringement. Avoid presenting the app as endorsed by those parties or borrowing their branding. I recommend removing the disparaging competitor comparison for clarity and tone, not because this review established it unlawful.

### B4 — App Store privacy link is missing inside the app

[AboutAndHelp.swift:4](/Users/francescolardieri/Projects/MyProjects/Rescale/SnapRescale/Sources/SnapRescale/AboutAndHelp.swift:4)

The policy exists in the repository and submission draft. About/Help/Settings have no explicit Privacy Policy link. Add one in an accessible place. Apple guideline 5.1.1(i) requires a link both in App Store Connect metadata and inside the app. This is a current submission-compliance gap, not a deferred feature. [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/).

The inspected code has no network client/analytics integration, and sandbox entitlements omit network access. “Data not collected” is consistent with that architecture. The policy's “does not … store … any personal data” is too absolute: the app writes user images and locally stores folder paths/security-scoped bookmarks, as well as presets/preferences. Prefer “We do not collect or transmit your images or personal data” and explain that local processing and optional folder permissions remain on the Mac. Mention Forget All and that external help/support links open the browser. Local processing is not the same as developer collection.

Public GitHub repository, support and privacy URLs returned HTTP 200 during this review. The Roadmap records a submission waiting for review; I did not independently inspect App Store Connect or establish that the app is already publicly downloadable.

### B5 — Avoid two unsupported release blockers

- No PrivacyInfo.xcprivacy file was found, but Apple's required-reason API overview explicitly scopes that requirement to iOS/iPadOS/tvOS/visionOS/watchOS. I am **not** calling its absence a native-macOS rejection solely because the app uses UserDefaults. Revisit if platform scope or Apple policy changes. [Apple required-reason API guidance](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api?changes=_2_8&language=objc).
- Do not infer broken bookmarks solely from the absence of `bookmarks.app-scope`. Apple DTS explains that user-selected read/write entitlements are also accepted for this purpose. Persistent grants still deserve an end-to-end relaunch test, but the missing extra entitlement alone is not an established defect. [Apple DTS clarification](https://developer.apple.com/forums/thread/798402?answerId=855880022).

## C. README and release-copy review

### C-README1 — Lead with the app, then the implementation

[README.md:5](/Users/francescolardieri/Projects/MyProjects/Rescale/README.md:5)

The headline is memorable, but a new visitor first learns which competing products disappointed you, then encounters ComfyUI and internal architecture. They should first learn what it does, who it is for, and how to use/get it. Move the inspiration paragraph into Acknowledgements and place the developer sections below usage.

Suggested opening:

> SnapRescale is a free, native macOS utility for resizing one image to the dimensions your workflow needs. Choose an aspect ratio and set width, height, megapixels or scale. Snap dimensions to multiples of 8 or 16 for AI image workflows, or use ordinary pixel dimensions.
>
> Preview the crop before saving, drag to adjust the framing, or pad with a chosen colour. Save useful settings as presets. Images are processed locally, without accounts or uploads.
>
> Requires macOS 26 or later. Open an image from Finder with Open With → SnapRescale, or launch the app and drop an image onto its window.

Use “App Store release pending” until the public listing is confirmed, then add its actual download link. Do not invent a store link. State Apple Silicon support according to what has actually been built/tested; do not promise Intel compatibility based only on source portability.

### C-README2 — Replace stale milestone status with current capabilities

[README.md:89](/Users/francescolardieri/Projects/MyProjects/Rescale/README.md:89)

“First vertical slice” and “presets and packaging … still to do” are stale. Presets, settings, About/Help, icons, sandboxing and release scripts are present. Replace the status paragraph with a short “Current release” statement and link future work to ROADMAP.md. Historical M0–M5 labels are useful in the PRD, not necessary for first-time users.

### C-README3 — Explain current output behavior prominently

Do not count metadata controls, WebP or batch as missing MVP functionality. **Do disclose the behavior users get now:** output is 8-bit sRGB; source EXIF/GPS/XMP and AI workflow metadata are not carried through; only the first frame is used; the app handles one image; output choices are JPEG/PNG/HEIC/TIFF. Explain that source badges describe what was detected, not what will be preserved or cryptographically verified. Link the Roadmap for preservation controls, frame selection and more formats.

This is especially relevant to AI-image users: resizing a PNG currently removes the embedded workflow needed to reopen its generation graph. That is an accepted limitation which must be understandable before saving, even though implementation is deferred.

### C-README4 — Add a three-step usage section and a screenshot

Show: open/drop → choose ratio/size and inspect framing → Save. Say that Save opens a prefilled panel by default, and explain the optional silent-save preference. State the intended Finder one-shot lifecycle separately from opening the app normally. Describe multiple 1 as no 8/16 snapping and identify scale as the fourth input view. Use one screenshot made from an image you have permission to distribute.

The promise “any ratio” also merits precision: the app picker offers Original plus eight presets; it does not provide a custom-ratio field. Original can preserve an arbitrary source ratio. Prefer “Choose a ratio…” in explanatory copy rather than implying arbitrary custom aspect entry in the UI.

### C-README5 — Clean-clone build prerequisites are incomplete

[Scripts/make-icns.sh:11](/Users/francescolardieri/Projects/MyProjects/Rescale/Scripts/make-icns.sh:11), [README.md:42](/Users/francescolardieri/Projects/MyProjects/Rescale/README.md:42)

Generated icons are gitignored, so the first app build calls `rsvg-convert`. The README mentions XcodeGen but not this required command. State the full Xcode/Swift requirement near the build instructions, require `rsvg-convert` from librsvg, and list Python 3 for icon generation. Distinguish the simple dev build from signing/submission steps tied to your Apple team. This is a static clean-clone prerequisite check; I did not install dependencies or rebuild the whole archive from a fresh clone.

The opening example should be `open -a build/SnapRescale.app photo.heic`; the existing `open build/SnapRescale.app photo.heic` opens two items and does not explicitly route the photo to SnapRescale. The CLI examples correctly distinguish solve-only from `--write` now.

### C-README6 — Separate user installation from maintainer release commands

[README.md:47](/Users/francescolardieri/Projects/MyProjects/Rescale/README.md:47)

Move archive/notarisation instructions to a maintainer document. Users should see a download route before commands that require signing identities. Note that the DMG's ad-hoc fallback is for local testing, not an ordinary trusted download. `appstore.sh` without UPLOAD exports a package; its README “validate” claim is stronger than an explicit validation step in the script. Also `UPLOAD=0` currently enables upload because the script tests nonempty text, not equality to 1; document the unset/set contract or test exactly `1`.

### C-README7 — Align acknowledgement and listing language

[README.md:104](/Users/francescolardieri/Projects/MyProjects/Rescale/README.md:104)

“One selector for every resize intent” and “crop-or-stretch … only honest answers” describe the inspiration, not the current Crop/Pad app. Use the shorter independent-implementation acknowledgement from B2. The public README should not require familiarity with ComfyUI to understand the tool.

The adjacent [APP-STORE.md](/Users/francescolardieri/Projects/MyProjects/Rescale/docs/APP-STORE.md) also needs correction before reuse:

- Its subtitle is **33 characters**, although labelled 30. Apple's limit is 30. “Resize images, snap to 8 or 16” is a shorter alternative. [App information reference](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information).
- `batch` is listed as a keyword although the MVP is single-image. Remove it. Apple requires accurate keywords and discourages packing metadata with other app names to game discovery; use ComfyUI mentions for genuine workflow explanation rather than keyword stuffing. [App Review Guidelines, §2.3.7](https://developer.apple.com/app-store/review/guidelines/).
- “Presets bundle every setting” overstates the current Preset type: it stores geometry/encoding settings, not composition grid, saving preferences or crop anchor. Say “size and export settings.”
- The checklist still refers to future programme membership/submission, while the Roadmap records submission. Treat it as a draft, not evidence of live store configuration. I did not alter a submission or upload anything.

Recommended README order: brief introduction → screenshot → requirements/install status → three-step usage → current features and limitations → build/test instructions → Roadmap → licence/acknowledgements/support.

## Verification and limitations

| Check | Result |
|---|---|
| `swift test --package-path RescaleKit` | 41 tests in 6 suites passed, including solver parity, validation, metadata and preset tests |
| `swift build --package-path SnapRescale` | Passed |
| Isolated session/store probes | Old-source byte count, preset-name collision and Keep-format preset failure reproduced |
| Malformed preset summary | Isolated test runner intentionally reproduced signal-5 crash |
| Extreme-ratio CLI | Signal-5 empty-array crash reproduced |
| Public repository/support/privacy URLs | HTTP 200 |
| Tracked-file private-key/AWS-key/GitHub-token pattern scan | No matches; limited pattern scan, not a full history/secret audit |
| Runtime dependencies, licence, tracked assets, build scripts | Inspected; no bundled GPL runtime dependency found |
| ComfyUI comparison | Local referenced upstream nodes compared with the prototype/solver/rendering design; no translated function body identified |

Tests are under `/tmp/rescale-mvp-review`. They use production RescaleKit and copies of Session, AppSettings, CompositionGrid, FolderAccess and PresetStore; only the copied PresetStore's default storage directory was redirected to `/tmp`. No production source or user preferences were changed. Test passes in that harness establish the explicitly asserted problematic behavior; they are not a claim that the bugs are fixed. Swift tests/builds used approved compiler-cache access outside the workspace sandbox.

The graph service returned “Transport closed,” so code discovery fell back to direct source inspection. The existing Roadmap edit was preserved. No UI click-through, full fresh-clone archive, new signing/upload, App Store Connect inspection, sandbox persistence relaunch test, large-image performance benchmark, full RAW/CMYK/HDR/orientation corpus, formal trademark search or patent search was performed.

This document is review evidence and recommendations only. It does not change application behavior, the licence, README, PRD, Roadmap or submitted build. The September 5 review remains historical; use this review for the current release baseline.

---

## Resolution log (coding assistant, 2026-09-07)

All items were acted on against `1addb17`. Verified by the kit suite (43
tests) and by driving the sandboxed build; static where noted.

| Finding | Status | Where |
|---|---|---|
| C1 Overlapping loads | **Fixed.** Loads are numbered; only the latest commits source, preview, size, flags and errors. `canSave` is false while a load is pending. | `Session.load`, `Session.canSave` |
| C2 Byte count from previous image | **Fixed.** The worker queues `(source, spec)` and publishes only if the session still shows that source with that spec. | `Session.scheduleEncode` |
| C3 Editable preset crashes | **Fixed.** `Preset.validate()` (finite quality 0…1, legal size/aspect, crop/pad, sane colour); the store skips bad files and lists them in the Preset menu as “Skipped: …”; all quality readouts go through non-trapping `Preset.percent`. Test with `"quality": 1e100`. | `Preset.swift`, `PresetStore.swift`, `ControlsPanel.swift` |
| C4 Name/file collisions | **Fixed.** Files tracked by real URL; a new name gets a fresh, non-colliding file name; saving under an existing name replaces that preset; a second file claiming an existing name is reported, not merged. *(static; store has no UI test)* | `PresetStore.swift` |
| C5 Presets re-enable unwritable Keep original | **Fixed.** One `resolveFormat()` used by load and preset application; the note clears when the user picks a writable format. Verified: GIF + Thumbnail preset writes a JPEG. | `Session.resolveFormat`, `Session.apply` |
| C6 Extreme aspect crash | **Fixed.** Clamp runs after the pinned axis is held; the lattice window is never empty (degrades to the largest legal value); `validate(for:)` checks the held ideal. The reported command now prints “8×80000 is too large to render”. Tests cover five extreme cases × three multiples. | `Solver.swift`, `Validation.swift` |
| C7 Defaults for a new image | **Fixed.** Multiple and quality are applied at the load boundary; `--multiple` and `--preset` still override. Verified in the sandboxed build. | `Session.load` |
| Save blocks the main actor | **Fixed.** Save encodes off the main actor with a saving indicator; buttons and menu items disable while saving or loading. | `Session.write` |
| Three-second one-shot heuristic | **Open.** Kept for now; an external open inside the first seconds is the only signal available for Services launches. Noted in the roadmap. | — |
| 500 MP limit / renderer | **Partly.** The renderer now refuses specs outside `Limits` instead of allocating. The limit remains a cost bound, not a memory guarantee. | `Renderer.render` |
| B1 Licence in the bundle | **Done.** Licence text in Resources of both builds (`LICENSE` in the store build, `LICENSE.txt` in the dev bundle). | `project.yml`, `build-app.sh` |
| B2 “Ported from” wording | **Done.** README, About box, PRD §1 and the reference doc now say “inspired by … own solver and pipeline”; quoted tooltip strings are attributed; upstream commit recorded. | README, `AboutAndHelp.swift`, PRD, `comfyui-node-review.md` |
| B3 Competitor comparison | **Done** in the README (moved to the PRD's problem statement only). Trademark/patent search: not performed, owner's call. | README |
| B4 Privacy link in app; policy wording | **Done.** Links in About, Help and Settings; policy reworded to “does not collect or transmit”, mentions bookmarks, Forget All, and browser links. | `AboutAndHelp.swift`, `SnapRescaleApp.swift`, `docs/PRIVACY.md` |
| B5 Non-blockers | Acknowledged; no action. | — |
| README 1–7 | **Done.** New README in the recommended order with usage, limitations (sRGB, metadata stripped, first frame), prerequisites (`xcodegen`, `librsvg`, Python 3), `open -a`, screenshot; maintainer steps moved to `docs/RELEASING.md`; `UPLOAD` must be exactly `1`; “validate” claim corrected. | README, `docs/RELEASING.md`, `Scripts/appstore.sh` |
| APP-STORE.md | **Done.** Subtitle 30 chars, “batch” removed, “size and export settings”, status section reflects the submission, sRGB/metadata limitation stated in the description. | `docs/APP-STORE.md` |

The fixes will ship as 1.0 (2) if review bounces, or 1.0.1 if 1.0 (1) is approved.
