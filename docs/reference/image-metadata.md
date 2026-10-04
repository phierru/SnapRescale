# Image metadata SnapRescale may encounter

Reference for PRD §10 and the badge row. Grouped by where the data lives and
how the loader sees it. "ImageIO" means `CGImageSourceCopyPropertiesAtIndex`
hands it over as a dictionary; "scan" means we parse the container ourselves.

## 1. Standard photo metadata

| Block | Contents | Where | How we see it | Badge |
|---|---|---|---|---|
| **EXIF** | Camera, lens, exposure, capture date, orientation, user comment, embedded thumbnail | JPEG APP1, HEIC/TIFF IFD, PNG `eXIf`, WebP `EXIF` | ImageIO `{Exif}` | `EXIF` |
| **GPS** | Latitude, longitude, altitude, timestamp | EXIF GPS IFD | ImageIO `{GPS}` | `GPS` (warning colour: the privacy one) |
| **TIFF tags** | Make, model, software, orientation, resolution | IFD0 | ImageIO `{TIFF}` | none — always alongside EXIF |
| **IPTC** | Caption, keywords, credit, copyright, city | JPEG APP13 / Photoshop IRB, XMP mirror | ImageIO `{IPTC}` | `IPTC` |
| **XMP** | Ratings, labels, edit history, face regions, rights, mirrors of the above | JPEG APP1 (`http://ns.adobe.com/xap/1.0/`), PNG `iTXt XML:com.adobe.xmp`, HEIC `mime` box | The packet itself, found by scanning the container (JPEG, PNG, TIFF, HEIC/AVIF, WebP); ImageIO's tag tree minus what it derives, for the rest | `XMP` |
| **Apple MakerNote** | Live Photo pairing, capture settings | EXIF MakerNote | ImageIO `{MakerApple}` | none |
| **RAW** | Sensor and processing data | Proprietary | ImageIO `{Raw}`; read-only | none (format is shown already) |

## 2. Image structure

| Property | How we see it | Badge |
|---|---|---|
| ICC colour profile | `ProfileName` (e.g. "sRGB IEC61966-2.1", "Display P3", "Adobe RGB (1998)", "ProPhoto RGB") | `ICC`, profile name in the tooltip |
| Colour model other than RGB | `ColorModel` = CMYK / Gray / Lab | `CMYK`, `Gray` |
| Bit depth above 8 | `Depth` | `16-bit` |
| Alpha channel | `HasAlpha` | `Alpha` |
| HDR | Auxiliary data: HDR gain map (Apple), ISO 21496-1 gain map | `HDR` |
| Depth / portrait matte | Auxiliary data: depth, disparity, portrait effects matte | `Depth` |
| Orientation flag ≠ 1 | `Orientation`; baked into pixels on load (§10) | `Rotated` |
| Multiple frames | `CGImageSourceGetCount` > 1 (animated GIF, HEICS, multi-page TIFF) | `Animated ·N` |

## 3. AI-generation provenance

ImageIO's PNG dictionary exposes only the well-known text keywords (Title,
Author, Description, Copyright, Software, Comment, …). Everything below that
lives in a custom PNG text chunk is invisible to it, so the loader scans the
PNG chunk list itself (`tEXt`, `iTXt`, `zTXt`, `caBX`). JPEG segments are
scanned for C2PA.

| Source | Where it hides | Recognised by | Badge |
|---|---|---|---|
| **ComfyUI** | PNG `tEXt` `prompt` (API graph) and `workflow` (UI graph), JSON | keyword `workflow`, or `prompt` JSON containing `class_type` | `ComfyUI` |
| **Automatic1111 / Forge** | PNG `tEXt` `parameters`; JPEG/WebP EXIF UserComment | text containing `Steps:` and `Sampler:` | `A1111` |
| **InvokeAI** | PNG `tEXt` `invokeai_metadata`, `invokeai_graph`, older `sd-metadata` | keyword | `InvokeAI` |
| **NovelAI** | PNG `tEXt` `Software` = `NovelAI`, `Comment` JSON | Software value | `NovelAI` |
| **Fooocus** | PNG `parameters` plus `fooocus_scheme` | keyword `fooocus_scheme` | `Fooocus` |
| **SwarmUI** | PNG `parameters` JSON with `sui_image_params` | JSON key | `SwarmUI` |
| **Midjourney** | EXIF/TIFF ImageDescription and XMP `dc:description` with the prompt and `Job ID: …` | `Job ID:` | `Midjourney` |
| **Content Credentials (C2PA)** — DALL·E, Adobe Firefly, Leica/Sony cameras | JPEG APP11 JUMBF box (`jumb` / `c2pa`), PNG `caBX` chunk, HEIC `uuid` box | marker / chunk | `C2PA` |

## 4. What the badges are for

Each badge opens the metadata inspector (PRD §10.2) at its section. What the
inspector offers per block:

| Block | Inspector section | Control | Copy / export |
|---|---|---|---|
| EXIF + TIFF tags | EXIF | keep · strip | Copy |
| GPS | GPS | keep · strip | Copy |
| IPTC | IPTC | keep · strip | Copy |
| XMP | XMP | keep · strip | Copy |
| ICC profile | ICC profile | keep · sRGB (convert) · strip | Copy (name, description) |
| AI provenance (§3, except C2PA) | AI workflow | keep · strip | Copy, Copy Prompt, Export… (`.json` / `.txt`) |
| C2PA | C2PA | none, always stripped — the signature binds the original pixels | Copy |
| Alpha, bit depth, HDR, depth, frames, orientation | Structure | none, read-only | Copy |

Default: strip EXIF, GPS, IPTC and XMP; keep the ICC profile and the AI
workflow (PRD §10.2).

Writing notes:

- ImageIO will not write custom PNG text chunks, so "keep AI workflow" splices
  the source's `tEXt` / `iTXt` / `zTXt` chunks back in before `IEND`: only
  those that were read. A chunk over the per-image metadata limit is skipped,
  noted in the Structure section, and not carried, even under Keep (PRD §10.2).
- The embedded EXIF thumbnail is always dropped, EXIF pixel dimensions are
  rewritten and orientation is reset to 1 (PRD §10.4).
- A stripped section's mirrored copies in XMP are removed with it (PRD §10.3).
