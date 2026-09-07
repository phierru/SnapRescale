# ComfyUI node review — source material for SnapRescale

Read from the local ComfyUI core install (v0.34.2) at
`~/ComfyUI-Installs/ComfyUI/ComfyUI/`. Both are stock core nodes, not custom packs.

> **Licensing and provenance.** ComfyUI is GPL-3.0. This document describes
> the nodes' *behaviour* and *design* so SnapRescale could implement the ideas
> independently. It quotes no function bodies; the short tooltip strings and
> option labels below are quoted from the upstream UI and attributed here.
> SnapRescale is MIT-licensed and contains no ComfyUI source: the Python
> prototype in `prototype/` was written from this behavioural description, and
> the Swift solver is a port of that prototype (checked by a parity fixture),
> not of upstream code. Upstream examined: ComfyUI v0.34.2, commit
> `7fd919f0caff66a52289ea5b19cb6eaca0da04ef`. Ideas and formulas are not
> subject to copyright; the credit in the README is owed regardless.

| Node | Display name | Source |
|---|---|---|
| `ResizeImageMaskNode` | Resize Image/Mask | `comfy_extras/nodes_post_processing.py:412` |
| `ResolutionSelector` | Resolution Selector | `comfy_extras/nodes_resolution.py:30` |

---

## 1. Resize Image/Mask (`ResizeImageMaskNode`)

Category `image/transform`. Takes one image *or* mask, one **resize_type**, one
**scale_method**, returns the resized input. The interesting design is that
`resize_type` is a *dynamic combo*: picking a mode swaps which parameter widgets
appear. One node, nine modes, never more than three visible controls.

### The nine resize modes

| Mode | Parameters | Behaviour |
|---|---|---|
| `scale dimensions` | width, height, crop | Exact W×H. **`0` on either axis = derive it from the other, preserving aspect ratio.** |
| `scale by multiplier` | multiplier (0.01–8.0) | Percentage scaling. |
| `scale longer dimension` | longer_size | Long edge → N, AR preserved. Orientation-agnostic. |
| `scale shorter dimension` | shorter_size | Short edge → N, AR preserved. |
| `scale width` | width | Height follows. (Sugar for `scale dimensions` with height=0.) |
| `scale height` | height | Width follows. |
| `scale total pixels` | megapixels (0.01–16.0) | Scale so W×H ≈ MP·1024². AR preserved. |
| `match size` | match (ref image/mask), crop | Copy dimensions from a reference input. |
| `scale to multiple` | multiple (1–MAX) | Snap both sides *down* to a multiple of N, then **cover-scale and centre-crop** so nothing is stretched. |

### Aspect-ratio mismatch: `crop`

Only two options, and they are the only two that matter:

- `disabled` — stretch to fit (distorts)
- `center` — cover + centre crop (preserves geometry, loses edges)

Exposed only for `scale dimensions` and `match size`, i.e. the two modes where a
mismatch is possible. Everywhere else it would be dead UI, so it is not shown.

### Resampling: `scale_method`

`nearest-exact`, `bilinear`, `area`, `bicubic`, `lanczos` — default **`area`**.
The tooltip carries the whole recommendation: *"area is best for downscaling,
lanczos for upscaling, nearest-exact for pixel art."*

### Implementation notes worth stealing

- `scale_to_multiple_cover` computes both axis scale factors, takes the larger,
  `ceil`s the other axis, clamps up if rounding undershot, then centre-crops.
  That clamp is the kind of off-by-one guard that is easy to forget.
- `scale_longer/shorter_dimension` handle the square case explicitly rather than
  falling through a comparison — square inputs otherwise hit an ambiguous branch.
- Mask vs image is distinguished purely by rank: images are `[B,H,W,C]` (4 dims),
  masks are `[B,H,W]` (3 dims). Masks get a channel axis added before scaling and
  squeezed after, so one code path serves both.

---

## 2. Resolution Selector (`ResolutionSelector`)

Category `utilities`. Outputs `width` and `height` ints. Not a resizer at all —
a *calculator* that turns an intent into a pixel pair.

### Inputs

- **aspect_ratio** — 8 presets, each labelled with orientation:
  `1:1 (Square)`, `2:3 (Portrait Photo)`, `3:2 (Photo)`, `3:4 (Portrait Standard)`,
  `4:3 (Standard)`, `9:16 (Portrait Widescreen)`, `16:9 (Widescreen)`,
  `21:9 (Ultrawide)`
- **megapixels** — 0.1–16.0, default 1.0. Tooltip anchors it: *"1.0 MP ≈ 1024×1024"*
- **multiple** — 8–128, step 4, default 8, marked *advanced*. Snap each side to
  the nearest multiple of this.

### The maths

In words: the target pixel count is megapixels × 1024². Divide it by the
product of the two ratio terms and take the square root; that is the scale
factor. Width is the first ratio term times the scale, height the second, and
each is then rounded to the nearest multiple.

Note `1 MP` here means 1024² = 1,048,576 px, not 1,000,000. Worth being explicit
about in our UI, because photographers read "12 MP" as the decimal kind.

---

## What Rescale takes from this

1. **Mode-as-discriminated-union.** One "Resize by:" selector that swaps the
   parameter row. Beats Parallels Toolbox's two fixed tabs and Apple's
   Small/Medium/Large.
2. **Long edge / short edge as first-class modes.** The single biggest gap in
   every Mac resizer: they make you pick W and H, which is wrong for a batch of
   mixed portrait and landscape shots.
3. **`0` = derive from the other axis.** A one-character way to say "preserve
   aspect ratio" without a lock toggle.
4. **Megapixel targeting**, with the 1024² caveat surfaced.
5. **Aspect-ratio + MP → dimensions calculator**, as a mode that *reframes*
   rather than merely scales (needs cover-crop to actually apply to a photo).
6. **Explicit resampling choice with opinionated guidance**, defaulting to the
   area/box filter for downscales — which is what most of this app will do.
7. **`crop: disabled | center` as the only two mismatch answers**, shown solely
   in the modes where a mismatch can arise. Rescale adds `contain` (pad) as a
   third, because export targets often need exact canvases.
8. **Snap-to-multiple**, useful well beyond latents: video encoders want even
   dimensions, sprite sheets want powers of two.
