# Crop frame: reviews of the design and the issues, 2026-11-03

Reviewed: the design note [crop-frame.md](crop-frame.md), the doc changes that
go with it (PRD, ROADMAP, Help in both copies, README, APP-STORE.md, the WebP
design renumbered to 1.4), and the drafts of the epic and items A–G before they
were filed. Nothing was implemented. Line numbers in the reports were read at
`e451678`.

The design note is the source of truth; "design §x" below refers to its
current text. Every accepted finding was written into the design or the
drafts before filing. The raw reports were working files and are not kept.

**Result:** three rounds. The first-round critiques reshaped the design.
Codex found 5 gaps in the design (2 major) and 9 in the drafts (3 major). All
were accepted except R6; the reason is given in its row.

## Round 1: six critiques of the first design

Two sweeps mapped every code site and every doc sentence the feature touches.
Six critiques then checked the behaviour and the maths: Claude, Codex GPT-6.1
Sol (xhigh) and Codex GPT-6 Astra (high), one on each. Where they disagreed,
the design gives the choice and the reason in place. What changed the design:

- **Scale's reference.** Measuring Scale against the snapped frame is
  circular: the output decides the frame's ratio, and the frame decides the
  output. The reference is the largest frame at the *requested* ratio ÷ zoom²
  (design §3). The crop itself follows the solved ratio.
- **Pad has no frame.** The critiques offered two references for Scale under
  Pad. The owner chose neither change: Pad keeps the whole source, and later
  the whole feature became Crop only (owner decision 1).
- **Parity.** The solver's parity fixture changes in 522 ideals and 518
  sizes. Two maths critiques agree on the counts, and one first reproduced all
  5,940 cases (design §3.4).
- **Floating point at 1:1.** Random sweeps showed that the 1:1 detent and the
  upscale test are not exact in floating point: an exact 1:1 could read
  "Upscales the source by 0%". Hence the named tolerances and the upscale
  test at > 1 + 1e-9 (design §2.2, §2.4).
- **Separate positions.** The crop frame and the padded image stop sharing
  one anchor (design §2.1).
- **One owner per gesture.** Corner hit areas win over the pan, the pivot comes
  from the gesture's start, and one framing value is written per step with a
  generation against stale writes (design §4.1, §4.7).
- **Presets.** A Width ↔ Scale switch could leave a preset named and flip it to
  Custom later; the switch now counts as a settings change (design §6).
- **Keyboard and VoiceOver.** One focusable element, arrow and +/− steps, named
  menu commands (design §4.6).

The owner chose GPT-6.1 Sol for the later reviews (2026-11-03).

## Round 2: Codex GPT-6.1 Sol (xhigh), the design and the docs

Five findings: 0 blocker, 2 major, 3 minor. The solver counts and the examples
reproduced.

| # | Finding | Resolution |
|---|---|---|
| F1 | A re-solved snapped ratio can push a Scale-view drag candidate out of the image | **Accepted.** Design §4.2 now re-checks every candidate after the re-solve. It never clamps the anchor, and it bisects on zoom (at most 10 re-solves) back to the last legal frame. A's resize functions take `target(forZoom:)`; B supplies `ResizeRequest.targetForZoom(source:fit:)`; E wires them together. Codex's 6000×4000 example is a test (design §10.1). |
| F2 | Which ratio governs `maxZoom`, and how it couples with the Scale solve | **Accepted in part.** The limit is a zoom bound on the **requested**-ratio frame (design §2.3), not on the solved frame. It never depends on the solve, and the CLI and launch arguments validate it before solving. The consequence is documented: the drawn frame can be shorter than 16 px when a tiny output's snap distorts the ratio. Codex's 1234×777 example is the test. A ratio change clamps zoom first (§4.4). Every minimum, the drag's included, is expressed through this bound. |
| F3 | Scale wording needs "before rounding" and "Crop only" | **Accepted.** The rounding qualification and Pad's rule are now in the PRD §5, Help (both copies) and README. The reason Scale has no 1:1 detent is rewritten (§4.3). |
| F4 | "Bit-identical at zoom 1" is too broad | **Accepted.** The compatibility boundary is stated in design §2.1. Whole-pixel origin rounding at 1:1 is a deliberate change, including at zoom 1 (§2.2). The renderer regression test is scoped to that boundary, and a 3001×2000 test is added. |
| F5 | 1234×777 is not a float counterexample | **Accepted.** It is now 1000×706. |
| — | Session.swift:458 should be :457 | **Accepted.** |

## Drafting the issues

Questions the drafting agents raised, and how they were settled.

### First round

| Topic | Raised by | Resolution (design section) |
|---|---|---|
| Interim build state between items; who edits other items' files | epic Q3, A, B, C, D, E | **Every item PR leaves the branch green**, with both packages building and `swift test` passing in both. An item that changes an API used in a later item's file makes the smallest edit there to compile and keep today's behaviour, and lists those edits in its issue. There are no shims (§10). |
| Defaulted `zoom: Double = 1` hides callers from the compiler | B | The C, D and E issues must name `main.swift:127`, `ControlsPanel.swift:320-321` and `PreviewView.swift:200` (§10). |
| Float noise: `d > 0` shows "less than 1%" for exact-ratio outputs | C, D | **Nothing is cropped exactly when `zoom == 1 && Tw·H == Th·W`** (integer test), and d is then exactly 0 (§2.4). |
| 1:1 tolerance | A | `|factor − 1| ≤ 1e-9` (§2.4). |
| Slack tolerance | A | < 1e-6 source px (§2.4). |
| NaN / ∞ inputs; `CropAnchor.init` lets NaN through; t_min > t_max | A | Geometry never traps and never returns NaN. NaN zoom → 1, NaN anchor component → 0.5, ±∞ clamps. `CropAnchor.init` is fixed. t_min ≤ t_start keeps t_min ≤ t_max, and t_max wins on rounding (§2.4). |
| Shared crop/upscale wording and reframe rule: no owner | A, C, D | A owns the new `CropSummary.swift` (fraction, factor, `isOneToOne`, `isUpscale`, percent phrase), used by C and D (§2.4, §5, §10). |
| CLI `fit pad/stretch` line gate | C | Same rule as the app (`CropSummary`) (§5). |
| `CropAnchor.grid` unused | A | A removes it (§2.4). |
| RenderSpec: add or replace | A | `framing` **replaces** `anchor`. Pad carries the pad anchor with zoom 1; Stretch carries `.full` (§2.1, §9). |
| ValidationError wording | A, C | A's proposals: "Zoom must be a number.", "Zoom 300 must be from 1 to 250 for this image.", "Anchor 1.5,0.2 must be two numbers from 0 to 1." (§7). |
| `validate(for:context:)` rejects bad framing? | B | Yes, with A's errors. The app passes clamped values; the CLI passes what was typed (§3.2). |
| Fixed ratio equal to the source's: ulp drift in A_ref | B | `source.area` exactly whenever `a·H == b·W` (§3.1). |
| Interim solve context | B | `SolveContext(fit:)` with the full frame until D adds framing (§3.2). |
| Caption "· 1:1" condition | D | Whenever the actual resample factor is 1 within tolerance, including zoom 1 (§5). |
| Caption hint "drag a corner to crop" | D, E | Hints move to `.help`, with the wording in §5. The caption text has no hint. |
| "upscaled N%" below 1% | D | Same percent phrase: "upscaled less than 1%" (§5). |
| §4.3 "no amber" vs §5 amber rule | D | §5 wins. A frame snapped back to zoom 1 is in the automatic state, so a 9:16 frame on landscape is amber again (§4.3 fixed). |
| Pad note sliver reads "0%" | D | Same percent phrase (§5). |
| Stretch spec framing | D | `.full` (§2.1). |
| App launch args: bad values; with `--fit pad` | D | Ignored, with a line on stderr (the other launch args print nothing; corrected in round 2). With Pad they still set the crop frame (§7). |
| Hit-zone reach vs 12 pt margin | E | The outward reach is clamped to the preview (§4.1). |
| Detent distance measure; precedence | E | Corner travel in points along the ratio diagonal; the nearer detent wins (§4.3). |
| Grid suppression per axis; edges count | E | Yes (§4.9). |
| Handle drawing details | E | Settled in E's screenshot round with the owner (§4.9). |
| Pan minimumDistance | E | Stays 1 pt (§4.1). |
| Pad double-click write path | E | ~~`deferredLive` too~~ Superseded by owner decision 1: Pad keeps today's `deferred` (§4.7). |
| Generation counter owner | E | `Session.framingGeneration` (D). New image, Reset, Centre, undo, Esc and every menu or key command bump it (§4.1). |
| E test file | E | New `CropHandlesTests.swift` (§10). |
| `.onModifierKeysChanged` owner | F | E's (§4.1). |
| Undo bursts, grouping, Centre entry, names | F | A burst ends after 1 s idle or on another change; menu and AX steps group like keys; Centre gets its own entry; names as in §4.5. |
| Undo after ratio/fit/preset change | F | Those changes clear the frame entries, as a new image does (§4.5). |
| AX / menu step sizes | F | A tenth of the frame's size per step, at least 1 source px, stopping at 1:1 (§4.6). |
| `+` enlarging at an image edge | F | Keys and menu Enlarge move the centre just enough to stay inside, so zoom 1 is reachable; drags still clamp (§4.6). |
| Detent under key repeat | F | A held key stops at 1:1 and at zoom 1; the next press goes past (§4.6). |
| Esc write path; Esc delivery mid-drag | F | The restore uses `deferredLive` and bumps the generation. F checks whether Esc is delivered mid-drag; if not, Esc is dropped and ⌘Z covers it (§4.5). |
| Keyboard layouts (Swiss German) | F | `+`/`−` matched by character (`=` and `-` count), one short-edge pixel per press, no ⇧×10 for resize (§4.6). Help says **+** and **−**. |
| Pad keyboard / AX (#68 item 1 asked for it) | F | ~~Under Pad the arrows, the AX element ("Padded image") and View ▸ Frame Move/Centre move the padded image.~~ Superseded by owner decision 1: Crop only; the Pad half of #68 item 1 stays open (§4.6). |
| Wording: AX value, announcements, dimmed menu items | F | As in §4.6. |
| WebP overlaps on F's files | F | Added to §9: #87, #88, #89. |
| macOS 27 check covers keys/menu | epic, F | Yes (§4.7). |
| Release number after WebP | G | ~~1.4, with the build after WebP's (question 2).~~ Superseded by owner decision 2: the crop frame is 1.3 (5) and WebP becomes 1.4 (6). |
| Renumbering list incomplete | G | Extended in question 2. Keep the file name `webp-1.3.md`. |
| Store copy wording, keywords, which screenshots | G | G drafts them and the owner approves in G's PR. ~~Keywords are an owner question in G.~~ Superseded by owner decision 3: no new keywords for now. Retake every screenshot that shows the crop frame. |
| VM check scope; RELEASING step | G | Run on the macOS 26 VM: corner drag, keys, VoiceOver. The sandbox checks are not required, since there are no save-path changes. RELEASING gains a standing "preview gestures on macOS 27" check. |
| G's ownership of status lines and renumbering edits | G | Added to §10. |
| Stale line refs (caption 196-214, `_solve` 61-88, main.swift 104-106 / 123-129, webp l.149-153 / 502-513, switchSizeKind 409-420) | all | Fixed in the design. The issues cite the actual lines. |

### Second round

| Topic | Raised by | Resolution (design section) |
|---|---|---|
| `reframed` cannot see the requested ratio | A, D | `Geometry.reframed(_:source:from:to:maxZoom:)` takes the new requested ratio's `maxZoom` (§2.4, §4.4). |
| Who clamps the zoom to the requested ratio | A, B | `cropRect` only guards with `max(1, min(W,H)/16)`; B's solve context and D's stored framing clamp first with `CropFraming.clamped(maxZoom:)`; the CLI rejects (§2.4). |
| Names beyond §2.4 | A, C | Added to §2.4: `clamped(maxZoom:)`, `validateZoom(_:maxZoom:)`, `CropAnchor.validate(x:y:)`, `CornerDrag.Step` and its functions, `framing(centredAt:…)`, the two tolerances, `CropSummary(source:target:framing:)`, `isCropped`, `reframes(source:target:)`, `percentPhrase(_:)`. `centrePaddedImage()` is gone (decision 1). |
| "more than 99%" for upscales of 100% or more | A, C, D | One phrase: the upper end applies only above 0.99 and below 1, so 150% reads "150%" (§2.4). |
| `%.0f` rounds half to even | A | Kept, as today: 0.625 reads "62%". The 9:16 test expects "62%" (§2.4, §10.1). |
| Where the 1:1 origin rounding lives | A | In `Geometry.cropRect`, so the preview, VoiceOver and the output agree (§2.2). |
| The upscale threshold "already" 1e-9 | review of §2.4 | It was not: today's test is `> 1` (`Solution.swift:69-71`). B changes it to `> 1 + 1e-9` (§2.4). |
| The ⌥ rejection pointer | B | ⌥ needs its own pointer, (5978.99, 3986.21); the end-to-end test is B's, and A uses a stand-in target (§4.2, §10.1). |
| `validate(for:context:)` scope | B | Checks only the zoom, whatever the fit (§3.2). |
| Launch-argument stderr line | D | The new flags print one line; the others print nothing today and are not changed (§7). |
| Caption suffixes under Pad | D | Crop only; Pad's and Stretch's captions stay as they are (§5, decision 1). |
| Which view carries the `.help` hint | E | The caption; E's screenshot round may move it to the crop layer (§5). |
| A cancelled gesture must end the encode pause | E, F | Every release calls `endFrameGesture()`, even when its last write is stale (§4.8). |
| Pad step units | F | Moot: Pad has no keys (decision 1). |
| Key or menu step under Scale pushed out of the image | F | It moves the centre just enough, like Enlarge at an edge; it never bisects (§4.6). |
| What ends an undo burst | F | 1 s idle, a step of the other kind, or any other settings change (§4.5). |
| Store shot 5 (Pad) caption | G | Moot: Pad's caption is unchanged (decision 1). |
| Who merges WebP's code if it reaches `main` first | G | G merges `main` in and resolves the §9 overlaps before its release checks (§9). |

## Round 3: Codex GPT-6.1 Sol (xhigh), the issue drafts

Nine findings: 0 blocker, 3 major, 6 minor. Codex reproduced the parity
counts, the geometry examples, the §4.2 rejection numbers with both pointers,
the zoom limit on 1234×777, F's Scale-step numbers, `500.5.rounded()` = 501 and
"62" for 0.625. The proposed SwiftUI calls typecheck against the macOS 26 SDK.

| # | Severity | Finding | Resolution |
|---|---|---|---|
| R1 | major | D's encode pause does not stop a job queued before the gesture, nor the publish of a render already running | **Accepted.** `beginFrameGesture()` drops the queued job; the worker checks the flag before each dequeue; a render that finishes during a gesture does not publish. Two new tests, and a hook that counts encode starts (D, design §4.8). |
| R2 | major | B's test asks a 50% Scale for a resample factor of 1 | **Accepted.** The factor is 1 for 100% at zoom 1 and 2, and 0.5 for 50%; none of the three upscales (B). |
| R3 | major | The WebP renumbering misses `v1.3`: the source-tag link, the release tag and "v1.3 — M4" in #90 and #91 | **Accepted.** The script changes SnapRescale's `v1.3` too, so the tag becomes `v1.4-build6`. It keeps ComfyUI's v1.39.10, the file name `webp-1.3.md` and "1.3 s", and lists every 1.3 it keeps for a check by hand. That check found six more places where the 1.3 app behaves as 1.2 does (#78, #85, #90, #97); they now name both. |
| R4 | minor | The apply step is unsafe to rerun: a second pass renumbers the new crop-frame references | **Accepted, by a guard.** The script works from a snapshot of the bodies taken before the edit. It edits an issue only if the live text still equals the snapshot, skips one that already equals the new text, and refuses one that differs from both. |
| R5 | minor | The preset wording loses "Crop only": a Pad preset with `scale` gives the same output as in 1.2 | **Accepted.** PRD §12, design §6, the epic and G now say: under Crop, when the preset's ratio differs from the source's (a smaller frame shrinks it further); under Pad and Stretch Scale measures the whole source. |
| R6 | minor | The two Help copies differ in two places | **Rejected.** Both differences predate the feature and suit the medium: the "Full list" sentence links a file that the in-app pane replaces with its own link row, and "this help" reads right inside the pane. G records both. |
| R7 | minor | A factor within 1e-9 of 1 can leave the 1:1 rect a few millionths of a pixel outside the image | **Accepted.** At 1:1 `cropRect` returns exactly Tw×Th at a rounded origin inside the image; a 30000×20000 → 10000×10000 test at the bottom-right edge pins it (A, design §2.2). |
| R8 | minor | Spec equality does not end an undo burst on every settings change | **Accepted.** A step joins a burst only if the settings (`currentPreset`) and the spec are what the previous step left. Two new cases: Width 1000 → Height 1000 on a square output, and a multiple the size already meets (F). |
| R9 | minor | The drafting log still showed the release number and the keywords as first resolved | **Accepted.** Both rows (first drafting round, above) are struck through and point to owner decisions 2 and 3. |

## Owner decisions (2026-11-03)

1. **Crop only.** "This new functionality is disabled when pad is selected,
   pad is rare case, this new functionality is for the crop case only." Pad
   keeps today's behaviour, Scale under Pad included (whole source). The Pad
   half of #68 item 1 stays open. The few changes Pad sees through shared
   code are listed in the design's end section.
2. **1.3.** The crop frame ships as 1.3; WebP moves to 1.4. The docs were
   renumbered in the branch's first commit, and GitHub on 2026-11-03, when
   the crop-frame issues were filed.
3. **Keywords.** "Don't add new keywords for now." G leaves them as they are.
