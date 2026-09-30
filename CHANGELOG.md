# Changelog

Notable changes to SnapRescale, newest first. Dates below are App Store upload
dates recorded in the repository, not dates of public availability.

## Unreleased

The Metadata milestone: implemented, not yet released.

### Added

- **Metadata inspector**, a panel on the trailing side of the window that lists
  what the source carries, section by section: EXIF, GPS, IPTC, XMP, ICC
  profile, AI workflow, C2PA and Structure. It opens from any badge (at that
  badge's section), from the new **Metadata** row in the sidebar, or with
  View ▸ Metadata Inspector (⌥⌘I). Values are shown with readable labels, the
  main fields first and the rest behind **More**; an AI workflow shows a
  summary (prompt, negative prompt, model, seed, steps, CFG, sampler,
  scheduler) above its raw payloads.
- **Keep or strip per section**: a Keep · Strip switch for EXIF, GPS, IPTC, XMP
  and the AI workflow, and Keep · sRGB · Strip for the colour profile. A master
  menu sets them all: Default · Keep all · Strip all, reading Custom for any
  other mix. A switch is disabled, with a note, when the output format cannot
  carry the section (a ComfyUI graph requires PNG output).
- **AI workflow carried over**: a resized ComfyUI PNG still opens its workflow
  in ComfyUI. A1111-style parameters also travel in the EXIF user comment of
  JPEG, HEIC and TIFF.
- **Copy and export**, whatever the switches say: Copy on every section, Copy
  Prompt and Export… (`.json` / `.txt`) on an AI workflow, Copy All and
  Export All… (one JSON file) in the inspector's menu.
- Presets carry a metadata policy (`metadata` in the JSON; optional, so older
  presets still load).

### Changed

- Output is no longer always 8-bit sRGB with all metadata stripped. **New
  default:** strip EXIF, GPS, IPTC and XMP; keep the colour profile and the AI
  workflow. The sidebar says so (*Default · only ICC, AI kept*). Opening
  another image returns to the default; a preset applies its own policy.
- Colour follows the ICC switch: the source's profile and, where the format
  allows, its bit depth are kept. CMYK sources are still converted to sRGB.
- The ICC badge appears only when the file embeds a profile; an assumed sRGB
  is no longer shown as one.
- Help describes the inspector and points to ExifTool, Photos and Preview for
  editing metadata, which SnapRescale does not do.

### Fixed

- The XMP badge no longer appears for files that have no XMP packet.
- What the writer fixes even when it keeps: the embedded EXIF thumbnail is
  never written, EXIF pixel dimensions are those of the output, and
  orientation is 1 because it is baked into the pixels.
- Stripping a section also removes its copies elsewhere: GPS, EXIF and IPTC
  fields mirrored in a kept XMP packet, the EXIF caption, artist and copyright
  when IPTC is stripped, and the IPTC block ImageIO adds to a JPEG by itself.
- C2PA content credentials are always stripped, and the inspector says why:
  the signature binds the original pixels.

### Known limits

- Stripping the colour profile is fully clean only in TIFF and JPEG: a PNG
  keeps a one-byte sRGB marker and HEIC tags sRGB.
- HDR gain maps are not written. RAW, PSD and GIF sources carry no XMP over.

## 1.1 (build 3) — 2026-09-28

### Added

- Snap dimensions to multiples of **32**, alongside 1, 8 and 16.
- Switch the composition grid and crop frame between white and black. The
  choice is remembered between sessions.

### Changed

- Made composition grid lines thicker and more visible.
- Combined Preset and Aspect ratio into matching rows in one group.
- Aligned the preview header and footer with the sidebar.
- Moved the solved dimensions, megapixels and scale into a labelled **Result**
  row at the bottom of the Size section.
- Added a `px` unit to the multiple selector and updated Settings' ladder
  validation for multiples of 32.
- New images start with the **Original** aspect ratio. An explicit launch
  argument or preset can still override it.
- Local development builds now read their version and build number from
  `project.yml`.

### Fixed

- Worked around the macOS 27 layout bug that briefly widened the sidebar
  after control changes, crop dragging, file drops, file opens, menu actions
  and Settings changes. State changes are deferred out of the triggering
  event, and file drops are handled after the drag session ends.

[Source tag](https://github.com/phierru/SnapRescale/tree/v1.1-build3)

## 1.0 (build 2) — 2026-09-14

Post-review fixes, as recorded in [the submission notes](docs/APP-STORE.md).

### Fixed

- An older image load can no longer replace a newer selection when decoding
  finishes out of order. Saving is disabled while a replacement loads.
- Background file-size calculations use the image and settings belonging to
  each queued job, avoiding byte counts from a previous image.
- Invalid hand-edited presets are skipped and reported instead of causing
  crashes. Preset filename and duplicate-name handling is more robust.
- Applying a preset cannot silently retain an unwritable source format;
  the app selects a supported fallback and explains the change.
- Extreme aspect ratios no longer crash the solver. The renderer rejects
  targets outside its supported limits.
- Default multiple and quality settings are applied when each image loads,
  while preserving launch overrides.
- Saving encodes off the main thread and shows a saving state.

### Changed

- Bundled the MIT licence and clarified credits, privacy information, help
  links and output limitations.

## 1.0 (build 1) — 2026-09-06

Initial App Store upload.

### Added

- Native macOS app for resizing one image at a time, with local processing.
- Aspect-ratio presets and sizing by width, height, megapixels or scale,
  with optional snapping to multiples of 8 or 16.
- Live crop preview, draggable framing, composition grids and coloured or
  transparent padding.
- JPEG, PNG, HEIC and TIFF export, with a real encoded output-size preview.
- Source metadata badges and orientation normalisation. Output is 8-bit sRGB
  with source metadata stripped; animated images use their first frame.
- Editable JSON presets, application settings, built-in help and credits.
- Finder Open With and Services integration, drag and drop, and keyboard
  shortcuts for opening and saving images.
- Sandboxed saving, with optional remembered folder access for saving beside
  the original, and quit-after-save behavior when launched for an image.

[Source tag](https://github.com/phierru/SnapRescale/tree/v1.0-build1)
