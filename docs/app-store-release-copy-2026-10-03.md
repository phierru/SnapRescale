# App Store copy proposal — next metadata release

Prepared 2026-10-03 against `fa50d19593e2574692aa1aef7e617d3ccd5e3b47`.
This is proposed copy for the next release, not a record of a submitted version.
The version number remains undecided; the project currently still specifies 1.1 (3).
See [the storefront review](storefront-review-2026-10-03.md) for evidence, limitations and screenshot briefs.

**Owner comment:** Adopted with corrections as the draft of record in [APP-STORE.md](APP-STORE.md) (#63); this file stays as the dated proposal. The version is 1.2 (decided 2026-10-04). Corrections: subtitle "Resize, crop & choose metadata"; keyword `picture` becomes `image`; the default policy also strips IPTC and XMP and always removes Content Credentials (C2PA); What's New says the default changed; the promotional text says PNG-to-PNG saves, not exports; the description gains the size ladder, Keep original format and JPEG/HEIC quality, and qualifies keeping the original proportions (to the nearest multiple chosen). The lengths are counted again in APP-STORE.md.

Counts include spaces and punctuation, and line breaks within each block; the code fences are not part of the text.

| Field | Proposed length | Limit |
|---|---:|---:|
| Name | 11 characters | 30 |
| Subtitle | 28 characters | 30 |
| Promotional text | 155 characters | 170 |
| Description | 1596 characters | 4,000 |
| What's New | 698 characters | 4,000 |
| Keywords | 95 UTF-8 bytes | 100 bytes |

Limits: [Apple app information](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information/), [platform version fields](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information).
Keywords use ASCII, avoid app/company names, and contain no terms shorter than three characters. These are relevant candidate terms, not a claim about search demand or ranking.

## Name

```text
SnapRescale
```

## Subtitle — recommended

```text
Resize, crop & keep metadata
```

This gives the core action and the new differentiator equal visibility. For a deliberately more technical positioning, the existing draft's alternative fits exactly at 30 characters: `Resize images, snap to 8/16/32`. Prefer the recommended version for a broader image-editing audience.

## Promotional text

```text
Resize with a live preview. Inspect metadata, choose what stays, and keep embedded ComfyUI workflows in PNG-to-PNG exports. Everything happens on your Mac.
```

## Description

```text
Resize an image to the shape and size you need, then choose what stays with it.

SnapRescale is a focused Mac app for resizing one image at a time. Choose an aspect ratio and set the width, height, megapixels or scale. Preview the crop, move the frame, or add padding.

• Keep the original proportions or choose a new aspect ratio.
• Snap output dimensions to multiples of 8, 16 or 32 for image workflows that need them.
• Use composition grids and reusable size and export presets.
• Save as JPEG, PNG, HEIC or TIFF, and check the encoded file size before saving.
• Add coloured padding, or transparent padding with a compatible output format.
• Inspect EXIF, GPS, IPTC, XMP, colour profiles and supported AI generation data.
• Choose which metadata sections to keep or remove.
• Keep embedded ComfyUI workflows when resizing PNGs and saving as PNG.
• Copy metadata and available prompts, or export workflows and metadata details.
• Preserve supported colour profiles or convert to sRGB. Save 16-bit PNG and TIFF from compatible sources.

By default, camera details and GPS are set to Strip; supported colour profiles and AI workflow data are set to Keep. Retained workflows can contain prompts and other details, so review your choices before sharing. Preservation depends on the source, output format and metadata read limits.

Open an image from Finder, use the Open dialog, or drop it into the app. Animated images use the first frame. All image processing happens on your Mac, with no account, analytics or cloud uploads.

Open source under the MIT licence. The app interface is in English.
```

## What's New

```text
More control over what stays with your resized image.

• New metadata inspector for photo information, colour profiles and embedded AI generation data.
• Choose what to keep or remove, section by section.
• Keep embedded ComfyUI workflows when resizing PNGs and saving as PNG.
• Copy metadata and available prompts, or export workflows and metadata details.
• Preserve supported colour profiles, convert to sRGB, and save 16-bit PNG and TIFF from compatible sources.

The default policy sets camera details and GPS to Strip, and supported colour profiles and AI workflow data to Keep. Review retained workflow data before sharing. Preservation depends on the output format and metadata read limits.
```

## Keywords

```text
photo,picture,aspect ratio,megapixel,scale,padding,png,jpeg,heic,tiff,exif,gps,workflow,convert
```

These complement the proposed name/subtitle; reassess duplication if those fields change.
The live keyword field is not public and was not inspected.

## Submission notes

Use these feature claims with the build that includes the metadata changes. Do not update the live 1.1 promotional text to advertise features its binary lacks.

Keep launch/auto-quit details, sandbox explanations, test instructions and any sample-file directions in App Review Notes or Help. Check those instructions against the final archived build. The consumer description intentionally describes opening an image from Finder without promising that every Finder-open invocation quits the app.

The compatibility mention is specifically embedded ComfyUI data in PNG-to-PNG output. It does not advertise a general workflow editor, a cloud service, AI generation, or metadata preservation across every format. The app's read limits can omit oversized data; the submitted build should make that limitation visible as intended.
