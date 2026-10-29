# SnapRescale 1.3: WebP output (GitHub #1). Final implementation design

> **Status (2026-10-29):** designed, not implemented. Planned for 1.3, tracked
> in #1 and its sub-issues on the SnapRescale project board. The design was
> written on 2026-10-21 and 2026-10-22 against `main` at `22f1fd5`; since then
> `main` has changed only in docs, so the code references still hold, and the
> line numbers in `README.md`, `docs/*.md` may have moved. The owner decisions
> of 2026-10-21 are fixed inputs. The four questions at the end are still open.

Every `file:line` reference below is relative to the repo root and was read at `22f1fd5`.

**What this design is built from**
- It starts from the highest-scoring design, "risk-first" (24.5).
- It adds the grafts the judges recommended and fixes every defect they found, each checked against the code first. Appendix A lists them. Two grafts are rejected, each with a reason.
- It was then revised against a 15-finding critique. Every finding was checked against the source, the libwebp 1.6.0 tree, or by running the check. Appendix B lists each one as fixed or rejected.
- The research material it cites (the `synth/`, `libwebp-research/` and `webp-ai/` folders of the 2026-10-21 session) was temporary and is gone. What was found is in [webp-research.md](webp-research.md).

**New files** (all absolute)

| File | Item |
|---|---|
| `RescaleKit/Sources/CWebP/` (vendored tree) | A |
| `Scripts/update-libwebp.sh`, `Scripts/keys/libwebp-release-key.asc` | A |
| `THIRD-PARTY-NOTICES.txt` | A |
| `RescaleKit/Sources/RescaleKit/EncoderEffort.swift`, `RescaleKit/Sources/RescaleKit/RenderCancellation.swift` | D |
| `RescaleKit/Sources/RescaleKit/MetadataWriter+ComfyUI.swift` | H |
| `RescaleKit/Sources/RescaleKit/WebPEncoder.swift` | E |
| `RescaleKit/Sources/RescaleKit/EXIFBlock.swift` | F |
| `RescaleKit/Sources/RescaleKit/WebPMetadata.swift` | L |
| `RescaleKit/Tests/RescaleKitTests/Support/{RIFFProbe,TIFFProbe,ComfyUIFrontendReader,WebPFixtures}.swift` | B |
| `RescaleKit/Tests/RescaleKitTests/Fixtures/webp/` (goldens, `comfyui-camera.png`, `imagesaver-hybrid.png`) | B |
| `Scripts/make-webp-fixtures.py` | B |
| `Scripts/test-all.sh` | J |
| `Scripts/check-app-binary.sh` | J |
| `SnapRescale/Sources/SnapRescale/NoticesView.swift` | O |

---

## 0. What must be proven, and the oracle for each

| # | Proof | Independent oracle | Where |
|---|---|---|---|
| P1 | A ComfyUI PNG saved as WebP with the AI switch on Keep loads its workflow in real ComfyUI. This includes an Image-Saver hybrid PNG (`parameters` + `workflow` + `prompt`) | Drop the file on a real ComfyUI server: the bundled frontend, the latest one, and the owner's install with custom nodes. This is a written manual recipe | `docs/RELEASING.md` release gate (section 4) |
| P2 | The EXIF bytes for ComfyUI equal ComfyUI's own, byte for byte | Goldens written by Pillow through ComfyUI's own save path (`Image.Exif`, then a WebP save). Plus an opt-in check against a real ComfyUI WebP (24,398 B, sha256 `2d80e541…`) | `EXIFBlockTests` |
| P3 | A frontend-equivalent parser finds `workflow` and `prompt` in every kind of WebP we write. That covers both the carrier path (hybrid source, EXIF Keep) and the no-carrier path | A test-side reader written clean-room from the frontend's behaviour, in `.current` and `.legacy` modes | `ComfyUIFrontendTests` |
| P4 | Every metadata switch does what it says on WebP, and every note matches the output | Test-side RIFF and TIFF probes (Foundation only), plus ImageIO read-back. Long Make/Model values are the exception: ImageIO drops them at 10,000 characters or more | `WebPMetadataTests`, `NotesMatchOutputTests` |
| P5 | Lossless is exact, alpha is straight, and lossy stays within tolerance on both architectures | libwebp's `WebPDecodeRGBA` for exact checks; ImageIO's decoder for tolerance checks. Lossy output is never hashed | `WebPEncoderTests` |
| P6 | Sandbox, hardened runtime, notarisation, universal binary, static link | `Scripts/check-app-binary.sh`. It is safe under `pipefail` and called by `release.sh` and `appstore.sh`, and is itself tested both ways. Plus `spctl` and `notarytool log` | J, RELEASING |
| P7 | The encode refactor changes no byte of JPEG, PNG, HEIC or TIFF output | A digest manifest of `Renderer.produce`, generated on `22f1fd5` in W0 and compared after the integration item, on the same machine | `RegressionManifestTests` (opt-in) |
| P8 | Nothing is shrunk or dropped silently at 16,384 px or more | An exact error and message; the sidebar note appears before any encode | `FormatLimitTests`, `SessionWebPTests` |
| P9 | The carrier behaviour holds on the deployment-target OS (macOS 26.6.2): camera EXIF, GPS, XMP sync, IPTC→XMP, give-way, no IFD1, PixelX/Y | Two sources, both verified on the host with carrier assertions. (1) The host-built universal CLI runs on the VM under `--metadata default` **and** `--metadata keep-all`. (2) The sandboxed app's outputs from step 4 are copied back | `ExternalWebPTests` (opt-in), RELEASING |

---

## 1. Architecture overview

```
Session (MainActor)                                  rescale CLI (Sources/rescale/main.swift)
  format, quality, lossless(new), metadataPolicy       --format webp --quality q --lossless --effort e
  AppSettings.webPEffort(new) ─┐                       --metadata default|keep-all|strip-all (new)
  spec (Session.swift:178-182) ┴─▶ RenderSpec { target, fit, anchor, padColor (default nil, unchanged),
                                                format, quality, lossless(new), effort(new), metadata }
        │                                    │
  scheduleEncode (readout; one             write(to:) (Save; encodes as today)
  RenderCancellation per running job)
        └──────────────┬─────────────────────┘
                       ▼
Renderer.produce(source, spec:, cancel: RenderCancellation? = nil)     one function, no async overload
  1 render(source, spec)                                               Renderer.swift:74
      Limits guard (l.77-78), then NEW format limit: WebP ≤ 16383 per side → .formatLimit
      ColorPlan: WebP = 8-bit; grey → sRGB (new); no-ICC space → sRGB (new); CMYK → sRGB (existing)
  2 cancel?.checkCancelled()
  3 encode(image, spec, source)                                        Renderer.swift:139
      resolvedType conforms to .webP ?
      ├─ yes ─ WebPMetadata.encode                                     NEW WebPMetadata.swift
      │          comfy = MetadataWriter.comfyUIStrings(in:policy:)       NEW (H), AI switch only
      │          props = MetadataWriter.properties(type: .webP)          existing, unchanged
      │          give-way, per tag: drop TIFF Make if a workflow is written, Model if a prompt is (H)
      │          tree  = XMPWriter.metadata(type: .webP)                 existing, unchanged
      │          wantsEXIF = props has Exif/TIFF/GPS;  wantsXMP = tree != nil || props has IPTC
      │          neither → exif = EXIFBlock.comfyUI(comfy), xmp = nil    (no carrier at all)
      │          else carrier = image.cropping(to: 1×1)  (keeps the colour space, so ExifColorSpace matches)
      │               imageIOEncode(carrier, as: .png, props, tree) + PendingUserComment.applied(toPNG:)
      │               exif = wantsEXIF ? EXIFBlock.finishing(eXIf body, size, comfy,
      │                                    dropAIPrefixedStrings: !policy.keeps(.aiWorkflow))
      │                                : EXIFBlock.comfyUI(comfy)
      │               EXIFBlock.Malformed → .encoderRefused(.webP, WebPMetadata.carrierFailedMessage)
      │               xmp  = wantsXMP  ? iTXt "XML:com.adobe.xmp" text : nil
      │          icc = ColorPlan.embedsProfile(policy.icc) ? image.colorSpace.copyICCData() : nil
      │          WebPEncoder.encode(image, options, chunks, cancel)    NEW WebPEncoder.swift
      │            vImage → straight RGBA/RGBX → WebPPicture(use_argb=1) → WebPEncode(progress_hook)
      │            → WebPMux (only if ICC/EXIF/XMP): ICCP, EXIF, "XMP " → assemble
      └─ no ── imageIOEncode(image, as: type, props, tree, quality) + MetadataWriter.finish
               = today's l.145-176, byte-identical (P7)
  4 PNGSplicer.keepingAIWorkflow (PNG only, PNGSplicer.swift:71-78; WebP untouched)
                       ▼
SafeWrite (unchanged) → name_WxH.webp (OutputNaming; UTType.webP's extension is "webp")
```

Design rules:
- The ComfyUI strings never pass through ImageIO. ImageIO is only the carrier: it produces the camera EXIF and XMP blocks with the semantics already used and tested for PNG output (every switch, mirror rule, PRD §10.4 fix and `PendingUserComment`).
- No byte ImageIO wrote is ever moved. Edits happen in place: two dimension values, the header pointer, next-IFD, and zero-fills. Everything else is appended.
- libwebp is reached only through `internal import CWebP` in `WebPEncoder.swift`. No C type appears in RescaleKit's public API.
- `EXIFBlock` depends on neither ImageIO nor `Renderer`. It throws its own `EXIFBlock.Malformed`, which `WebPMetadata` maps to the user-facing error. So F builds on W0 alone.

---

## 2. RescaleKit API changes

### 2.1 `OutputFormat` (`RescaleKit/Sources/RescaleKit/OutputFormat.swift`)

| Member | Today | 1.3 | Item |
|---|---|---|---|
| cases (l.5-10) | keepOriginal, jpeg, png, heic, tiff | add `webp` last. The picker iterates `allCases` (ControlsPanel.swift:72), so the order users know stays the same | D |
| `label` (l.12-20) | | `.webp: "WebP"` | D |
| `writable` (l.22-23) | `[.jpeg, .png, .heic, .tiff]`, "Types ImageIO can encode on this platform that v1 exposes." | `[.jpeg, .png, .heic, .tiff, .webP]`, "Types SnapRescale can write: ImageIO's four, and WebP through the bundled libwebp." **Changed only in L**, so Keep original never resolves WebP before an encoder exists | L |
| `resolvedType` (l.25-35) | | `case .webp: return .webP`. The doc's "(GIF, WebP, RAW, …)" becomes "(GIF, RAW, …)" | D |
| `isLossy(for:)` (l.45-49) | jpeg, heic | adds webP. It means "has a Quality row"; lossless is `RenderSpec.lossless` | D |
| `supportsAlpha(for:)` (l.51-54) | png, heic, tiff | adds webP. This gives transparent padding (`padNeedsAlpha`, Renderer.swift:23-27) and no flatten warning (ControlsPanel.swift:313-314) | D |
| `supportsLossless(for:) -> Bool` | none | `resolvedType(for:) == .webP` | D |
| `static func maxDimension(for: UTType) -> Int?` | none | 16383 for `.webP`, nil otherwise. `WebPEncoderTests` asserts it equals C `WEBP_MAX_DIMENSION` | D |
| `static func displayName(for: UTType) -> String?` | none | "WebP" for `.webP`, otherwise `preferredFilenameExtension?.uppercased()`. Each call site keeps its own fallback | D |
| `init?(name: String)` / `var name: String` | none | the single parser, lowercased: keep/keeporiginal/original, jpeg/jpg, png, heic, tiff/tif, webp; and its inverse. Used by the decoder and encoder (Codable+Readable.swift:49-72), the CLI (main.swift:77-85) and the app's `--format` | D |
| `fallback(for:hasAlpha:)` (l.39-43) | PNG if alpha, else JPEG | unchanged; WebP is never chosen silently | none |

`displayName` replaces every ad-hoc uppercasing of a format name (all found with `grep preferredFilenameExtension.*uppercased`):
- ColorPlan.swift:65 (G)
- Renderer.swift:68-69 (D)
- Session.swift:360 (M)
- main.swift:133 (K)
- ControlsPanel.swift:216-223, `keptExtension` and `sourceExtension` (N)
- **ContentView.swift:138**, `SourceHeader.summary`, the source header's format label (N)

So the app never shows "WEBP", and the header of a WebP source reads "… · WebP", matching the sidebar. D also adds the `.webp` arm to any other exhaustive switch on `OutputFormat` that the compiler reports in RescaleKit or SnapRescale.

### 2.2 Encoder options model, Codable and preset keys

**Decision: flat fields on `RenderSpec`, and no `EncoderOptions` value until a second encoder needs options.**

```swift
// Renderer.swift:7-40 (D)
public struct RenderSpec: Hashable, Sendable {
    …
    /// WebP only: VP8L lossless instead of lossy; `quality` is then unused. Other formats ignore it.
    public var lossless: Bool
    /// How hard an encoder that has the choice works (WebP). An app setting, never a preset field.
    public var effort: EncoderEffort

    public init(target: PixelSize, fit: FitPolicy = .crop, anchor: CropAnchor = .center,
                padColor: PadColor? = nil,                       // unchanged: the CLI (main.swift:135) relies on nil
                format: OutputFormat = .keepOriginal, quality: Double = 0.95,
                lossless: Bool = false, effort: EncoderEffort = .balanced,
                metadata: MetadataPolicy = .default)

    /// "WebP holds at most 16383 px per side; 20000×11250 is larger." or nil (section 2.8).
    public func formatLimitProblem(sourceType: UTType) -> String?
}
```

```swift
// NEW RescaleKit/Sources/RescaleKit/EncoderEffort.swift (D)
public enum EncoderEffort: String, CaseIterable, Hashable, Sendable, Codable {
    case fast, balanced, best
    public var label: String { switch self { case .fast: "Fast"; case .balanced: "Balanced"; case .best: "Best" } }
}

// NEW RescaleKit/Sources/RescaleKit/RenderCancellation.swift (D)
import Synchronization
/// Cancels one `Renderer.produce`. It is a defaulted parameter of the single `produce`;
/// there is deliberately no async or overloaded variant. ImageIO encodes check it between
/// phases only; a WebP encode also checks it from libwebp's progress hook.
public final class RenderCancellation: Sendable {
    private let flag = Atomic<Bool>(false)
    private let tripOnFirstEncoderPoll: Bool
    public init() { tripOnFirstEncoderPoll = false }
    /// Tests only: cancels itself the first time the encoder polls it (deterministic mid-encode cancel).
    init(cancellingOnFirstEncoderPoll: Bool) { tripOnFirstEncoderPoll = cancellingOnFirstEncoderPoll }
    public func cancel() { flag.store(true, ordering: .relaxed) }
    public var isCancelled: Bool { flag.load(ordering: .relaxed) }
    func checkCancelled() throws { if isCancelled { throw Renderer.RenderError.cancelled } }
    /// Called from libwebp's progress hook, possibly on a worker thread.
    func shouldStopEncoding() -> Bool { if tripOnFirstEncoderPoll { cancel() }; return isCancelled }
}
```

The fields are flat because:
- Three call sites build a `RenderSpec`: Session.swift:180, MetadataInspector.swift:281 and main.swift:135. The defaults leave the inspector's capability-only spec unchanged. The CLI passes the new fields explicitly (section 2.11).
- `Hashable` equality already drives readout publishing (Session.swift:465).

**Preset keys and compatibility** (K):

| Key | Preset JSON | 1.2 file → 1.3 | 1.3 file → 1.2 app |
|---|---|---|---|
| `format: "webp"` | new value, decoded through `OutputFormat(name:)`, so "WebP" also works | n/a | 1.2 throws at Codable+Readable.swift:59, so the preset is **skipped** with "Skipped: X.json: The data couldn’t be read because it isn’t in the correct format." (PresetStore.swift:72). 1.2 cannot be fixed; the CHANGELOG says so |
| `lossless: true` | **written only when true**, by a hand-written `encode(to:)` that otherwise matches the synthesised one (same key order as `CodingKeys`, Preset.swift:34-36; `encodeIfPresent(padColor)`) | `decodeIfPresent ?? false`, the pattern of Preset.swift:50 | the unknown key is ignored |
| effort | **not in presets** | | |

Every non-WebP preset stays byte-identical to 1.2, including the shipped ones that PresetStore.swift:37-39 writes to disk.
- Effort is an app preference. Preset.swift:3-5 says presets are "Not the framing (the crop anchor), nor the app's preferences".
- The 1.3 decoder stays strict: an unknown format still throws.
- `PresetStore` (l.72) reports a `DecodingError`'s `debugDescription` instead of `localizedDescription`, for example `Skipped: x.json: unknown format "avif"`.
- `Preset` gains `public var lossless: Bool`, with init parameter `lossless: Bool = false` after `quality`.
- `Preset.summary` (l.85) gives "WebP lossless" when `format == .webp && lossless`, and the existing "\(format.label) \(qualityPercent)" otherwise.
- `shipped` (l.92-98) is unchanged.

### 2.3 `WebPEncoder` (new `RescaleKit/Sources/RescaleKit/WebPEncoder.swift`, E)

```swift
internal import CWebP
import Accelerate
import CoreGraphics

enum WebPEncoder {
    struct Options: Hashable, Sendable { var quality: Double; var lossless: Bool; var effort: EncoderEffort }
    struct Chunks { var icc: Data?; var exif: Data?; var xmp: Data? }
    static func encode(_ image: CGImage, options: Options, chunks: Chunks,
                       cancel: RenderCancellation?) throws -> Data
    static func config(for options: Options) throws -> WebPConfig          // internal, tested
    static func error(for code: WebPEncodingError, size: PixelSize) -> Renderer.RenderError  // internal, tested
}
```

**Pixels (straight alpha).**
- Convert with `vImage_Buffer(cgImage:format:)`. The format is `vImage_CGImageFormat(bitsPerComponent: 8, bitsPerPixel: 32, colorSpace: image.colorSpace, bitmapInfo: hasAlpha ? .last : .noneSkipLast)`.
- The colour space is the image's own, so no conversion happens. vImage un-premultiplies, narrows defensively to 8 bits (ColorPlan already gives 8 for WebP), and handles a padded `bytesPerRow`.
- Import with `WebPPictureImportRGBA` when there is alpha, else `WebPPictureImportRGBX`, with stride `Int32(buf.rowBytes)`. Free the buffer right after the import.
- Always set `pic.use_argb = 1`, because sharp YUV runs only from ARGB.

**Config.** Call `WebPConfigInit`, then:

| | Fast | Balanced (default) | Best |
|---|---|---|---|
| Lossy: `WebPConfigPreset(&c, WEBP_PRESET_DEFAULT, q×100)`, `thread_level 1` | `method 2` | `method 4` | `method 6`, `use_sharp_yuv 1` |
| Lossless: `WebPConfigLosslessPreset(&c, level)`, `exact 1`, **`thread_level 0`** | level 1 (m1 q20) | level 6 (m4 q75, libwebp's own lossless default) | level 8 (m5 q90) |
| Research, 16 MP, arm64 | lossy 238 ms; lossless level 0 806 ms | lossy 660 ms; lossless roughly 8 s | lossy m6 777 ms (about 1.3 s with sharp YUV); lossless measured in E |

- Common settings: `alpha_quality 100`, then `WebPValidateConfig`. A 0 maps to `.encodeFailed(.webP)`.
- **Why lossless uses `thread_level 0`.** In VP8L, `thread_level` has one effect. With it set, the crunch configs split between the calling thread and a side worker (vp8l_enc.c:1727-1736), and the side worker's picture has `progress_hook = NULL` (vp8l_enc.c:1763). Level 8 (m5, q ≥ 75) tries two configs on a palette image (vp8l_enc.c:396-401, `kLosslessPresets` config_enc.c:143-146). The main thread would then wait in `Sync` for the side encode without polling, so cancel would be late. With `thread_level 0`, both configs run on the calling thread, where the hook is polled. This costs time only for palette images at Best. Levels 1 and 6 always use one config.
- **Lossy keeps `thread_level 1`** for the analysis split and the alpha worker. A lossy encode's alpha plane runs on a fresh picture without the hook (alpha_enc.c:62-65, worker at :404-442). Cancelling a lossy encode with alpha can therefore wait for that one-plane encode. E measures and records the delay; it is not hidden.
- Level 9 is excluded: 22.7 s at 16 MP in research, and its brute-force configs delayed cancel by 2.9-6.3 s.
- `exact = 1` in lossless makes the output byte-exact on straight RGBA, which gives P5 a trivial oracle. The render is premultiplied, so RGB under alpha 0 is already 0 and the setting costs nothing.

**Encode.**
1. `WebPMemoryWriterInit(&w)`, `pic.writer = WebPMemoryWrite`, `pic.custom_ptr = &w`.
2. When a token exists, set `pic.user_data = Unmanaged.passUnretained(token).toOpaque()` and set `pic.progress_hook`:
   ```swift
   { _, p in
       guard let u = p?.pointee.user_data else { return 1 }
       return Unmanaged<RenderCancellation>.fromOpaque(u).takeUnretainedValue().shouldStopEncoding() ? 0 : 1
   }
   ```
   This is a non-capturing `@convention(c)` closure, and the read is atomic, so it is safe on worker threads.
3. Run the call inside `withExtendedLifetime(token)`.
4. Failure is **`ok == 0 || pic.error_code != VP8_ENC_OK`**, because 1.6.0 can return 1 with `USER_ABORT`.
5. Clean up with `defer { WebPPictureFree(&pic); WebPMemoryWriterClear(&w) }`.

`checkCancelled()` runs before the carrier, before `WebPEncode`, and before the mux.

**Mux** runs only when `icc`, `exif` or `xmp` is non-nil. Otherwise the encoder's own RIFF is returned. That is simple VP8 or VP8L, or VP8X+ALPH+VP8 for lossy with alpha, because libwebp writes VP8X whenever a lossy picture has alpha (syntax_enc.c:29-30).
1. `WebPMuxNew`
2. `WebPMuxSetImage(copy: 0)`
3. `WebPMuxSetChunk` with "ICCP", "EXIF" and "XMP " (`copy: 1`)
4. `WebPMuxAssemble`

Assemble sets the VP8X flags (ICC 0x20, alpha 0x10, EXIF 0x08, XMP 0x04), orders the chunks VP8X, ICCP, ALPH, VP8/VP8L, EXIF, XMP, and pads odd chunks. Clean up with `WebPDataClear` and `WebPMuxDelete`. Any mux result other than `WEBP_MUX_OK` maps to `.encodeFailed(.webP)`.

**Error model.** The new cases are generic, so a future encoder can reuse them. They are added to `Renderer.RenderError` at Renderer.swift:59-72 (D):

```swift
case formatLimit(UTType, max: Int, size: PixelSize)   // "WebP holds at most 16383 px per side; 20000×11250 is larger. Choose a smaller size or another format."
case encoderRefused(UTType, reason: String)           // message = reason
case profileNotWritable(UTType)                       // "The colour profile could not be written to WebP."
case cancelled                                        // never shown: the readout drops it
```

The existing `.encodeFailed(t)` text becomes "Could not encode as \(displayName ?? identifier)." No test asserts the old "jpeg" form. `.cannotKeepFormat` (l.69) becomes "\(displayName ?? identifier) cannot be written; choose JPEG, PNG, HEIC, TIFF or WebP."

| libwebp `WebPEncodingError` | RenderError |
|---|---|
| 1 OUT_OF_MEMORY, 2 BITSTREAM_OUT_OF_MEMORY | `.encoderRefused(.webP, "Not enough memory to encode this image as WebP.")` |
| 3 NULL_PARAMETER, 4 INVALID_CONFIGURATION, 8 BAD_WRITE, import failure | `.encodeFailed(.webP)` |
| 5 BAD_DIMENSION | `.formatLimit(.webP, max: 16383, size:)` |
| 6 PARTITION0_OVERFLOW, 7 PARTITION_OVERFLOW | `.encoderRefused(.webP, "WebP cannot encode this image at this quality. Lower the quality or turn on Lossless.")`. There is **no** automatic `partition_limit` retry, because that would lower quality silently |
| 9 FILE_TOO_BIG | `.encoderRefused(.webP, "The WebP file would be larger than 4 GB.")` |
| 10 USER_ABORT | `.cancelled` |

### 2.4 The EXIF block builder (`EXIFBlock.swift`, F; `WebPMetadata.swift`, L; predicates in `MetadataWriter+ComfyUI.swift`, H)

**Shared predicates (H, W0).** The writer and the notes both call these, so there is one classification, following ImageMetadata.swift:402-406 and `MetadataWriter.movedParameters`.

```swift
extension MetadataWriter {
    struct ComfyUIStrings: Hashable, Sendable { var workflow: String?; var prompt: String? }

    /// IFD0 ASCII tags shared by a camera and ComfyUI's WebP layout.
    struct IFD0Tags: OptionSet, Hashable, Sendable {
        let rawValue: Int
        static let make  = IFD0Tags(rawValue: 1)   // 0x010F: the workflow
        static let model = IFD0Tags(rawValue: 2)   // 0x0110: the prompt
    }

    /// The first `workflow` and the first `prompt` chunk that has text, among the chunks Keep
    /// carries (`PNGSplicer.aiWorkflowChunks(in: metadata.pngTextChunks)`, PNGSplicer.swift:17), in file
    /// order. Nil when `policy.aiWorkflow == .strip`, or when neither exists. Either field may be nil.
    static func comfyUIStrings(in metadata: ImageMetadata, policy: MetadataPolicy) -> ComfyUIStrings?

    /// The tags the strings take: .make for a workflow, .model for a prompt.
    static func comfyUITags(_ s: ComfyUIStrings?) -> IFD0Tags

    /// The at most two chunks that WebP holds (Make, Model); every other AI chunk stays PNG-only.
    static func webPWorkflowChunks(in metadata: ImageMetadata) -> [PNGScanner.TextChunk]

    /// The source's camera tags that give way on this save: `type.conforms(to: .webP)`,
    /// `policy.exif == .keep`, ComfyUI strings present, and a non-empty source TIFF value for a
    /// tag those strings take. Built from the policy and the type only, never from
    /// `MetadataPolicy.capability` or the private `MetadataWriter.writes` (MetadataWriter.swift:258-260),
    /// whose WebP row lands later, in I.
    static func cameraTagsGivingWay(sourceProperties: [CFString: Any], metadata: ImageMetadata,
                                    policy: MetadataPolicy, type: UTType) -> IFD0Tags
}
```

The first `workflow` and `prompt` chunks are taken whatever their classification.
- A `workflow` keyword alone makes the file ComfyUI (ImageMetadata.swift:376).
- A `prompt` chunk without `class_type` is "unrecognised", but Keep carries it (ImageMetadata.swift:445-448). That keeps the switch label honest: "Keep carries whatever is listed".
- tEXt, zTXt and iTXt are already decoded by `PNGScanner`.
- **Only one of the two.** A workflow-only source writes Make alone, and a prompt-only source writes Model alone. Research shows a prompt alone still loads, through the frontend's `loadApiJson` (ai-results v14). The give-way and the notes follow the tags actually written.

**`EXIFBlock.comfyUI(_ s: ComfyUIStrings) -> Data?`** produces ComfyUI's own layout, byte for byte:

```
0   4D 4D 00 2A  00 00 00 08            "MM", 42, IFD0 at 8 (bare: no "Exif\0\0")
8   00 0N                                N = 1 or 2; nil when both strings are nil (never an empty IFD)
10  01 0F 00 02 <count W u32> <off W>    only if workflow; count = bytes + 1 (the NUL)
    01 10 00 02 <count P u32> <off P>    only if prompt
10+12N  00 00 00 00                      next IFD = 0 (no IFD1, no thumbnail)
14+12N  W bytes, 00 [, 00 pad if count is odd]     values from 38 (0x26) when N = 2; each at an even offset
        P bytes, 00 [, 00 pad if count is odd]     the final pad is included
W = "workflow:" + esc(text)     P = "prompt:" + esc(text)
esc: the text copied verbatim, except that every scalar above U+007F, and U+0000, becomes \uXXXX:
     lowercase hex, UTF-16 surrogate pairs above U+FFFF. The result is pure ASCII, with no raw 00 inside a value.
```

**`EXIFBlock.finishing(_ tiff: Data, size: PixelSize, comfy: ComfyUIStrings?, dropAIPrefixedStrings: Bool) throws(EXIFBlock.Malformed) -> Data`** is append-only.

`EXIFBlock.Malformed: Error` is F's own error, with a `reason` string for test diagnostics. L maps it to the user-facing message, so F does not depend on `WebPMetadata` or `Renderer`.

1. Parse with bounds checks, using the existing zero-based `XMPScanner.Bytes` helpers (XMPScanner.swift:363-380). The block must be `MM`: the owner decision is a big-endian TIFF, and the probe shows ImageIO's PNG `eXIf` is MM. Anything unexpected throws `Malformed`. Unverified bytes are never written.
2. In the ExifIFD (0x8769), overwrite 0xA002/0xA003 in place with the output width and height, as SHORT or LONG with count 1. The carrier's ImageIO writes 1×1 there.
3. **Force IFD0's next-IFD to 0.** In the no-rebuild path this is done in place on the old table; in the rebuild path the new table is built that way. So no thumbnail can come back even if a future ImageIO writes IFD1 (PRD §10.4).
4. Rebuild only when `comfy != nil`, or when `dropAIPrefixedStrings` is set and some IFD0 type-2 value starts with a prefix from step 5. Otherwise return.
5. Build the new IFD0 entries:
   - start from the old entries, copied as raw 12-byte records whose offsets stay valid;
   - remove only the tags being written: 0x010F when a workflow is written, 0x0110 when a prompt is;
   - remove any type-2 entry whose value (inline or at its offset) starts, ASCII case-insensitively, with `workflow:` or `prompt:`. This runs whenever the rebuild runs. With `comfy`, no competing key may remain: the core frontend keeps the last such key and comfyui-image-saver the first. Under AI Strip (`dropAIPrefixedStrings`), it removes a WebP source's workflow that ImageIO read as a camera Make/Model;
   - add 0x010F W and/or 0x0110 P;
   - sort by tag. The 0x8769/0x8825 pointers keep their positions in tag order, after 0x0110.
6. Pad the data to an even length. Append the table (2 + 12n + 4, next = 0), then W and P at even offsets.
7. Rewrite header bytes 4-7 to point at the new table. The old table is left unreferenced.
8. **Zero-fill the dropped entries' value bytes** in the orphaned old table: the inline 4-byte fields, and the out-of-line ranges. ImageIO syncs a kept XMP tree's `tiff:Make` into `eXIf` IFD0 (probe), so camera strings must not remain physically in the chunk. If a dropped range overlaps any range still referenced, throw `Malformed` instead. This check is defensive; ImageIO never shares values.

No byte ImageIO wrote moves. The 0x8769/0x8825 sub-IFDs, the UserComment and any `{MakerApple}` maker note with absolute offsets stay valid, so EXIF Keep on WebP is as faithful as PNG output.

**`WebPMetadata.encode` (L)** runs the sequence in section 1. Its details:
- `static let carrierFailedMessage` = "The metadata could not be prepared for WebP. Strip EXIF, GPS and the AI workflow, or choose another format." `EXIFBlock.Malformed`, a missing `eXIf`/iTXt the dictionary asked for, and a failed `PendingUserComment.applied(toPNG:)` all map to `.encoderRefused(.webP, reason: carrierFailedMessage)`.
- **Give-way, per tag.** For each tag in `comfyUITags(comfy)`, the matching key (`TIFFMake`, `TIFFModel`) is removed from the TIFF dictionary before ImageIO sees it. A workflow-only save keeps the camera Model, and a prompt-only save keeps the camera Make.
- `wantsEXIF` and `wantsXMP` are decided from the **dictionary**, not from what the carrier writes. ImageIO writes an `eXIf` for any dictionary, an IPTC-only one included; that block is discarded when `!wantsEXIF`.
- **Hybrid sources take the carrier path under Default.** An Image-Saver or LoRA-Manager PNG has `parameters` + `workflow` + `prompt`. For non-PNG output, `properties` moves `parameters` into `{Exif}UserComment` (MetadataWriter.swift:38-39, :74-85) and adds PixelX/Y and Orientation (l.88-97). So `wantsEXIF` is true even with EXIF stripped, and the workflow reaches the file through `finishing`, not through the pure `comfyUI` block. The output matches Image-Saver's own WebP: IFD0 Make/Model plus an ExifIFD `UNICODE\0` UserComment. Tests cover this path specifically (section 5).
- The carrier is `image.cropping(to: CGRect(x: 0, y: 0, width: 1, height: 1))`, which keeps the render's colour space. An sRGB carrier therefore writes ExifColorSpace 0xA001 = 1, as the other formats do. P3 and device RGB write none, as PNG output does (probe).
- The `eXIf` body is taken with `PNGScanner.forEachChunk`, widened from `private` to `internal` (PNGScanner.swift:276). The XMP is taken from the public `PNGScanner.textChunks(in:)` (l.116), keyword `XML:com.adobe.xmp`.

**Every `MetadataPolicy` switch on WebP:**

| Switch | Keep | Strip |
|---|---|---|
| EXIF | The source TIFF/Exif dictionaries and maker extras, exactly as `properties` (MetadataWriter.swift:45-71) builds them, through the carrier and `finishing`. **Give-way, per tag:** the camera Make goes when a workflow is written, the camera Model when a prompt is. Any 0x010F/0x0110 that an XMP sync re-adds for a written tag is dropped and zero-filled | No camera tags. With AI on Keep and moved `parameters`, `Exif{UserComment, PixelX/Y}` and `TIFF{Orientation 1}` remain (l.74-97) |
| GPS | the GPS IFD through the carrier | none |
| IPTC | carried **as XMP** (`photoshop:`/`dc:`), derived by ImageIO in the PNG carrier as for PNG output. WebP has no IPTC chunk | none |
| XMP | the kept packet plus ImageIO's mirrors of kept dictionary sections, from the carrier's iTXt, as an `XMP ` chunk | No `XMP ` chunk unless IPTC is kept. That is cleaner than PNG output, which keeps ImageIO's EXIF mirror packet (follow-up 4) |
| ICC | section 2.5 | section 2.5 |
| AI workflow | The ComfyUI workflow goes to IFD0 Make and the prompt to Model, each only if present, **even under EXIF Strip**. A1111/SwarmUI/Fooocus `parameters` go to the ExifIFD UserComment: ASCII as ASCII, otherwise "UNICODE\0" + UTF-16BE via `PendingUserComment.applied(toPNG:)` (MetadataWriter.swift:173-192), exactly as JPEG/HEIC/TIFF do. A Midjourney ImageDescription goes to IFD0 0x010E. Anything else gets a capability note | Nothing AI is written. That includes IFD0 type-2 values starting `workflow:`/`prompt:` that a WebP source brings along as "camera" EXIF: `finishing` drops and zero-fills them (`dropAIPrefixedStrings`, step 5) |
| Always (§10.4) | no IFD1 (forced), PixelX/Y = output (patched after the carrier), Orientation 1 (`properties`), no C2PA, no HDR gain map | same |

**Give-way and XMP.** The camera `tiff:Make`/`tiff:Model` survive only in the `XMP ` chunk, and only when the XMP switch keeps a source packet that holds them. ImageIO's generated mirror no longer has them, because they were removed from the dictionary.

**WebP sources (reading them is out of scope; follow-up 1).** SnapRescale 1.3 does not recognise a workflow inside a WebP source. ImageIO reads one under 10,000 characters as camera Make/Model. In 1.3:
- **Default (EXIF Strip):** a ComfyUI WebP saved as WebP, or as any other format, loses the workflow with the EXIF, and no AI note appears. 1.2 behaved the same: Keep original fell back to JPEG/PNG, and EXIF was stripped.
- **EXIF Keep + AI Keep:** a short workflow rides as camera Make/Model in every output format.
- **EXIF Keep + AI Strip:** WebP output drops it (the guard above). JPEG/HEIC/TIFF output still carries it as camera Make, which is the 1.2 behaviour.

The XMP chunk is not scanned for such values. HELP and image-metadata.md say this (section 6).

### 2.5 XMP and ICC chunks; IPTC

**XMP.**
- The chunk is written when XMP is kept, or when IPTC is kept and the source has IPTC.
- The payload is the carrier's bare `<x:xmpmeta>` text, which `XMPScanner.webP` (XMPScanner.swift:45) and ImageIO both read.
- IPTC is never written as an IPTC block.

**ICC.**
- `ColorPlan.embedsProfile(_ icc: MetadataPolicy.ICC) -> Bool { icc != .strip }` is a new static, and ColorPlan.swift:46 calls it too.
- **Preserve:** the profile of the rendered image's colour space (`copyICCData()`).
- **Convert to sRGB:** **the sRGB ICCP is embedded** (3,144 B). This keeps the promise of `keeps(.icc)` that "Converting to sRGB still embeds a profile" (MetadataPolicy.swift:137-138), and keeps sRGB and Strip as different files, as on TIFF.
- **Strip:** no ICCP. `render()` has already retagged the image as device RGB (Renderer.swift:117).
- **Source path:** if a profile is wanted and `copyICCData()` returns nil, throw `.profileNotWritable(.webP)`. This is defensive: ColorPlan (section 2.7) already falls back to sRGB for such spaces.
- **Sourceless public `encode(_:spec:sourceType:)`:** a device-RGB image there gets no ICCP. Its doc comment says so.

### 2.6 Capability rows and notes (I)

`MetadataPolicy.capability(of:in:)` (MetadataPolicy.swift:172-205) gets an explicit WebP branch before GIF, so the generic `.none` at l.204 no longer applies:

| Section | WebP row |
|---|---|
| exif, gps, xmp, icc | `.full` |
| iptc | `.limited("WebP has no IPTC block. Caption, keywords and copyright are kept as XMP, so the file holds an XMP packet even when XMP is stripped.")` |
| aiWorkflow | `.limited("WebP keeps a ComfyUI workflow in EXIF Make and Model and A1111-style parameters in the EXIF user comment, even when EXIF is stripped, but cannot hold an InvokeAI graph or other AI text. Save as PNG to keep those.")` |

- The doc of `capability(format:source:)` (l.207-208) drops "WebP".
- `partialWorkflowNote` (l.216-218) is unchanged. It is the plain table's text, which the inspector shows only through the source-aware path.

**Reuse proof.** With `.full` EXIF/GPS/XMP rows, `writes()` (MetadataWriter.swift:258-260) treats WebP exactly as JPEG, and only l.39 branches on PNG. So `properties(type: .webP) == properties(type: .jpeg)`, which `WebPRulesTests` pins.

`MetadataCapability.swift` changes:
- `isPNGOnly` (l.173-175) and `isPartlyKept` (l.162-164) take the output type and the metadata. On WebP, a payload or unrecognised chunk is not PNG-only when it is one of `webPWorkflowChunks`. **Duplicate** workflow or prompt chunks stay PNG-only, so their loss is reported.
- New `requiresPNGOrWebPNote = "Requires PNG or WebP output"`. On JPEG/HEIC/TIFF it replaces `requiresPNGNote` at l.34 when WebP would carry everything that is PNG-only. The limited text at l.38 then reads "…; the graph requires PNG or WebP output."
- On WebP, when a workflow/prompt is carried and something PNG-only remains: `.limited("Only the first ComfyUI workflow and prompt are kept; the rest requires PNG output.")`. InvokeAI-, NovelAI-, Fooocus-scheme- or Midjourney-only PNG sources get the existing `Requires PNG output`.
- `switchState` (l.68-126):
  - **Format name** (l.81-82): adds `webP ? "WebP"`. The IPTC keep note's condition (l.93) becomes `png || heic || webP`: "WebP has no IPTC block; kept as the XMP copies."
  - **aiWorkflow on Keep:** after the l.97 check and before the l.98 guard, for WebP with `comfyUIStrings != nil`, the note is `webPWorkflowNote(...)` (a new static), built from what is written:

    | Written | Note |
    |---|---|
    | workflow + prompt | "Kept in EXIF Make and Model, as ComfyUI saves WebP." |
    | workflow only | "Kept in EXIF Make, as ComfyUI saves WebP." |
    | prompt only | "Kept in EXIF Model, as ComfyUI saves WebP." |
    | any of these + moved parameters | "Kept in EXIF: " + the parts in this order, joined by ", ": "the workflow in Make", "the prompt in Model", "the parameters in the user comment"; then "." |
    | the same, when a user comment is replaced (l.99-100 rule) | as above, ending ", replacing the comment already there." This variant counts as a loss |

  - **exif on Keep** (before the `return nil` at l.104-105), from `cameraTagsGivingWay`:

    | Gives way | Note |
    |---|---|
    | make and model | "The camera make and model give way to the ComfyUI workflow and prompt, as in ComfyUI's own WebP files." |
    | make | "The camera make gives way to the ComfyUI workflow, as in ComfyUI's own WebP files." |
    | model | "The camera model gives way to the ComfyUI prompt, as in ComfyUI's own WebP files." |

    When `policy.xmp == .keep` and the packet holds `tiff:Make` or `tiff:Model` for a tag that gives way, append " The XMP copy keeps them." (or " … keeps it." for one tag).
  - **`isLoss`** (l.122-124) adds the give-way notes and the replacing-comment variants.
- The doc at l.14-20 ("survives only in PNG") becomes "lives in PNG text chunks, and a ComfyUI one also in WebP's EXIF Make and Model".

### 2.7 `ColorPlan` (G)

| Source | WebP output | Change |
|---|---|---|
| 8-bit RGB, any profile | 8-bit, profile per section 2.5 | none |
| 16-bit or float | 8-bit, no note (as JPEG) | none: `deep` (l.31) stays png/tiff/heic |
| Greyscale, under preserve | sRGB | `.monochrome` (l.77-80): `if type == .webP` comes first and returns `.fallback("WebP has no greyscale; the output is converted to sRGB.")` |
| CMYK / Lab | sRGB, existing note | l.81-85 unchanged. The name comes from `displayName` (l.65), so it reads "WebP cannot hold CMYK pixels; the output is converted to sRGB." |
| An RGB space with no ICC data | sRGB | new check before `.kept`: `type == .webP && space.copyICCData() == nil` returns `.fallback("This colour space has no ICC profile WebP can hold; the output is converted to sRGB.")` |
| HDR (PQ/HLG) | 8-bit in the source space with its ICC; the gain map is not written (existing `hdrGainMapNote`, ImageMetadata.swift:292) | none. A test asserts `copyICCData()` is non-nil for PQ and HLG |

The fallbacks reach the inspector through `iccCapability` (ColorPlan.swift:122-129) unchanged.

### 2.8 The 16,383 px limit (never shrink silently)

There is one source and one message.
1. **Limit:** `OutputFormat.maxDimension(for:)`.
2. **UI query:** `RenderSpec.formatLimitProblem(sourceType:)` gives "WebP holds at most 16383 px per side; 20000×11250 is larger." This follows `ValidationError`'s style: no thousands separators, `PixelSize` printed as is.
3. **`Renderer.render`**, right after the Limits guard (l.77-78), throws `.formatLimit(type, max:, size:)` before any allocation. The message is the same plus " Choose a smaller size or another format."
4. **`WebPEncoder`** has a defensive guard, and `BAD_DIMENSION` maps to the same error.

The solver is untouched. In the app and CLI:
- the sidebar shows the note before encoding;
- the readout shows "—" (the failed `try?`);
- Save stays enabled and fails with that alert, so `--save` scripting gets an error, not a silent no-op;
- the CLI fails with the same message.

### 2.9 `Renderer.produce` integration

- **`produce`** (D adds the parameter in W0; L routes it in W2):
  ```swift
  public static func produce(_ source: SourceImage, spec: RenderSpec, cancel: RenderCancellation? = nil) throws -> Data
  ```
  It runs render → `try cancel?.checkCancelled()` → encode → `PNGSplicer.keepingAIWorkflow`. There is one function with a default argument and no overload pair.
- **The private `encode`** (l.139-177) splits (L):
  - `guard let type = …` (l.141-143), then `if type.conforms(to: .webP) { return try WebPMetadata.encode(image, spec:, sourceProperties:, sourceMetadata:, cancel:) }`.
  - Otherwise it runs today's `properties` and `xmp` lines, then `imageIOEncode(_ image: CGImage, as type: UTType, properties: [CFString: Any], xmp: CGImageMetadata?, quality: Double?) throws -> (data: Data, written: [CFString: Any])`. That is today's `write()` plus the pending-comment step (l.150-175). Then it runs `MetadataWriter.finish` (l.176).
  - The carrier calls the same `imageIOEncode` with `as: .png` and `quality: nil`.
- **The public `encode` overloads** (l.122-124, l.134-137) route the same way, with no token.
- P7 proves that JPEG/PNG/HEIC/TIFF bytes are unchanged.

### 2.10 Live readout: performance and cancellation (M)

`Session.scheduleEncode` (Session.swift:449-472) keeps its design: an 80 ms coalesce, one runner, latest wins, and publishing only when nothing is pending (l.465).
- New `private var runningCancel: RenderCancellation?`. The loop creates a token per job, stores it, and calls `try? Renderer.produce(job.source, spec: job.spec, cancel: token)` (today l.461).
- When `scheduleEncode` is called while a job runs, it calls `runningCancel?.cancel()`. A WebP encode stops at the next progress tick. The exception is a lossy encode's alpha plane, which is bounded and measured in E. ImageIO jobs stop only between phases, as before. `.cancelled` becomes nil through `try?` and is never published, because a job is pending.
- **The readout stays a real encode with the Save settings**, so HELP's "The file size shown is a real encode, not an estimate" stays true.
- Save does **not** reuse the readout's bytes in 1.3 (follow-up 5). Lossless Best on a large image therefore encodes twice. Section 8 gives the time and memory figures.
- The comment block at l.439-444 changes "ImageIO work cannot be interrupted, so cancelling tasks alone would not bound memory." to "ImageIO work cannot be interrupted; a WebP encode can (RenderCancellation), so a newer request cancels the running one."
- **Effort** reaches the spec through `AppSettings.shared.webPEffort`. `AppSettings` is `@Observable`, so the `.onChange(of: session.spec)` at **ContentView.swift:37** re-runs the readout when it changes. ControlsPanel.swift:128 only calls `noteSettingsChanged`.

### 2.11 CLI (`RescaleKit/Sources/rescale/main.swift`, K)

- The usage comment (l.5-7) and text (l.20-22) add `webp`, `[--lossless]`, `[--effort fast|balanced|best]` and `[--metadata default|keep-all|strip-all]`.
- `--format` (l.77-85) uses `OutputFormat(name:)`. Error: "format must be keep, jpeg, png, heic, tiff or webp".
- **`--metadata`** (new, every format) maps to `MetadataPolicy.default`, `.keepAll` and `.stripAll` (MetadataPolicy.swift:95-96 and the existing statics). The default is `default`, which is today's behaviour. Error: "metadata must be default, keep-all or strip-all". The macOS 26 carrier check needs it (P9); before it, the CLI could only write the Default policy.
- `--lossless` and `--effort` are rejected outside WebP:
  - at parse time, when the format is explicit and not WebP;
  - after loading, when `keep` does not resolve to WebP.
  - Errors: "--lossless applies to WebP only" and "--effort applies to WebP only". A bad value gives "effort must be fast, balanced or best".
- l.133 becomes "cannot keep \(displayName ?? "this format"); pass --format jpeg|png|heic|tiff|webp".
- l.135 becomes `RenderSpec(target: s.size, fit: fit, format: format, quality: quality, lossless: lossless, effort: effort, metadata: metadata)`, with `padColor` still defaulting to nil, which means transparent padding where the format has alpha.
- The CLI links CWebP transitively. It is the Rosetta and VM smoke tool (section 4).

---

## 3. App changes

**Quality row** (ControlsPanel.swift:83-90, N). It is a conditional view with no reserved blank space. It has the File row's fixed height (l.113), so the row never reflows:

```swift
if let src = session.source, session.format.isLossy(for: src.type) {
    let canLossless = session.format.supportsLossless(for: src.type)
    LabeledContent("Quality") {
        HStack(spacing: 8) {
            if canLossless && session.lossless {
                Spacer(minLength: 0)
            } else {
                Slider(value: $session.quality.deferredLive, in: 0.1...1, step: 0.05)
                Text("\(Preset.percent(session.quality))").monospacedDigit()
                    .frame(width: 28, alignment: .trailing)
            }
            if canLossless {
                Toggle("Lossless", isOn: $session.lossless.deferred)   // Binding.deferred (Deferred.swift:46-54)
                    .toggleStyle(.switch).controlSize(.mini).fixedSize()
            }
        }
        .frame(height: 20)
    }
}
```

The switch stays at the trailing edge, so it never moves.

**Session** (Session.swift, M):
- `var lossless = false`, and `private var launchLossless: Bool?`.
- **Lossless resets per image, like Quality.** In `decode`, after `quality = …` (l.327) and before the preset apply (l.336-339): `lossless = launchLossless ?? false; launchLossless = nil`. A preset sets it. Like `--width`, `--lossless` applies to the first image opened after launch only; the doc comment of `applyLaunchArguments` says so.
- `apply` (l.54-70): `lossless = preset.lossless`.
- **Normalised so hidden state never lands anywhere.** A private helper `carriesLossless(_ f: OutputFormat) -> Bool` is `source.map { f.supportsLossless(for: $0.type) } ?? (f == .webp)`.
  - `currentPreset` (l.73-76) passes `lossless: lossless && carriesLossless(format)`.
  - `asApplied` (l.90-96) becomes source-aware: `asApplied(_ preset:, sourceType: UTType?)` applies the same rule.
  - So a JPEG preset never gets `lossless`, and applying a preset never reads as Custom.
- `spec` (l.178-182) passes:
  - `lossless: lossless && format.supportsLossless(for: source.type)`;
  - `effort: format.supportsLossless(for: source.type) ? AppSettings.shared.webPEffort : .balanced`.
  - So non-WebP specs never change, and never re-encode, when the effort or the hidden switch changes.
- `var formatLimitProblem: String? { spec.flatMap { s in source.flatMap { s.formatLimitProblem(sourceType: $0.type) } } }`.
- The `resolveFormat` message (l.360) uses `displayName`. The comment at l.352 becomes "GIF, RAW…".
- **Launch arguments** (`applyLaunchArguments`, l.196-241):
  - `--format <name>` → `if let v = it.next(), let f = OutputFormat(name: v) { format = f }`. Format persists across loads, so no launch override is needed.
  - `--lossless` → `lossless = true; launchLossless = true`.
  - `--notices` → `openWindowOnLaunch = "notices"`.
  - Effort needs no flag: the UserDefaults argument domain already accepts `-webPEffort best`.

**AppSettings** (AppSettings.swift:11-30, M):
```swift
// WebP (Settings ▸ Saving)
var webPEffort: EncoderEffort { didSet { d.set(webPEffort.rawValue, forKey: "webPEffort") } }
// init:
webPEffort = d.string(forKey: "webPEffort").flatMap(EncoderEffort.init(rawValue:)) ?? .balanced
```

**Settings effort control** (SnapRescaleApp.swift, section "Saving", l.75-92, O). Insert it after the conditional "Folders allowed" row (l.83-91). It has a tooltip and no permanent caption, and there is no sidebar row.

```swift
Picker("WebP effort", selection: $settings.webPEffort.deferred) {
    ForEach(EncoderEffort.allCases, id: \.self) { Text($0.label).tag($0) }
}
.pickerStyle(.segmented)
.help("Best usually makes smaller WebP files and takes longer. The file size in the sidebar uses this setting.")
```

**Sidebar notes** (`notes(solution:source:)`, ControlsPanel.swift:289-324, N):
- After `sizeProblem` (l.291-293): `if let p = session.formatLimitProblem { out.append(Note(text: p, warning: true)) }`.
- The flatten warning (l.313-314) stops for WebP through `supportsAlpha`.
- **Frames note.** When the source has `frameCount > 1` (ImageMetadata.swift:24) and the output resolves to the source's own type: `Note(text: "Saves the first of \(n) frames; the animation is not kept.", warning: true)`. Keep original on an animated WebP now resolves to WebP and writes one frame. The existing badge "Animated ·N … only the first is used" (ImageMetadata.swift:94) is in the source header, not next to the output.
- `keptExtension`/`sourceExtension` (l.216-223) use `displayName`, so the picker reads "Keep original (WebP)".

**Source header** (ContentView.swift:138, `SourceHeader.summary`, N): `OutputFormat.displayName(for: src.type) ?? ""`, so a WebP source reads "… · WebP" like the sidebar.

**Inspector notes.** No view code changes. The WebP notes come from `switchState` (section 2.6), and the give-way note appears under EXIF. The fallback spec at MetadataInspector.swift:281 stays valid, because capability ignores lossless and effort.

**Presets.** The menu summary shows "WebP lossless" or "WebP 80". The shipped presets are unchanged. The PresetStore problem line names a bad format (section 2.2).

**Help** (AboutAndHelp.swift and docs/HELP.md, word for word; O and P):
- "Format and saving" (AboutAndHelp.swift:84-90) gains, after the Keep original line: "**WebP** saves lossy with the quality slider, or exact pixels with the **Lossless** switch beside it. It holds at most 16383 pixels per side and 8 bits per channel; **Settings ▸ WebP effort** trades saving time for file size."
- l.97 and l.98 change as in section 6.

**About and acknowledgements** (O):
- AboutView (AboutAndHelp.swift:22-58) gains, under the copyright line (l.36): `Text("Includes libwebp © Google Inc., BSD licence.").font(.callout)`.
- It also gains `Button("Acknowledgements") { openWindow(id: "notices") }.buttonStyle(.link)` in the link row (l.46-51), with `@Environment(\.openWindow)`. If five links crowd the 440 pt window in the screenshot, the button moves into the libwebp line.
- A new scene beside about/help (SnapRescaleApp.swift:55-59): `Window("Acknowledgements", id: "notices") { NoticesView() }.windowResizability(.contentSize)`.
- New `NoticesView.swift`: a 560×480 `ScrollView` of monospaced, `.textSelection(.enabled)` text loaded from `Bundle.main.url(forResource: "THIRD-PARTY-NOTICES", withExtension: "txt")`. If the file is missing it shows "The notices file is missing from this build."
- The `Deferred.swift` doc (l.3-14) lists the two new `.deferred` call sites: the Lossless switch and the effort picker.

---

## 4. Build and distribution

**Vendoring layout** (A; validated in the protoA prototype):

```
RescaleKit/Sources/CWebP/
  include/CWebP.h            #include "../src/webp/encode.h", "../src/webp/mux.h", "../src/webp/decode.h" (tests' oracle)
  include/module.modulemap   module CWebP { umbrella header "CWebP.h" export * }
  src/{dec,dsp,enc,mux,utils,webp}/*.c,*.h   sharpyuv/*.c,*.h      (99 .c, 50 .h, about 2.4 MB)
  src/cwebp_build_check.c    #if !defined(WEBP_USE_THREAD) #error "CWebP needs WEBP_USE_THREAD (Package.swift)" #endif
  LICENSE-libwebp.txt  PATENTS-libwebp.txt  AUTHORS-libwebp.txt  VERSION
```

- The build check is in a **.c file of the target**, not in the umbrella header. SwiftPM `cSettings` defines do not reach the clients that import the module, so an `#error` in `CWebP.h` would fire in RescaleKit's own import.
- Left out: `*_mips32.c`, `*_mips_dsp_r2.c`, `*_msa.c`, `msa_macro.h`, `mips_macro.h` and `src/mux/anim_encode.c`. `src/dec` stays because mux links its header parsers.

**Package.swift** (RescaleKit/Package.swift:11-27):

```swift
.target(name: "CWebP",
        exclude: ["LICENSE-libwebp.txt", "PATENTS-libwebp.txt", "AUTHORS-libwebp.txt", "VERSION"],
        cSettings: [.headerSearchPath("."),                                 // libwebp includes "src/…" from its root
                    .define("WEBP_USE_THREAD"),                             // pthread workers + guarded DSP init
                    .define("NDEBUG", .when(configuration: .release))]),
.target(name: "RescaleKit", dependencies: ["CWebP"], swiftSettings: [.swiftLanguageMode(.v6)]),
.executableTarget(name: "rescale", dependencies: ["RescaleKit"], swiftSettings: [.swiftLanguageMode(.v6)]),
.testTarget(name: "RescaleKitTests", dependencies: ["RescaleKit", "CWebP"], resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]),
```

CWebP is a static C target, so `Scripts/build-app.sh:11`, which copies only the executable, still works.

**`Scripts/update-libwebp.sh <version> [--self-test]`** (A):
1. A pinned table: `1.6.0 → e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564`, and the release key fingerprint `6B0E6B70976DE303EDF2F601F9C3D6BDB8232B5D`.
2. Download the tarball and its `.asc` from `https://storage.googleapis.com/downloads.webmproject.org/releases/webp/` into a new, empty temporary directory.
3. `shasum -a 256 -c`.
4. `gpg --status-fd 1 --verify` in a temporary `GNUPGHOME`, importing only the committed `Scripts/keys/libwebp-release-key.asc`, and requiring `VALIDSIG <fingerprint>`.
5. Extract and copy files. The script never builds or runs anything from the tarball.
6. Apply the exclusion list.
7. Write `VERSION` (version, tag, commit, sha256).
8. Regenerate `THIRD-PARTY-NOTICES.txt`.
9. Print `git diff --stat`.
10. Exit non-zero on any mismatch.

`--self-test` corrupts one byte of the downloaded tarball and must exit non-zero. A second run on a clean tree must leave `git status` clean.

**Licence notices** (A writes them, J ships them, O shows them):
- `THIRD-PARTY-NOTICES.txt` sits at the repo root, next to `LICENSE`. It holds a header (libwebp 1.6.0, its source URL and the vendored path), then COPYING (BSD-3-Clause, whose clause 2 requires the notice in binary distributions), then PATENTS.
- `project.yml`, following the pattern at l.40-41: `- path: THIRD-PARTY-NOTICES.txt` with `buildPhase: resources`.
- `Scripts/build-app.sh`, after l.18: `cp "$ROOT/THIRD-PARTY-NOTICES.txt" "$APP/Contents/Resources/THIRD-PARTY-NOTICES.txt"`.
- About ▸ Acknowledgements shows it. The README Licence section names libwebp.

**DEAD_CODE_STRIPPING and x86_64** (J):
- `project.yml` settings.base (l.16-30) gains `DEAD_CODE_STRIPPING: YES`. Research measured 629 KB without it against 386 KB per arm64 slice: without it the whole library is linked, decoder included.
- Release builds are universal, as 1.2's already were (`lipo -archs` on the installed 1.2 binary: x86_64 arm64). libwebp uses NEON on arm64 and SSE2 on x86_64.
- Lossy bytes differ between architectures, so tests compare decoded pixels.
- Version: `MARKETING_VERSION "1.3"`, `CURRENT_PROJECT_VERSION "5"` (project.yml:21-22).

**Binary guards: `Scripts/check-app-binary.sh <SnapRescale.app> [--stripped]`** (J, new). Both release scripts call it. It never pipes `nm` into `grep -q`. Under the scripts' `set -euo pipefail` (release.sh:11, appstore.sh:8), `grep -q` exits on the first match, `nm` dies of SIGPIPE, and the pipeline returns 141. This was checked on the installed 1.2 binary (9,936 symbols): `if ! nm -U "$B" | grep -q " $S$"` reported a present symbol as missing three times out of three. It would invert both guards: fail on a linked encoder, and pass silently with a linked decoder. Capturing the output first gives the right answer on the same binary.

```zsh
#!/bin/zsh
set -euo pipefail
APP=$1; BIN="$APP/Contents/MacOS/SnapRescale"
lipo "$BIN" -verify_arch arm64 x86_64 || { echo "not universal"; exit 1; }
LIBS=$(otool -L "$BIN")
if grep -qi webp <<<"$LIBS"; then echo "libwebp linked dynamically"; exit 1; fi
[ -f "$APP/Contents/Resources/THIRD-PARTY-NOTICES.txt" ] || { echo "notices missing"; exit 1; }
if [ "${2:-}" != "--stripped" ]; then
  SYMS=$(nm -U "$BIN")     # captured once: `nm | grep -q` under pipefail fails with SIGPIPE (141)
  grep -q ' _WebPEncode$' <<<"$SYMS" || { echo "libwebp encoder missing"; exit 1; }
  if grep -q '_VP8LDecodeImage' <<<"$SYMS"; then echo "WebP decoder linked: check DEAD_CODE_STRIPPING"; exit 1; fi
fi
echo "binary checks passed"
```

- **`release.sh`**, after `codesign --verify` (l.34): `Scripts/check-app-binary.sh "$APP"`. This checks the unstripped xcodebuild Release product, the one the DMG ships.
- **`appstore.sh`**, after the archive (l.14-17): `Scripts/check-app-binary.sh "$OUT/SnapRescale.xcarchive/Products/Applications/SnapRescale.app" --stripped`. The archive is stripped (`nm -U` shows only `__mh_execute_header`), so the symbol guards are skipped there.

**Sandbox, hardened runtime, notarisation.**
- No new entitlements: libwebp needs only pthreads, and does no file or network I/O.
- No dylibs.
- The vendored decoder only parses our own bitstream headers during mux. Sources are decoded by ImageIO.

**`Scripts/test-all.sh`** (J). There is no CI, so this script is what "tests green" means in every acceptance criterion. Each PR records its result.
```zsh
(cd RescaleKit && swift test) && (cd SnapRescale && swift test)
(cd RescaleKit && swift test --arch x86_64 --filter 'WebP|EXIFBlock|ComfyUI|CWebP|FormatLimit|Oracle')   # Rosetta
```
If the x86_64 runner refuses, the script prints the fallback: build `rescale` for x86_64 and run the external check (RELEASING step 2).

**`docs/RELEASING.md`**: a new section "WebP and ComfyUI (release gate from 1.3)", placed after "Sandbox checks" (l.38-78):

1. **Tests.** `Scripts/test-all.sh` passes on the host, arm64 and Rosetta.
2. **x86_64 fallback, and the macOS 26 carrier check (P9).**
   - In RescaleKit, build `swift build -c release --arch arm64 --arch x86_64 --product rescale`.
   - Inputs: every image in `Fixtures/metadata/` (not README.md), plus `Fixtures/webp/comfyui-camera.png` and `Fixtures/webp/imagesaver-hybrid.png`.
   - Run each input three ways, each into its own folder:
     - `--width 512 --format webp --metadata default --write` into `default/`;
     - the same with `--metadata keep-all` into `keep-all/`;
     - `--width 512 --aspect 1:1 --fit pad --format webp --lossless --write` into `default/` (transparent pad; the 1:1 canvas gives it its own `name_WxH.webp` name).
   - `--write` saves next to the input and never over a file, so copy the inputs into each folder first.
   - Do this once with `arch -x86_64` on the host, and once on the VM (macOS 26.6.2). Copy the binary and fixtures there and the outputs back with `scp` to `10.211.55.8`.
   - On the host: `SNAPRESCALE_VERIFY_WEBP_DIR=<dir> swift test --filter ExternalWebPTests`.
3. **Release guards.** `release.sh` and `appstore.sh` pass `check-app-binary.sh`. `spctl -a -vv` accepts the notarised app on the VM. `xcrun notarytool log <id>` shows no issues. The App Store archive validates.
4. **Sandboxed app on the VM.** Use the `Scripts/build-xcode.sh Release` build, installed with `ditto`/`scp` as usual.
   - Launch with `open -a SnapRescale --args --format webp`. Format, Fit and the pad colour persist across images. Size, quality, Lossless and the metadata policy reset for each image (Session.swift:322-339), so set them per image as below.
   - Once, create two presets with **Save Current as Preset…** (ControlsPanel.swift:382):
     - "WebP keep EXIF+XMP": format WebP, inspector EXIF and XMP on Keep;
     - "WebP lossless pad": aspect 1:1, Fit Pad, pad well opacity 0, Lossless on.
     
     Presets carry lossless (K), fit, pad colour and the policy. Apply them from the Presets menu after opening each image.
   - Open each image with Open With and save with ⌘S into a granted folder:
     - with no change (Default): `comfyui.png`, `imagesaver-hybrid.png`, the owner's real ComfyUI PNG and one of the owner's Image-Saver PNGs (both local only, never committed);
     - `comfyui-camera.png` with "WebP keep EXIF+XMP". Screenshot the inspector's give-way note;
     - `comfyui.png` again with "WebP lossless pad" (the transparent lossless leg).
   - Repeat check 4 (exFAT disk image; the second save writes `_2`) with WebP output.
   - No staged `.tmp` may be left.
   - Copy every output back to the host into `<dir>/app/` and run `ExternalWebPTests` on it, as in step 2.
5. **ComfyUI drop test (P1).** This is a written manual recipe; nothing GPL or Node is committed.
   - Start a local server on the host:
     ```
     PYTHONDONTWRITEBYTECODE=1 ~/ComfyUI/.venv/bin/python3 ~/ComfyUI-Installs/ComfyUI/ComfyUI/main.py \
       --cpu --listen 127.0.0.1 --port 8199 --base-directory "$(mktemp -d)/comfybase" \
       --disable-all-custom-nodes --database-url sqlite:///:memory: --disable-auto-launch [--front-end-root <dist>]
     ```
   - Open `http://127.0.0.1:8199` in Safari. For each WebP from step 4, keeping its `.webp` name, drag it from Finder onto the canvas. The graph must appear with the same node count, node titles and link count as when the source PNG is dropped. "Clear" the canvas between drops.
   - Legs:
     - (a) the bundled frontend;
     - (b) the latest frontend, through `--front-end-root`;
     - (c) the owner's everyday install with custom nodes, `comfyui-image-saver` included, so without `--disable-all-custom-nodes`;
     - (d) a negative control: a WebP saved with the AI switch on Strip loads no graph;
     - (e) the two hybrid WebPs (`imagesaver-hybrid` and the owner's Image-Saver file) in legs (a) and (c). Their A1111 parameters are checked by `ExternalWebPTests` on `app/` (the UserComment decodes to the source's `parameters`), not by uploading to a third-party site.
   - Record the frontend version of each leg (ComfyUI ▸ Settings ▸ About).
6. **Optional performance check.** `rescale <large> --width 16383 --format webp --write` completes. Record the time and the peak RSS (`/usr/bin/time -l`).

The results table follows the existing format (l.79-83): Date | Build | macOS | Result.

---

## 5. Tests

**How fixtures are produced**
- `Scripts/make-webp-fixtures.py` (B) runs with ComfyUI's venv Pillow: `~/ComfyUI/.venv/bin/python3 -I Scripts/make-webp-fixtures.py`. It writes into `RescaleKit/Tests/RescaleKitTests/Fixtures/webp/`:
  - `comfyui.exif`. The PNG's `workflow` and `prompt` text are read with Pillow (`Image.open(png).text`), then put through ComfyUI's own path: `exif = img.getexif(); exif[0x010F] = "workflow:" + text; exif[0x0110] = "prompt:" + text; img.save(x.webp, exif=exif)`. The EXIF chunk payload is extracted from the saved WebP, and the script asserts it equals `exif.tobytes()[6:]`.
  - `compressed-text.exif`, made the same way from `compressed-text.png` (zTXt/iTXt).
  - `nonascii.exif`: a synthetic workflow holding é, 日本, 😀 and U+0000. It is pre-escaped per character with Python's `json.dumps(c)[1:-1]`, an independent implementation of the escaping rule.
  - `comfyui-pillow.webp`: the whole Pillow file, to check that the test reader parses a real ComfyUI-style file.
  - `README.md`: the Pillow version, the command, and the sha256 of every file.
- `Scripts/make-metadata-fixtures.swift` (B) gains one function that writes two PNGs into `Fixtures/webp/`:
  - `comfyui-camera.png`: camera EXIF with Make, Model and GPS, an XMP packet with `tiff:Make`, and comfyui.png's ComfyUI tEXt chunks;
  - `imagesaver-hybrid.png`: Image-Saver's PNG layout, i.e. a1111.png's `parameters` tEXt plus comfyui.png's `workflow` and `prompt` tEXt, with no EXIF.
  
  The `Fixture` enum (MetadataFixtures.swift:25-35) is **not** extended, so existing `allCases` loops do not change. A separate `WebPFixture` enum in `Support/WebPFixtures.swift` loads the new files.
- Every other WebP is produced at test time by our encoder from the existing synthetic fixtures. Grey, PQ and HLG sources are drawn in-test with CoreGraphics. Workflow-only, prompt-only, duplicate-chunk and short-workflow sources are built in-test with `PNGSplicerTests.source(holding:)` (PNGSplicerTests.swift:183-185).

**Test-only oracles** (`RescaleKit/Tests/RescaleKitTests/Support/`, B). They use Foundation only, never call production scanners (`XMPScanner`, `ICCScanner`, `PNGScanner`), and contain no ComfyUI code.
- `RIFFProbe.swift`:
  - checks the RIFF/WEBP header and RIFF size = count − 8, and walks the chunks (fourcc, offset, size, zero pad byte);
  - exposes `vp8xFlags` (nil for the simple format), canvas size, bitstream kind (VP8 or VP8L), `hasALPH` and `vp8lAlphaIsUsed`;
  - checks that the chunk order is valid per the spec, and gives `payload(_:)`;
  - throws on truncation and never traps.
- `TIFFProbe.swift`:
  - II/MM; IFD0 at the header offset; entries (tag, type, count, inline value or offset), all bounds-checked;
  - `ascii()` requires the trailing NUL;
  - follows 0x8769 and 0x8825; reports IFD0's next-IFD; `overlappingValues()`; raw byte scans.
- `ComfyUIFrontendReader.swift` is **written clean-room from the documented behaviour**. The frontend is GPL-3.0, and PRD.md:36, :707 and APP-STORE.md (l.73 and l.280 at `6729ae4`; l.223 at `22f1fd5`) say no ComfyUI code is used. Behaviour:
  - the first `EXIF` chunk only; an optional `Exif\0\0` is skipped; `II` means little-endian, otherwise big-endian;
  - IFD0 only, type-2 entries only, `count − 1` bytes decoded as UTF-8 at the offset field;
  - the key is the text before the first `:`, and later entries overwrite;
  - mode `.current` skips odd-chunk padding; `.legacy` (frontends before v1.39.10) does not.

**New tests**

| File (item) | Tests |
|---|---|
| `CWebPTests.swift` (A) | `encoderAndMuxVersionsAre1_6_0` (`WebPGetEncoderVersion() == 0x010600`, and mux); `noticesHoldTheLicenceAndPatentsVerbatim` (via `#filePath`); `concurrentEncodesMatchSerial` (8 tiny encodes run in parallel are byte-equal to serial ones; a race smoke test, while the define itself is enforced by `cwebp_build_check.c`) |
| `OracleSelfTests.swift` (B) | the probes on hand-built bytes (both endians, odd chunks, ALPH, VP8X); truncations and corruptions throw and never trap; the frontend reader on `comfyui-pillow.webp` returns texts equal to comfyui.png's; `.legacy` versus `.current` on a hand-built odd-chunk file |
| `RegressionManifestTests.swift` (B, P7) | Opt-in. `REGRESSION_MANIFEST_WRITE=<path>` writes and `REGRESSION_MANIFEST=<path>` compares the sha256 of `Renderer.produce` for every metadata fixture × {jpeg, png, heic, tiff, keepOriginal} × {Default, Keep all, Strip all, ICC sRGB} × {crop, transparent pad}. A cell whose two write-mode runs differ is marked nondeterministic and compared by decoded pixels plus the ImageIO property dictionary. The manifest is generated on `22f1fd5` in W0, attached to issue L, and not committed (it is machine-specific) |
| `FormatLimitTests.swift` (D, P8) | `webPAt16383Renders` (16383×8); `webPAt16384Throws` (16384×8 and 8×16384 throw `.formatLimit` before any allocation, from a 1×1 source); `jpegAt16384IsFine` (control); `theMessageIsExact`; `formatLimitProblemAgrees`; `keepOriginalOfWebPIsLimitedToo` (activated in L, because it needs `writable`) |
| `ComfyUIStringsTests.swift` (H) | `firstWorkflowAndPromptInFileOrder`; `nilUnderAIStrip`; `nilWithNeither`; `workflowOnlyAndPromptOnly` (one field nil, `comfyUITags` = .make or .model); `zTXtAndITXtGiveTheSameStrings` (compressed-text.png); `duplicatesTakeTheFirst`; `unclassifiedPromptIsCarried`; `giveWayTruthTable`: type × EXIF × AI × {workflow, prompt, both} × camera {Make, Model, both, none} gives the exact `IFD0Tags`. The camera+ComfyUI source is built in-test: an ImageIO PNG of `camera-exif-gps-thumbnail.jpg` plus `PNGSplicer.splice` of the chosen chunks. The test also asserts that the predicate gives the same answer while `MetadataPolicy.capability(of: .exif, in: .webP)` is still `.none` (W0), so it never goes through the capability table |
| `WebPEncoderTests.swift` (E, P5) | `maxDimensionMatchesLibwebp` (`WEBP_MAX_DIMENSION == OutputFormat.maxDimension(for: .webP)`); `losslessIsExact` (`WebPDecodeRGBA` equals the straight buffer, opaque and partial alpha); `premultipliedBecomesStraight` (a 50% red pad decodes 255/0/0/128 ±1); `alphaIsLosslessInLossy` (alpha exact at q50); `lossyWithinTolerance` (ImageIO decode, max abs diff threshold); `opaqueHasNoAlpha` (no ALPH; VP8L alpha-used bit 0; no VP8X alpha flag); `alphaIsSignalled`, split by case: lossy with alpha, with or without metadata, has VP8X with the alpha flag 0x10 plus ALPH (syntax_enc.c:29-30); lossless with alpha and no metadata is simple VP8L (no VP8X) with the alpha-used bit 1; lossless with alpha and metadata (mux ran) has the VP8X alpha flag. Then `oddWidthsAndPaddedRows` (1, 3, 17, 1023); `configMapping` (each effort × mode passes `WebPValidateConfig` with the fields in 2.3, including `thread_level` 1 lossy / 0 lossless); `errorMapping` (the whole table); `deterministicOnOneArch`; `cancelBeforeEncode` (a pre-cancelled token gives `.cancelled`); `cancelOnFirstProgressPoll` (`RenderCancellation(cancellingOnFirstEncoderPoll: true)` gives `.cancelled` for lossy m2/m4/m6 opaque and transparent, and for lossless levels 1/6/8 on a photo **and on a ≤256-colour palette image**, with no wall-clock bound); `muxOnlyWithMetadata`; `chunkOrderIsValid`. Issue E records, as measurements, the latencies and the time-to-cancel at 1, 16 and 100 MP for every effort × mode. That includes the palette image at Best lossless and a transparent lossy encode (alpha-plane delay) |
| `EXIFBlockTests.swift` (F, P2) | `comfyUIGolden` (bytes == `comfyui.exif`); `compressedTextGolden`; `nonASCIIGolden`; `escaping` (U+0000, BMP, astral pairs, lowercase hex, ASCII untouched); `layout` (N=1 for workflow-only or prompt-only, nil for neither, values from 0x26, even offsets, final pad, count includes the NUL, next-IFD 0); `finishingPatchesDimensions`; `finishingMovesNothing` (every carrier value keeps its offset and bytes; the header is repointed; Exif and GPS pointers stay valid); `finishingWithUserCommentAndWorkflow` (a hybrid carrier: an ImageIO PNG `eXIf` holding a UNICODE UserComment, then Make/Model added; the IFD0 is sorted 0x010F, 0x0110, 0x8769; the UserComment bytes and ExifIFD unchanged); `finishingPromptOnlyKeepsCameraMake` (only 0x0110 replaced; the camera 0x010F untouched); `finishingForcesNextIFDZero` (a carrier with a hand-made IFD1 comes out with next = 0 in both paths); `prefixedStringsDropped` (an ImageDescription "Workflow: …" is gone); `aiStripDropsPrefixedValuesWithoutComfy` (`comfy: nil, dropAIPrefixedStrings: true` removes a Make "workflow:{…}" and zero-fills it; with `false` it is kept); `droppedValuesAreZeroFilled` (no camera Make bytes anywhere in the block); `littleEndianCarrierThrows` and `fuzzedCarriersThrowNeverTrap` (random truncation and corruption), both asserting `EXIFBlock.Malformed`; `realComfySample` (opt-in `SNAPRESCALE_COMFY_SAMPLE=<dir>` with ComfyUI's own `comfy.webp` and the `comfy.png` of the same run: our block from the PNG equals the WebP's EXIF chunk; 24,398 B and sha256 `2d80e541…` for the research sample) |
| `ColorPlanTests.swift`, plan-level additions (G) | `webPIsEightBit`; `greyFallsBackToSRGBOnWebP` (note text); `cmykNamesWebP` ("WebP cannot hold CMYK pixels…"); `noICCSpaceFallsBack`; `pqAndHLGHaveICCData`; `embedsProfileStatic` |
| `WebPRulesTests.swift` (I) | `webPUsesTheJPEGRules`: for every fixture × policy, `MetadataWriter.properties(type: .webP)` equals `properties(type: .jpeg)` as NSDictionary, with the `PendingUserComment` placeholder normalised and compared by `.text`, since its UUID is random (MetadataWriter.swift:158). `webPRowsAndNotes`: every text in 2.6 exact, every row of both note tables. `duplicatesStayPNGOnly`; `invokeAIRequiresPNG`; `jpegSaysPNGOrWebP` |
| `WebPMetadataTests.swift` (L, P4) | Per section × keep/strip, with the probes and ImageIO read-back: `defaultOnComfyUI` (EXIF payload == golden, no XMP, VP8X EXIF flag); `hybridDefault` (imagesaver-hybrid.png: Make/Model are workflow/prompt, ExifIFD UserComment is ASCII or "UNICODE\0" per content and ImageIO reads it equal to `parameters`, PixelX/Y = output, no camera tags, no IFD1); `workflowOnlyAndPromptOnly` (one tag each; with EXIF Keep on a camera+ComfyUI source the other camera tag survives); `stripAllWritesNoMetadata` (no EXIF, XMP or ICCP); `exifKeepCamera` (tags present, no IFD1, Orientation 1 on the rotated fixture, PixelX/Y = output, ExifColorSpace as JPEG output has it, `{MakerApple}` kept where PNG keeps it); `gpsOnly`; `iptcKeepIsXMP` (XMP chunk with `dc:`/`photoshop:`, no IPTC); `exifKeepWithIPTCAndXMPStripHasNoXMP`; `xmpKeepAndMirrorRemoval` ("Also removed from XMP"); `iccPreserveP3`, `iccConvertEmbedsSRGB` (3,144 B), `iccStripWritesNone`; `a1111ASCIIStaysASCII`, `a1111NonASCIIIsUnicode` ("UNICODE\0", UTF-16BE; XMP text swapped too); `aiStripWritesNoWorkflow`; `aiStripOnAWebPSourceDropsPrefixedMake` (a short in-test workflow PNG → our WebP → loaded as a source → EXIF Keep + AI Strip: no `workflow:` bytes in the output; EXIF Keep + AI Keep: carried as Make, the documented 1.3 behaviour); `giveWayBytes` (comfyui-camera.png with EXIF+XMP Keep: Make/Model are the workflow and prompt, no camera Make in the raw EXIF bytes, the XMP chunk keeps `tiff:Make`); `greyAndCMYKBecomeSRGB`; `carrierFailureMessage` (a corrupted carrier through an internal seam gives the exact `carrierFailedMessage`) |
| `ComfyUIFrontendTests.swift` (L, P3) | Sources {comfyui.png, imagesaver-hybrid.png, workflow-only, prompt-only} × {lossy, lossless} × {opaque, alpha} × {Default, EXIF+XMP Keep, ICC P3}, plus comfyui-camera.png under EXIF+XMP Keep. The `.current` reader gives `workflow` and/or `prompt` equal to the escaped source text, and `JSONSerialization` of each equals the parsed source JSON. The hybrid cells exercise the carrier + `finishing` path under Default. `.legacy` must pass for lossy opaque; the other cells record their result (the old-frontend caveat) |
| `NotesMatchOutputTests.swift` (L) | For every metadata fixture, `comfyui-camera.png`, `imagesaver-hybrid.png` and in-test workflow-only, prompt-only and duplicate-chunk PNGs × {Default, Keep all, Strip all, EXIF only, XMP only, IPTC only, AI Strip} on WebP: each give-way note ⇔ the named camera tags are in the source ∧ EXIF kept ∧ those tags hold the workflow/prompt in the output ∧ no bytes of those camera values in the EXIF chunk; the AI note names exactly the parts the reader and the UserComment probe find (Make ⇔ workflow, Model ⇔ prompt, user comment ⇔ parameters); IPTC note ⇔ the XMP chunk holds IPTC fields; "Only the first ComfyUI workflow and prompt…" ⇔ the output holds the first pair only |
| `ExternalWebPTests.swift` (L, P9) | Opt-in `SNAPRESCALE_VERIFY_WEBP_DIR=<dir>` with subfolders `default/`, `keep-all/` (CLI) and `app/` (step 4). Outputs are matched to fixtures by the stem of `name_WxH.webp`. **Every file:** valid RIFF and chunk order; when EXIF is present, IFD0 next-IFD 0, PixelX/Y = the canvas, Orientation 1 where present. **default/:** comfyui outputs' EXIF equals the golden; the reader finds workflow and prompt for comfyui, comfyui-camera and imagesaver-hybrid; hybrid and a1111 UserComment (ImageIO) equal the source `parameters`; no camera tags. **keep-all/:** camera Make/Model equal the source's, GPS IFD present, ExifColorSpace as the host's output; rotated has Orientation 1; iptc-xmp has an XMP chunk with `dc:`/`photoshop:`; comfyui-camera has Make/Model = workflow/prompt, no camera Make bytes in the EXIF chunk, and the XMP chunk keeps `tiff:Make`; display-p3 has a Display P3 ICCP. **app/:** the generic checks, the reader finds a parseable `workflow` in every ComfyUI/hybrid/owner file, and a hybrid's UserComment is non-empty. Decoded pixels of fixture outputs are within tolerance of the host arm64 output of the same spec |
| `SnapRescaleTests/SessionWebPTests.swift` (M) | `losslessResetsPerImage`; `launchLosslessSurvivesTheFirstLoadOnly`; `presetSetsLossless`; `currentPresetDropsLosslessOutsideWebP`; `appliedWebPPresetIsNotCustom`; `specNormalisesLosslessAndEffort` (a JPEG spec does not change when effort changes); `formatLimitProblemShowsBeforeEncoding`; `formatLaunchArgument`; `readoutPublishesOnlyTheLatestSpec` (merged after L: two schedules, await `!isEncoding`, `outputBytes` equals `produce(...).count` of the last spec) |

**Changed tests** (each owned by exactly one item):

| Test | Change | Item |
|---|---|---|
| `ValidationTests.swift:137` | becomes `keepOriginal.resolvedType(for: .webP) == .webP` | L |
| `ValidationTests.swift:140` | `fallback(for: .gif, hasAlpha: false) == .jpeg` (WebP no longer needs a fallback) | L |
| `MetadataPolicyTests.swift:183` (`gifAndBMPCarryNothingAndSayWhy`) | drop `.webP` from the cannot-carry list | I |
| `MetadataPolicyTests.swift:197` (`everyOutputTypeIsCovered`) | unchanged; it covers `.webP` once L changes `writable`, and I's rows all carry | none |
| `MetadataPolicyTests.swift:202-217` | unchanged; the keepOriginal-of-WebP expectations follow `resolvedType` | none |
| `MetadataCapabilityTests.swift:37-39, 44-46` (`aGraphNeedsPNG`) | renamed `aGraphNeedsPNGOrWebP`. It expects "Requires PNG or WebP output" for comfyUI and compressedText on JPEG/HEIC/TIFF, and `.limited` (carried) on WebP. The other assertions of the old text at l.62 and l.97 are updated the same way | I |
| `PNGSplicerTests.swift:186-215` (`ordinaryTextUnderAToolKeywordIsShownAndFollowsTheSwitch`) | At l.209-213 the expected note is `["workflow", "prompt"].contains(keyword) ? requiresPNGOrWebPNote : requiresPNGNote`, because a `workflow` keyword is ComfyUI by keyword alone (ImageMetadata.swift:376). `.webp` is added: switch enabled for those two keywords, `Requires PNG output` for the others | I |
| `ColorPlanTests.swift` (all encode-level cases) | `formats` (l.12) gains `.webp`. `depthFollowsTheFormatWhateverThePolicy` (l.57-64) adds `.sixteenBit, .webp → 8`. `convertTagsSRGBTheWayEachFormatDoes` (l.87-93) expects WebP to have a 3,144 B ICCP. `stripWritesNoProfile` (l.97-110) includes webp. `stripLeavesOnlyWhatTheFormatInsistsOn` (l.114-128) adds WebP: no ICCP, `capability(of: .icc, in: .webP) == .full`. `padColourLooksTheSameInEveryMode` (l.139) treats webp as lossy. **`greyIsPreservedUnlessThePadIsColoured` (l.240-256) loops over `formats.filter { $0 != .webp }`**, because WebP has no grey. It adds a WebP assertion: colorModel "RGB", profile sRGB, and `iccCapability` note = G's grey note. **`ColorProbe.hasEmbeddedProfile` (l.311-332) gains a RIFF branch** (an `ICCP` chunk via `RIFFProbe`); without it the WebP strip assertions would pass vacuously | L (after G) |
| `MetadataWriterTests.swift:45` (`formats`, aliased by `XMPWriterTests.swift:18`), `XMPWriterTests.swift:110`, `:447` (`chunkFormats`, `AIWorkflowInEXIFTests` at :417) | `.webp` added where the assertion holds for WebP; ComfyUI Make/Model are checked with the probes, since ImageIO drops long values | L |
| `XMPDetectionTests.swift:152, :168, :221-225`; `:251-255` (`damagedFilesDoNotTrap`) | `.webp` added; a truncated SnapRescale WebP added to the damaged set | L |
| `MetadataTests.swift:19` (the `encode` helper force-unwraps `CGImageDestinationCreateWithData`) | routes `.webP` through `Renderer.encode` | L |
| `MetadataRoundTripTests.swift` | WebP round-trips per section. Re-reading expects **no** ComfyUI provenance (reading WebP is out of scope) | L |
| `OutputNamingTests.swift` | `.webp` extension | L |
| `MetadataReadableTests.swift:538-539`, `MetadataBudgetTests.swift:376` | add `.webp` only where the list is "every writable format"; leave lists about ImageIO-only behaviour alone (decided per line in L's PR) | L |
| `PresetTests.swift` | `losslessRoundTrips`; `a1_2PresetDecodesLosslessFalse`; `webpAndWebPDecode`; `nonWebPPresetsEncodeAs1_2` (shipped presets byte-equal to strings captured on `22f1fd5`); `summaries` ("WebP lossless", "WebP 80") | K |
| `SnapRescaleTests/PresetStoreTests.swift` | an unknown format's problem line names it (`unknown format "avif"`) | K |
| `SnapRescaleTests/SessionPresetTests.swift` | apply and `currentPreset` carry lossless | M |

---

## 6. Docs to update (sentences that become false)

| Where | Now | Becomes |
|---|---|---|
| README.md:20 | "macOS 26 or later, Apple Silicon (that is what has been built and tested)." | owner question Q1 |
| README.md:54 | "(1.2)" | "(1.3)" |
| README.md:56-57 | "Output formats: JPEG, PNG, HEIC, TIFF, or the source's own format when it is one of those." | "Output formats: JPEG, PNG, HEIC, TIFF, WebP (lossy or lossless), or the source's own format when it is one of those." |
| README.md:60-62 | "A resized ComfyUI PNG saved as PNG still opens its workflow in ComfyUI; A1111-style parameters travel in the EXIF user comment of JPEG, HEIC and TIFF." | "A resized ComfyUI PNG saved as PNG or WebP still opens its workflow in ComfyUI; A1111-style parameters travel in the EXIF user comment of JPEG, HEIC, TIFF and WebP." |
| README.md:66-67 | "Sources deeper than 8 bits give 16-bit PNG and TIFF, and 10-bit HEIC." | append "JPEG and WebP are 8-bit." |
| README.md:72 | "Planned next: WebP and per-format encoder options, then multiple windows." | "Planned next: per-format encoder options, then multiple windows." |
| README Licence section | "MIT — see LICENSE. The same text ships inside the app bundle." | add "WebP encoding uses libwebp 1.6.0 (BSD-3-Clause, © Google), vendored in `RescaleKit/Sources/CWebP`; its notice ships in the app as THIRD-PARTY-NOTICES.txt and is shown under About ▸ Acknowledgements." |
| docs/HELP.md "Format and saving" (around :38), AboutAndHelp.swift:84-90 | no WebP | the WebP line from section 3 |
| docs/HELP.md:69, AboutAndHelp.swift:97 | "…a resized ComfyUI PNG still opens its workflow in ComfyUI." | "…a resized ComfyUI PNG saved as PNG or WebP still opens its workflow in ComfyUI. In WebP it is kept in EXIF Make and Model, as ComfyUI saves it; with EXIF kept, the camera make and model give way to it. A workflow inside a WebP source is not read yet." |
| docs/HELP.md:72, AboutAndHelp.swift:98 | "A switch is disabled, with a note, when the output format cannot carry the section: a ComfyUI graph requires PNG output." | "…: a ComfyUI graph requires PNG or WebP output, an InvokeAI graph PNG." |
| docs/PRD.md:3 | status naming 1.2 released and v1.3 next | 1.3 status |
| docs/PRD.md:5 | "macOS 26+ (Apple Silicon)" | per Q1 |
| docs/PRD.md:415-420 | "**WebP** and **JPEG XL** are read-only in ImageIO. WebP is the format the web actually asks for, so WebP encoding via bundled `libwebp` is the first item of M4…" | "WebP is written with the bundled libwebp 1.6.0 (1.3): lossy or lossless, at most 16383 px per side, 8-bit. JPEG XL stays read-only." |
| docs/PRD.md:423-424 | "WebP quality + lossless + effort" | "WebP quality and Lossless (sidebar), effort (Settings)" |
| docs/PRD.md:427 | "(GIF, WebP, RAW, …)" | "(GIF, RAW, …)" |
| docs/PRD.md:524-528 | "ComfyUI graph survives only in PNG; A1111, SwarmUI and Fooocus parameters can also ride in the EXIF UserComment of JPEG, HEIC and TIFF" | "a ComfyUI graph survives in PNG, and in WebP as EXIF Make and Model (ComfyUI's own layout); an InvokeAI graph only in PNG; A1111, SwarmUI and Fooocus parameters can also ride in the EXIF UserComment of JPEG, HEIC, TIFF and WebP" |
| docs/PRD.md:632 | "`format` is `keep`, `jpeg`, `png`, `heic` or `tiff`" | "…`tiff` or `webp`; `lossless` is optional (true for lossless WebP)" |
| docs/PRD.md:677, :707 | M4 row; "the libwebp dependency (M4) must be sandbox- and notarisation-clean" | WebP marked done in 1.3; "verified: static C target, no entitlements, guarded by Scripts/check-app-binary.sh" |
| docs/ROADMAP.md:6-10 | "Released: …1.2 (4)…" | 1.3 status |
| docs/ROADMAP.md:78 | the WebP row | done (1.3), with follow-ups 1-7 from section 7 |
| docs/ROADMAP.md:129 | "Stripping the ICC profile is fully clean only in TIFF and JPEG" | "…in TIFF, JPEG and WebP" |
| docs/APP-STORE.md (description, l.63, l.69, l.73 at `6729ae4`) | The description was rewritten after this design (#71, #73). Its save-format sentence, the ComfyUI PNG-to-PNG sentence and the MIT sentence | WebP added to the formats, the ComfyUI sentence widened once the drop test passes, and a libwebp BSD sentence. P carries the proposed wording and the "Before submitting 1.3" list (l.78-87) |
| docs/APP-STORE.md keywords | 93 bytes | add `webp` (98 of 100 bytes), weighed against the `crop,metadata` rebalance in the keyword note; "What's New (1.3)" per Q4 |
| docs/reference/image-metadata.md:71 | "…saved as JPEG, HEIC or TIFF" | "…saved as JPEG, HEIC, TIFF or WebP" |
| docs/reference/image-metadata.md:99-107 (writing notes) | no WebP | Add: the WebP EXIF chunk layout; Make for the workflow and Model for the prompt, each only if present; the per-tag give-way; the Image-Saver-compatible hybrid (Make/Model + UNICODE UserComment); IPTC as XMP; sRGB ICCP on convert; no XMP chunk unless XMP or IPTC is kept; "ComfyUI frontends before v1.39.10 can miss the workflow in a lossless or transparent WebP; lossy opaque files load everywhere". Also the WebP-source paragraph of 2.4: not read for AI; Default drops it with EXIF and no note; EXIF Keep + AI Keep carries a short one as camera Make/Model; AI Strip removes it from WebP output only |
| CHANGELOG.md | none | a 1.3 entry, including "Presets saved as WebP need 1.3; 1.2 skips them." and "A ComfyUI workflow inside a WebP source is not read yet." |
| RescaleKit/Tests/RescaleKitTests/Fixtures/metadata/README.md:15 | none | a pointer to `Fixtures/webp/README.md` |
| Code comments and messages | OutputFormat.swift:22, :25-26; Codable+Readable.swift:50; Renderer.swift:68-69; MetadataPolicy.swift:207-208; MetadataCapability.swift:14-20; Session.swift:352, :439-444; main.swift:5-7, :20-22, :84, :133; Deferred.swift:3-14 | as described in sections 2 and 3 |

Any review of this work lands as `docs/code-review-webp-<date>.md` with a Resolution log, as the existing reviews do.

---

## 7. Implementation plan in waves

- There is one GitHub issue per item, linked from #1. PRs go into `feature/webp`, which merges to `main` only after item Q.
- The owner approves every PR from screenshots before it is committed.
- "Tests green" means `Scripts/test-all.sh` from J onwards; before that, `swift test` in both packages.
- No two items in a wave edit the same file. Each item compiles on top of the earlier waves alone: no item refers to a type another item of the same or a later wave creates.

### Wave 0 (four independent items, in parallel)

- **A. "WebP: vendor libwebp 1.6.0 as the CWebP target"**
  - Owns: `RescaleKit/Sources/CWebP/**`, `RescaleKit/Package.swift`, `Scripts/update-libwebp.sh`, `Scripts/keys/libwebp-release-key.asc`, `THIRD-PARTY-NOTICES.txt`, `CWebPTests.swift`.
  - Depends on: nothing.
  - Acceptance:
    - the script reproduces the tree from a clean checkout, with `git status` clean;
    - `--self-test` fails as designed;
    - `swift build -c release` passes for arm64 and for x86_64;
    - removing the define breaks the build at `cwebp_build_check.c`;
    - CWebPTests pass.
- **B. "WebP: test oracles, fixtures and the regression manifest"**
  - Owns:
    - `Tests/RescaleKitTests/Support/{RIFFProbe,TIFFProbe,ComfyUIFrontendReader,WebPFixtures}.swift`;
    - `OracleSelfTests.swift`, `RegressionManifestTests.swift`;
    - `Fixtures/webp/**` (goldens, `comfyui-camera.png`, `imagesaver-hybrid.png`), `Scripts/make-webp-fixtures.py`;
    - the new function in `Scripts/make-metadata-fixtures.swift`;
    - `Fixtures/metadata/README.md` (pointer line).
  - Depends on: nothing.
  - Acceptance:
    - the self-tests pass;
    - the README records the Pillow version and every sha256;
    - the reader's header says it was written from behaviour, with no GPL code;
    - the manifest generated on `22f1fd5` is attached to issue L.
- **D. "WebP: format case, spec fields, limit, cancellation token, errors"**
  - Owns:
    - `OutputFormat.swift` (everything except `writable`);
    - `EncoderEffort.swift`, `RenderCancellation.swift`;
    - `Codable+Readable.swift` (the OutputFormat extension only);
    - in `Renderer.swift`: the `RenderSpec` struct, the `RenderError` enum, `render()`'s limit guard, and `produce`'s signature and cancel check;
    - any other exhaustive `OutputFormat` switch the compiler reports;
    - `FormatLimitTests.swift`.
  - Depends on: nothing.
  - Acceptance:
    - sections 2.1 (minus `writable`), 2.2 (RescaleKit part) and 2.8 behave as designed, with tests;
    - W0 stays green, because `writable` is unchanged;
    - until L, an explicit WebP encode throws `.encodeFailed(.webP)`, which is acceptable on the feature branch.
- **H. "WebP: shared ComfyUI predicates"**
  - Owns: `MetadataWriter+ComfyUI.swift`, `ComfyUIStringsTests.swift`.
  - Depends on: nothing. Its camera+ComfyUI sources are built in-test, not from B's fixture.
  - Acceptance:
    - the predicates behave as in section 2.4, per tag;
    - they use only the policy and the type, never `capability(of:…)`, which `giveWayTruthTable` proves while WebP's row is still `.none`;
    - the tests pass.

### Wave 1 (six items, in parallel)

- **E. "WebP: the libwebp encoder"**
  - Owns: `WebPEncoder.swift`, `WebPEncoderTests.swift`.
  - Depends on: A, D.
  - Acceptance:
    - tests pass on arm64 and under Rosetta;
    - the issue records the benchmark and time-to-cancel table at 1, 16 and 100 MP for every effort × mode, including the palette image at Best lossless and the transparent lossy case;
    - it confirms the level numbers, and that lossless Best stays at level 8 or below with `thread_level 0`.
- **F. "WebP: the EXIF block (ComfyUI layout and the append-only finisher)"**
  - Owns: `EXIFBlock.swift` (including `EXIFBlock.Malformed`) and `EXIFBlockTests.swift`.
  - Depends on: B, H. It needs nothing from D or L.
  - Acceptance: every golden is byte-equal; the append-only invariants hold, including the hybrid and prompt-only carriers and the AI-Strip drop; the block has no ImageIO or `Renderer` dependency (its tests may use ImageIO to build carriers).
- **G. "WebP: colour rules"**
  - Owns: `ColorPlan.swift` and the plan-level cases in `ColorPlanTests.swift`.
  - Depends on: D.
  - Acceptance: the section 2.7 rules and notes hold; existing tests are unchanged.
- **I. "WebP: capability rows and notes"**
  - Owns:
    - `MetadataPolicy.swift`, `MetadataCapability.swift`;
    - `MetadataPolicyTests.swift`, `MetadataCapabilityTests.swift`, `WebPRulesTests.swift`;
    - in `PNGSplicerTests.swift`, only the function `ordinaryTextUnderAToolKeywordIsShownAndFollowsTheSwitch`.
  - Depends on: D, H.
  - Acceptance:
    - every note text in both 2.6 tables is exact, and `isLoss` is right;
    - JPEG/PNG/HEIC/TIFF notes are unchanged apart from "Requires PNG or WebP output";
    - the reuse proof passes.
- **J. "WebP: packaging, guards and test-all"**
  - Owns: `project.yml`, `Scripts/build-app.sh`, `Scripts/release.sh`, `Scripts/appstore.sh`, `Scripts/check-app-binary.sh`, `Scripts/test-all.sh`.
  - Depends on: A.
  - Acceptance:
    - the notices are in both app bundles;
    - `DEAD_CODE_STRIPPING YES`; version 1.3 (5);
    - the size delta per slice is recorded;
    - `check-app-binary.sh` is tested both ways. It passes on a local ad-hoc release build. It fails with "notices missing" on the installed 1.2 app. It fails with "libwebp encoder missing" on a copy of the 1.2 app given a dummy notices file (the large-symbol-table case that a `pipefail` pipeline gets wrong). It fails with "WebP decoder linked" on a release build made with `DEAD_CODE_STRIPPING=NO`.
- **K. "WebP: presets and the CLI"**
  - Owns: `Preset.swift`, `rescale/main.swift`, `PresetTests.swift`, `SnapRescale/Sources/SnapRescale/PresetStore.swift` (the problem text at l.72), `SnapRescaleTests/PresetStoreTests.swift`.
  - Depends on: D.
  - Acceptance:
    - the section 2.2 and 2.11 behaviours hold, including `--metadata`, and every CLI parse error is exact;
    - shipped presets are byte-identical to 1.2;
    - `rescale --format webp --metadata keep-all --write` works once L lands.

### Wave 2

- **L. "WebP: renderer integration"** (the critical path)
  - Owns:
    - in `Renderer.swift`: the private `encode`, the new `imageIOEncode`, the public `encode` overloads and `produce`'s body. **Shared file:** D edited other declarations in W0;
    - new `WebPMetadata.swift`, including `carrierFailedMessage` and the `EXIFBlock.Malformed` mapping;
    - `OutputFormat.writable` (**shared file** with D in W0);
    - `PNGScanner.forEachChunk` visibility;
    - `ValidationTests.swift`;
    - new tests: `WebPMetadataTests`, `ComfyUIFrontendTests`, `NotesMatchOutputTests`, `ExternalWebPTests`;
    - the format-loop edits in `MetadataWriterTests`, `XMPWriterTests`, `XMPDetectionTests`, `MetadataRoundTripTests`, `MetadataTests`, `OutputNamingTests`, `MetadataReadableTests`, `MetadataBudgetTests`;
    - in `ColorPlanTests.swift` (**shared file** with G in W1): the `formats` list, the encode-level cases listed in section 5 (grey test included), and the `ColorProbe` RIFF branch.
  - Depends on: D, E, F, G, I.
  - Acceptance:
    - P2, P3, P4 and P7 pass, and the manifest is identical for the ImageIO formats;
    - `rescale --format webp` output under `--metadata default` and `keep-all` passes `ExternalWebPTests` on the host;
    - `FormatLimitTests.keepOriginalOfWebPIsLimitedToo` is active.
- **M. "WebP: session, settings value, launch arguments"**
  - Owns: `Session.swift`, `AppSettings.swift`, `SnapRescaleTests/SessionPresetTests.swift`, `SnapRescaleTests/SessionWebPTests.swift`.
  - Depends on: D, K. It uses `produce(_:spec:cancel:)` from D's signature.
  - Acceptance:
    - the Session behaviours of sections 2.10 and 3, and the launch arguments `--format`, `--lossless` and `--notices`;
    - spec-level tests pass on their own;
    - `readoutPublishesOnlyTheLatestSpec` is merged after L.

### Wave 3 (three items, in parallel)

- **N. "WebP: sidebar Quality row, notes and source header"**
  - Owns: `ControlsPanel.swift`, `ContentView.swift` (`SourceHeader.summary` only), `Deferred.swift` (doc only).
  - Depends on: M.
  - Acceptance:
    - screenshots with the switch on and off: no reflow, the switch does not move, the slider is gone when the switch is on;
    - the 16383 note shows before encoding;
    - "Keep original (WebP)", the header's "WebP" and the frames note appear;
    - the macOS 27 width check, using the CGEvent click recipe on the switch and the picker.
- **O. "WebP: Settings effort, Acknowledgements, About, Help"**
  - Owns: `SnapRescaleApp.swift`, `AboutAndHelp.swift`, new `NoticesView.swift`.
  - Depends on: J, M.
  - Acceptance: screenshots of Settings (picker and tooltip), About, the notices window and Help; the Help text matches section 6 word for word.
- **P. "WebP: docs for 1.3"**
  - Owns: `README.md`, `CHANGELOG.md`, `docs/HELP.md`, `docs/PRD.md`, `docs/ROADMAP.md`, `docs/APP-STORE.md`, `docs/reference/image-metadata.md`, and the new section of `docs/RELEASING.md` (**shared file** with Q).
  - Depends on: the texts of this design. It merges after N and O.
  - Acceptance: every row of section 6 is done; `docs/HELP.md` and `AboutAndHelp.swift` agree word for word (diff checked in the PR).

### Wave 4

- **Q. "WebP: release gate run for 1.3"**
  - Owns: the result rows in `docs/RELEASING.md` only.
  - Depends on: all the above.
  - Acceptance: every step of the RELEASING section passes on the sandboxed, notarised build, and a row is recorded. Then `feature/webp` merges to `main`.

### Follow-up issues (filed, not implemented)

1. **Read ComfyUI workflows from WebP sources.** This means a badge, carrying a WebP workflow to PNG, and classifying `workflow:`/`prompt:` Make/Model as AI rather than camera EXIF, with notes. Today:
   - **WebP → WebP under Default:** the workflow is dropped with EXIF, with no AI note.
   - **EXIF Keep + AI Keep:** a short workflow (under 10,000 characters) rides as camera Make/Model in every format.
   - **EXIF Keep + AI Strip:** 1.3 removes it from WebP output only. JPEG/TIFF/HEIC output still writes it as camera Make (1.2 behaviour), and a kept XMP packet is not scanned.
2. `invokeai_workflow` is not among the tool keywords (ImageMetadata.swift:391-393).
3. SwarmUI UTF-16LE and Fooocus IFD0 detection.
4. PNG output keeps ImageIO's EXIF mirror XMP packet when XMP is stripped; verify and decide.
5. Save reuses, or awaits, the matching readout's bytes.
6. An `EncoderOptions` value once JPEG or PNG options arrive.
7. C2PA in WebP.

---

## 8. Risks and owner-only questions

**Risks** (mitigated; none needs owner action):
- **Old ComfyUI frontends.** Before v1.39.10 the frontend does not skip RIFF padding, so an odd VP8L, ALPH or ICCP chunk before EXIF hides the workflow. Lossy opaque files load everywhere. The `.legacy` reader tests pin this, and image-metadata.md documents it.
- **The carrier depends on ImageIO's PNG writer:** a bare MM `eXIf`, the 1×1 dimension overwrite, no IFD1, the XMP sync. These facts were probed on macOS 27.
  - `finishing` throws rather than write unverified bytes, and the user sees an actionable message.
  - Only saves that need the carrier are affected; the plain ComfyUI case has no carrier at all. Hybrid sources under Default do need it, and are tested specifically.
  - `WebPMetadataTests` pin the facts on macOS 27. RELEASING step 2 checks macOS 26.6.2 output under Default and Keep all, and step 4 checks the sandboxed app's output, both with carrier assertions.
- **Cancel latency.** Every lossless level is polled on the calling thread (`thread_level 0`). A lossy encode with alpha can wait for its alpha plane, which is encoded without the hook. E measures the delay. The readout ignores late results anyway.
- **Time and memory at the extreme.** In research, a 16383² lossy q100 encode took about 101 s and 3.1 GB RSS. The readout and Save each encode, so an early Save can briefly double the peak (follow-up 5). Lossless Best at 16 MP takes seconds, during which the readout shows its spinner. Palette images at Best are slower with `thread_level 0`.
- **Lossy bytes differ between arm64 and x86_64.** Tests never hash lossy output.
- **ImageIO drops Make/Model of 10,000 characters or more on read.** SnapRescale's own inspector cannot show the workflow of its WebP output until follow-up 1.
- **WebP sources' workflows are not recognised** (section 2.4). Documented in HELP, image-metadata.md and the CHANGELOG; follow-up 1.
- **Keep original on an animated WebP writes one frame.** The sidebar says so.
- **1.2 skips WebP presets.** The CHANGELOG says so.
- **GPL hygiene.** The test reader is clean-room, the drop test is a manual recipe against a local install, and nothing from ComfyUI enters the repo.
- **Supply chain.** libwebp changes only through the pinned, signature-checked script. The vendored decoder never sees untrusted input.

The owner-only questions are listed under "Questions for the owner" at the end.

---

## Decisions taken by the plan

1. **The carrier is a 1×1 crop of the render, not a static device-RGB image.** It keeps ExifColorSpace in line with the other formats (probe: an sRGB carrier writes 0xA001, device RGB does not), and the crop costs nothing measurable.
2. **The IFD0 is append-only, next-IFD is forced to 0, and dropped values are zero-filled.** No ImageIO offset moves, a thumbnail cannot come back, and no synced camera string is left in the chunk.
3. **Every IFD0 ASCII value starting with `workflow:` or `prompt:` is dropped whenever the IFD0 is rebuilt, and U+0000 is escaped too.** The core frontend keeps the last key and image-saver the first, and a raw NUL would truncate a value.
4. **Only the first workflow and the first prompt chunk are carried in WebP; duplicates stay PNG-only with a note.** Make and Model hold one value each, and a loss must not be silent.
5. **There is no XMP chunk unless XMP or IPTC is kept.** The switch then means what it says (cleaner than PNG's mirror packet).
6. **The ICCP is embedded whenever the policy embeds a profile, sRGB included (3,144 B), and Strip writes none.** This keeps the promise of `keeps(.icc)` and keeps sRGB and Strip as different files.
7. **Greyscale and no-ICC colour spaces become sRGB with a note.** WebP has no grey mode, and an ICC that cannot be written must not leave the file untagged silently.
8. **Lossless levels are 1/6/8 with `thread_level 0` (level 9 excluded); lossy methods are 2/4/6 with sharp YUV on Best and `thread_level 1`; `exact = 1`; no `partition_limit` retry.** Every lossless level is polled on the calling thread, Balanced matches libwebp's default, and quality is never lowered silently.
9. **`RenderSpec` gets flat fields, in files named `EncoderEffort.swift` and `RenderCancellation.swift`, and there is no `EncoderOptions` type yet.** There is one user so far, and a file should be named after what it holds.
10. **The errors are generic (`.formatLimit`, `.encoderRefused`, `.profileNotWritable`, `.cancelled`).** A future encoder reuses them, and no case name sits one letter from `encodeFailed`.
11. **Lossless resets per image like Quality, presets carry it, and specs and presets normalise it.** Hidden state never reaches a JPEG preset or a non-WebP spec.
12. **Preset JSON writes `lossless` only when true, and effort is never in presets.** Non-WebP presets stay byte-identical to 1.2, and effort is an app preference (Preset.swift:3-5).
13. **The effort picker is in Settings ▸ Saving with a tooltip, and the Quality row hides the slider conditionally at a fixed 20 pt height.** This follows "no reserved blank space" and "notes only when they apply".
14. **A frames note appears when a format is kept as itself from an animated source.** Keep original on an animated WebP now writes one frame, and saying so beside the output costs one conditional line.
15. **The CLI rejects `--lossless` and `--effort` outside WebP.** A flag that does nothing should fail, not be ignored.
16. **`writable` changes only in the integration item, and the shared predicates land in W0 without touching the capability table.** No wave merges red, Keep original never resolves to an encoder that does not exist yet, and H does not depend on I.
17. **The ComfyUI drop test is a written manual recipe; no Node or Playwright harness is committed.** The repo is Swift-only, and an unpinned browser harness would rot.
18. **Save does not reuse the readout's bytes in 1.3.** That cache would tie Save's correctness to a cache key; it is follow-up 5.
19. **The `WEBP_USE_THREAD` check is an `#error` in a .c file of the target, not in the header.** Clients that import the module do not get the target's defines.
20. **The macOS 26 check runs the host-built CLI on the VM, and the sandboxed app there, and verifies both sets of outputs on the host.** The VM stays a clean user machine, installed with `ditto`/`scp`, with no toolchain.
21. **The preset decoder stays strict, and PresetStore shows the decoding reason.** Nothing converts silently, and a future format names itself in the problem line.
22. **The give-way is per tag: a workflow takes Make, a prompt takes Model, and only the tag taken loses its camera value.** For the usual source with both strings, this is owner decision 2 unchanged. For a source with only one, nothing is dropped that is not replaced, and the notes name what was written.
23. **The CLI gains `--metadata default|keep-all|strip-all`.** Without it the CLI can write only the Default policy, and the carrier on macOS 26 would go untested.
24. **Under AI Strip, WebP output drops IFD0 values prefixed `workflow:`/`prompt:` even when they come from a WebP source's EXIF.** WebP output's Make/Model are ComfyUI's AI slot, so "Strip" must hold there. Other formats keep 1.2 behaviour until follow-up 1, because reading WebP sources is out of scope.
25. **The release binary checks live in `Scripts/check-app-binary.sh` and capture `nm`/`otool` output before grepping.** One script for both release paths, testable on its own, and correct under `pipefail`.
26. **`EXIFBlock` throws its own `Malformed`; `WebPMetadata` owns the user message.** F compiles in W1 without L, and the block stays free of `Renderer`.

## Questions for the owner

1. **Platform claim.** 1.3 is universal and is tested on Apple silicon and under Rosetta, but not on an Intel Mac. README.md:20 and PRD.md:5 say "Apple Silicon". Should they say "Apple silicon and Intel (built universal; tested on Apple silicon and under Rosetta)", or stay as they are?
2. **Keep original on a lossless WebP source.** As designed, Lossless starts off for each image, so a resized VP8L WebP becomes lossy unless the switch is turned on. The Quality row shows this. Alternatively, Lossless could start on when Keep original resolves a VP8L source, found by sniffing the RIFF header. The plan ships the switch off by default unless you choose otherwise.
3. **Drop-test automation.** Keep the ComfyUI drop test manual for 1.3, as designed? Or commit a Node/Playwright harness later, as a dev-only dependency with pinned versions?
4. **Store copy.** What should "What's New (1.3)" say on the App Store, and is adding `webp` to the keywords acceptable (98 of 100 bytes)?

---

## Appendix A: judges' defects and how each was resolved

| Defect (who) | Checked against | Resolution |
|---|---|---|
| The `padColor` default was `.white` in the init sketch (all three judges) | Renderer.swift:30 is `nil`; main.swift:135 passes none | the default stays `nil` (2.2) |
| "Camera Make/Model are not in the carrier" is false under XMP Keep (risk-first) | probe: ImageIO syncs `tiff:Make` into `eXIf` IFD0 | the written tags' 0x010F/0x0110 are dropped and their bytes zero-filled; tested on raw bytes (2.4, F, L) |
| next-IFD was copied, not forced to 0 (risk-first) | design text | forced to 0 in both paths (2.4); `finishingForcesNextIFDZero` |
| Duplicate ComfyUI chunks were treated as carried (risk-first, reuse) | MetadataCapability.swift:162-175 | duplicates stay PNG-only with a WebP-specific limited note (2.6) |
| Animated WebP writes one frame without saying so (all) | ImageMetadata.swift:94 badge only | frames note in the sidebar (3) |
| Lossless persisted while Quality resets, and a VP8L source defaults to lossy (risk-first) | Session.swift:322-339 | reset per image, normalised in presets and specs; the VP8L default is owner question 2 |
| Permanent Settings caption (risk-first) | SnapRescaleApp.swift:75-92 | tooltip instead (3) |
| Committed Node/Playwright harness (judge 2) | repo is Swift-only | manual recipe in RELEASING (4) |
| Save reuse cache (judges 2 and 3) | Session.swift:445-472, 524-531 | moved to follow-up 5 |
| `EncoderOptions.swift` holds no EncoderOptions (judge 2) | design text | `EncoderEffort.swift`, `RenderCancellation.swift` |
| Preset `lossless` was always encoded (judge 2) | PresetStore.swift:37-39 writes shipped presets | hand-written `encode(to:)`, written only when true |
| Quality row hidden with opacity (judge 2) | ControlsPanel.swift:113 idiom | conditional view plus `.frame(height: 20)` |
| Mixed error granularity (judge 2) | design text | four generic cases (2.3) |
| Per-render crop carrier is extra work (judge 2) | probe: sRGB writes 0xA001, device RGB does not | **rejected**: a static device-RGB carrier loses ExifColorSpace parity, and a 1×1 crop is negligible |
| W0 red: `writable` broke MetadataPolicyTests:197 and ValidationTests:137 (judge 3) | those lines | `writable` changes in L, which owns ValidationTests |
| #C depended on #B within W0 (judge 3) | wave table | #C removed (manual recipe) |
| PNGSplicerTests:209-213 broken by the note change (judge 3) | ImageMetadata.swift:376 | I owns that function's edit |
| Waves labelled "parallel" were partly serial (judge 3) | wave table | waves relabelled; M moved to W2 by putting `produce`'s signature in D |
| Wall-clock cancel tests (judge 3) | design text | deterministic token; latencies only recorded |
| No guard for the dead-strip claim (judge 3) | stripped App Store archive | `nm` guards on release.sh's unstripped product; lipo and otool only on the archive |
| A carrier failure fails every WebP save; no macOS 26 run (judge 3) | design text | actionable message; only carrier saves affected; P9 VM run plus `ExternalWebPTests` |
| `forEachChunk` is private (reuse) | PNGScanner.swift:276 | widened to internal in L; XMP read via the public `textChunks` |
| "WEBP" shown in ControlsPanel (reuse) | ControlsPanel.swift:216-223 | `displayName` everywhere, ContentView.swift:138 included |
| Re-encode trigger misattributed to ControlsPanel:128 (reuse) | ContentView.swift:37 | cited correctly (2.10) |
| `throwIfCancelled` not defined (reuse) | design text | `checkCancelled()` defined and used |
| `nm` check on the App Store archive always passes or fails (judges 1 and 3) | the 1.2 archive has only `__mh_execute_header` | guard on the right artefact (`--stripped` skips it) |
| No spctl, notarytool or Rosetta fallback rows (judge 3) | RELEASING.md | added (4) |
| No truncation tests for the carrier parser (judge 3) | design text | `fuzzedCarriersThrowNeverTrap` |
| `#error` in the shim header (judge 3 graft) | SwiftPM C target semantics | **adopted in modified form**: a .c file, because a header `#error` would fire in importing targets |
| `swift test` on the VM (judge 3 graft) | VM notes: a clean install target | **adopted in modified form**: host-built CLI on the VM, verified on the host |
| Pillow golden, compressed-text golden, U+0000 escaping, reuse-proof test, real-file gate, exFAT leg, real-install leg, test-all.sh (grafts) | n/a | all adopted (sections 4 and 5) |
| Cross-format `workflow:` Make leak (judge 2 graft) | MetadataWriter.swift:45-71 | follow-up 1; 1.3 guards WebP output under AI Strip only (decision 24) |

## Appendix B: Critique resolution

| # | Finding (severity) | Verdict | How it was checked, and what changed |
|---|---|---|---|
| 1 | `nm -U \| grep -q` guards misfire under `set -euo pipefail` (major) | **Fixed** | Confirmed. release.sh:11 sets `pipefail`, and on the installed 1.2 binary (9,936 symbols) the guard reported a present symbol as missing 3 of 3 times. Captured output gave the right answer. The guards moved into `Scripts/check-app-binary.sh`, which captures `nm`/`otool` output first. J tests every guard both ways (section 4, J) |
| 2 | P9 untested: the CLI can only write the Default policy (major) | **Fixed** | Confirmed at main.swift:135. K adds `--metadata default\|keep-all\|strip-all`. Step 2 runs Default and Keep all on the VM. `ExternalWebPTests` gains Keep-all carrier assertions: camera tags, GPS, no IFD1, PixelX/Y, Orientation, give-way bytes, IPTC as XMP, ICCP |
| 3 | F refers to `WebPMetadata.carrierFailedMessage`, which L creates (minor) | **Fixed** | Confirmed against the wave table. F throws its own `EXIFBlock.Malformed`; L maps it to `.encoderRefused(.webP, carrierFailedMessage)`. F's tests assert `Malformed`, and L's `carrierFailureMessage` asserts the text |
| 4 | `alphaIsSignalled` rationale wrong for lossy (minor) | **Fixed** | Confirmed: syntax_enc.c:29-30, `IsVP8XNeeded` returns `has_alpha`. The test is split into lossy+alpha (VP8X+ALPH always), lossless+alpha without metadata (simple VP8L, alpha bit) and lossless+alpha with metadata (VP8X flag). Section 2.3's mux text says the same |
| 5 | ContentView.swift:138 still shows "WEBP" (minor) | **Fixed** | Confirmed by grep: it is the only uppercasing site the plan missed (main.swift:133 was already listed). Added to the `displayName` sites; N owns `SourceHeader.summary` |
| 6 | Best lossless on palette images runs a hookless side thread (minor) | **Fixed** | Confirmed: level 8 = m5 q90 (config_enc.c:143-146) gives two configs for palette images (vp8l_enc.c:396-401), and the side worker gets `progress_hook = NULL` (:1763) while the main thread waits in `Sync`. Lossless now uses `thread_level 0`, which affects only that split (:1727). The lossy alpha-plane delay (alpha_enc.c:62-65, :404-442) is documented and measured. The cancel test adds a palette image; `configMapping` asserts `thread_level` |
| 7 | RELEASING step 4: `--lossless` applies once and there is no pad-colour launch option (minor) | **Fixed** | Confirmed for lossless (consumed in decode) and pad colour (Session.swift:34; none in l.196-241). The claim of no fit option is wrong: `--fit` exists (Session.swift:216-217). Step 4 now uses two presets made with "Save Current as Preset…", applied per image, and spells out what persists and what resets |
| 8 | Wrong line anchors (minor) | **Fixed** | Confirmed: the RenderSpec is at main.swift:135; Session.swift's comment is l.439-444, `scheduleEncode` l.449-472, the resolveFormat comment l.352. All corrected; the other anchors used in the edited sections were re-read |
| 9 | Image-Saver hybrid PNG, the one Default path through the carrier and `finishing`, is untested (major) | **Fixed; one part rejected** | Confirmed: MetadataWriter.swift:38-39, 74-97 give `wantsEXIF` under Default for a PNG with `parameters`. Added the `imagesaver-hybrid.png` fixture, `EXIFBlockTests.finishingWithUserCommentAndWorkflow`, `WebPMetadataTests.hybridDefault`, hybrid cells in `ComfyUIFrontendTests` and `NotesMatchOutputTests`, External checks, and P1 leg (e) with a real Image-Saver PNG. **Rejected:** checking civitai, which would upload the owner's images to a third-party site. Parameters are verified by ImageIO read-back of the UserComment instead |
| 10 | P9 carrier check needs a policy switch (major; same as #2) | **Fixed** | Same change as #2. The alternative it offered, copying the step-4 app outputs back and checking them, is adopted as well (`app/` folder) |
| 11 | Hidden F→L dependency (minor; same as #3) | **Fixed** | Same change as #3 |
| 12 | H's give-way predicate could depend on I's capability row (minor) | **Fixed** | The plan did not say H uses the table, but it did not forbid it either. `writes()` (MetadataWriter.swift:258-260) is capability-based, and WebP is `.none` until I (MetadataPolicy.swift:204). H's predicates now use the policy and type only, and `giveWayTruthTable` proves it while the row is still `.none` |
| 13 | ColorPlanTests grey test would fail when `formats` gains `.webp` (minor) | **Fixed** | Confirmed at ColorPlanTests.swift:240-256. L excludes `.webp` from that loop and adds a WebP assertion. Also found: `ColorProbe.hasEmbeddedProfile` (l.311-332) has no RIFF branch, so the strip tests would pass vacuously. L adds one |
| 14 | Prompt-only and workflow-only sources: notes and give-way wrong (minor) | **Fixed** | Confirmed against ImageMetadata.swift:376 and :445-448, and ai-results v14 (a prompt alone loads). The give-way is per tag (`IFD0Tags`); `finishing` replaces only the tags written; the note texts are built from what is written (2.6 tables). Tests: `workflowOnlyAndPromptOnly`, `finishingPromptOnlyKeepsCameraMake`, and the new `NotesMatchOutputTests` rows |
| 15 | AI Strip does not hold for a WebP source's workflow (minor) | **Fixed** | Confirmed: step 5's prefix drop ran only with `comfy`, and the inspector cannot see WebP-source AI. `finishing` takes `dropAIPrefixedStrings` (set under AI Strip). The 2.4 table is corrected and a WebP-sources paragraph added. HELP, image-metadata.md, the CHANGELOG and follow-up 1 name the WebP→WebP and Default cases. Test: `aiStripOnAWebPSourceDropsPrefixedMake`. No cross-format guard: that is 1.2 behaviour, and reading WebP sources is out of scope (owner decision 3) |