# App Store listing — draft

Everything App Store Connect asks for, ready to paste. This is the draft of
record for the next release, version 1.2: the
[copy proposal of 2026-10-03](app-store-release-copy-2026-10-03.md) with the
owner's corrections (#63). The text live for 1.1, which this submission
replaces, is recorded at the end.

## Name, subtitle, category

- **Name:** SnapRescale
- **Subtitle:** Resize, crop & choose metadata
- **Category:** Graphics & Design · secondary: Photo & Video
- **Price:** Free · no in-app purchases
- **Bundle ID:** com.phierru.SnapRescale · **SKU:** snaprescale-mac

The subtitle says "choose", not "keep": the default strips camera details,
GPS, IPTC and XMP. For a more technical positioning, `Resize images, snap to
8/16/32` also fits (30 characters); see the keyword note if it is used.

## Field lengths

Counts include spaces and punctuation, and line breaks within each block; the
code fences are not part of the text. Count them again after any edit.

| Field | Length | Limit |
|---|---:|---:|
| Name | 11 characters | 30 |
| Subtitle | 30 characters | 30 |
| Promotional text | 153 characters | 170 |
| Description | 1895 characters | 4,000 |
| What's New | 1082 characters | 4,000 |
| Keywords | 93 UTF-8 bytes | 100 bytes |

## Promotional text

```text
Resize with a live preview. Inspect metadata, choose what stays, and keep embedded ComfyUI workflows in PNG-to-PNG saves. Everything happens on your Mac.
```

## Description

```text
Resize an image to the shape and size you need, then choose what stays with it.

SnapRescale is a focused Mac app for resizing one image at a time. Choose an aspect ratio and set the width, height, megapixels or scale. Preview the crop, move the frame, or add padding.

• Keep the original proportions, as closely as the chosen multiple allows, or choose a new aspect ratio.
• Snap output dimensions to multiples of 8, 16 or 32 for image workflows that need them.
• Pick common sizes such as 512, 1024 or 2048 in one click. The panel says when snapping adjusts a size.
• Use composition grids and reusable size and export presets.
• Save as JPEG, PNG, HEIC or TIFF, or keep the original format when it is one of them.
• Set the JPEG or HEIC quality and check the encoded file size before saving.
• Add coloured padding, or transparent padding when saving as PNG, HEIC or TIFF.
• Inspect EXIF, GPS, IPTC, XMP, colour profiles and supported AI generation data.
• Choose which metadata sections to keep or remove.
• Keep embedded ComfyUI workflows when resizing PNGs and saving as PNG.
• Copy metadata and available prompts, or export workflows and metadata details.
• Preserve supported colour profiles or convert to sRGB. Save 16-bit PNG and TIFF from compatible sources.

By default, EXIF camera details, GPS, IPTC and XMP are set to Strip, and supported colour profiles and AI workflow data are set to Keep. Content Credentials (C2PA) are always removed. Retained workflows can contain prompts and other details, so review your choices before sharing. Preservation depends on the source, output format and metadata read limits.

Open an image from Finder, use the Open dialog, or drop it into the app. Animated images use the first frame. All image processing happens on your Mac, with no account, analytics or cloud uploads.

Open source under the MIT licence. The app interface is in English.
```

"As closely as the chosen multiple allows": an image of 1000×667 at width
1000 and multiple 8 becomes 1000×664 (`rescale --source 1000x667 --width 1000
--multiple 8`), and the panel says so.

Left out on purpose: that the typed number is never changed (snapping can move
it), that the app shows where an image came from (it reads embedded AI
generation data, not verified provenance), and that an export holds all
metadata (it holds what was read, within the read limits). The auto-quit is in
the review notes, since it depends on how the app was launched, and the live
1.1 claims listed at the end stay out.

## Keywords

```text
photo,image,aspect ratio,megapixel,scale,padding,png,jpeg,heic,tiff,exif,gps,workflow,convert
```

They complement the name and subtitle. With the alternative subtitle, `image`
repeats it and `crop` and `metadata` are no longer covered: rebalance within
the 100 bytes. Names of other products (ComfyUI, Stable Diffusion) stay out.

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

## Review notes

Open any image with Open With → SnapRescale, or drop one on the window.
Launched for an image (Open With or Services in Finder, or a drop on the Dock
icon), the app quits after saving it, and the button reads Save & Quit…;
launched from Applications, it stays open. The app is sandboxed; saving goes
through the save panel by default. The "save next to the original without
asking" setting asks for folder access once per folder via the standard open
panel (security-scoped bookmark); an allowed folder also covers the folders
inside it. The metadata inspector's Export… and Export
All… also write only through the save panel.

## Screenshots

Required sizes for Mac: 1280×800, 1440×900, 2560×1600 or 2880×1800, opaque.
Recipe (Retina display, so 1440×900 points capture at 2880×1800 pixels):

```sh
open -n -a build/xcode/SnapRescale.app --args --window 1440x900 --preset "Social 16:9"
sleep 4; open -a build/xcode/SnapRescale.app photo.jpg      # opened after launch → stays open, plain "Save"
# add --inspector to the first line for the shots with the metadata inspector open
screencapture -l<window id> -x -o raw.png                    # window id from CGWindowList (owner SnapRescale)
swiftc -O -o flatten Scripts/flatten-screenshot.swift && ./flatten raw.png shot.png 2880 1800   # opaque, centred
```

Which shots, and whether they carry captions, is decided at release (#64).
Start from the five-shot brief in the
[storefront review](storefront-review-2026-10-03.md#proposed-screenshot-sequence),
with the corrections in its Owner comment; #64 names the photos for the EXIF
and GPS, IPTC and XMP, and AI workflow shots.

## Status

1.0 (1) submitted 2026-09-06; 1.0 (2) uploaded 2026-09-14 (post-review fixes from
commit 110e688); 1.0 approved, Ready for Distribution. 1.1 (3) uploaded 2026-09-28
(tag v1.1-build3). The live 1.1 listing differs from what this file held at the
time (its subtitle and description were never in it); it is recorded below as
captured on 2026-10-03. The fields above are the draft for 1.2, not uploaded.
This file is not a live view of App Store Connect.

## Checklist for the next build

- [ ] Bump `CURRENT_PROJECT_VERSION` in `project.yml` (and `MARKETING_VERSION` for a new version).
- [ ] `UPLOAD=1 Scripts/appstore.sh` (archives, exports and uploads through Xcode's account).
- [ ] Select the build on the version page; update "What's New".
- [ ] Keep the privacy answer "Data not collected" and the policy URL current.

## Live listing (1.1)

The US storefront on 2026-10-03, transcribed from the storefront review's
captures (`storefront-review-2026-10-03/01-overview.png`, `02-description.png`,
`03-release-and-trust.png`). This is the live 1.1 text, which the 1.2
submission replaces. Three of its claims must not come back: a `rescale`
command that runs without a window, invocation by AI assistants and automation
tools, and originals that are never overwritten (Save As can replace a file
after confirmation, in 1.1 too).

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
