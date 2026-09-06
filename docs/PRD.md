# SnapRescale — Product Requirements Document

**Status:** Draft v0.12 · 2026-09-06 · **v1 scope: one image** · M0 solver shipped in `RescaleKit/`
**Name:** SnapRescale — *Resize to any ratio, snapped to multiples of 8 and 16* · bundle ID `com.phierru.SnapRescale`
**Platform:** macOS 26+ (Apple Silicon), Swift 6 / SwiftUI

---

## 1. Problem

Resizing an image on a Mac is served by three bad options.

**Apple's *Convert Image* Quick Action** offers Small / Medium / Large / Actual
Size. What those mean is never stated, and there is no way to say what you
actually want.

**Parallels Toolbox → Resize Images** (v7.1.0, the tool this project is a reaction
to) is better and still thin. Its entire surface: an *Image Size* tab with Width
and Height, a *File Size* tab with a KB/MB target, a format picker limited to
JPEG / PNG / TIFF / HEIC, a "Keep image metadata" checkbox, and one fixed output
folder. It reads only TIFF, JPEG, PNG and HEIC. It has no percentage scaling, no
megapixel or aspect targeting, no quality control, no upscale guard, no filename
templating, no presets, no Finder Quick Action, no CLI — and it is gated behind a Toolbox
subscription.

**Photoshop / Affinity / GIMP** can do all of it and cost a full application
launch plus a dialog tour to shrink four screenshots for a wiki page.

Meanwhile ComfyUI's stock `Resize Image/Mask` node — a free node in a Python
image-generation tool — models the problem better than any of them. Nine resize
modes behind one selector, five resampling algorithms with a stated
recommendation, and an aspect-mismatch policy with exactly two honest answers.
See [`reference/comfyui-node-review.md`](reference/comfyui-node-review.md).

**SnapRescale ports that model to a native Mac utility.**

## 2. Goals

- Cover every resize intent people actually have, not just W×H.
- Right-click an image, get a resized copy, in under ten seconds — and *see the
  crop before committing to it*.
- Never silently degrade an image: no accidental upscales, no stripped colour
  profiles, no rotated-sideways EXIF surprises.
- Keep the engine free of UI, so batch, a CLI and Shortcuts can be added later
  without revisiting the model.

## 3. Non-goals (v1)

- **Batch.** v1 handles exactly one image — the one you right-clicked (§8).
  Folders, multi-selection, queues and progress UI are v2.
- Editing: no retouch, filters, layers, or colour grading.
- AI upscaling. SnapRescale resamples; it does not hallucinate. (Possible v2.)
- iOS / iPadOS.
- A cloud anything.

## 4. Users

- **Primary — Francesco.** Screenshots for docs and tickets, photos for Obsidian
  notes, assets for internal dashboards. Wants a right-click and a preset.
- **Secondary — colleagues** who receive "can you shrink these" requests and
  currently open Preview and do it one at a time.
- **Tertiary — scripts.** Build steps, LaunchAgents, `find | xargs rescale`.

---

## 5. The core model: one parametric constraint system

**There are no modes.** There is an aspect ratio and a size, both always visible
and both always editable. Changing either re-solves the rest.

This is the operating principle of the whole application, and it is what
separates SnapRescale from every tool in §1 — those make you first choose *how* you
want to express the size, then express it. SnapRescale lets you express it however
you happen to be thinking, and keeps the rest consistent.

### Aspect ratio is always set

Aspect is not a free field competing for a slot. It is a picker, always
populated, exactly ComfyUI's `ResolutionSelector` list plus one entry, shown
with ComfyUI's names ("16:9 (Widescreen)", "2:3 (Portrait Photo)", …):

**Original** *(default)* · 1:1 · 2:3 · 3:2 · 3:4 · 4:3 · 9:16 · 16:9 · 21:9

**Original** means each image keeps whatever ratio it already has — any ratio, not
a preset — so nothing is cropped and nothing is padded. It is the default because
it is the answer most of the time: usually you want the image smaller, not
different.

Because the ratio is *always* known, the target size has **one remaining degree
of freedom**, not two. This collapses the model considerably. There is no
contest between constraints, so there are no pins to track, no locks, and no
parameters silently demoted to derived — the machinery in v0.2 of this document
existed only to arbitrate a competition that no longer happens.

> **Aspect + one number = a complete answer.**

### One size, four views

Width, Height, Megapixels and Scale % are four ways of writing the same single
number. Edit any one; the other three re-read immediately:

| You edit | Solver does |
|---|---|
| Width | height = width ÷ aspect |
| Height | width = height × aspect |
| Megapixels | both, from √(px × aspect) and √(px ÷ aspect) |
| Scale % | both, as a linear multiple of the source |

Values you typed render normally; values the solver produced render dimmed. That
is the whole of the state model.

**Selecting a view makes it the controlling input.** The current solved value is
carried across at full precision (only the field's text is rounded), and the
solver re-solves for that view. Pinning width holds one axis; megapixels frees
both. So at multiple 16 the derived axis can legally move by one lattice step
on a view switch, and the notes under Output say so. At multiple 1 nothing
moves.

**Original is exact up to the multiple.** With a multiple of 8 or 16 the
snapped size can differ from the source ratio by a few pixels; the renderer
then crops that sliver and the crop percentage reports it (typically under
0.5 %).

**Long edge and short edge are dropped.** They existed to disambiguate mixed
portrait/landscape batches, and with an explicit ratio — and, in v1, a single
image — the ambiguity is gone. The case that resurrects them is a
mixed-orientation *folder* under **Original**, where `width = 1024` gives a
portrait shot 1024×1536 and a landscape shot 1024×683: same width, wildly
different size on screen. Megapixels equalises that, so it is the parameter batch
mode should default to. Both are v2 concerns (§8).

### The size control

One control, reused for Width, Height, Megapixels and Scale. Three affordances
over the same value, each for a different intent:

| Affordance | For |
|---|---|
| **Numeric field** | You know the number. Type it. |
| **− / + steppers** | You are one notch off and want to nudge. |
| **Ladder row** | You want one of the usual sizes. One click. |

> **The detented slider was dropped 2026-09-06** after living with the app:
> the ladder row covers the "I don't know the number" case well enough, and
> a slider would have cost a day and a row of panel height. The log-scale and
> detent notes below are kept for the record; M2 is struck from §14.

**The steppers must step by the `multiple`, not by 1.** Prototyped, and this is
not a preference: at multiple 16, +1 from 1024 gives 1025, which snaps straight
back to 1024×688. So does 1026. The button appears broken because it *is*
broken. Step by 1 when the multiple is 1, otherwise by the multiple; hold ⇧ for
×10.

**The slider must be logarithmic.** Also prototyped. On a linear 128–8192 track
the four detents land at 4.8%, 7.9%, 11.1% and 23.8% — every value anyone cares
about crushed into the left quarter, and the whole right half spent on sizes
nobody picks. On a log₂ track they sit at 33%, 43%, 50% and 67%:

```
 128    256    512   768  1024  1536  2048        4096            8192
  |      |      |     |     |     |     |           |               |
  0%   16.7%  33.3% 43.1% 50.0% 59.7% 66.7%       83.3%           100%
```

**Detents at 512 · 768 · 1024 · 1536 · 2048**, drawn as labelled ticks. Until
the slider exists (M2) the same ladder is a row of buttons under the field. They are
*magnetic, not modal*: the thumb is attracted within a few points and ⌥-drag
bypasses them entirely. A second, unlabelled detent grid sits at every multiple,
so a free drag still lands on a legal value.

All five detent values are divisible by **8 and 16**, so a detent is never
displaced by snapping (§6) at any multiple. Any custom entry failing that test is
flagged in preferences, because it quietly loses the guarantee. Combined with
steppers that move by the multiple, the pinned axis is essentially always already
on the lattice — which makes §6 a no-op in normal use and a safety net in the
rest.

Details:

- **Range** 128–8192 by default, extending upward if a source image exceeds it.
- **⌘1–⌘5** jump to the five detents; ← / → step; ⇧← / ⇧→ step by ten.
- **The ladder is editable** in preferences. The default is the ML/diffusion
  ladder; web work wants something nearer 640 · 1280 · 1920 · 2560.
- **Upscaling is a warning, not a lock** (decided 2026-09-06): a target larger
  than the source is allowed and flagged under Output with the factor. No
  *Never upscale* setting.
- The **megapixel** instance uses its own ladder: 0.25 · 0.5 · 1 · 2 · 4 MP.
- Dragging re-solves continuously. Numbers update at full rate; the crop preview
  (§7) throttles to keep the drag smooth.
- **Build cost:** SwiftUI's `Slider` does neither log scales nor detents, so this
  is a custom control over a normalised 0–1 binding with a log₂ mapping and a
  drawn tick layer. Roughly a day to do properly, reused three times.

### `multiple` is not a degree of freedom

The multiple — **1, 8 or 16** — is a quantiser applied *after* the continuous
solve, not another constraint competing for a DOF. Given the ideal real-valued
(W\*, H\*), the solver searches nearby lattice points and minimises a weighted sum of
squared log errors, aspect ratio weighted 1.0 and pixel count 0.05 — so aspect
dominates, but a large pixel deviation can outweigh a tiny aspect one.

---

## 6. Snapping must not move what the user typed

This is the one genuinely subtle decision in the model, and prototyping it
changed the answer. Source 6000×4000, comparing two snapping objectives:

| Request | multiple | Aspect-priority | Pin-respecting |
|---|---|---|---|
| width 1920 + 16:9 | 16 | **1936**×1088 (AR off 0.09%) | **1920**×1088 (AR off 0.74%) |
| width 1032 + 3:2 | 16 | **1040**×688 | **1024**×688 |
| width 1500 + 16:9 | 8 | 1496×840 | 1504×848 |
| aspect 16:9 + 2 MP | 8 | 1888×1064 | 1888×1064 |

Across 69 widths × 4 ratios at multiple 16, the two objectives disagree **142
times** — this is the common case, not a corner.

A pure aspect-ratio objective will happily rewrite **1920 to 1936** to recover
0.65% of aspect error that no human can see. Typing a number and watching it
change under your fingers is the single most alienating thing a parametric UI can
do, so:

> **Rule.** The axis the user set numerically snaps to its own nearest lattice
> value and is then **held fixed**. Only the axis derived from the aspect ratio
> is searched.

Restricting the multiple to 1/8/16 keeps the cost of this trivial: worst observed
aspect deviation is **0.74%**, against 0.35% for the objective that betrays the
user. That is a good trade.

**Hold first, then derive.** When the typed value is off the lattice, the
snapped value is what gets written, so the derived axis is computed from *that*,
not from the number typed. `width 1500 + 16:9` at multiple 8 snaps the width to
1504 and then asks for the best height for 1504, not for 1500. Property-testing
the Swift port found this: without it, re-solving with the value on screen could
move the derived axis by one lattice step, so the solution was not a fixed point
of itself.

In practice this section rarely fires at all: the steppers move by the multiple
and every slider detent is divisible by 8 and 16 (§5), so the axis you set is
almost always on the lattice already. This is the safety net for typed values and
for **Original** ratios, not the everyday path.

**When the request is impossible, say so.** `1920×1080` with multiple 16 cannot
exist — 1080 is not divisible by 16. The solver returns 1920×1088 and the UI
states plainly that the multiple forced the change, rather than silently
producing a number the user did not ask for.

Reference implementation and the case table: [`prototype/solver.py`](../prototype/solver.py),
[`prototype/compare.py`](../prototype/compare.py). The Swift port in
[`RescaleKit/`](../RescaleKit/) is held to the prototype by a generated parity
fixture (`prototype/export_fixture.py`, 5,940 cases) plus property tests.

---

## 7. Crop and pad, with a live preview

Solving for a target size does not say what happens to the pixels. Whenever the
target aspect differs from the source aspect — which, under this model, is most
of the time — geometry must be added or removed.

### Fit policy

- **Crop (cover)** — *default.* Scale to fill the target, discard the overflow.
- **Pad (contain)** — scale to fit inside, fill the remainder with a chosen
  colour: transparent, white, black, or custom via colour well and eyedropper.
  Transparent (opacity 0 in the colour well) falls back to compositing over
  white for formats without an alpha channel; the preview shows the same white,
  not a checkerboard, and the UI says so rather than silently flattening to black.
- ~~**Stretch** — distorts. Present because it is occasionally meant.~~ *Dropped
  from the app 2026-09-05; the CLI keeps it.*

### The preview

The window's main content: the source image at a comfortable size with a **crop
rectangle** overlaid — the region that survives — or, in pad mode, the padded
canvas with the source inset and the fill colour rendered.

The preview is not decoration. Under this model the user is frequently changing
one number and getting a reframe they did not fully picture, and the rectangle is
the only honest way to show it before anything is written. At n=1 (§8) it can be
exact rather than indicative, which is most of the argument for starting there.

- **Anchor**: **direct dragging of the crop rectangle** (or of the inset image,
  in pad mode); double-click re-centres. *The 3×3 grid was built and then dropped
  2026-09-05 — dragging covers it.*
- **Composition grid** inside the frame, display only, disabled in pad mode,
  remembered across launches (the default grid becomes a setting in the M5
  preferences window): **Frame only · Centre lines · Rule of thirds** *(default)* **·
  Golden ratio · Rule of fifths**, picked from an icon button group under the
  image pane, not in the control panel. Reviewed and left out for now, in case
  they are wanted later: diagonals (45° from each corner), golden triangles (one
  diagonal plus perpendiculars, two orientations), golden spiral (eight
  orientations), uniform N×N grid for straightening, centre crosshair, dynamic
  symmetry armature, aspect-ratio ghost frames, video safe areas. Lightroom's
  O / ⇧O cycle-and-flip convention is the model if the orientation-dependent
  ones are ever added.
- Live update on every solver change.
- Reports the discarded fraction — "crops 18% of the image" — so an aggressive
  reframe announces itself.
- Warns when the target exceeds the source and *Never upscale* is off.

---

## 8. The single-image session

**v1 targets exactly one image: the one you right-clicked or dropped.** No file
list, no queue. That is not a limitation to apologise for — it is what makes the
crop preview honest. At n=1 the app can show you precisely what you are about
to get, and there is no such thing as a representative thumbnail for a folder.

### Entry

Right-click an image in Finder → **Open With → SnapRescale**, the same route the
Parallels tool takes. The app registers as a viewer for the image UTIs in §9, and
also ships a **Services** entry, *Resize with SnapRescale*, so it appears in the
context menu's Services submenu. (A true *Quick Actions* entry needs an Action
Extension or a Shortcut; deferred with the rest of §13.)

**Session lifetime follows the entry route** (decided 2026-09-06):

- Launched *for* an image — Open With, Services, a drop on the Dock icon — the
  app is a one-shot tool: the buttons read **Save & Quit** and **Save As &
  Quit…**, and a successful save reveals the file in Finder and quits.
- Launched from the Applications menu and given an image by drop or ⌘O, it is
  a window: it stays open until closed, and Save is just Save.
- An image handed to an *already open* window by Open With or Services keeps
  the window's mode.

**Second route: launch the app itself.** SnapRescale is also an ordinary app in
Applications, Launchpad and the Dock. Launched with no document, it opens an
empty window that is a **drop target**: drag one image onto it (or onto the Dock
icon) and it becomes the session. The same window offers ⌘O and a *Choose
Image…* button for people who do not drag. Dropping a second image while one is
open **replaces it immediately** — this is a disposable one-shot session, not a
document, so there is no dirty check (decided 2026-09-05). v1 never holds two.

Drop accepts the image UTIs in §9. A folder, a multi-selection or a non-image
is refused with a plain message rather than taking the first file silently.

One file in, one window, whichever way it arrives.

### The window

The preview is not a 240 px inspector thumbnail any more — at n=1 it is the
window's main content, large, with the crop rectangle drawn over it and the
controls in a sidebar on the right (built and kept; "beneath" in earlier drafts).
Source dimensions and file size are shown plainly at the top, because every
decision below is relative to them.

Because there is exactly one image, two things become possible that a batch
cannot offer:

- **A real output size, not an estimate.** The app encodes to memory in the
  background on each change and shows the actual byte count — "1024×683 JPEG,
  148 KB" — rather than guessing from a quality curve. One render runs at a
  time and the latest request wins, so a drag never queues stale full-size
  encodes. This is what will make the *target file size* control (§11, M4)
  trustworthy instead of aspirational.
- **Detents past the source size dim** with a real number attached, since the
  source is known and singular.

### Saving

Default `⌘S`: write next to the original as `{name}_{w}x{h}.{ext}`, and reveal it
in Finder. `⇧⌘S` opens a standard save panel, pre-filled with the next free
counter name; choosing an existing name — the original included — goes through
the system's own replace confirmation. `⌘S` never overwrites anything.

### What batch mode changes later

Deferring batch does not cost re-architecture, because the solver already runs
per image (§5) and knows nothing about how many there are. Batch adds a file
list, a queue with progress and cancel, recursion, filename collision counters,
and the "reframes 14 of 22 images" warning that only matters in aggregate. The
natural v2 split is:

> **UI for one image, headless presets for many.** You open a window when you
> need to look at the crop; you use a preset Quick Action when you do not.

## 9. Formats

Decode and encode run on ImageIO. Verified on this machine (`sips --formats`, macOS 26.6):

**Read:** JPEG, PNG, TIFF, HEIC/HEIF, AVIF, WebP, JPEG XL, GIF, BMP, PSD, PDF,
OpenEXR, SVG, and the full RAW set (CR2/CR3, NEF, ARW, RAF, ORF, RW2, DNG, …).

**Write via ImageIO:** JPEG, PNG, TIFF, HEIC, AVIF, GIF, JPEG 2000, BMP, PDF.

**Write, needs help:** **WebP** and **JPEG XL** are read-only in ImageIO. WebP is
the format the web actually asks for, so WebP encoding via bundled `libwebp`
is the first item of M4, immediately after the v1 cut (M0–M3). This is the single biggest implementation constraint in the project:
it adds a native dependency and complicates sandboxing and notarisation if
SnapRescale is ever distributed. JPEG XL is deferred to v2.

Per-format encoder options: JPEG quality + chroma subsampling + progressive,
PNG bit depth + interlace, HEIC/AVIF quality + lossless toggle, WebP quality +
lossless + effort.

**Format: Keep original** must be available, so a resize is only a resize. When
the source cannot be written (GIF, WebP, RAW, …) the item is disabled with the
reason, and the app switches to PNG if the source has alpha, JPEG otherwise, and
says so — it never converts silently.

## 10. Metadata and colour

Not a checkbox. Three independent switches, because "keep metadata" conflates
things that people want separately:

- **EXIF / IPTC / XMP** — keep all · keep camera & date, drop the rest · drop all
- **GPS location** — keep · drop *(separate: this is the one people strip for privacy)*
- **ICC profile** — preserve · convert to sRGB · strip

**What the source carries is shown up front.** The header row above the
preview — name, dimensions, file size, format — ends with one badge per
metadata block found: **ICC** (profile name on hover), **EXIF**, **GPS** (in a
warning colour), **IPTC**, **XMP**, **Alpha**, **16-bit**, **HDR**, **Depth**,
**Rotated**, **Animated ·N**, and one per AI-generation source detected:
**ComfyUI**, **A1111**, **InvokeAI**, **NovelAI**, **Fooocus**, **SwarmUI**,
**Midjourney**, **C2PA**. The full catalogue, where each lives and how it is
detected, is in [`reference/image-metadata.md`](reference/image-metadata.md).
The badges are the hooks the switches below attach to; a **keep AI workflow**
switch (carry the PNG text chunks into the output) joins them in M4.

**Orientation is always normalised**, whatever the metadata setting: the EXIF
orientation flag is baked into the pixels and reset to 1. Stripping metadata
without doing this is how naive resizers deliver sideways photos, and it is the
most common defect in tools of this class.

## 11. Output

**v1** writes one file, next to the original, named `{name}_{w}x{h}.{ext}`.
`⇧⌘S` opens a save panel for anywhere else. Collisions append a counter; nothing
is ever silently overwritten. Replacing a file, the original included, happens
only through the save panel's explicit confirmation.

**Target file size** *(M4)*: an optional byte ceiling per output — "≤ 1 MB" —
met by searching the encoder quality downward, at fixed geometry, using the
same background encoder that produces the live byte count.

**Deferred to batch (v2):** destination folder choice, a `./resized/` subfolder,
replace-in-place with Trash-the-original, recursion preserving directory
structure, and the full filename template (`{name}` `{ext}` `{w}` `{h}`
`{preset}` `{n}` `{date}`). The v1 name is that template with the default value,
so the mechanism ships early even though the UI for it does not.

## 12. Presets

A named bundle of *every* setting above — mode, parameters, fit, resampling,
format, quality, metadata, destination, template. Presets are the point: they
turn a twelve-control dialog into a one-click action.

Shipped defaults: **Web (Original ratio, 1.5 MP, JPEG q80, sRGB, strip GPS)** ·
**Email (Original, ≤ 1 MB)** · **Thumbnail (1:1, 320 px, crop)** ·
**Social 16:9 (1920 px, crop)** · **Discord/Slack (≤ 8 MB)**.

A preset stores the aspect ratio and the one size parameter, so it replays
exactly. Presets whose aspect is a preset rather than Original will crop, and the
preset editor says which.

Stored as JSON in `~/Library/Application Support/SnapRescale/presets/`, so they are
editable, diffable, and shareable.

## 13. Surfaces

1. **App, one image** *(v1, the primary surface)* — opened from Finder via
   **Open With → SnapRescale**, or launched directly and given an image by drag and
   drop / ⌘O. Large crop preview, aspect picker, one size control,
   real output byte count, Save. This is the interaction that replaces the
   Parallels workflow, and the reason to build the thing.
2. **Finder Quick Action, headless** *(v2)* — right-click → SnapRescale →
   *‹preset name›*, applied to a selection without opening a window. Notifies on
   completion. Batch belongs here rather than in the app.
3. **CLI** — one aspect flag and one size flag, mirroring the panel. Proposed
   v2 syntax: `rescale --aspect 16:9 --width 1920 --format jpeg --quality 80 *.png`,
   or `rescale --mp 1.5 *.png` (aspect defaults to original), plus `--preset web`,
   exit codes and machine-readable `--json` output. The M1 throwaway CLI is not
   this: it takes one file, quality 0–1, and writes only with `--write`.
4. **Shortcuts action** — so it composes with the rest of the automation on this
   machine.

Surfaces 2–4 are v2. All four drive the same `RescaleKit`, so none of them
requires revisiting the model.

## 14. Milestones

| # | Scope | Estimate |
|---|---|---|
| **M0** ✅ | **The solver**, ported from `prototype/solver.py`: aspect + one size parameter, source inheritance, pin-respecting snapping. Pure value code, no image I/O. Property tests: the solved size always honours the axis the user set, and re-solving is idempotent. *Done 2026-09-05: `RescaleKit/`, 20 tests incl. 5,940-case parity fixture.* | 1 day |
| **M1** | `RescaleKit`: decode → resize → crop/pad → encode, for one image. Fit policies, resampling, metadata and orientation rules. Fixture corpus (portrait, landscape, square, alpha, CMYK, EXIF-rotated, RAW). A throwaway CLI here is the cheapest way to test it. | 2 days |
| ~~**M2**~~ | ~~The size control: field + steppers + logarithmic detented slider.~~ **Dropped 2026-09-06**; the ladder row in M3 covers it. | — |
| **M3** | **The app**: Open With registration, empty-window drop target + ⌘O, single-image window, large crop preview with draggable rectangle, aspect picker, real output byte count, Save. | 2–3 days |
| **M4** | Formats: WebP via libwebp, per-format encoder options, target-file-size search. | 1–2 days |
| **M5** | Presets, icon, help, preferences, DMG, notarisation. | 1–2 days |

**M0, M1 and M3 are v1** — roughly a week and a half, and it fully replaces the Parallels
tool for the single-image case. M0 is worth doing first and alone: the solver is
the product, and it is testable without a single pixel being decoded.

**v2**, once v1 has been lived with: batch, the headless preset Quick Action, a
shipped CLI, and the Shortcuts action (§13).

## 15. Open questions

1. **Megapixel convention.** ~~ComfyUI uses 1024² (1 MP = 1,048,576 px). Cameras
   and photographers use 10⁶.~~ **Decided 2026-09-05: 10⁶**, labelled "MP
   (millions of pixels)", since SnapRescale's users are photographers, not latent
   wranglers. One constant, `Megapixel.pixels` in `RescaleKit`, if this ever
   needs revisiting.
2. **Name.** ~~"SnapRescale" is a placeholder.~~ **Decided 2026-09-05: SnapRescale**,
   tagline "Resize to any ratio, snapped to multiples of 8 and 16". Engine stays `RescaleKit`, CLI stays `rescale`
   (short in pipelines). No exact-match collisions found; nearest neighbours are
   SnapResizer (web/iPad) and Snap Converter (Mac App Store).
3. **Distribution.** Personal tool, or signed and shipped? Determines whether the
   libwebp dependency and App Sandbox constraints matter.
4. **Animated GIF / HEICS.** **Decided 2026-09-05: first frame, for now.** The
   loader takes frame 0; frame selection (and video frames) is future work.
   Since GIF cannot be written, the format switches to PNG/JPEG with a note.
5. **RAW output.** Read RAW, write JPEG/HEIC — presumably never write RAW. Confirm.
6. **Target-file-size cost.** 6–8 encode passes per image — imperceptible for
   one image, and the same background encoder already producing the live byte
   count (§8). Revisit when batch arrives.
7. **Does the ladder need 1536?** **Decided 2026-09-05: yes**, as the fifth
   detent — SDXL-era workflows land there often, and it is divisible by 8 and 16.
   Shortcuts are ⌘1–⌘5.
8. **Should aspect presets auto-flip to match source orientation?** Choosing 16:9
   for a folder of portrait photographs crops them to ribbons. The list carries
   both orientations explicitly (2:3 *and* 3:2), so the user can already say what
   they mean — but a "match source orientation" toggle would prevent a nasty
   surprise on a mixed folder. Leaning towards offering it, off by default.
9. **Should target file size participate in the solver?** It constrains bytes,
   not pixels, so it is orthogonal — but at a fixed quality it does imply a pixel
   budget. Simplest v1: keep it separate, applied after the geometry is settled.
