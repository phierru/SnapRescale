# App Store listing

Everything App Store Connect asks for, ready to paste. The promotional text,
keywords, What's New and review notes are the copy prepared for version 1.2:
the [copy proposal of 2026-10-03](app-store-release-copy-2026-10-03.md) with
the owner's corrections (#63). The subtitle is the owner's, live since 1.2.
The description is the owner's 1.1 text, corrected and saved for 1.3. See
[Status](#status). The text live for 1.1 is recorded at the end.

## Name, subtitle, category

- **Name:** SnapRescale
- **Subtitle:** Resize, snap to 8/16/32 px
- **Category:** Graphics & Design · secondary: Photo & Video
- **Price:** Free · no in-app purchases
- **Bundle ID:** com.phierru.SnapRescale · **SKU:** snaprescale-mac

The subtitle is the owner's, live since 1.2 and kept (owner decision
2026-10-29). The prepared `Resize, crop & choose metadata` was not used. With
this subtitle, neither `crop` nor `metadata` is in the name or the subtitle;
see the keyword note.

## Field lengths

Counts include spaces and punctuation, and line breaks within each block; the
code fences are not part of the text. Count them again after any edit.

| Field | Length | Limit |
|---|---:|---:|
| Name | 11 characters | 30 |
| Subtitle | 26 characters | 30 |
| Promotional text | 153 characters | 170 |
| Description | 3128 characters | 4,000 |
| What's New | 1082 characters | 4,000 |
| Keywords | 93 UTF-8 bytes | 100 bytes |

## Promotional text

```text
Resize with a live preview. Inspect metadata, choose what stays, and keep embedded ComfyUI workflows in PNG-to-PNG saves. Everything happens on your Mac.
```

## Description

The owner's 1.1 text, corrected on 2026-10-29 and checked against the 1.2 (4)
build. The changes:

- The command-line paragraph is gone.
- "Originals are never overwritten" is gone.
- The multiples now include 32.
- The markdown is removed, since the store shows it literally.
- The metadata features are added, with the limits that apply.

It goes live with 1.3.

```text
SnapRescale is a free, lightweight macOS utility for resizing images, one at a time, using presets and simple controls. It also supports changing aspect ratios, cropping, padding, and choosing which metadata to keep, without requiring a full image-editing application.

The primary workflow is to right-click an image in Finder and open it in SnapRescale using Open With or the Services menu. When launched this way, the app automatically quits after the processed image is saved.

Alternatively, users can launch SnapRescale from the Applications folder and open an image by dragging it into the app or using the standard macOS Open dialog. In this workflow, the app stays open after saving, until the user closes its window or quits it.

Users choose an aspect ratio and set one of width, height, megapixels, or scale; the other three follow. A live preview shows the crop, which can be adjusted by dragging the frame. The resized image can be saved as JPEG, PNG, HEIC, or TIFF, and its file size is shown beforehand.

SnapRescale also shows the metadata it can read in an image: EXIF, GPS, IPTC, XMP, the colour profile, and AI generation data embedded by tools such as ComfyUI. Each of these can be kept or removed; what can be kept depends on the source, the output format, and the metadata read limits. By default, EXIF, GPS, IPTC, and XMP are removed, and supported colour profiles and AI generation data are kept. Because AI generation data can include prompts, users should review it before sharing the image. Content Credentials (C2PA) are always removed. Metadata can be copied or exported, but not edited.

All features are available in the main window, with a few preferences in Settings, and can be tested immediately. No account, registration, login credentials, or external website is required. SnapRescale saves the result as a new file; an existing file, including the original, is replaced only if the user confirms the replacement in the Save dialog.

SnapRescale is particularly useful for preparing images for AI image-processing workflows, including ComfyUI and Stable Diffusion. Its options for output dimensions that are multiples of 8, 16, or 32 pixels support these workflows, and with the default settings an embedded ComfyUI workflow survives a PNG-to-PNG resize. It is also suitable for anyone who needs to resize, crop, or pad an image for other purposes. The app processes existing images; it does not generate new images using AI.

All image processing takes place locally on the Mac. The app collects no user data, includes no telemetry, and transmits no data off the device. It is fully self-contained and does not rely on external tools or services.

SnapRescale takes inspiration from ComfyUI image-processing nodes, but contains none of their code and is not affiliated with the ComfyUI project. Its functionality was implemented independently from scratch, and its source code is available under the MIT licence.

The app is free to download and use, with no in-app purchases, subscriptions, or other monetization. Its functionality is the same in all regions. The interface is in English.
```

Before submitting 1.3, check it against the 1.3 build:

- **Draft:** paste this text over the first draft saved in App Store Connect on
  2026-10-29.
- **Save formats:** add WebP if 1.3 writes it, and say so if a ComfyUI workflow
  survives a PNG-to-WebP save.
- **Licence:** if libwebp is bundled, the licence sentence must not say all of
  the code is MIT; libwebp is BSD-3-Clause.
- **Services menu:** keep "or the Services menu" only if the entry appears
  without a manual step (#74).

Left out on purpose:

- That the typed number is never changed: snapping can move it.
- That the app shows where an image came from: it reads embedded AI generation
  data, not verified provenance.
- That an export holds all metadata: it holds what was read, within the read
  limits.
- That originals are never overwritten: the Save dialog can replace one after
  confirmation.
- Batch processing.

The other live 1.1 claims listed at the end stay out.

## Keywords

```text
photo,image,aspect ratio,megapixel,scale,padding,png,jpeg,heic,tiff,exif,gps,workflow,convert
```

They complement the name and subtitle. The subtitle covers resizing and the
multiples, but neither it nor these keywords has `crop` or `metadata`. When
the keywords are next pasted, rebalance within the 100 bytes: for example,
`crop,metadata` in place of `convert` gives 99 bytes. Names of other products
(ComfyUI, Stable Diffusion) stay out.

## What's New (1.2)

```text
More control over what stays with your resized image.

• New metadata inspector for photo information, colour profiles and embedded AI generation data.
• Choose what to keep or remove, section by section.
• Keep embedded ComfyUI workflows when resizing PNGs and saving as PNG.
• Copy metadata and available prompts, or export workflows and metadata details.
• Preserve supported colour profiles, convert to sRGB, and save 16-bit PNG and TIFF from compatible sources.
• Presets remember your metadata choices.
• Saving: a large file on a slow disk no longer freezes the window, an allowed folder also covers the folders inside it, and opening another image during Save & Quit keeps the app open on it.
• ⌘W closes windows.

The default has changed. Version 1.1 removed all metadata; now supported colour profiles and AI workflow data are kept, prompts included, and EXIF camera details, GPS, IPTC and XMP are set to Strip. Content Credentials (C2PA) are always removed. Review retained workflow data before sharing. Preservation depends on the output format and metadata read limits.
```

## URLs

- **Support:** https://github.com/phierru/SnapRescale/issues
- **Marketing:** https://github.com/phierru/SnapRescale
- **Privacy policy:** https://github.com/phierru/SnapRescale/blob/main/docs/PRIVACY.md

## App privacy (questionnaire)

**Data not collected.** The app has no network access, no analytics, no
accounts. Images are read from where you open them and written where you
save them. Preferences and presets stay in the app's container.

## Accessibility Nutrition Labels

**Mac:** Dark Interface and Differentiate Without Color Alone (owner decision
2026-10-20, from the evaluation of the 1.2 build; the gaps are in #68).
Published on 2026-10-29.

## Review notes

Open any image with Open With → SnapRescale, or drop one on the window.
Launched for an image (Open With or Services in Finder, or a drop on the Dock
icon), the app quits after saving it, and the button reads Save & Quit…;
launched from Applications, it stays open. The app is sandboxed; saving goes
through the save panel by default. The "save next to the original without
asking" setting asks for folder access once per folder via the standard open
panel (security-scoped bookmark); an allowed folder also covers the folders
inside it. The metadata inspector (⌥⌘I) also exports only through the save
panel: Export All… in its ⋯ menu, and the Export… (share) icon on the AI
workflow section of an image that carries one.

## Screenshots

Required sizes for Mac: 1280×800, 1440×900, 2560×1600 or 2880×1800, opaque.
Recipe (Retina display, so 1440×900 points capture at 2880×1800 pixels):

```sh
open -n -a build/xcode/SnapRescale.app --args -ApplePersistenceIgnoreState YES \
  -saveNextToOriginalWithoutAsking NO --window 1440x900 <shot flags>
sleep 4.5; open -a build/xcode/SnapRescale.app photo.jpg   # opened after launch → stays open, "Save…" (not "Save & Quit…")
screencapture -l<window id> -x -o raw.png                    # window id from CGWindowList (owner SnapRescale)
swiftc -O -o flatten Scripts/flatten-screenshot.swift && ./flatten raw.png shot.png 2880 1800   # opaque, centred
```

The `-key value` arguments override a setting for one launch and write
nothing; `-compositionGrid thirds -compositionGridDark NO -defaultMultiple 8
-defaultQuality 0.95` pin the grid and defaults whatever the stored settings
say. Move the pointer off the window before capturing.

The 1.2 set (owner decision 2026-10-20: plain window captures, no captions;
dark appearance):

| # | Photo | Flags | In the UI |
|---|---|---|---|
| 1 | `IMG_3368.jpeg` (Ascona) | `--preset "Social 16:9"` | — |
| 2 | `IMG_2946.jpeg` (real GPS, accepted) | `--inspector` | — |
| 3 | Replicate PNG (IPTC, XMP, C2PA) | `--inspector --scale 50` | open IPTC and XMP *More* |
| 4 | `ComfyUI_00006_.png` | `--inspector --height 512 --multiple 16` | — |
| 5 | `IMG_3368.jpeg` | `--aspect 16:9 --width 1920 --multiple 8 --fit pad` | pad colour #2B5C66 |
| 6 | Replicate PNG | `--scale 50` | Format HEIC, Quality 80 |

## Status

1.0 (1) submitted 2026-09-06; 1.0 (2) uploaded 2026-09-14 (post-review fixes from
commit 110e688); 1.0 approved, Ready for Distribution. 1.1 (3) uploaded 2026-09-28
(tag v1.1-build3). The live 1.1 listing differs from what this file held at the
time (its subtitle and description were never in it); it is recorded below as
captured on 2026-10-03. 1.2 (4) uploaded 2026-10-20 (tag v1.2-build4) and
submitted the same day with six plain window captures (dark appearance).
1.2 has been live since 2026-10-21.
This file is not a live view of App Store Connect.

The US page matches this file in these fields:

- the subtitle (owner's, kept on 2026-10-29);
- the promotional text and What's New above;
- both categories;
- the six screenshots;
- Data Not Collected;
- the accessibility labels: Dark Interface and Differentiate Without Color
  Alone, published 2026-10-29 and shown on the page the same day.

These were checked on 2026-10-25, and the subtitle and accessibility labels
again on 2026-10-29. The page still has the 1.1 description recorded below.
A first draft of the corrected description was saved in the 1.3 version on
2026-10-29. The checked text above replaces it there, and goes live with 1.3
(#71).

The keywords are not shown on the page and were not checked. The subtitle,
description and keywords change only with a new version. Accessibility
Nutrition Labels can be published at any time, without a new version (App
Store Connect → App Accessibility → Publish).

## Checklist for the next build

- [ ] Bump `CURRENT_PROJECT_VERSION` in `project.yml` (and `MARKETING_VERSION` for a new version).
- [ ] `UPLOAD=1 Scripts/appstore.sh` (archives, exports and uploads through Xcode's account).
- [ ] Select the build on the version page; update "What's New".
- [ ] Paste the Description and Keywords, and the Subtitle when it changes,
      into the new version: unlike the promotional text, they cannot be edited
      between versions. Check them on the public page after release.
- [ ] Keep the privacy answer "Data not collected" and the policy URL current.
- [ ] Accessibility Nutrition Labels (Mac): answer from the evaluation of the
      common tasks (open, size, reframe, inspect metadata, change retention,
      save, settings), declaring only features every common task passed at
      runtime. Captions and Audio Descriptions do not apply. Re-evaluate on
      every update.

## Live listing (1.1)

The US storefront on 2026-10-03, transcribed from the storefront review's
captures (`storefront-review-2026-10-03/01-overview.png`, `02-description.png`,
`03-release-and-trust.png`). This was the live 1.1 text. Its subtitle,
promotional text, screenshots and What's New were replaced in 1.2; its
description stays live until 1.3 (#71). Three of its claims must not come
back: a `rescale` command that runs without a window, invocation by AI
assistants and automation tools, and originals that are never overwritten
(Save As can replace a file after confirmation, in 1.1 too).

- **Subtitle:** Resize to ratio, snap to 8/16
- **Category:** Graphics & Design · **Price:** Free · **Age rating:** 4+ · **Size:** 1.7 MB
- **Screenshots:** one, the full window with a photo [its controls are too small to read in the capture]
- **App privacy:** Data Not Collected · **Accessibility:** none indicated
- [The Information rows below Seller, Size and Category (Compatibility, Age Rating, Copyright) are cut off in the capture.]

Promotional text, shown above the description:

```text
Pick a ratio, pick one number, see the crop before you save. Snaps to multiples of 8, 16 and 32 for diffusion models and video. Free and open source.
```

Description. The page's line wrapping is not kept; the asterisks and backticks
are on the page as shown:

```text
SnapRescale is a free, lightweight macOS utility for resizing images using presets and simple controls. It also supports changing aspect ratios, cropping, and padding, without requiring a full image-editing application.

The primary workflow is to right-click an image in Finder and open it in SnapRescale using **Open With** or the **Services** menu. When launched this way, the app automatically quits after the processed image is saved.

Alternatively, users can launch SnapRescale from the Applications folder and open an image by dragging it into the app or using the standard macOS Open dialog. In this workflow, the app remains open until the user quits it.

SnapRescale can also be launched from the command line using the `rescale` command. In this workflow the app works without a UI window. This enables scripted workflows, such as processing multiple images, and allows AI assistants and other automation tools to invoke the app.

All features are available in a single window and can be tested immediately. No account, registration, login credentials, or external website is required. Original images are never deleted or overwritten.

SnapRescale is particularly useful for preparing images for AI image-processing workflows, including ComfyUI and Stable Diffusion. Its options for output dimensions that are multiples of 8 or 16 pixels support these workflows. It is also suitable for anyone who needs to resize, crop, or pad an image for other purposes. The app processes existing images; it does not generate new images using AI.

All image processing takes place locally on the Mac. The app collects no user data, includes no telemetry, and transmits no data off the device. It is fully self-contained and does not rely on external tools or services.

SnapRescale takes inspiration from ComfyUI image-processing nodes, but contains no ComfyUI code. Its functionality was implemented independently from scratch.

The app is free to download and use, with no in-app purchases, subscriptions, or other monetization. Its functionality is the same in all regions. The current version supports English only; additional languages are planned for future releases.
```

What's New, Version 1.1, with the line break the page shows in the last item:

```text
• Added multiple of 32, for image models that prefer it.
• The final size now sits as a Result row at the bottom of the Size card.
• Bolder composition grid, with a white/black switch for light pictures.
• Tidier sidebar: Preset and Aspect ratio side by side, aligned rows.
• A new image now starts with the original aspect ratio.
• Fixed on macOS 27: the sidebar briefly widened after a click, a drop or
  opening a file.
```
