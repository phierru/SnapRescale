# SnapRescale roadmap

Everything not in the current milestone lives here. The PRD (`PRD.md`) holds the
requirements; this file holds the order. Dates are decisions, not promises.

**Current milestone: M5 — ship it.** Free on the Mac App Store, source public
under MIT. See §14 of the PRD and the M5 section below.

## Deferred from v1 (2026-09-06)

These were in the v1 cut and were moved out so M5 could start. 1.1 shipped
(2026-09-28) without them. The two metadata items — the §10 switches and
"keep AI workflow" — were redesigned on 2026-09-30 and are now the **Metadata**
milestone below; what remains here is still open.

| Item | PRD | Notes |
|---|---|---|
| Resampling choice: area for downscale, Lanczos for upscale, nearest for pixel art | §1, ComfyUI review | CoreGraphics high-quality interpolation today; Core Image filters are the likely route. |

## Next — Metadata (decided 2026-09-30)

PRD §10: a metadata inspector in the window's trailing panel, opened from the
badges. Keep / strip per section, copy / export, **no editing**. Default policy:
strip EXIF, GPS, IPTC and XMP, preserve ICC, keep the AI workflow (changed from
"keep everything except GPS" after trying the app). Output today is still 8-bit sRGB with everything
stripped.

GitHub milestone **Metadata**, tracking issue #21. The items are cut so
that each wave can be worked by separate agents in parallel; the few places
where two items of a wave meet in one file are listed under the table.

| Wave | Item | Issue | Touches | Needs |
|---|---|---|---|---|
| 0 | Capture metadata values, not just presence (fields per section, full PNG chunk text incl. compressed, raw chunks) | #8 | `RescaleKit/ImageMetadata.swift` | — |
| 0 | `MetadataPolicy` on `RenderSpec` and in presets; per-format capability table | #9 | `RescaleKit`: new `MetadataPolicy.swift`, `Renderer.swift` (`RenderSpec`), `Preset.swift` | — |
| 0 | Real-file fixture corpus and round-trip test harness | #10 | `RescaleKit/Tests` | — |
| 1 | Inspector panel, read-only: collapsible sections, badge click, ⌥⌘I | #11 | `SnapRescale`: new `MetadataInspector.swift`, `ContentView.swift` | #8 |
| 1 | Copy / export serialisation: section text, Export All JSON, workflow `.json` / `.txt`, prompt extraction | #12 | `RescaleKit`: new `MetadataExport.swift` | #8 |
| 1 | Writer: keep / strip EXIF, GPS, IPTC; drop thumbnail, fix dimensions | #13 | `RescaleKit/Renderer.swift` (`encode`) | #9 |
| 1 | Writer: keep AI workflow — splice PNG text chunks before `IEND` | #14 | `RescaleKit`: new `PNGSplicer.swift` | #8, #9 |
| 1 | ICC: preserve · convert to sRGB · strip; renderer off fixed 8-bit sRGB | #15 | `RescaleKit/Renderer.swift` (`render`), `SnapRescale/Session.swift` | #9 |
| 1 | Fix: XMP badge shown for files with no XMP packet | #22 | `RescaleKit/ImageMetadata.swift`, `MetadataSection.swift` | — |
| 1 | Sidebar summary line; policy in shipped presets (Web strips GPS) | #16 | `SnapRescale/ControlsPanel.swift`, `PresetStore.swift` | #9 |
| 2 | Inspector: Copy, Copy All, Copy Prompt, Export…, Export All… buttons | #17 | `SnapRescale/MetadataInspector.swift` | #11, #12 |
| 2 | Writer: keep / strip XMP; remove mirrored copies of stripped sections | #18 | `RescaleKit/Renderer.swift` (`encode`) | #13 |
| 2 | Inspector switches: per section, master Default / Keep all / Strip all / Custom, disabled with a note ("Requires PNG output") when the output format cannot carry the section | #19 | `SnapRescale/MetadataInspector.swift` | #9, #11, #16 |
| 3 | Help, in-app help text, changelog, App Store copy | #20 | `docs/`, `AboutAndHelp.swift` | all |

#13 and #15 both edit `Renderer.swift` but different functions (`encode` vs
`render`); #17 and #19 both edit the inspector and should land one after the
other; #15 and #16 both edit `Session.swift` (preview colour vs policy state).
New sidebar and inspector controls must use `Binding.deferred` (the
macOS 27 Form width bug, `docs/apple-feedback-macos27-form-width.md`).

## Also next — multiple windows (decided 2026-09-06)

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

## Known rough edges (from the 2026-09-06 release review)

- The one-shot rule uses an "external open within the first seconds of launch"
  heuristic. A lifecycle signal would be better, but Services launches offer
  none; revisit with multiple windows.
- The 500 MP render limit bounds cost, not memory; very large targets are
  slow before they are refused.

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
   *(done 2026-09-06: entitlements, sandboxed build verified with Open With,
   `FolderAccess` bookmark behind the preference with a "Forget All" in
   Settings. `--save` scripting stays dev-build only.)*
4. **Presets** — JSON in Application Support, shipped defaults, a picker.
   *(done 2026-09-06: Web, Thumbnail, Social 16:9, SDXL 1024; hand-editable
   JSON; `--preset` launch argument. Email and Discord/Slack wait for v1.2.)*
5. **Settings** (⌘,) — default grid, ladder values, default multiple and quality,
   *Save next to the original without asking*, *Show the saved image in Finder*.
   *(done 2026-09-06; the ladder editor flags values not divisible by 16, as
   PRD §5 asks; `--settings` launch argument opens the window for tests)*
6. **Icon, About box with credits, help page.** *(done 2026-09-06. Icon:
   Liquid Glass `SnapRescale/AppIcon.icon` — three vector layers, frame + thirds
   grid + resize arrow on a blue gradient; the system derives light, dark,
   clear and tinted. `Scripts/make-icns.sh` rasterises the flat version for
   the dev build and the catalog fallback. About and Help are native windows,
   ⌘? and the Help menu; the help text is mirrored in `docs/HELP.md`.)*
7. **Distribution** — Developer ID build + DMG + notarisation for the GitHub
   release; App Store Connect listing, privacy "no data collected", screenshots.
   *(prepared 2026-09-06: `Scripts/release.sh` builds a hardened, signed DMG
   and notarises when `NOTARY_PROFILE` is set — falls back to ad-hoc without a
   certificate; `Scripts/appstore.sh` archives, exports and validates/uploads;
   `docs/APP-STORE.md` holds the listing copy, keywords, review notes and the
   checklist; `docs/PRIVACY.md` is the policy. **Submitted 2026-09-06 16:29: SnapRescale 1.0 (1), submission
   d3af19ad-35c0-4d7b-9ace-08a9658378bd, Waiting for Review.** GitHub DMG still
   needs a Developer ID Application certificate.)*
