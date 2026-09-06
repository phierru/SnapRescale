# App Store listing — draft

Everything App Store Connect will ask for, so the submission is copy-and-paste
once the Developer Program membership (personal team 7XVA74UJHL) exists.

## Name, subtitle, category

- **Name:** SnapRescale
- **Subtitle (30 chars):** Resize to any ratio, snap to 8/16
- **Category:** Photo & Video · secondary: Graphics & Design
- **Price:** Free · no in-app purchases
- **Bundle ID:** com.phierru.SnapRescale · **SKU:** snaprescale-mac

## Promotional text (170 chars)

Pick a ratio, pick one number, see the crop before you save. Snaps to
multiples of 8 and 16 for diffusion models and video. Free and open source.

## Description

SnapRescale resizes one image the way you actually think about it.

Choose an aspect ratio — or keep the original — and one number: width,
height, megapixels or scale. The other three follow. A live preview shows
exactly what will be cropped; drag the frame to reframe, or pad instead with
any colour, including transparent.

Made for AI image workflows as much as for photos: sizes snap to multiples
of 8 or 16, the number you typed is never changed behind your back, and the
panel tells you when the multiple forced an adjustment. A ladder of the
usual sizes — 512 · 768 · 1024 · 1536 · 2048 — is one click away and editable.

• Right-click any image in Finder: Open With, or Services → Resize with
  SnapRescale. Save, and it quits. Or open it from Applications and keep it
  around.
• Real output file size, from a real encode, before you save.
• Keep the original format, or write JPEG, PNG, HEIC or TIFF.
• Badges show what the source carries: colour profile, EXIF, GPS, HDR, and
  where an AI image came from (ComfyUI, Automatic1111, InvokeAI, …).
• Composition grids: thirds, golden ratio, fifths, centre lines.
• Presets bundle every setting; the files are plain JSON you can edit and share.
• No account, no network, no analytics. MIT-licensed; source on GitHub.

## Keywords (100 chars)

resize,image,crop,aspect ratio,megapixel,comfyui,stable diffusion,batch,
photo,scale,png,jpeg

## What's new (1.0)

First release.

## URLs

- **Support:** https://github.com/phierru/SnapRescale/issues
- **Marketing:** https://github.com/phierru/SnapRescale
- **Privacy policy:** https://github.com/phierru/SnapRescale/blob/main/docs/PRIVACY.md

## App privacy (questionnaire)

**Data not collected.** The app has no network access, no analytics, no
accounts. Images are read from where you open them and written where you
save them. Preferences and presets stay in the app's container.

## Review notes

Open any image with Open With → SnapRescale, or drop one on the window. The
app is sandboxed; saving goes through the save panel by default. The
"save next to the original without asking" setting asks for folder access
once per folder via the standard open panel (security-scoped bookmark).

## Screenshots

Required sizes for Mac: 1280×800, 1440×900, 2560×1600 or 2880×1800, opaque.
Recipe (Retina display, so 1440×900 points capture at 2880×1800 pixels):

```sh
open -n -a build/xcode/SnapRescale.app --args --window 1440x900 --preset "Social 16:9"
sleep 4; open -a build/xcode/SnapRescale.app photo.jpg      # opened after launch → stays open, plain "Save"
screencapture -l<window id> -x -o raw.png                    # window id from CGWindowList (owner SnapRescale)
swiftc -O -o flatten Scripts/flatten-screenshot.swift && ./flatten raw.png shot.png 2880 1800   # opaque, centred
```

Suggested set:

1. 16:9 crop preview with the frame and thirds grid.
2. Pad mode with a coloured canvas.
3. The badges row on a phone photo (GPS, HDR, EXIF).
4. Presets menu open.
5. Settings window.

## Checklist before submitting

- [ ] Paid Developer Program on the personal Apple ID; Xcode signed in.
- [ ] App record in App Store Connect for `com.phierru.SnapRescale`.
- [ ] `MARKETING_VERSION` 1.0 in `project.yml`; `CURRENT_PROJECT_VERSION` bumped.
- [ ] `Scripts/appstore.sh` validates; then `UPLOAD=1`.
- [ ] Screenshots uploaded; privacy answered "no data collected".
- [ ] `docs/PRIVACY.md` published (below).
