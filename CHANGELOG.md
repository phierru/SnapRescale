# Changelog

Notable changes to SnapRescale, newest first. Dates below are App Store upload
dates recorded in the repository, not dates of public availability.

## Unreleased

No changes recorded yet.

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
