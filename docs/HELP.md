# SnapRescale Help

The same text as the in-app help (⌘?). Deliberately brief; the
[PRD](PRD.md) is the long version.

## Getting an image in

- Right-click an image in Finder → **Open With → SnapRescale**, or **Services →
  Resize with SnapRescale**. The window then quits after saving.
- Or open SnapRescale from Applications and **drop an image** on the window, or
  press **⌘O**. The window stays open.
- One image at a time. Dropping another replaces it.

## Choosing a size

- Pick an **aspect ratio** — Original keeps the image's own — and **one number**:
  width, height, megapixels or scale. The other three follow.
- **Multiple of 8 or 16** rounds the result onto a lattice, as diffusion models
  and video encoders want. The number you typed is kept; the derived side moves,
  and the panel says by how much.
- The **ladder** under the field jumps to the usual sizes. Edit it in Settings.

## Crop or pad

- When the ratio changes, **Crop** keeps the framed region — drag the frame to
  reframe, double-click to centre — and **Pad** fits the whole image on a canvas
  of the colour in the well. Opacity 0 means transparent padding, where the
  format allows it.
- The buttons under the image switch the **composition grid**: frame only,
  centre lines, thirds, golden ratio, fifths.

## Format and saving

- **Keep original** writes the same format as the source when possible;
  otherwise the app says which format it switched to.
- The **file size** shown is a real encode, not an estimate.
- **⌘S** opens the save panel, pre-filled with *name_WxH*. In Settings you can
  make ⌘S save beside the original without asking; the first save into a folder
  asks for permission once.
- **Presets** bundle every setting. Save your own from the Preset menu; the
  files are plain JSON.

## The badges

Next to the file name: what the source carries — colour profile, EXIF, GPS,
XMP, HDR, alpha — and where an AI image came from (ComfyUI, A1111, InvokeAI, …).
Hover for details. Nothing is written back yet. Full list:
[image-metadata.md](reference/image-metadata.md).

## Shortcuts

**⌘O** open · **⌘S** save · **⇧⌘S** save as · **⌘,** settings · **⌘?** help

Problems or ideas: [github.com/phierru/SnapRescale/issues](https://github.com/phierru/SnapRescale/issues).
