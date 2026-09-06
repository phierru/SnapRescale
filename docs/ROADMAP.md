# SnapRescale roadmap

Everything not in the current milestone lives here. The PRD (`PRD.md`) holds the
requirements; this file holds the order. Dates are decisions, not promises.

**Current milestone: M5 — ship it.** Free on the Mac App Store, source public
under MIT. See §14 of the PRD and the M5 section below.

## Deferred from v1 (2026-09-06)

These were in the v1 cut and are moved out so M5 can start. They come back
first, as **v1.1**.

| Item | PRD | Notes |
|---|---|---|
| Metadata switches: EXIF keep all / camera & date / drop; GPS keep / drop; ICC preserve / convert to sRGB / strip | §10 | Output is currently sRGB with everything stripped and orientation normalised. The badges are the hooks. |
| Keep AI workflow: carry ComfyUI / A1111 PNG text chunks into the written PNG | §10 | ImageIO won't; splice the chunks before `IEND`. |
| Resampling choice: area for downscale, Lanczos for upscale, nearest for pixel art | §1, ComfyUI review | CoreGraphics high-quality interpolation today; Core Image filters are the likely route. |

## v1.1 also — multiple windows (decided 2026-09-06)

One session per window instead of the single shared session. Open With,
Services and Dock drops open a **new window per image** (two files selected in
Finder become two windows, retiring the "one at a time" refusal). ⌘N gives an
empty window; ⌘O and a drop on an empty window fill it; **a drop on a window
that already has an image replaces it**, never opens a new one. The one-shot
rule moves to the window: a window opened from Finder closes after its save,
and the app quits when its last window closes. Commands act on the focused
window. PRD §8 "v1 never holds two" is superseded by this.

## v1.2 — M4, formats and encoding

| Item | PRD |
|---|---|
| WebP writing via bundled `libwebp` (the one native dependency; affects sandbox and notarisation) | §9 |
| Per-format encoder options: JPEG progressive + chroma subsampling, PNG interlace, HEIC/AVIF lossless, TIFF compression | §9 |
| Target file size: a byte ceiling met by searching quality downward with the background encoder | §11 |
| JPEG XL writing | §9, deferred again |

## v2 — many images, headless

| Item | PRD |
|---|---|
| Batch: file list, queue with progress and cancel, recursion, collision counters, "reframes 14 of 22" warning — for folders and dozens; a few images are covered by multiple windows (v1.1) | §8 |
| Headless preset Quick Action (Action Extension or Shortcut) so `right-click → SnapRescale → ‹preset›` works without a window | §13 |
| Real CLI: presets, globs, `--json`, exit codes; the current `rescale` stays a test harness | §13 |
| Shortcuts action | §13 |
| Destination folder, `./resized/` subfolder, replace-in-place with Trash, full filename template | §11 |
| Match-source-orientation toggle for aspect presets | §15.8 |
| Frame selection for animated GIF / HEICS and video frames | §15.4 |

## Open verification

- Provenance detection for InvokeAI, NovelAI, Fooocus, SwarmUI, Midjourney and
  C2PA is verified only on synthesised fixtures; ComfyUI and camera EXIF/GPS/XMP
  on real files.
- PDF and SVG are in the §9 read list and untested through the loader.
- No RAW / CMYK / wide-gamut / EXIF-orientation corpus has been run end to end.

## M5 — ship it (current)

Ordered so that each step leaves something usable.

1. **Licence and credits** — MIT, ComfyUI acknowledged. *(done 2026-09-06)*
2. **Xcode project** via `xcodegen`, wrapping the SwiftPM packages, because the
   App Store needs an archive of an app target with entitlements.
   *(done 2026-09-06: `project.yml`, `Scripts/build-xcode.sh`; personal team
   7XVA74UJHL pinned, signed to run locally until the paid programme exists)*
3. **App Sandbox** — required for the store. *Decided 2026-09-06:* `⌘S` always
   opens the save panel, pre-filled with the counter name, so the name can be
   tweaked. A preference, *Save next to the original without asking*, restores
   the silent path via a once-per-folder security-scoped bookmark.
   *(entitlements in place and the sandboxed build verified with Open With;
   still to do: the bookmark behind the preference, and `--save` is dev-only)*
4. **Presets** — JSON in Application Support, five shipped defaults, a picker.
5. **Preferences** — default grid, ladder values, default multiple and quality,
   *Save next to the original without asking*, *Show the saved image in Finder*.
6. **Icon, About box with credits, help page.**
7. **Distribution** — Developer ID build + DMG + notarisation for the GitHub
   release; App Store Connect listing, privacy "no data collected", screenshots.
