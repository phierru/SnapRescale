# WebP output (#1): research record, 2026-10-21

This file records what the research behind [the 1.3 WebP design](webp-1.3.md) established. The prototypes, probes and harnesses were kept in temporary session folders, which are gone, so the findings are written down here and need not be found again. Where the design builds on a finding, the section is named.

ComfyUI and its frontend are GPL-3.0. Their behaviour is described in prose only; tag numbers, string formats, versions and commit ids are facts, and no ComfyUI source is reproduced.

---

## 1. Status and provenance

- **Dates.** Research on 2026-10-21. Three competing designs, three judges, a synthesis and two critiques followed on 2026-10-21 and 2026-10-22, giving [webp-1.3.md](webp-1.3.md). Nothing is implemented yet.
- **The design is newer.** [webp-1.3.md](webp-1.3.md) was revised after this research, through the synthesis, the critiques and the owner decisions. Where this record and the design differ, the design is newer and wins. For example, the plan has nine proofs (P1–P9, against risk-first's P1–P8) and 16 items in 5 waves (A, B, D–Q): risk-first's item C, the committed drop harness, became the manual recipe (decision 17).
- **Base.** `main` at `22f1fd5` (merge of PR #67, release 1.2 (4), 2026-10-20); every code reference was read there. `main` is now `6729ae4` with docs-only changes, so code references hold; docs line numbers may have moved.
- **Nothing was modified** in the repository or the ComfyUI install (`git status` clean in both). ComfyUI Desktop, launched separately during the end-to-end run, changed its own files under `~/ComfyUI/user`; the research servers used a scratch base directory and port 8199.

| Item | Version |
|---|---|
| Host | macOS 27.0.1 (Darwin 27.0.0), Apple silicon (M5 Max); x86_64 under Rosetta |
| Deployment target | macOS 26; the macOS 26.6.2 VM was **not** used in research (it is in the release gate) |
| libwebp | 1.6.0 from the signed upstream tarball; Homebrew `cwebp`/`webpmux` 1.6.0 as command-line tools only |
| ComfyUI (local) | Desktop install v0.42.3 (`edb3db00`, 2026-10-20); Python 3.12.11, Pillow 12.2.0, piexif 1.1.3 |
| Frontend (local) | `comfyui-frontend-package` 1.55.18 (build commit `79a53509d1`) |
| Upstream | ComfyUI master `7a28332047` (2026-10-21, pins frontend 1.57.1); frontend `main` `dc3247704a` (2026-10-21); frontend releases 1.59.0 (2026-10-19) and 1.39.9 |
| Automation | Playwright 1.49.1 with chromium-headless-shell 1148; Node 26 |

**Built and now deleted:** four libwebp packaging prototypes (vendored, vendored with `-O3`, SDWebImage's libwebp-Xcode, encoder-only) with progress, cancel and RIFF-writer probes, a Swift encoder wrapper and self-test, and the vendoring script; a Node replay of the frontend's WebP reader (three variants) and of comfyui-image-saver's drop handler, 14 test vectors and synthesised A1111, Fooocus, SwarmUI and Image-Saver WebPs; the end-to-end harness (section 4); ImageIO carrier probes (section 3.6); five code maps and a cross-check (section 5). The archived prototype apps left three sandbox containers, `~/Library/Containers/com.example.webpproto.{vendored,remote,o3}`, still present on 2026-10-29; they can be deleted.

The method of the 2026-10-20 PNG drop check ([ROADMAP](../ROADMAP.md): "the same 11 nodes and 12 links as the source") was never committed and its script is also gone. Section 4.3 describes an equivalent harness.

---

## 2. libwebp packaging

### 2.1 Options compared

| Option | Finding | Verdict |
|---|---|---|
| (a) Vendor the 1.6.0 C sources as SwiftPM C target `CWebP` in RescaleKit (prototyped) | Builds universal with `swift build` and `xcodebuild archive`; self-test passes on arm64, under Rosetta and sandboxed; flags under our control | **Chosen** (owner decision) |
| (b) Prebuilt static xcframework as a `binaryTarget` (not prototyped) | Upstream `xcframeworkbuild.sh` needs autotools, hard-codes macOS 10.15, builds iOS slices and emits three module-map-less frameworks. Official Mac binaries are separate arm64/x86-64 tarballs (minimum macOS 15.0). Binaries in git or a URL plus checksum | Rejected |
| (c) SDWebImage/libwebp-Xcode tag 1.6.0 (`2b5256c`, 2026-07-31; submodule at libwebp `4fa21912`) (prototyped) | Builds and archives universal (1.06 MB binary). Compiles all of `src/` (125 objects). Defines neither `WEBP_USE_THREAD` nor `NDEBUG` (`thread_utils.o` has no pthread references; 60 objects call `__assert_rtn` in Release), and remote packages refuse `unsafeFlags`. 24 MB checkout; the resolved pin lives in the gitignored `.xcodeproj` | Rejected (owner decision) |
| (d) Vendor the encoder only, write RIFF in Swift (prototyped) | 86 `.c` files, 2.1 MB. A 40-line Swift writer matched `WebPMuxAssemble` byte for byte in all 32 cases (sizes, alpha, lossy/lossless, four metadata mixes incl. odd EXIF) | Fallback, not needed: dead-stripping already removes the unused decoder |

Effect of (c)'s missing defines at 4000², arm64: lossless z9 10.7 s against 5.1 s vendored; lossy m4 627 ms against 557 ms. Without `WEBP_USE_THREAD` the DSP initialisation has no mutex, so two simultaneous encodes race; the live size readout and a Save can encode at once. Wrappers on (c) (ainame/Swift-WebP 0.7.0, awxkee/webp.swift 1.1.2, the-swift-collective/libwebp 1.4.1, SDWebImageWebPCoder) were not used.

### 2.2 How (a) was built and verified

- `swift build --arch arm64 --arch x86_64`: clean universal build in 8.7 s, no warnings. An xcodegen project mirroring `project.yml` plus `xcodebuild archive`: 15 s. Xcode builds the local package's C target itself; the archive log showed `-Os -DSWIFT_PACKAGE -DWEBP_USE_THREAD -DNDEBUG` on all 198 C compiles (99 files × 2 architectures), the same flags as `swift build`.
- Result: a 913 KB universal binary, ad hoc signed, hardened runtime, sandbox entitlements, linking only libSystem (malloc, math, pthread, qsort).
- Self-test passed on arm64, x86_64 under Rosetta, and inside the App Sandbox from the archived app on both: straight alpha lossy and lossless; ICCP + EXIF + XMP read back by ImageIO; 16-bit P3 to 8-bit; grey to sRGB; rejection at 16,384 px; 12 concurrent encodes; cancellation.
- No extra signing, sandbox or notarisation work: static code, no file or network I/O, no required-reason APIs. No cryptography in `src/` or `sharpyuv/`, so `ITSAppUsesNonExemptEncryption = false` and "Data not collected" stay valid.

### 2.3 The vendored tree

- **Copied:** the `*.c` and `*.h` files of `src/{dec,dsp,enc,mux,utils,webp}` and `sharpyuv/`, in upstream's relative layout. Nothing else from the tarball (for example `src/demux`, `examples/`, `extras/`, `imageio/`, build files).
- **Dropped:** `*_mips32.c`, `*_mips_dsp_r2.c`, `*_msa.c`, `msa_macro.h`, `mips_macro.h` (never built on macOS) and `src/mux/anim_encode.c` (needs `WebPDecode`).
- **Kept:** `COPYING`, `PATENTS`, `AUTHORS`; the design renames them `LICENSE-libwebp.txt`, `PATENTS-libwebp.txt`, `AUTHORS-libwebp.txt` and adds `VERSION`.
- **Added:** `include/CWebP.h` (`encode.h`, `mux.h`; the design adds `decode.h` for the tests' oracle), `include/module.modulemap`, and in the design `src/cwebp_build_check.c`.
- **Result:** 99 `.c` and 50 `.h` files, 2.4 MB (about 0.5 MB gzipped). Layout and `Package.swift`: [design §4](webp-1.3.md).

### 2.4 `cSettings` and why

| Setting | Why |
|---|---|
| `.headerSearchPath(".")` | libwebp includes `src/…` and `sharpyuv/…` from its root |
| `.define("WEBP_USE_THREAD")` | pthread workers and the mutex around DSP initialisation; without it `thread_level` is silently ignored |
| `.define("NDEBUG", .when(configuration: .release))` | removes about 756 asserts; neither SwiftPM nor Xcode defines it for package C targets |

- **The define check belongs in a `.c` file of the target:** `cSettings` defines do not reach importing targets, so an `#error` in the umbrella header would fire in RescaleKit. A concurrency test cannot catch a missing define once the DSP was initialised earlier in the process.
- **SIMD needs no flags.** arm64 gets NEON through `__aarch64__`. On x86_64 clang's default CPU for macOS 26 is penryn, which defines `__SSE4_1__` (`enc_sse41.o` holds real SSE4.1). AVX2 compiles empty and is never dispatched; Intel Macs miss only lossless AVX2 speed-ups. `-Xarch_x86_64 -mavx2` should be safe on macOS 26 hardware but is untested.
- **`-O3` was not adopted.** SwiftPM and Xcode compile C at `-Os`. `.unsafeFlags(["-O3"])` works only because RescaleKit is a local package; it gave 5–20 % faster encodes (m6 690 against 775 ms, z6 133 against 168 ms) and a 1.36 MB instead of 0.9 MB universal binary.
- **Never link Homebrew.** Its `libwebp.a`/`libsharpyuv.a` are arm64-only and the dylib points into `/opt/homebrew`; `pkgConfig`, `-L/opt/homebrew/lib` or `linkedLibrary("webp")` would pass the arm64 dev build and break the universal link, library validation and App Review.

### 2.5 Why the decoder is vendored

- The mux library calls `VP8GetInfo`, `VP8LGetInfo` and `VP8LCheckSignature` from `src/dec`; the encoder includes `src/dec/*.h`.
- `DEAD_CODE_STRIPPING=YES` removes the decoder proper. Xcode's default here is NO: an arm64 slice was 629 KB with `VP8LDecode*` linked, 386 KB with stripping. SwiftPM release builds strip by default (42 WebP symbols, no decoder). The unused lossless decoder was the site of CVE-2023-4863, so the design checks for `_VP8LDecodeImage` in `Scripts/check-app-binary.sh`.
- The vendored decoder only parses our own bitstream headers during mux; sources are decoded by ImageIO.

### 2.6 Version and release signature

- Latest stable: **v1.6.0**, tag v1.6.0, commit `4fa21912`, July 2025; checked against GitHub tags, chromium.googlesource refs and the download listing. No newer release as of 2026-10-21.
- Tarball SHA-256 `e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564`. The GPG signature verified against the WebP release signing key, fingerprint `6B0E6B70976DE303EDF2F601F9C3D6BDB8232B5D`.
- 362 development commits followed 1.6.0, including `525a9d6b6` (a lossy abort can be lost; progress stops at 97 %), `291be6480` (a zero partition-0 size taken for an abort), `fa4ecc72e` and `6ff2f43ac` (palette-sort infinite loops; 1.6.0 exposure unconfirmed), `459c0d245` (SharpYuv signed overflow) and `87b985f8d` (RGB stride validation). Check the next release for them.

### 2.7 Licence

- libwebp and sharpyuv are BSD-3-Clause ("Copyright (c) 2010, Google Inc.") plus `PATENTS`, a royalty-free grant that ends for anyone suing over WebP patents. Compatible with MIT and the App Store.
- Obligations: keep `COPYING`, `PATENTS`, `AUTHORS` with the sources; reproduce notice, conditions and disclaimer with binaries (clause 2): the app bundle in both build paths, the DMG, a README credit; no endorsement using Google's name. A README line or GitHub link alone does not cover a binary.
- Homebrew's install lacks `PATENTS`; take the files from the tarball. Keep `LICENSE` MIT-only and put the notice in a root `THIRD-PARTY-NOTICES.txt`. Today the two build paths name the licence differently (`LICENSE` in Xcode, `LICENSE.txt` from `build-app.sh`).
- Store copy: once libwebp ships, no text may say all the code is MIT ([APP-STORE.md](../APP-STORE.md) 1.3 checklist).

### 2.8 Binary size and build cost

| Build | Size or time |
|---|---|
| (a) universal, `-Os` / `-O3` | 913 KB / 1.36 MB |
| (c) universal | 1.06 MB (archive 19.4 s) |
| arm64 slice without / with dead-stripping | 629 KB / 386 KB |
| (a) clean universal `swift build` / Xcode archive | 8.7 s / 15 s |
| Installed 1.2 binary | 9,936 symbols in `nm -U` (DMG, unstripped); the App Store archive is stripped (`__mh_execute_header` only); universal; only non-system link `/usr/lib/libz` |

### 2.9 Recipe to recreate the vendor script

The design calls it `Scripts/update-libwebp.sh <version> [--self-test]` ([design §4](webp-1.3.md)). The research script copied the files and applied the exclusions from an already verified tarball; the download, checksum and signature steps and the self-test are the design's additions.

1. Pin version → tarball SHA-256 (2.6) and the key fingerprint. Commit the public key as `Scripts/keys/libwebp-release-key.asc`, its fingerprint checked once by hand.
2. Download `libwebp-<version>.tar.gz` and `.asc` from `https://storage.googleapis.com/downloads.webmproject.org/releases/webp/` into a new, empty temporary directory.
3. `shasum -a 256 -c`.
4. `gpg --status-fd 1 --verify` in a temporary `GNUPGHOME` holding only the committed key; require `VALIDSIG <fingerprint>`.
5. Extract; never build or run anything from the tarball.
6. Replace the vendored `src/{dec,dsp,enc,mux,utils,webp}` and `sharpyuv/` with the tarball's `*.c`/`*.h` files, apply the exclusions, and for 1.6.0 assert 99 `.c` and 50 `.h`. Leave `include/` and `src/cwebp_build_check.c` (ours) alone.
7. Copy the three licence files under their new names; write `VERSION` (version, tag, commit, SHA-256); regenerate `THIRD-PARTY-NOTICES.txt` (header, COPYING, PATENTS).
8. Print `git diff --stat`; exit non-zero on any mismatch.

`--self-test` corrupts one tarball byte and must fail. A second run on a clean tree must leave `git status` clean.

### 2.10 libwebp facts the design relies on

The design's configuration and error mapping are in [design §2.3](webp-1.3.md). Facts behind them:
- **Picture.** Always `use_argb = 1`; with 0 the import converts to YUV at once and ignores `use_sharp_yuv`. Imports are `WebPPictureImportRGBA` (straight alpha) and `…RGBX`. **There is no premultiplied import**: un-premultiply first (vImage with alpha `.last`, or `vImageUnpremultiplyData_RGBA8888`). Feeding premultiplied pixels turned a source of 235,194,164 at alpha 64 into 59,49,41 (`cwebp`: 235,197,167).
- **1.6.0 abort bug:** `WebPEncode` can return 1 with `error_code` USER_ABORT; check both.
- **`WebPEncodingError`:** 0 OK, 1 OUT_OF_MEMORY, 2 BITSTREAM_OUT_OF_MEMORY, 3 NULL_PARAMETER, 4 INVALID_CONFIGURATION, 5 BAD_DIMENSION, 6 PARTITION0_OVERFLOW, 7 PARTITION_OVERFLOW, 8 BAD_WRITE, 9 FILE_TOO_BIG, 10 USER_ABORT. A 16383² noise image at q100 did not overflow partition 0. `WebPMuxError`: OK 1, NOT_FOUND 0, INVALID_ARGUMENT −1, BAD_DATA −2, MEMORY_ERROR −3, NOT_ENOUGH_DATA −4.
- **Mux.** `"XMP "` has a trailing space. `WebPMuxAssemble` sets VP8X flags (ICC 0x20, alpha 0x10, EXIF 0x08, XMP 0x04, animation 0x02), orders VP8X, ICCP, ALPH, VP8/VP8L, EXIF, XMP, and pads odd chunks (seen: 0x2c for ICC+EXIF+XMP). `WebPMuxCreate` rejects an EXIF chunk without the VP8X flag and a simple VP8 file with EXIF appended. Without mux, lossy with alpha always writes VP8X + ALPH; lossless with alpha is a simple VP8L file (`syntax_enc.c`).
- **Size.** `WEBP_MAX_DIMENSION` is 16383 per side (`encode.h:298`); 16384 gives BAD_DIMENSION. RescaleKit allows 65,536. A 16383² lossy q100 encode took 101–143 s and 3.1–8.9 GB.
- **Cancellation.** `progress_hook` returning 0 aborts. It can run on worker threads, so it reads an atomic via `pic.user_data`, never `Task.isCancelled` or the main actor. At 4000², arm64: lossy m6 3–31 ms; lossless z0–z7 prompt; z9 with `thread_level 1` 2.9–6.3 s, because extra configurations run on a side thread whose hook is switched off (`vp8l_enc.c:1763`); z9 with `thread_level 0` 12–451 ms but 9.8 s instead of 5.1 s. A lossy alpha plane is also encoded without the hook. Hence `thread_level 0` for lossless and no level 9 in the design.
- **Timings, 16 MP, M5 Max:** lossy m2 238 ms, m4 660 ms, m6 777 ms (about 1.3 s with sharp YUV); lossless z0 806 ms, z3 4.8 s, z6 8.2 s, z9 22.7 s. The prototype used `exact = 0` and effort level `effort*9/6`; the design chose differently.
- **Lossy bytes differ by architecture** (6,752 against 6,710 bytes): compare decoded pixels with a tolerance, never hash.
- **Swift overload trap:** given sync `encode(…, cancel:)` and async `encode(…)`, an async caller gets the async one; hence one `produce` with a defaulted parameter.

### 2.11 Colour

- WebP is 8-bit only; a 16-bit P3 source came out 8-bit with P3 kept. Display P3, Adobe RGB and Rec.2020 survive through ICCP; without ICCP readers assume sRGB.
- No grey mode: grey becomes RGB tagged sRGB (128 stayed 128). CMYK becomes sRGB.
- HDR: PQ and HLG profiles are recognised as BT.2100 but band at 8 bits, as JPEG does; extended-range sRGB clips. No CICP, no gain maps.
- Lossy is 4:2:0; `use_sharp_yuv` helps edges but doubles the time (660 to 1,314 ms at 16 MP). Lossless is exact for 8-bit RGB.

---

## 3. How AI tools store data in WebP

### 3.1 ComfyUI, the writer

- **One core node writes WebP with metadata:** SaveAnimatedWEBP (`comfy_extras/nodes_images.py`); one frame gives a still WebP. SaveImage writes PNG only, SaveImageAdvanced offers PNG, EXR and AVIF, previews carry no metadata. AVIF uses the same tags.
- **Layout.** One RIFF `EXIF` chunk with a TIFF stream; only IFD0 ASCII (type 2) entries. 0x0110 Model = `prompt:` + the API prompt as JSON. 0x010F Make = `<key>:` + JSON for the first `extra_pnginfo` key, normally `workflow`; further keys go to 0x010E, 0x010D and down. Lowercase keys, no space after the colon. With `--disable-metadata` neither string is added.
- **Encoding.** Python `json.dumps` defaults: separators `", "`/`": "` and `ensure_ascii=True`, so values are 7-bit ASCII with lowercase `\uXXXX` escapes and surrogate pairs. Pillow writes ASCII with replacement, so no raw non-ASCII byte appears.
- **PNG for comparison:** one text chunk per key (`prompt`, `workflow`, others) with the same JSON; animated PNG uses a private `comf` chunk.
- **Versions:** local v0.42.3 and upstream master `7a28332047`; the WebP metadata function is byte-identical in both.
- **Real files.** All 274 workflow-bearing WebPs in `~/ComfyUI/output`: VP8X › VP8 › EXIF, flags 0x08, payload `MM\0*\0\0\0\x08` (no `Exif\0\0`), IFD0 with exactly two NUL-terminated ASCII entries, next-IFD 0. Make counts 12,365–15,796 bytes (all over 10,000), Model at most 4,253. `ComfyUI_00891_.webp`: Make 15,247 at offset 38, Model 3,626 at 15,286 (38 + 15,247 + 1 pad), 20 nodes / 29 links. Every real `VP8 ` chunk was even-sized. Of 896 local PNG workflow chunks, 871 exceed 10,000 bytes.
- **The backend never reads the workflow back.** LoadImage decodes pixels and applies EXIF transposition, so Orientation (0x0112) is the only tag it acts on: never write an Orientation other than 1 on already-rotated pixels.

### 3.2 Pillow serialisation (12.2.0)

- `Image.Exif.tobytes()` = `Exif\0\0` + header + IFD0; a fresh `getexif()` has no byte order, so the header is big-endian `MM`.
- ASCII is `encode("ascii", "replace")` + NUL, count including the NUL; values word-aligned (pad after an odd value, the last included); entries sorted; next-IFD 0.
- A single-frame WebP save strips the `Exif\0\0` prefix; a multi-frame save keeps it (reproduced with ComfyUI's Pillow).
- Pillow decodes ASCII tags as Latin-1, so raw UTF-8 becomes mojibake for Python readers (`café` → `cafÃ©`).

### 3.3 The ComfyUI frontend's reader

Location: minified in 1.55.18 and exported as `window.comfyAPI.pnginfo.getWebpMetadata`; `src/scripts/pnginfo.ts` in 1.57.1 and 1.59.0; `src/scripts/metadata/webp.ts` on `main` (moved by `0c29393d3e`, PR `#21224`, 2026-10-19), re-exported under the old name and dispatched from `metadata/parser.ts`. Same logic in all four:
1. Requires `RIFF` at 0 and `WEBP` at 8; the RIFF size is not checked.
2. Walks chunks from 12 by size plus the odd-size pad byte.
3. Takes the **first** chunk whose fourcc is exactly `EXIF`, then stops. VP8X flags and chunk order are ignored.
4. Skips an optional `Exif\0\0`.
5. Little-endian when the first bytes are `II`, else big-endian; magic 42 unchecked.
6. Reads IFD0 only (offset at TIFF+4); no next-IFD, Exif IFD, GPS or SubIFDs.
7. Decodes only type 2 entries, so UserComment and XMP are never seen.
8. Always reads the value at the entry's offset field, so inline values (≤ 4 bytes) are misread. Decodes **count − 1** bytes as UTF-8: without the NUL in the count the closing `}` is lost.
9. Splits each value at the first `:` into key and untrimmed value; tag numbers do not matter; in ascending tag order a later duplicate overwrites an earlier one.
10. Uses `workflow`/`Workflow` and `prompt`/`Prompt` only; A1111 `parameters` are never imported from WebP.
11. Needs `File.type == "image/webp"`, from the `.webp` extension. The same bytes as `image/png` give "Not a valid PNG file" and a LoadImage node.

Then: with neither key, the image is pasted as a LoadImage node. Otherwise the workflow is tried first (a JSON object, not an array; non-finite numbers tolerated) and loaded as a graph. On failure the prompt is tried; it loads only if every node has a string `class_type` and object `inputs`, and loses layout, groups and notes. A prompt alone loads this way.

**Fix history.** Odd-chunk padding came with `c0a209226d` "fix: handle RIFF padding for odd-sized WEBP chunks (`#8527`)", 2026-02-08, first shipped in v1.39.10 (release branch) and v1.40.0 (2026-02-11). Older frontends miss the EXIF chunk after any odd-sized chunk: VP8L in about a third of cases, sometimes ALPH; real ICC profiles are multiples of 4. Lossy opaque files load everywhere. The prefix skip is older.

### 3.4 Other ComfyUI readers and custom savers

- **comfyui-image-saver v1.23.0** (installed locally). With `ImageSaver.HandleImageWorkflowDrop` on (default) it takes JPEG and WebP drops first, reads all tags with its bundled ExifReader 4.26.2, accepts any tag starting `workflow:` or `prompt:` in any case, and otherwise falls back to the core handler. ExifReader tolerates a missing NUL; the core does not. Its writer (piexif) uses ComfyUI's IFD0 layout with compact JSON plus Exif UserComment `UNICODE\0` + UTF-16BE holding the A1111 `parameters`; its PNGs carry `parameters`, each `extra_pnginfo` key and `prompt`. Eight such PNGs exist locally.
- **WAS Node Suite** writes `Prompt:` + JSON to Make and `Workflow:` + JSON to 0x010E ImageDescription, capitalised: the reason the frontend accepts both spellings in any tag.
- **ComfyUI-LoRA-Manager** writes and reads only ImageDescription `Workflow:` (case-sensitive) plus a UTF-16BE UserComment; it never sees ComfyUI's own WebP workflows.
- **rgthree-comfy** uses the core reader in the app; its standalone fallback still has the pre-`#8527` walk. **ComfyUI-Manager 4.2.2** has no WebP reader.
- **civitai** (`main` `22e2aace41`) uses npm `@civitai/generation-metadata` 0.4.0, read unpacked and not executed. Parser order: automatic1111, swarmui, ruinedfooocus, comfyui. ComfyUI in WebP is detected **only** by Model starting `prompt:`; that JSON serves as prompt and workflow, and Make is ignored. UserComment is decoded as ASCII, UTF-8 or BOM text, else UTF-16 with a guessed byte order. SwarmUI and Fooocus WebP JSON are not read.

This is why the workflow takes Make and the prompt Model, as ComfyUI does (owner decision; design decision 22). Keeping the camera Make/Model and moving the workflow to 0x010E and the prompt to 0x010D loaded in the core and image-saver, but civitai needs Model `prompt:`, LoRA Manager needs `Workflow:`, and other readers would show JSON as the description.

### 3.5 Other tools

| Tool (version read) | PNG | WebP |
|---|---|---|
| AUTOMATIC1111 `82a973c043`, Forge `dfdcbab685`, SD.Next `936d0d84b8` | tEXt `parameters` | Exif UserComment (0x9286, UNDEFINED) = `UNICODE\0` + UTF-16BE via piexif; IFD0 holds only the Exif pointer. Read back by the tools, civitai and ImageIO, not by the ComfyUI frontend |
| Fooocus `ae05379cc9` | tEXt `parameters` + `fooocus_scheme` | All tags in **IFD0**: UserComment as ASCII, Software `Fooocus v…`, MakerNote (scheme) as ASCII; also JPEG. ImageIO sees nothing (it drops IFD0 when Software is its only tag) |
| SwarmUI `5dc94afacf` (ImageSharp 3.1.12) | `parameters` = `{"sui_image_params": …}`; optional alpha-LSB data | UserComment `UNICODE\0` + **UTF-16LE** JSON in an `II` TIFF. ImageIO always decodes UNICODE as UTF-16BE, giving mojibake |
| InvokeAI `090a287364` | tEXt `invokeai_metadata`, `invokeai_workflow`, `invokeai_graph` (older `sd-metadata`) | None; WebP only for thumbnails without metadata |
| NovelAI | text chunks plus alpha-LSB `stealth_pngcomp` and a signed hash | None; any resize destroys the stealth bits |
| Midjourney | PNG `Description` with `Job ID:` (as modelled) | Not verified |
| C2PA | `caBX` | Spec 2.1 §A.2.6: a `C2PA` chunk at the end of the RIFF; SnapRescale strips it |

### 3.6 ImageIO facts (macOS 27.0.1)

- Reads WebP but **cannot write it**: `org.webmproject.webp` is not among the 22 writable identifiers and `CGImageDestinationCreateWithData` returns nil.
- Reads a WebP EXIF chunk with or without `Exif\0\0`, either byte order.
- **Drops TIFF Make and Model of 10,000 characters or more on read**, `MM` and `II`: 9,999 come back, 10,000 give nil and vanish from `CGImageMetadata`. ImageDescription has no limit (5,019,814 characters returned). Writing is unaffected (a 20,000-byte Make wrote to JPEG, TIFF, PNG). So SnapRescale must parse RIFF and IFD0 itself, to detect workflows and to verify its own output, and never route a workflow through property dictionaries.
- A1111 UserComments read at every length tested (200 B–40 KB, ASCII and UNICODE-BE). An animated test WebP reported `CGImageSourceGetCount` 2 and a `{WebP}` DelayTime.
- A metadata chunk without its VP8X flag is ignored, as is EXIF in a simple file. **ICCP after the image makes the image undecodable**; EXIF before the image, or XMP before EXIF, works.
- A grey ICC profile on RGB data falls back to sRGB. An XMP-only file gets Exif and IPTC derived from the XMP. EXIF Orientation 6 and XMP `tiff:Orientation` alone are both applied; EXIF wins over XMP for Make and Orientation, and the first of two EXIF chunks wins. Hence Orientation 1 in both.

**ImageIO's PNG writer as an EXIF carrier** (design-phase probes, macOS 27 only; re-checked on macOS 26.6.2 by the release gate):
- `eXIf` is a bare `MM` TIFF, IFD0 at 8, next-IFD 0 (no IFD1).
- PNG, JPEG and TIFF encoders overwrite PixelX/YDimension with the encoded size (1 for a 1×1 carrier); HEIC drops them; the derived XMP keeps the dictionary's values.
- The derived XMP mirrors `tiff:Make`, dates and IPTC; under XMP Keep a `tiff:Make` in the tree is synced into the `eXIf` IFD0. An IPTC-only carrier still writes an `eXIf` with only PixelX/Y.
- An sRGB carrier writes ExifColorSpace (0xA001 = 1); DeviceRGB does not. `{MakerApple}` survives a carrier built from an iPhone JPEG. A 12,010-character Make is written and mirrored into XMP.
- `DeviceRGB.copyICCData()` is nil; untagged sources decode as sRGB with a 3,144-byte profile. `CGImageMetadataCreateXMPData` output in an `XMP ` chunk and a P3 ICCP both read back.

### 3.7 What SnapRescale 1.2 does with these files (`22f1fd5`)

Run read-only through RescaleKit and the `rescale` CLI:
- A real ComfyUI WebP shows only an `EXIF` badge, no provenance, no AI section; the prompt appears as a camera "Model", the workflow is lost. EXIF Strip (the default) discards the prompt silently; EXIF Keep to JPEG keeps only the prompt.
- A short-workflow WebP (Make 9,655 B) shows Make and Model as EXIF fields, still no ComfyUI provenance. The Image-Saver hybrid is detected as A1111 only; an A1111 WebP is detected fully.
- PNG → PNG drops `invokeai_workflow` (missing from `ImageMetadata.toolKeywords`; follow-up 2 in [design §7](webp-1.3.md)). SwarmUI and Fooocus non-PNG files are not detected (follow-up 3); CHANGELOG/ROADMAP claims about them hold only for files SnapRescale wrote.

Reading workflows from WebP sources is out of scope for 1.3 (owner decision; follow-up 1).

### 3.8 The byte layout that follows

Verified in section 4; specified as `EXIFBlock.comfyUI` in [design §2.4](webp-1.3.md):
- Bare TIFF, no prefix: `4D 4D 00 2A 00 00 00 08`; N as u16 (2, or 1 with only a workflow or only a prompt); 12-byte entries sorted by tag, 0x010F then 0x0110, type 2, count = length + 1; next-IFD 0. Values from 8 + 2 + 12N + 4 (38 for N = 2): `workflow:` + text + NUL, `prompt:` + text + NUL, each at an even offset, a pad after an odd value including the last. Offsets are u32; multi-megabyte values are fine.
- Copy pure-ASCII text verbatim (byte-identical round trip). Otherwise escape non-ASCII as lowercase `\uXXXX` with surrogate pairs, which matches `json.dumps(ensure_ascii=True)` byte for byte; the design also escapes U+0000. Never a raw 00 in a value.
- One EXIF chunk through `WebPMuxSetChunk`; written even under EXIF Strip; never an empty IFD; no second IFD0 value starting `workflow:` or `prompt:` (the core keeps the last, image-saver the first).
- With camera EXIF kept, the camera Make/Model give way; other IFD0 entries, the Exif IFD and GPS stay in the single IFD0 (verified in ImageIO and Pillow). Moving a real MakerNote was not tested; absolute-offset ones (for example Canon) break.
- The file needs the `.webp` extension.

---

## 4. The end-to-end drop test

### 4.1 What was run (2026-10-21)

- **Source:** `Krea2_Share_00002_.png`, 1184×1760; tEXt `workflow` 19,603 bytes (20 nodes / 24 links) and `prompt` 4,737 bytes (17 API nodes), pure ASCII and stable under `json.dumps(json.loads(x))`.
- **Reference:** ComfyUI's real save path run in its venv, lossy and lossless. Its EXIF chunk was **byte-identical** to the hand-built `MM` blob: 24,398 bytes, SHA-256 `2d80e5415afc2df837eff54725732cbf32b68ff6c6af14633003fb41decb788f`; Make count 19,613 at 0x26, Model 4,745 at 0x4CC4.
- **Writers:** `cwebp -q 90 -resize 592 880 -metadata none` (or `-lossless`) with `webpmux -set exif|icc|xmp` (it stores the file verbatim, so pass the bare TIFF); and a Swift program on `WebPEncodeRGBA`, `WebPMuxCreate`, `WebPMuxSetChunk`, `WebPMuxAssemble`, identical for `MM`, `II` and an escaped UTF-8 iTXt source.
- **Readers:** (a) the frontend in headless Chromium, four runs: 1.55.18 core only; 1.59.0 core only; 1.55.18 with comfyui-image-saver 1.23.0 (the owner's real path; it performed every WebP load); v1.39.9 (before `#8527`). Plus Node replays of `main` and the old walk. (b) ImageIO: type, size, TIFF strings, Exif, GPS, Orientation, ICC, XMP. (c) Pillow 12.2.0: tags 0x010D–0x0110, Exif and GPS IFDs.

### 4.2 Results

| Variant | Frontend | ImageIO | Pillow |
|---|---|---|---|
| Source PNG (control) | 20/24, same ids, types, titles, all runs | n/a | n/a |
| ComfyUI's own WebP; recipe `MM`, `II`, each with and without `Exif\0\0`; Swift mux path | Loads == source in every run; reader string exact (2 ms) | Make nil, Model exact | Exact |
| Lossless VP8L odd size + pad before EXIF | Loads, except **v1.39.9**: "Unable to find workflow in …", empty canvas | Decodes | Exact |
| Raw UTF-8 (`Prompt — Zürich ☕ 🎨 日本語 café`) | Loads, renders | Model exact | **Mojibake** |
| Escaped `\uXXXX` with surrogate pairs | Loads, renders identically | Model exact | JSON-equal |
| 119,807-byte and 5,019,805-byte workflows | Load (≤ 5 ms); at 5 MB the frontend cannot save its draft (localStorage quota), the file is fine | Make nil | Exact |
| Camera EXIF merged, 10 IFD0 entries | Loads | Exif, GPS, Orientation 1 correct; Model shows the prompt as camera model | Exact |
| Camera Make/Model kept, workflow 0x010E, prompt 0x010D | Loads (not ComfyUI's convention) | All returned | Exact |
| ICCP 536 B + odd XMP; alpha + ICC + XMP (flags 0x2C, 0x3C) | Loads, v1.39.9 included | ICC, XMP read | Exact |
| Workflow only (N = 1) | Loads | No AI metadata visible | Exact |
| **No NUL in the counts** | **Core fails completely**: both JSONs lose `}`, empty canvas, no prompt fallback. Loads through image-saver | Tolerant | Tolerant |
| No EXIF / correct file typed `image/png` | LoadImage node (1.39.9: nothing) / "Not a valid PNG file", then a LoadImage node | n/a | n/a |

Two lessons: a missing NUL does not fall back to the prompt, and only the core reader catches it, so a test without a core-equivalent reader passes a broken file. And no empty IFD may be written (an early Swift version emitted 14 bytes for a source without AI text).

### 4.3 Rebuilding the harness

None of the frontend's code may enter the repo. The design keeps the gate as a manual Safari recipe ([design §4](webp-1.3.md), RELEASING step 5); automation is owner question 3. To rebuild an automated harness outside the repo:
1. **Source.** Take a real ComfyUI PNG; record its node and link counts by dropping it; extract `workflow` and `prompt` with any PNG chunk reader.
2. **Reference.** In ComfyUI's venv, Pillow `Image.Exif` with 0x010F = `workflow:` + text and 0x0110 = `prompt:` + text, saved as a single-frame WebP; its `EXIF` chunk equals `exif.tobytes()[6:]` (as the design's `Scripts/make-webp-fixtures.py`).
3. **Candidates.** WebPs from SnapRescale with their `.webp` names, plus negative controls: no EXIF, counts without the NUL, the right file typed `image/png`.
4. **Server.** `PYTHONDONTWRITEBYTECODE=1 ~/ComfyUI/.venv/bin/python3 ~/ComfyUI-Installs/ComfyUI/ComfyUI/main.py --cpu --listen 127.0.0.1 --port 8199 --base-directory <scratch>/comfybase --disable-all-custom-nodes --database-url sqlite:///:memory: --disable-auto-launch`, adding `--front-end-root <dist>` for a frontend release downloaded from GitHub. For the image-saver leg, copy the node into `<scratch>/comfybase/custom_nodes` and drop `--disable-all-custom-nodes`.
5. **Drop.** Headless Chromium through Playwright; wait for the app object; build a `File` with the bytes, the `.webp` name and type `image/webp` inside a `DataTransfer`; dispatch `dragenter`, `dragover` and `drop` on `#graph-canvas`. This is the app's real file path.
6. **Check.** Read node count, ids, types, titles, link count and tab name from the page's app object and compare with the source. Optionally call `window.comfyAPI.pnginfo.getWebpMetadata` on the `File` and compare the workflow string exactly and as JSON. Wrap the graph-loading entry points to see whether core or image-saver loaded it.
7. **Record** the frontend version per leg, keep the console log and a failure screenshot, stop the server.

In the repo the automated oracle is the clean-room `ComfyUIFrontendReader` (test support, `.current` and `.legacy` modes), written from section 3.3 ([design §5](webp-1.3.md)).

---

## 5. Code touchpoints at `22f1fd5`

Five code maps and a cross-check; the design cites exact lines.

| Area | Finding | Design |
|---|---|---|
| `OutputFormat` (OutputFormat.swift:5-55) | `writable = [.jpeg, .png, .heic, .tiff]` (l.23), so Keep original is nil for WebP; `isLossy` JPEG/HEIC; the sidebar picker iterates `allCases`; `UTType.webP` gives `webp` | §2.1 |
| `RenderSpec`, `RenderError` (Renderer.swift:7-40, 59-72) | Only `quality` (0.95); `padColor` defaults to nil (l.30), relied on by the CLI | §2.2, §2.3 |
| `Renderer` (Renderer.swift:74, 139-177, 180) | `render` checks Limits (l.77-78), builds ColorPlan, retags DeviceRGB under ICC Strip (l.117). Private `encode` is the one seam (ImageIO destination l.152, `MetadataWriter.finish` l.176); `produce` adds `PNGSplicer` (l.182). Synchronous, uncancellable | §1, §2.9 |
| `ColorPlan` | 16-bit only for PNG/TIFF/HEIC (l.31); `embedsProfile` (l.19); CMYK only JPEG/TIFF; premultiplied contexts with padded rows | §2.7 |
| `MetadataWriter` (l.22-115) | Per-switch dictionary filter; `parameters` → UserComment outside PNG (l.31-40); §10.4 fixes; `PendingUserComment` same-length swap (l.150-206); `writes()` asks the capability table (l.258-260). No raw EXIF bytes exist in the engine | §2.4 |
| `PNGSplicer`, scanners | `keepingAIWorkflow` PNG only (l.71-78); `PNGScanner.forEachChunk` private (l.276); `XMPScanner.webP`, `ICCScanner.webP` | §2.4, §2.5 |
| AI classification (ImageMetadata.swift) | ComfyUI only from PNG keys (l.373-387, l.376); `toolKeywords` (l.391-393); one `workflowChunks` classification (l.407-432); nothing reads TIFF Make/Model | §2.4, §2.6 |
| Capability table | `MetadataPolicy.capability(of:in:)` (l.172-205): WebP falls to `.none` (l.204); `partialWorkflowNote`; `MetadataCapability` `requiresPNGNote`, `isPNGOnly` | §2.6 |
| `Session`, sidebar | `spec` (l.178-182); per-image reset (l.322-339); `resolveFormat` (l.354-362) says "WEBP cannot be written; saving as JPEG."; `scheduleEncode` (l.449-472) encodes per change, latest wins, `try?`. ControlsPanel Quality row (l.83-90), File row height (l.113), extensions (l.216-223), notes (l.289-324); trigger ContentView.swift:37, uppercase source label l.138; `Binding.deferred`/`deferredLive` | §3 |
| CLI (main.swift) | Format lists (l.6, 21, 77-85, 133); `RenderSpec` at l.135 with no policy | §2.11 |
| Presets | Format names hand-written (Codable+Readable.swift:49-72); `PresetStore` writes shipped presets (l.37-39) and shows a generic decode error (l.72); effort is an app preference (Preset.swift:3-5) | §2.2, §3 |
| Build | `RescaleKit/Package.swift:11-27`; `project.yml` (DEAD_CODE_STRIPPING unset, version l.21-22, LICENSE l.40-41); `build-app.sh` copies only the executable (l.11); release scripts use `pipefail`; no CI | §4 |
| Tests listing formats | `MetadataWriterTests.swift:45`, `ColorPlanTests.swift:12`, `PNGSplicerTests.swift:210-213`, `MetadataPolicyTests.swift:183, 196-197`, `ValidationTests.swift:137`; ImageIO-based helpers cannot make WebP sources | §5 |

The cross-check corrected three claims (the CLI never calls `fallback(for:hasAlpha:)`; ControlsPanel l.216-219 is the output extension, the source's is l.221-223; a 1.2 app shows a generic message for a WebP preset) and flagged that the maps had planned "Requires PNG output" for ComfyUI on WebP, against the acceptance gate.

---

## 6. The design competition

### 6.1 The three designs

All took the owner decisions of 2026-10-21 as fixed and used the same research.
- **reuse:** builds the metadata on a static 1×1 DeviceRGB PNG carrier through ImageIO, moves its `eXIf` and XMP into RIFF, and natively appends only an IFD0 with the exact Make/Model strings and the real pixel dimensions.
- **own-bytes:** serialises everything itself: a Swift `TIFFWriter` (about 180 lines), an `EXIFBlock` with a 110-tag mapping table (about 350), `ComfyCarrier`, `WebPWriter`, about 700 test lines; maker notes dropped in WebP.
- **risk-first:** an oracle per claim (P1–P8), the carrier behind a clean seam (`imageIOEncode(_:encodeAs:rulesOf:)`), shared predicates for writer and notes, a committed Node/Playwright drop harness, Save reusing the readout's bytes, 17 items in 5 waves.

### 6.2 Scores

All three judges chose risk-first. Judges are numbered in the order their reports were filed; Appendix A of the design uses its own labels.

| Design | Judge 1 | Judge 2 | Judge 3 | Total |
|---|---|---|---|---|
| risk-first | 8 | 8 | 8.5 | **24.5** |
| reuse | 7 | 6.5 | 8 | 21.5 |
| own-bytes | 4.5 | 5.5 | 6 | 16 |

### 6.3 What the judges valued and penalised

- **risk-first, valued:** independent oracles (libwebp's decoder for lossless, ImageIO with tolerance for lossy, a Pillow golden, a byte manifest for the other formats); `NotesMatchOutputTests`; single-source predicates; a hardened carrier parser that throws rather than write unverified bytes; never degrading silently; measurable acceptance criteria; the widest release gate. **Penalised:** process weight (17 items, a Node harness in a Swift-only repo), the Save-reuse cache, a misnamed `EncoderOptions.swift`, `lossless` always in presets, an opacity-hidden slider, next-IFD not forced to 0, duplicates treated as carried, wall-clock cancel tests, a red Wave 0.
- **reuse, valued:** smallest footprint, EXIF parity through ImageIO, append-only IFD0, the `properties(type: .webP) == properties(type: .jpeg)` proof, deterministic cancel tests. **Penalised:** WebP woven into the encode through flags, the DeviceRGB carrier losing ExifColorSpace, only 0x010F/0x0110 dropped, `encoderFailed` beside `encodeFailed`, `--lossless` ignored outside WebP.
- **own-bytes, valued:** deterministic bytes, late `writable` change, the Pillow golden, U+0000 escaping, automated binary guards. **Penalised:** code volume, EXIF drift (maker notes dropped, rationals re-derived, ExifVersion forced), silent loss of unmapped keys, a cross-format guard changing JPEG/TIFF output, a quality-lowering `partition_limit` retry, a reader described as a line-by-line port of GPL code.
- **All three:** `padColor` defaulting to `.white` (it is nil); no word on Keep original writing one frame of an animated WebP; `writable` changed in a wave that did not own the tests it breaks.

### 6.4 Grafts

Taken ([design Appendix A](webp-1.3.md)): the Pillow golden, also from `compressed-text.png`; U+0000 escaping; the reuse proof; the opt-in real-file gate (`SNAPRESCALE_COMFY_SAMPLE`); `lossless` written to presets only when true and normalised; a conditional slider at 20 pt; `writable` changed only in the integration item; one `produce` with a defaulted cancellation parameter; `EncoderEffort.swift` and `RenderCancellation.swift`; a manual drop recipe; Save reuse as follow-up 5; deterministic cancel tests; next-IFD forced to 0; duplicates PNG-only with a note; zero-filled dropped values; a frames note; a Settings tooltip; binary guards; `spctl`, `notarytool log` and Rosetta rows; carrier fuzz tests; `Scripts/test-all.sh`; exFAT and real-install legs; the cross-format `workflow:` Make leak as follow-up 1.

Rejected or changed: the static DeviceRGB carrier, which loses ExifColorSpace parity while a 1×1 crop costs nothing (decision 1). The `WEBP_USE_THREAD` `#error` moved from the header to a `.c` file (decision 19), and `swift test` on the VM became a host-built CLI run there, verified on the host (decision 20). The design says two grafts were rejected; Appendix A marks the carrier outright and these two as adopted in modified form.

### 6.5 Critiques

Two critics reviewed the synthesis: 8 findings (2 major, 6 minor) and 7 (2 major, 5 minor), 15 in all, two duplicated. The majors: `nm | grep -q` guards that invert under `pipefail` (confirmed on the installed 1.2 binary, 3 of 3 runs); a CLI limited to the Default policy, leaving the macOS 26 carrier check untested (raised by both); and the untested Image-Saver hybrid PNG, the one Default-policy source that goes through the carrier. All were checked and fixed ([design Appendix B](webp-1.3.md)); one part of one was declined.

### 6.6 Declined: the civitai check

The hybrid-PNG finding also proposed checking that A1111 tools and civitai read the `parameters` from SnapRescale's WebP. Checking on civitai would upload the owner's images to a third-party site, so it was declined; `ExternalWebPTests` verifies by ImageIO read-back that the UserComment decodes to the source's `parameters`. civitai's behaviour in section 3.4 comes from reading its published package offline, with nothing uploaded.
