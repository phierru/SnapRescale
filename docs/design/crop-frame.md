# SnapRescale: a crop frame you can resize (corner handles, locked ratio)

> **Status (2026-11-03):** designed, not implemented. It ships as 1.3, and
> WebP moves to 1.4. Work happens on the `feature/crop-frame` branch, in its
> own worktree. The items are on the SnapRescale project board, under the epic
> #99 (items A–G: #100–#106).

Every `file:line` reference is relative to the repo root and was read at
`e451678`.

**How this design was made**
- The owner asked for it on 2026-11-03: four handles at the corners of the
  crop frame select a smaller part of the image, and the frame keeps the
  selected ratio.
- The owner agreed two rules the same day. The size selectors always mean the
  output, except Scale %. Scale % stays linear and is measured against the
  selected area.
- Two sweeps mapped every code site and every doc sentence it touches. Six
  critiques checked the behaviour and the maths:
  - three on behaviour (Claude, GPT-6.1 Sol, GPT-6 Astra);
  - three on geometry and the solver (the same three models).
- Where the critiques disagreed, the choice and the reason are given in place.
- The owner then settled three more points (end of this note): the feature is
  for Crop only and Pad stays as it is; it ships as 1.3; the App Store
  keywords stay as they are.
- The two maths critiques that counted the solver's parity fixture agree on
  the number of rows that change (§3.4). One of them first reproduced all
  5,940 cases.
- Codex GPT-6.1 Sol then reviewed this note with the doc changes, and later
  the issue drafts. The findings and what was done about each are in
  [crop-frame-review.md](crop-frame-review.md).

---

## 1. What changes for the user

- **The frame.** Under **Crop**, the frame starts where it does today: the
  largest region of the image at the target ratio, centred. Four handles sit
  at its corners.
  - **Drag a corner** to make the frame smaller or larger again. The opposite
    corner stays where it is.
  - **⌥-drag** resizes around the centre.
  - The ratio stays locked to the target. The frame never leaves the image.
- **Moving.** Dragging anywhere else still moves the frame, as today.
- **Reset.** A double-click puts the frame back to full size, centred.
  **View ▸ Frame ▸ Reset Frame** does the same.
- **Original.** Under Original the handles are there too, so a part of the
  image can be kept at the image's own ratio.
- **Pad stays as it is.** The new functionality is for Crop only: Pad is the
  rare case. Under Pad there are no handles, keys, View ▸ Frame commands or
  undo. Dragging the padded image and double-clicking to centre it work as
  today.
- **Width, Height and Megapixels** keep meaning the output size. Making the
  frame smaller does not change the output: it resamples less of the image, up
  to the point where it would enlarge it. The panel then says so, as for any
  upscale.
- **Scale %** is measured against the frame under Crop (§3): 100% keeps the
  frame's own pixels, a pure crop, and 50% halves the frame's width and
  height, before rounding to whole pixels and the multiple. Under Pad it is
  still measured against the whole source.
  - This also changes Scale under a fixed ratio when no handle has moved.
  - Example: 3000×2000 at 1:1 and 100% gives 2000×2000 instead of today's
    about 2449×2449, which was "Upscales the source by 22%".
- **Keyboard and assistive technologies** (item 1 of #68), under Crop:
  - the frame can take keyboard focus, and the arrow keys move it;
  - `+` and `−` resize it around the centre;
  - VoiceOver and Voice Control reach the same actions;
  - ⌘Z undoes a frame change.

  The Pad half of #68 item 1 stays open.
- **Presets.** The framing stays out of presets: position and now size too.
  Applying a preset leaves the frame alone; a new image starts with the full
  frame, centred.

## 2. The model

### 2.1 One framing value

```swift
/// Where the crop frame sits and how large it is. Framing, so never in a preset (PRD §12).
public struct CropFraming: Hashable, Sendable {
    public var anchor: CropAnchor   // 0…1 per axis, normalised over the slack of the zoomed frame
    public var zoom: Double         // ≥ 1; 1 = the largest frame at the ratio
    public static let full = CropFraming(anchor: .center, zoom: 1)
}
```

- The frame is the largest frame at the ratio, divided by `zoom` on each edge.
- **What stays as it is at `zoom == 1`** (division by 1.0 is exact):
  - The crop geometry is today's for the same target, except for the
    whole-pixel origin at 1:1 (§2.2).
  - Original under Scale, and every Width, Height and Megapixels request, keep
    today's solver results.
  - Scale under a fixed ratio changes, as specified in §3.
- **Validation and clamping:**
  - `zoom` is clamped to `1…maxZoom(source, requested ratio)` (§2.3) and must
    be finite.
  - `CropAnchor.init` clamps, but mutable fields and decoded values can bypass
    it, so geometry clamps again at use.
  - The CLI and the launch arguments reject bad values instead of clamping
    them (§7).
- **Written as one value.** The app writes anchor and zoom together. Two
  separate writes mean two solves and an intermediate frame on screen.
- **Crop and Pad positions are separate.** Session keeps a `cropFraming` and a
  `padAnchor`; a new image resets both.
  - Today one anchor serves both (`Session.swift:33`, `PreviewView.swift:64`
    and `:95`), so moving the padded image moves the crop.
  - With a hidden zoom, coming back to Crop would show a small frame somewhere
    else.
  - Pad's layer changes only in writing `padAnchor`. Its gestures, write paths
    and caption stay as they are.
- **What the renderer gets.** `RenderSpec.framing` replaces
  `RenderSpec.anchor`. Under Pad it carries the pad anchor with zoom 1; under
  Stretch it carries `.full`. An invisible zoom must not make two specs
  differ: `scheduleEncode` publishes only when `self.spec == job.spec`
  (`Session.swift:465`).

### 2.2 The frame rectangle

Source `W×H`, ratio `r` (width ÷ height), zoom `z`, anchor `(ax, ay)`. All
values are in source pixels, with the origin at the top left.

```
largest frame:  Bw = min(W, r·H),  Bh = min(H, W/r)
frame:          w = Bw / z,        h = Bh / z
origin:         x = ax·(W − w),    y = ay·(H − h)
```

- **Rendering uses the solved output's ratio,** `r = Tw/Th`. This is today's
  `Geometry.cropRect` (`Geometry.swift:23-29`), with the visible size divided
  by `z` **before** the slack is computed:

  ```
  c = max(Tw/W, Th/H);  w = min(W, Tw/c) / z;  h = min(H, Th/c) / z
  ```

  - Under Original with a multiple, the frame keeps today's sliver crop. For
    example, 6000×4000 → 1024×688 keeps about 5953.488×4000 at zoom 1.
  - So under Original the handles start a few pixels inside the border, not
    always on it.
- **The renderer barely changes.** It passes the framing, and at an exact 1:1
  it sets its scale to exactly 1. Its draw transform (`Renderer.swift:89-96`)
  already maps any crop rect onto the canvas.
- **Pixel-exact 1:1.** When the resample factor is exactly 1, round the crop
  origin to whole pixels. Otherwise a fractional origin resamples by a
  sub-pixel shift and the "1:1" result comes out soft.
  - This is the 1:1 detent (§4.3), and also any zoom-1 case that happens to
    be 1:1. Example: 3001×2000 to 2000×2000 at 1:1, centred, has today's
    origin (500.5, 0) and becomes (500, 0) or (501, 0) by the usual rounding.
  - This changes today's output in such cases, on purpose: today's result is
    soft.
  - The rounding is in `Geometry.cropRect`, not in the renderer, so the
    preview, the VoiceOver position and the output agree.
  - It rounds with `.rounded()` (half away from zero), so the example gives
    (501, 0). The size is snapped to exactly `Tw×Th`, and the rounded origin
    is clamped into the image. Within the 1e-9 tolerance the model's size can
    be off by more than an ulp: 30000×20000 → 10000×10000 at zoom
    `2·(1 − 5e-10)` is about 5e-6 px too large, and rounding only the origin
    would put the frame's far edges outside the image.
  - So at an exact 1:1 the fixed corner of a drag, or its centre under ⌥, can
    move by up to half a source pixel. Every step takes its pivot from the
    drag-start snapshot, so the half pixel never adds up.
- **From a rectangle back to framing:**

  ```
  z = Bw/w  (= Bh/h)
  ax = x/(W − w),  ay = y/(H − h)
  ```

  - When an axis has no slack (within tolerance), its anchor cannot be
    observed. Keep the previous value; never divide by zero.
  - This matters: at zoom 1 one axis always has no slack, and under Original
    both do. Any operation that keeps the anchor while it changes the zoom
    would jump to a stale edge. Every resize therefore fixes a **point** in
    source pixels and derives the anchor afterwards (§4).

### 2.3 Limits

- **Smallest frame in the model:** a zoom bound,
  `maxZoom = max(1, min(Bw, Bh) / 16)`, where `Bw×Bh` is the largest frame at
  the **requested** ratio, the same frame Scale measures against (§3.1). At
  the chosen ratio the short edge is then at least 16 source pixels, or the
  whole short edge of the largest frame if that is smaller.
  - **Requested, not solved,** so the limit never depends on the solve.
    - The CLI and the launch arguments can validate a zoom before solving.
    - A Scale solve, whose reference area depends on the zoom, never feeds
      back into its own limit.
  - **The drawn frame can be smaller.** It follows the solved ratio (§2.2).
    When the snap moves the ratio a lot (tiny outputs at a large multiple),
    the drawn short edge can fall below 16.
    - Example: 1234×777, Original, Scale 100%, multiple 32, at the limit
      zoom 777/16 = 48.5625, solves to 64×32.
    - At that ratio the largest frame is 1234×617, so the drawn frame is
      about 25.41×12.71. It is still inside the image, and nothing else
      depends on the 16.
  - **Every minimum is this zoom bound,** the drag's included (§4.2).
  - **A ratio change can lower the limit** (§4.4). The zoom is then clamped to
    the new `maxZoom` before the centre rule runs.
  - The minimum does not depend on the window, so resizing the window never
    changes the crop.
  - It is not tied to the output size or the multiple: deliberate upscaling
    stays allowed (PRD §5, "a warning, not a lock").
- **Smallest frame while dragging:** also about 24 pt on screen, converted
  through the preview's scale. If the frame was already smaller when the drag
  started, that smaller size is the floor instead.

### 2.4 Names, tolerances and bad input

Settled while the items were drafted, so that every item uses the same names
and the same numbers.

- **API names.** These are the working names; an item may refine them, but
  then it updates the issues that call them.
  - A, in RescaleKit:
    - `CropFraming`, with `clamped(maxZoom:)` and `validateZoom(_:maxZoom:)`;
    - `CropAnchor.validate(x:y:)`, which checks a typed anchor before
      `CropAnchor.init` clamps it;
    - `CornerDrag`, with `Step`, `step(zoom:lastLegal:target:)`,
      `step(translation:lastLegal:target:)`, `size(zoom:)`, `zoom(size:)`,
      `rawSize(translation:)` and `sizeRange` (E's detents and cursors need
      the last two);
    - `Geometry.largestFrame(source:ratio:)` and
      `Geometry.maxZoom(source:ratio:)`;
    - `Geometry.cropRect(source:target:framing:)` and
      `Geometry.framing(of:source:target:previous:)`;
    - `Geometry.framing(centredAt:zoom:source:target:previous:)`, the centre
      rule shared by the ratio change (§4.4) and the keys (§4.6);
    - `Geometry.reframed(_:source:from:to:maxZoom:)`. It takes the new
      requested ratio's `maxZoom`, because a solved target cannot tell the
      requested ratio (§4.4);
    - `Geometry.oneToOneZoom(source:target:)`;
    - `Geometry.cropResampleFactor(source:target:framing:)` and
      `Geometry.discardedFraction(source:target:framing:)`;
    - `Geometry.oneToOneTolerance` and `Geometry.slackTolerance` (below);
    - `CropSummary` (below);
    - `Limits.minimumFrameEdge = 16`;
    - `ValidationError.zoomNotFinite`, `.zoomOutOfRange` and
      `.anchorOutOfRange`.
  - B:
    - `SolveContext(fit:framing:)`, `Solver.solve(_:source:context:)`, and
      `ResizeRequest.solve(for:context:)` and `validate(for:context:)`;
    - `Solution.referenceArea` and `Solution.scale`, which replaces
      `scale(relativeTo:)`;
    - `ResizeRequest.targetForZoom(source:fit:)`, the `target(forZoom:)`
      function of §4.2.
  - D, in the app:
    - `Session.cropFraming`, `Session.padAnchor` and
      `Session.framingGeneration`;
    - `resetFrame()` and `centreFrame()`;
    - `beginFrameGesture()`, `endFrameGesture()` and `frameGestureActive`;
    - `Session.outputFacts`, which the notes, the caption and F's VoiceOver
      value read;
    - `OutputFacts`, `OutputNote` (with a stable `Kind`), and
      `OutputNotes.notes(_:)` and `.caption(_:)`.
- **Who clamps the zoom.** `cropRect` cannot see the requested ratio. It
  only guards with `max(1, min(W, H)/16)`, the widest bound of any ratio,
  which keeps the rect finite and inside the image and never cuts a legal
  zoom: the 1234×777 frame at 48.5625 (§2.3) is drawn as it is. Clamping to
  the requested ratio's `maxZoom` is the caller's job, with
  `CropFraming.clamped(maxZoom:)`: B's solve context and D's stored framing
  are clamped first. The CLI rejects instead (§7).
- **`CropSummary`** (A, new `CropSummary.swift`). It holds what the sidebar,
  the caption and the CLI report about a crop. The CLI (C) and the app (D)
  both use it, so the reframe rule and the wording exist once.
  - `CropSummary(source:target:framing:)` gives `discardedFraction`,
    `resampleFactor`, `isCropped`, `isOneToOne` and `isUpscale`.
  - `CropSummary.reframes(source:target:)` is the integer ratio test
    (`Tw·H != Th·W`) for the Pad note and the CLI's `fit pad` and
    `fit stretch` lines.
  - `CropSummary.percentPhrase(_:)` is the one percent phrase. Below 0.01 it
    reads "less than 1%", so a sliver never reads "0%" (#69). Above 0.99 and
    below 1 it reads "more than 99%". Otherwise it reads "N%", so an upscale
    of 150% reads "150%". Callers pass only positive values: they gate on
    `isCropped`, `isUpscale` or `reframes`.
  - N keeps today's `%.0f` (`ControlsPanel.swift:309`), which rounds half to
    even: 0.625 reads "62%".
- **Tolerances.**
  - **Nothing is cropped** exactly when `zoom == 1` and `Tw·H == Th·W` in
    integers. The discarded fraction is then exactly 0. Today's arithmetic
    leaves float noise of about 1e-16 on outputs at exactly the source ratio,
    for example 6000×4000 → 1008×672. A test on `d > 0` alone would then show
    "Crops less than 1%".
  - **1:1** means `|factor − 1| ≤ 1e-9` (`Geometry.oneToOneTolerance`). The
    upscale test becomes `factor > 1 + 1e-9` to match (§5); today it is
    `> 1` (`Solution.swift:69-71`). At `z₁` the factor often misses 1 by an
    ulp: 6000×4000 → 999×666, and 1234×777 → 640×403.
  - **No slack** on an axis means less than 1e-6 source px
    (`Geometry.slackTolerance`), the tolerance `Session.reframes` uses today
    (`Session.swift:187-190`).
- **Bad numbers.**
  - Geometry never traps and never returns NaN.
  - A NaN zoom counts as 1; +∞ and huge values clamp to `maxZoom`, and −∞ to 1.
  - A NaN anchor component counts as 0.5; ±∞ clamps to 0 or 1.
    `CropAnchor.init` gets the same NaN rule (today `min(max(.nan, 0), 1)` is
    NaN).
  - In a drag, `t_min` is never above `t_start` (§2.3), so `t_min ≤ t_max`. If
    rounding still crosses them, `t_max` wins and the frame stays inside the
    image.
- **`CropAnchor.grid`** (`Geometry.swift:15-16`) is unused since the 3×3 grid
  was dropped (PRD §7). A removes it.

## 3. Scale % against the frame

### 3.1 The rule

```
pixel budget = A_ref · s²,   A_ref = (Bw · Bh at the REQUESTED ratio) / z²
readout s    = √(Tw · Th / A_ref)
```

- **Requested ratio, not solved.** The reference uses the ratio you chose, not
  the solved output's. Otherwise Scale would depend on the solved size, which
  depends on Scale. With a multiple of 8, 16 or 32 the snapped ratio moves by
  up to 3.6% (PRD §6), so the loop would show in normal use.
- **The crop itself** still follows the solved output (§2.2). The two areas
  differ only by rounding. Example: Original, 6000×4000 → 608×400 has a
  reference area of 24,000,000 and a cropped area of about 23,684,210.5.
- **Today's arithmetic is kept:**

  ```swift
  let mp = referenceArea * s * s / Megapixel.pixels
  return fromPixelCount(mp * Megapixel.pixels, aspect: ar)
  ```

  Under Original at zoom 1, `referenceArea` is `source.area` exactly, not a
  ratio-based recomputation. The same holds for a fixed ratio equal to the
  source's in integers (`a·H == b·W`): 21:9 on 1050×450 would otherwise give
  `Bh = 449.99999999999994`. The fixture rows are the same either way. `sh·(sw/sh)` is not always `sw` in floating
  point; 1000×706 is a case (`706 * (1000/706)` is 999.9999999999999). Every
  Original result therefore stays bit-identical.
- **Pad and Stretch** keep today's reference, the whole source, and ignore
  zoom. The owner confirmed this: the new functionality is for Crop only
  (decision 1 at the end).

### 3.2 Plumbing

- The solver needs the fit and the framing; today `ResizeRequest` has neither.
  - They are passed as a **solve context**, not as request fields, because
    `Preset.request` (`Preset.swift:53`) must stay framing-free.
  - `Solver.solve(_:source:context:)` defaults the context to "crop, full
    frame". A Crop solve with no handle moved is then simply the call
    without a context.
- **`Solution` stores the `referenceArea` it used.**
  - `scale(relativeTo:)` (`Solution.swift:51`) is removed in favour of a
    read-out from that stored area, so the compiler finds every caller:
    `Session.swift:416`, `ControlsPanel.swift:253`, `main.swift:113`, and
    tests at `TableTests.swift:80`, `PropertyTests.swift:147` and
    `ValidationTests.swift:67`.
  - The readout, the Width↔Scale view switch and the solver must all use the
    same area, or switching to Scale moves the output.
- **`ResizeRequest.validate(for:context:)`** (`Validation.swift:90-104`)
  takes the same context. It rejects a non-finite zoom, or one outside
  `1…maxZoom`, with A's errors. The app always passes clamped values; the CLI
  passes what was typed.
  - It checks the zoom whatever the fit, and only the zoom. The anchor never
    enters the solve; C checks a typed anchor with `CropAnchor.validate(x:y:)`.
- **Between items** the context carries the real fit from B on. Until D adds
  the framing, the app and the CLI pass `SolveContext(fit:)` with the full
  frame, so Pad and Stretch keep 1.2's numbers on the branch.

### 3.3 View switching is a fixed point only before rounding

- Before rounding, the round trip is exact: `A_ref·(√(P/A_ref))² = P`.
- After the lattice snap or the Limits clamp it is not. PRD §5 already allows
  that, and the notes under Output say when it happens. The examples become
  tests:
  - 6000×4000, 16:9, Width 1920 at multiple 16 gives 1920×1088. Switching to
    Scale (32.1182998%) re-solves to 1936×1088.
  - At multiple 1: 21:9 at Width 22 gives 22×9. Scale carries 21×9.
  - 1×1 source, Width 65536 gives 22305×22305. Its Scale is 2,230,500%, past
    the 6400% cap (`Limits.maxScale`).
- A small frame makes values above the cap easier to reach. Selecting Scale
  must then say why the value changed, not clamp it silently.

### 3.4 The parity fixture

The Swift solver is held to `prototype/solver.py` by a 5,940-case fixture
(`ParityTests.everyCaseMatchesThePrototype`, PRD §6).
- **522 cases change their ideal:** Scale at a fixed ratio that differs from
  the source's (576 fixed-ratio Scale cases, minus 54 whose ratio matches).
- **518 of them change their integer size.** The other four, all from
  1234×777, keep it:
  - 3:2 at 10% ×8 (120×80);
  - 3:2 at 25% ×16 (288×192);
  - 4:3 at 10% ×16 (112×80);
  - 16:9 at 10% ×8 (128×72).
- **Fix the prototype first, then the fixture.**
  - `_solve` (`solver.py:61-88`, the Scale branch at l.65-67) gets the source
    edges and the integer ratio,
    and computes the frame-based budget.
  - `export_fixture.py` passes the ratio tuple, not `a/b`.
  - The fixture is then regenerated. Replacing the expected numbers alone
    would turn the parity test into a tautology.
  - A one-off check confirms the new fixture differs from the old one in
    exactly these 522 ideals and 518 sizes.
- Original rows, Width, Height and Megapixels rows, and `TableTests` are
  unchanged. For example, `.megapixels(source.megapixels)` at 1:1 still gives
  4899×4899.
- `PropertyTests.scaleAndMegapixelsRoundTrip` needs the reference area from
  the solution.

## 4. Interaction

### 4.1 Who gets the mouse

- **Handles:**
  - Drawn as L-shaped marks just outside the frame stroke, about 10 pt long,
    so they hide no kept pixel.
  - The hit zone is about 24 pt, biased outward (roughly 16 pt outside the
    corner, 8 pt inside).
  - When the frame is small on screen, the zones are split by nearest corner
    and never overlap.
  - At zoom 1 the frame touches the image border. The outward part of the zone
    is clamped to the preview, so there it reaches only the 12 pt margin
    (`PreviewView.swift:189`).
- **Moving:** dragging anywhere else moves the frame, as today. That includes
  outside the frame, so a tiny frame stays movable.
- **Gesture priority:**
  - The handles are hit-testable children of the crop layer, and their drag
    gestures win over the layer's pan (`PreviewView.swift:89`).
  - `minimumDistance` is about 3 pt, so a click with 1 pt of jitter does not
    leave the zoom at 1.0004. The pan keeps its 1 pt
    (`PreviewView.swift:171`).
- **Cursor:**
  - On handles: `.pointerStyle(.frameResize(position:directions:))`. It shows
    `.inward` at zoom 1 or when clamped, and `.outward` at the minimum size.
  - Elsewhere: an open hand, which closes while moving (should).
- **Gesture lifecycle:** each gesture starts from an immutable snapshot (the
  start rect in source pixels, the pointer, the corner and ⌥). A generation
  counter makes queued writes from an ended or cancelled gesture no-ops, for
  example after Reset, a new image or Esc.
  - The counter is `Session.framingGeneration` (D). A new image, Reset, Centre,
    an undo, Esc and every menu or key command bump it. Then F's paths and a
    reload of the same file reach it too.
- **Modifiers** for the drag (⌥ to rebase, ⌘ to bypass the detents) are E's:
  read on every event from `NSEvent.modifierFlags`, because
  `DragGesture.Value` has none, and with `.onModifierKeysChanged`, so they act
  without the mouse moving.

### 4.2 The drag maths

Corner signs: `u` is −1 for a left corner and +1 for a right one; `v` is −1
for a top corner and +1 for a bottom one. `Q` is the fixed opposite corner.
`P` is the start corner plus the pointer's movement, so grabbing a handle
anywhere in its zone does not make it jump.

```
dx = u·(Px − Qx),  dy = v·(Py − Qy)
t_raw = (r·dx + dy) / (r² + 1)                         // orthogonal projection onto the ratio diagonal; t = frame height
t_max = min((u>0 ? W−Qx : Qx) / r,  v>0 ? H−Qy : Qy)    // image bounds
t_min = max(Bh / maxZoom, m_w / r, m_h)                 // §2.3; m = the on-screen minimum in source px
t = clamp(t_raw, t_min, t_max)
w = r·t,  h = t,  x = Qx + min(0, u·w),  y = Qy + min(0, v·h)
```

- **⌥ (resize around the centre):**
  - `Q` is the start centre `C`, and `t` is the **half**-height.
  - `t_max = min(min(Cx, W−Cx)/r, min(Cy, H−Cy))` and
    `t_min = max(Bh/(2·maxZoom), m_w/(2r), m_h/2)`.
  - Rect = `(Cx − r·t, Cy − t, 2r·t, 2t)`.
  - Pressing or releasing ⌥ mid-drag rebases the gesture on the current rect.
- **Projection, not `max(dx, dy)`.** The diagonal projection puts the corner at
  the reachable point nearest the pointer, and growing feels the same as
  shrinking. `max(|dx|/r, |dy|)` lets one axis dominate and makes shrinking
  feel sticky.
- **Clamp, don't push.** At the image edge the corner stops while the pointer
  runs on. The opposite corner (or the centre) never moves.
  - So an off-centre frame cannot grow back to full size without moving. Reset,
    or a move followed by a resize, gets it there.
- **Never flip.** Dragging past the fixed corner stops at the minimum size.
- **Order of constraints:** image bounds, then minimum size, then detents.
- **Scale view with a multiple:**
  - Each step re-solves the output, and its snapped ratio can change.
    Example: Original, 6000×4000 at 10% ×16 gives 608×400 at zoom 1 and
    528×352 at zoom 1.1.
  - The handler re-solves on every event (cheap), and re-derives the anchor
    against the re-solved rect from the drag-start snapshot. It never steps
    from the last rendered frame, so the fixed corner does not drift.
  - **Every candidate is checked again after the re-solve.**
    - The projection above uses the drag-start ratio. The re-solved ratio
      can make one edge longer, even while shrinking, so a candidate that
      passed the bounds can leave the image.
    - Rebuild the frame at the re-solved ratio about the fixed corner (or the
      centre). Check the image bounds and the minimum again.
    - Never clamp the anchor to rescue an infeasible candidate: that would
      move the pivot.
    - If the candidate fails, bisect on zoom between the last legal frame of
      this gesture and the candidate, with at most 10 re-solves, and take the
      legal zoom closest to the candidate. If none is legal, keep the last
      legal frame.
  - **Example** (all numbers reproduced): 6000×4000, Original, Scale 10%,
    multiple 16, zoom 1.19 solves to 512×336. With anchor (1, 1) the frame is
    (957.98, 691.18, 5042.02, 3308.82).
    - Dragging the bottom-right corner to (5957.98, 3972.43) projects to
      zoom 1.2, which solves to 496×336. (The printed pointers are rounded,
      so they reach just above 1.2: about 1.2000001, and 1.2000012 for the ⌥
      one below. A stand-in target must switch at or below that.)
    - The rebuilt frame is 4920.63×3333.33. Its bottom edge would be at
      4024.51, outside the image.
    - So the candidate is rejected and the top-left corner stays where it
      is.
    - With ⌥ the test needs its own pointer: under ⌥ the one above gives a
      frame that fits. The pointer at (5978.99, 3986.21) projects to zoom 1.2
      about the centre (3478.99, 2345.59). The rebuilt 4920.63×3333.33 frame
      would end at y = 4012.25, so it is rejected too, and the centre stays.
  - **Where it lives:**
    - A's resize functions take the target as a function of zoom,
      `target(forZoom:)`, which returns a constant under Width, Height and
      Megapixels.
    - B supplies the Scale version.
    - E wires them together.

### 4.3 Detents

- **Zoom 1:** within about 4 pt of the full frame the drag snaps to exactly
  `zoom == 1`. A frame put back by hand then returns to the automatic state:
  notes and caption as for an untouched frame (§5). A 9:16 frame on a
  landscape image is amber again.
- **1:1, under Width, Height and Megapixels only:**
  - At the zoom where the frame is exactly `Tw×Th` source pixels:
    `z₁ = 1 / max(Tw/W, Th/H)`, using the **solved** output.
  - It is offered only when `z₁ > 1` and the size is reachable with the
    current pivot.
  - It snaps within about 6 pt, with hysteresis: it lets go beyond 10 pt. It
    plays the `.alignment` haptic and shows "1:1" in the caption.
- **Scale view:** no 1:1 detent. Before rounding, the resample factor equals
  s at every frame size, so there is no frame size to snap to. Rounding to
  whole pixels and to the multiple can change the actual factor: on 3000×2000
  at 1:1, 100% at multiple 32 gives 2016×2016 from a 2000×2000 frame, an
  upscale of 0.8%. The notes use the actual crop rect (§5).
- **Distances** are the corner's travel in points along the ratio diagonal,
  between the projected corner and the corner at the detent. When both detents
  are in range, the nearer one wins.
- **⌘ while dragging** bypasses both. ⌥ already means "around the centre";
  the PRD's old slider used ⌥ to bypass detents (§5), and that convention
  moves to ⌘.
- **Typical case:** Width defaults to min(source width, 2048)
  (`Session.swift:334`). For any source up to 2048 px wide, `z₁ = 1`, so any
  inward drag upscales at once and the note says so.

### 4.4 Aspect ratio changes while zoomed

- **Keep the zoom and the frame's centre in source pixels.** First clamp the
  zoom to the new ratio's `maxZoom` (§2.3), then clamp the centre so the new
  frame fits, then derive the anchor.
- **Why not keep the anchor:** keeping `(z, anchor)` moves the subject even
  when its centre still fits.
  - Example: 3000×2000, 1:1, z 2, anchor (0.8, 0.25) gives the frame
    (1600, 250, 1000, 1000), centred on (2100, 750).
  - Switching to 3:2 and keeping the anchor gives (1200, 250, 1500, 1000). The
    centre lands at (1950, 750), 150 px off.
  - Keeping the centre gives (1350, 250, 1500, 1000), anchor (0.9, 0.25).
- **Applying a preset that changes the ratio** follows the same rule. At zoom
  1 the same rule leaves a centred frame centred, as today.
- **Disagreement:** one maths critique preferred keeping `(z, anchor)`, so an
  edge-anchored frame keeps touching its edge. The other five reviews kept the
  centre, and so does this design.

### 4.5 Reset, undo and Esc

- **Double-click** and **View ▸ Frame ▸ Reset Frame** set the framing to
  `.full`: zoom 1, centred.
  - **View ▸ Frame ▸ Centre Frame** centres without changing the size, which
    is what double-click did before.
  - Lightroom users may expect a double-click to commit the crop. There is
    nothing to commit here, so reset is the useful meaning, and undo makes it
    safe.
- **Undo (⌘Z):**
  - Frame changes register on the window's undo manager: one entry per
    finished gesture, per Reset, per Centre, and per burst of key presses.
  - A burst ends after 1 s without a frame key, on a step of the other kind
    (a move after resizes, or the reverse), or on any other change to the
    settings. Menu and accessibility steps group like keys.
  - Action names: Move Frame, Resize Frame, Reset Frame, Centre Frame.
  - Pad registers nothing, as today.
  - A new image, a ratio change, a fit change and applying a preset clear the
    entries, because an entry restores a framing chosen under other
    settings. The app has no `UndoManager` use today.
- **Esc during a drag** puts the frame back where the drag started, bumps the
  generation and cancels the queued writes. The restore uses `deferredLive`,
  like the gesture's own writes (§4.7).
  - Whether SwiftUI delivers Esc while the mouse is down is to be checked in
    F. If it does not, Esc is dropped and ⌘Z covers it.
- **Pad:** a double-click centres the padded image, as today.

### 4.6 Keyboard, VoiceOver and Voice Control (#68 item 1, Crop only)

- **Crop only.** Under Pad and Stretch the preview takes no focus, has no
  frame element and View ▸ Frame is disabled. Pad's preview stays as it is
  today, so the Pad half of #68 item 1 stays open there.
- **Focus:** under Crop the preview is `.focusable()`, and a click on it
  focuses it. Keys act only while it has focus, so the sidebar's size field
  keeps its arrows.
- **Keys:**
  - Arrows move 1 source pixel, ⇧-arrows 10. The step is in source pixels, not
    anchor units: 0.01 of the anchor is 0.08 px of an 8 px sliver but 40 px of
    4000 px.
  - `+` and `−` resize by one short-edge pixel. They are matched by
    character, so `=` and `-` count too: on Swiss German `=` is ⇧0 and `+` is
    ⇧1, so a ⇧ modifier cannot mean "ten" here.
  - They resize around the centre. At an image edge, enlarging moves the
    centre just enough to stay inside, as the ratio-change rule does (§4.4),
    so the keys can always reach zoom 1. Drags still clamp (§4.2).
  - A held key stops at the 1:1 detent and at zoom 1. The next press goes
    past 1:1.
  - Under Scale a resize step re-solves, and the re-solved ratio can push the
    frame out of the image. The step then moves the centre just enough to
    stay inside, as Enlarge does at an edge. It never bisects: that is for
    drags (§4.2).
  - ⌘+, ⌘− and ⌘0 are left alone; they mean view zoom on macOS.
- **VoiceOver:** one accessibility element, "Crop frame".
  - Its frame is the rect on screen.
  - Its value is the caption plus the position, for example "Keeps 1500×1000
    of 3000×2000, left edge 500, top edge 0". With nothing cropped it is
    "Whole image, 3000×2000".
  - Adjustable: increment enlarges, decrement shrinks.
  - Named actions: Move Left/Right/Up/Down, Centre, Reset.
  - Reaching 1:1, the full frame, the smallest frame or an image edge is
    announced ("1:1", "Full frame", "Smallest frame", "At the left edge");
    individual drag samples are not.
  - **Steps:** a spoken command must not crawl a pixel at a time. The
    adjustable action, the named actions and the menu move by a tenth of the
    frame's width or height, and resize by a tenth of the frame's size. Each
    step is at least 1 source px, and stops at 1:1 like a key.
- **Voice Control:** custom accessibility actions alone are not a dependable
  path, so the same commands are in **View ▸ Frame**:
  - Move Left, Move Right, Move Up, Move Down;
  - Enlarge, Shrink;
  - Centre Frame, Reset Frame.

  - They are disabled with no image, and under Pad and Stretch.
  - An item that would do nothing is dimmed: Enlarge at zoom 1, Shrink at the
    smallest frame, a Move at that edge.
- **Write path:** every keyboard, accessibility and menu write goes through
  `deferred`. They are events too, and they have not been tested against the
  Form-width bug.
- **Modifiers** for the drag are E's (§4.1).

### 4.7 The macOS 27 Form-width bug

- **What the pan doesn't trigger:** today the pan changes nothing the sidebar
  shows.
- **What a corner drag changes on every event:**
  - it rewrites "Crops X%";
  - it adds and removes the upscale note as it crosses 1:1;
  - in the Scale view it rewrites the result and the output size.
- **Notes need stable ids.** They are `ForEach(…, id: \.self)` keyed by their
  text (`ControlsPanel.swift:115`), so each percent tick removes one row and
  inserts another while the mouse is down. Stable ids by kind make it an edit
  of one row.
- **Write path:** drag writes go through `deferredLive`, as one framing value.
  The release write and the Crop double-click also use `deferredLive`; Pad's
  gestures keep today's writes. `deferred`
  and `deferredLive` are not ordered with each other (`Deferred.swift:24`,
  `:35`), so a final `deferred` write could land before the last drag write.
- **Check:** the CGEvent drag recipe on macOS 27 must cover a corner drag
  crossing 1:1, in both the Width and the Scale view. It must also cover an
  arrow-key nudge, a `+` and a View ▸ Frame command. The sidebar must stay at
  340 pt.
- **Fallback if it still fails:** keep the drag state local to the preview,
  show live numbers only in the caption, and commit once on release.

### 4.8 Live output size during drags

- **Why it is needed:** each frame change changes the spec, which schedules a
  full-size encode. The 80 ms wait in `scheduleEncode` (`Session.swift:457`)
  happens once; after that, renders run back to back.
- **During a frame gesture:**
  - the byte readout pauses and shows its pending state;
  - one encode runs on release;
  - the frame, the caption and the sidebar numbers stay live.
- **Queued and running encodes too.** A job queued just before the gesture
  must not start during it: `scheduleEncode` sleeps 80 ms and then dequeues
  without looking again (`Session.swift:451-458`). Beginning a gesture
  discards the queued job, and the worker checks for a gesture before every
  dequeue. A render already running finishes, but does not publish.
- The existing pan of the crop frame gets the same pause. Pad's drag stays as
  it is.
- **Every gesture ends the pause.** The release calls `endFrameGesture()`
  even when the gesture's last framing write is dropped as stale, for example
  after Esc or a new image bumped the generation. Otherwise the byte readout
  would stay paused.

### 4.9 Drawing

- **Grid:** composition lines are hidden, per axis, when they would fall less
  than about 12 pt apart; the frame edges count as lines. The saved grid
  preference does not change.
- **Transparency:** when the output keeps alpha, a checkerboard shows behind
  the source in Crop view, as Pad already does (`PreviewView.swift:107`)
  (should).
- **Frame:** the frame and handles use the grid colour (black or white) with a
  contrasting hairline, so they read on any picture. Line weights, arm length
  on tiny frames and the existing shadow (`PreviewView.swift:83`) are settled
  in E's screenshot round with the owner.

## 5. Notes and caption

- **Crop note:**
  - It is shown whenever something is cropped (§2.4), Original included.
    Today it is gated on `session.reframes` (`ControlsPanel.swift:305`).
  - Compute `d = clamp(1 − (w/W)·(h/H), 0, 1)` in Double, with `source.area`,
    not the integer `pixelCount`. Equivalently, `d = 1 − (1 − d₀)/z²`.
  - Wording:
    - `0 < d < 1%`: "Crops less than 1% of the image." This fixes #69. Example:
      Original 6000×4000 → 1031×687 discards about 0.0485%.
    - `d > 99%`: "Crops more than 99% of the image."
    - Otherwise: "Crops N% of the image."
  - Amber only for the automatic reframe: `zoom == 1 && d > 0.4`. A frame you
    resized is a choice, not a surprise.
- **Pad note:** the same percent phrase. A sliver of padding reads "less than
  1% of the canvas is padding", not "0%". This wording fix, from the shared
  phrase, is the only change Pad's notes see.
- **Upscale note:**
  - Computed from the actual crop rect, `target.width / crop.width`, in one
    Geometry helper. Under Crop that equals `max(sx, sy)·z`. Under Pad and
    Stretch it is today's factor.
  - It shows when the factor is above `1 + 1e-9`, so the 1:1 detent never
    reads "Upscales by 0%". Below 1% it says "less than 1%".
  - The wording stays "Upscales the source by N%", independent of the crop
    note.
- **Caption** (`PreviewView.swift:196-214`), under Crop:
  - Zoomed, or reframed by the ratio: "Keeps W×H of S".
  - Nothing cropped (§2.4): "Whole image → W×H".
  - The hint goes to `.help` on the caption, not into the text: "Drag the
    frame to move it, or a corner to resize it. Double-click to reset." E's
    screenshot round may move it to the crop layer.
  - Dimensions are rounded, not truncated. Today `Int(crop.width)` turns
    1919.9999 into 1919.
  - When the actual resample factor is 1 (§2.4), the caption adds "· 1:1".
    That includes zoom 1 when the output is the frame's own size. When the
    output upscales it adds "· upscaled N%", with the same percent phrase, so
    the warning is where the eyes are.
  - The caption is one line (`lineLimit(1)`) with `.monospacedDigit()`. At
    the 960 pt minimum window the pane is about 590 pt wide and shares the row
    with two pickers, so a wrapping caption would change the preview's
    height, and with it the pointer mapping, mid-drag.
- **Under Pad and Stretch the caption stays as it is,** Pad's hint included:
  "Padded canvas W×H · drag to place, double-click to centre", and
  "Stretched to W×H". No "· 1:1" or "· upscaled" is added there.
- **Testable:**
  - `notes()` (`ControlsPanel.swift:289`) and the caption text move out of the
    views into plain functions that the SnapRescale tests can call.
  - The crop/reframe rule moves to RescaleKit (`CropSummary`, §2.4), so the
    CLI uses it too. Today the CLI uses `aspect.reframes(source)`
    (`main.swift:123`), and the app uses the solved ratio
    (`Session.swift:187-190`). The CLI's `fit pad` and `fit stretch` lines
    follow the same rule.

## 6. Presets and Custom

- **Framing never flips Custom,** not even when it changes the output under
  Scale. `currentPreset` (`Session.swift:73-76`) already leaves framing out.
- **Switching the size view** (Width ↔ Scale) now calls
  `noteSettingsChanged`. It changes the stored size parameter, but today
  Custom only follows spec changes (`ControlsPanel.swift:128`). Without the
  call, the preset name stays and a later frame change flips it to Custom out
  of the blue.
- **PRD §12 changes:**
  - A preset "replays exactly" only for Width, Height and Megapixels. A Scale
    preset replays a percentage of the current frame under Crop, and of the
    whole source under Pad and Stretch, as today.
  - A user Crop preset that stores `scale` gives a smaller output than in 1.2
    when its ratio differs from the source's. Applying a preset keeps the
    frame, so a frame made smaller shrinks the output further. No shipped
    preset uses Scale.
  - Presets have no version field, so this is a release note, not a
    migration.

## 7. CLI and launch arguments

- **`rescale --zoom Z --anchor x,y`:**
  - `Z` must be finite, at least 1, and at most `maxZoom` for the source at
    the requested ratio (§2.3), so it is checked before the solve.
  - `x,y` must be two finite numbers in 0…1, in upright image coordinates with
    y from the top. Parse with `NumberPair.parse`.
  - Out of range fails, unlike `CropAnchor.init`, which clamps.
  - Either flag with `--fit pad|stretch` fails, instead of being silently
    ignored.
  - Error messages come from A's errors, for example "Zoom 300 must be from 1
    to 250 for this image." and "Anchor 1.5,0.2 must be two numbers from 0 to
    1."
- **The same framing reaches** the solve, the summary and `RenderSpec`
  (`main.swift:104-106`, `:113`, `:123-129`, `:135`).
  - The crop line uses the shared reframe rule and the "less than 1%" wording.
  - The upscale line becomes "upscales the source by N%". A zoomed crop can
    upscale while the output is smaller than the source.
- **Units:** the CLI's `--scale 1` is a factor; the app's launch `--scale 100`
  is a percent. This is existing behaviour, now documented in the CLI usage
  text (C).
- **App launch arguments:**
  - `--zoom` and `--anchor` are held like `launchAspect`
    (`Session.swift:208`, `:323`) and applied once after the image loads, then
    cleared.
  - Loading an image resets the framing (`Session.swift:321`), so assigning
    them directly would be lost.
  - A bad value is ignored, as for the other launch arguments
    (`Session.swift:196-242`), and prints one line on stderr. The other launch
    arguments print nothing today, and this design does not change them. The
    other flag still applies.
  - With `--fit pad` they still set the crop frame, which shows on switching to
    Crop.
  - They let the screenshot recipes in `APP-STORE.md` show handles.

## 8. Not in scope (possible follow-ups)

- Free-form ratios, and drawing a new frame by dragging outside it, as in
  Preview. The ratio picker is the ratio.
- Edge handles; pinch to resize; X to flip the ratio's orientation
  (Lightroom).
- A magnifier for very small frames. The preview is at most 2048 px
  (`Session.swift:313`), and Photos and Lightroom enlarge the image rather
  than shrinking the frame.
- XMP face regions (MWG/IPTC) are kept as they are, so any crop leaves them
  wrong. This is true today too, and gets worse with smaller frames. Stripping
  or remapping them on crop is a metadata follow-up.

## 9. Interaction with the WebP design

`docs/design/webp-1.3.md` (WebP, now 1.4) edits some of the same places. The
crop frame ships first. If WebP code reaches `main` before
`feature/crop-frame` merges, G merges `main` into the branch and resolves
these before its release checks; otherwise WebP's items resolve them on top of
the crop frame:
- `RenderSpec` and its initialiser (webp-1.3.md l.61, l.149-153): this design
  replaces `anchor` with `framing`.
- The `RenderSpec` call sites, `main.swift:135` among them (webp l.187).
- The `Preset.swift:3-5` doc comment quoted in webp l.199 and decision 12. It
  becomes "Not the framing (the crop frame's position and size)".
- The CLI usage lines (webp l.502-513).
- The sidebar notes in `ControlsPanel.swift:289-324` (webp l.583). This
  design moves them into a testable function.
- The Help text, which must stay word for word the same (webp l.595-600).
- The per-image reset recipe (webp l.714): framing resets per image.
- F's files:
  - `Session.swift` (WebP M, #87);
  - `SnapRescaleApp.swift` (WebP O, #89: the Settings view and a new
    scene);
  - the `Deferred.swift` doc comment (WebP N, #88).
- Files the WebP items own that crop-frame items also edit:
  - `ValidationTests.swift` (WebP L, #86, l.137 and l.140; B edits l.67 and
    adds tests);
  - B's interim edits in `Session.swift` (l.175, 411, 416),
    `ControlsPanel.swift` (l.244, 253) and `main.swift` (l.105-106, 113),
    which WebP M, N and K own.
- The docs table (webp l.823-854): README, PRD status line, ROADMAP,
  CHANGELOG and `docs/APP-STORE.md`. The keywords are not a crop-frame edit
  (decision 3).
- The webp-1.3.md line numbers here are at `e451678`. This branch's first
  commit adds a 5-line renumbering note at its top, so on the branch each
  reads 5 higher (l.61 is l.66).
- **If WebP's code is on `main` when G runs,** it is the whole feature: WebP
  merges to `main` only after its release gate (#91). G then stops before the
  release and asks the owner what 1.3 ships.

## 10. Items

Items go into `feature/crop-frame` one PR each; the branch merges to `main`
after item G. Each item's issue lists what it depends on, the files it owns,
the design, the tests and the acceptance criteria.

| Wave | Item | What | Owns | Needs |
|---|---|---|---|---|
| 0 | **A** | Framing model and geometry: `CropFraming`, frame rect with zoom, rect → framing, corner and centre resize, reframe keeping the centre, 1:1 zoom, `maxZoom`, discarded fraction, resample helper; `RenderSpec.framing`; pixel-exact 1:1 origin; validation | `Geometry.swift`, new `CropSummary.swift`, `Renderer.swift`, `Validation.swift` (framing checks), `Preset.swift` (doc comment), new `GeometryTests.swift`, `RendererCropTests.swift` | — |
| 1 | **B** | Scale against the frame: solve context, `referenceArea` on `Solution`, readout, `resampleScale`/`isUpscale` with zoom, `targetForZoom`; prototype, exporter and regenerated parity fixture | `Solver.swift`, `Solution.swift`, `SizeParameter.swift`, `Validation.swift` (`validate(for:)`), `prototype/solver.py`, `prototype/export_fixture.py`, `Fixtures/solver-parity.json`, `ParityTests`, `PropertyTests`, `TableTests`, `ValidationTests` | A |
| 2 | **C** | CLI: `--zoom`, `--anchor`, the shared reframe rule, crop and upscale lines | `RescaleKit/Sources/rescale/main.swift` | A, B |
| 2 | **D** | Session and sidebar: `cropFraming`/`padAnchor`, reset and centre, aspect-change rule, launch arguments, view-switch Custom fix, notes as a testable function with stable ids (#69), caption text, encode pause during gestures | `Session.swift`, `ControlsPanel.swift`, new `OutputNotes.swift`, new `OutputNotesTests.swift`, `SessionFramingTests.swift` | A, B |
| 3 | **E** | Preview: handles, hit zones, gestures and lifecycle, cursors, detents, drag maths wiring, grid suppression, Crop checkerboard, caption layout | `PreviewView.swift`, new `CropHandles.swift`, new `CropHandlesTests.swift` | D |
| 4 | **F** | Keyboard, VoiceOver, Voice Control and undo, under Crop only: focus, keys, the accessibility element, View ▸ Frame menu, undo registration, Esc (the Crop half of #68 item 1) | `PreviewView.swift` (focus and accessibility), `SnapRescaleApp.swift`, `Session.swift` (undo and steps), `Deferred.swift` (doc), new test files | E |
| 5 | **G** | Release 1.3: CHANGELOG, App Store copy (What's New and the description sentence; the keywords stay as they are), README screenshot with handles, the macOS 27 check, the VM check on macOS 26, version 1.3 (5) | `CHANGELOG.md`, `docs/APP-STORE.md`, `docs/RELEASING.md`, `README.md`, `docs/screenshots/`, `project.yml`, the status lines (PRD, ROADMAP, this note) | all |

- **Every item PR leaves the branch green:** both packages build, and
  `swift test` passes in `RescaleKit` and `SnapRescale`.
  - An item that changes an API used in a later item's file makes the
    smallest edit there to compile and keep today's behaviour, for example
    passing `.full` or zoom 1.
  - It lists those edits in its issue. There are no compatibility shims.
  - The later item then does the real change.
- **Defaulted parameters hide callers.** B gives `resampleScale` and
  `isUpscale` a defaulted `zoom: Double = 1`, so the compiler does not find
  `main.swift:127` (C), `ControlsPanel.swift:320-321` (D) or
  `PreviewView.swift:200` (E). Those issues name them.
- **Docs done before the items:** the PRD, Help (`docs/HELP.md` and
  `AboutAndHelp.swift`), README and ROADMAP changes are in the branch's first
  commit, together with this design. So is renumbering WebP to 1.4
  (decision 2). The items do not redo them, but each
  item corrects the docs if its implementation differs.
- **Tests per item** are listed in the issues. The concrete numbers below are
  shared by all of them.

### 10.1 Shared test cases

All at multiple 1 unless a multiple is given. The app's default is 8
(`AppSettings.swift:25`), so manual checks set multiple 1 first.

- **Geometry, on 3000×2000:**
  - 1:1, zoom 1, centred → (500, 0, 2000, 2000).
  - 1:1, zoom 2, anchor (0.25, 0.75) → (500, 750, 1000, 1000), discards 83⅓%.
- **Drag, from start (1000, 500, 1000, 1000), dragging the bottom-right corner:**
  - Pointer to (2300, 1100) → (1000, 500, 950, 950), zoom 40/19, anchor
    (20/41, 10/21).
  - Same pointer with ⌥ → (1050, 550, 900, 900), zoom 20/9, centred.
  - Pointer to (4000, 4000) → (1000, 500, 1500, 1500). The opposite corner
    is unchanged.
- **Drag, from start (500, 0, 2000, 2000), dragging the bottom-right corner:**
  - Pointer to (2000, 1000) → (500, 0, 1250, 1250), zoom 1.6, anchor (2/7, 0).
  - Same start, ⌥ with the pointer at (2000, 1500) → (1000, 500, 1000, 1000),
    zoom 2, centred.
- **Every drag:**
  - All four corners.
  - The pointer crossing the fixed corner stops at the minimum, with no flip.
  - Zero slack: the rect → framing → rect round trip holds.
  - NaN, ∞ and huge zoom or anchor values give finite, clamped geometry.
  - Under Scale, a candidate that the re-solved ratio pushes out of the image
    is rejected, and the pivot does not move: the §4.2 example, for all four
    corners, and for ⌥ with its own pointer, (5978.99, 3986.21).
  - The end-to-end case, through B's `targetForZoom`, is in B's `TableTests`.
    A, in wave 0, tests the check and the bisection with a stand-in target.
- **Scale on 3000×2000 at 1:1, multiple 1:**
  - 100% gives 2000×2000 at zoom 1 and 1000×1000 at zoom 2, with no upscale.
  - Original at zoom 1 is bit-identical to today.
  - 1234×777, Original, Scale 100%, multiple 32, at zoom 48.5625 (the
    limit): accepted, solves to 64×32, and the drawn frame of about
    25.41×12.71 lies inside the image. Zoom 48.6 is rejected by the CLI.
  - A ratio change that lowers `maxZoom` clamps the zoom first.
- **Detents on 3000×2000 at 1:1:**
  - Width 1000 → 1:1 at zoom 2; Height 500 → zoom 4; 1 MP → zoom 2.
  - Width 3000 → none (it would need zoom 2/3).
  - Width 1500 at zoom 2 resamples by 1.5 and upscales.
- **Aspect switch:** the §4.4 example.
- **View switching:** the three §3.3 examples.
- **Notes:**
  - Original 6000×4000 → 1031×687 reads "less than 1%".
  - At zoom 64, "more than 99%".
  - 9:16 on 6000×4000 at zoom 1 is 62.5%, reads "Crops 62% of the image"
    (§2.4) and is amber; after a resize it is not.
  - Under Pad, the notes and caption are today's, apart from the sliver
    wording.
- **Renderer:**
  - A quadrant-coloured fixture at zoom 2, anchor (0, 0), gives the top-left
    quadrant.
  - At zoom 1 the bytes match today's for the same target when the
    resample factor is not exactly 1.
  - 3001×2000 to 2000×2000 at 1:1, centred: the output equals a whole-pixel
    crop of the source (§2.2).
  - At the 1:1 detent the output equals a whole-pixel crop of the source, and
    `cropRect` returns that whole-pixel rect.

### 10.2 Choices the items made

The second drafting round settled these where the design was silent. They are
in the issues; they are listed here so the design stays the record.
- **B:** `Solution.resampleScale` and `isUpscale` use the zoom as given.
  Callers pass their stored, clamped zoom; `cropRect`'s guard keeps a bad
  value finite.
- **B:** `validate(for:context:)` calls `CropFraming.validateZoom(_:maxZoom:)`.
  C relies on it and does not check the zoom a second time.
- **C:** errors come in argument order. Parse errors first (a bad zoom, a bad
  anchor, the anchor's range), then a flag with `--fit pad|stretch`, then
  `validate(for:context:)`. Parse errors keep the CLI's wording ("bad zoom").
- **D:** a bad launch value prints "SnapRescale: ignoring --zoom 300." and
  then A's sentence.
- **D:** a ratio change under Pad also moves the hidden crop frame by the
  centre rule (§4.4), solving the Crop target, so it is where the user left
  it on going back to Crop.
- **E:** a drag that SwiftUI cancels without `onEnded` is finished through a
  `@GestureState` reset, which calls `endFrameGesture()` (§4.8).
- **F:** the VoiceOver value keeps the caption's "· 1:1" and "· upscaled N%",
  so the warning is heard too.
- **F:** ⌘Z, or any other generation bump, during a gesture means the gesture
  registers no undo entry.
- **F:** Centre Frame is dimmed when the rect is centred; an axis with no
  slack counts as centred, whatever its stored anchor.
- **F:** a step refused at a stop changes nothing, registers nothing and does
  not restart the 1 s burst clock.
- **G:** #68 item 1 stays unticked when the branch merges; G notes on #68 that
  the Crop half shipped in 1.3. G's merge PR into `main` says "Fixes #69",
  because GitHub closes issues only from PRs into the default branch.

## Owner decisions (2026-11-03)

1. **Crop only; Pad stays as it is.** The question was whether Scale under
   Pad should measure against the whole source, as today (3000×2000 at 1:1
   and 100% gives a 2449×2449 canvas with the image at 82%), or against the
   smallest canvas that contains the image (3000×3000).
   - The owner's answer: the new functionality is for Crop only, and Pad,
     the rare case, keeps today's behaviour. Scale under Pad stays measured
     against the whole source.
   - Under Pad there are no handles, keys, accessibility element, View ▸
     Frame commands or undo. Its drag, double-click, caption and write paths
     are today's (§2.1, §4.5-4.8, §5).
   - What Pad does see comes from shared code, not new features: a separate
     `padAnchor` (§2.1); the shared percent phrase in its padding and upscale
     notes, so a sliver or a 0.3% upscale reads "less than 1%", not "0%"
     (§5); the upscale test's 1e-9 tolerance; the padding note's gate
     becoming the integer ratio test (`CropSummary.reframes`); and the CLI's
     `fit pad` and upscale lines worded the same way (§7).
   - The Pad half of #68 item 1 stays open.
2. **1.3.** The crop frame ships as 1.3 (5), and WebP moves to 1.4, with the
   build after the crop frame's. The renumbering is in the branch's first
   commit (§10):
   - the WebP design's text (the file name `webp-1.3.md` stays, since #1
     and #76–#98 link to it);
   - ROADMAP (the v1.3 heading and the M5 preset note), PRD §9 and §12, and
     the `Preset.swift:89-90` comment;
   - `docs/APP-STORE.md`'s "Before submitting 1.3" list.

   On GitHub, done on 2026-11-03: the milestone is now "1.4 WebP", with
   the `webp` label's description, the titles of #90 and #91 and the bodies
   of #1 and #76–#98 to match, and a note on #1. There is a precedent:
   `6b81ba4`, "renumber formats to 1.3".
3. **Keywords.** No new App Store keywords for now. G leaves them as they
   are.
