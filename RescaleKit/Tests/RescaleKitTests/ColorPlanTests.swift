import Foundation
import CoreGraphics
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import RescaleKit

/// ICC policy and bit depth through `Renderer.produce` (issue #15, PRD §10.2):
/// what each mode writes into each format, checked on the output bytes.
struct ColorPlanTests {
    typealias ICC = MetadataPolicy.ICC
    static let formats: [OutputFormat] = [.jpeg, .png, .heic, .tiff]
    static let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// The top-left patch of the card: pure red in the fixture's own space.
    static let red = (x: 8, y: 8)
    /// The grey disc in the centre.
    static let grey = (x: 32, y: 24)

    static func out(_ f: Fixture, _ format: OutputFormat, _ icc: ICC) throws -> Fixture.Output {
        try f.roundTrip { $0.format = format; $0.metadata.icc = icc }
    }

    // MARK: - Preserve

    @Test(arguments: [OutputFormat.heic, .png, .jpeg, .tiff])
    func preserveKeepsDisplayP3(_ format: OutputFormat) throws {
        let source = try Fixture.load(.displayP3)
        let o = try Self.out(.displayP3, format, .preserve)
        #expect(o.metadata.iccProfileName == "Display P3")
        #expect(ColorProbe.hasEmbeddedProfile(o.data))
        #expect(o.image.colorSpace?.name == CGColorSpace.displayP3)
        // Read in P3, the red patch is still the source's red: outside sRGB,
        // where the same colour would read about (234, 51, 35).
        let kept = ColorProbe.pixel(of: o.image, in: Self.p3, Self.red.x, Self.red.y)
        let original = ColorProbe.pixel(of: source.image, in: Self.p3, Self.red.x, Self.red.y)
        #expect(ColorProbe.close(kept, original, 6))
        #expect(kept[0] > 245 && kept[1] < 12 && kept[2] < 12)
    }

    @Test(arguments: [OutputFormat.tiff, .png])
    func preserveKeepsSixteenBits(_ format: OutputFormat) throws {
        let o = try Self.out(.sixteenBit, format, .preserve)
        #expect(o.metadata.bitDepth == 16)
        #expect(o.image.bitsPerComponent == 16)
        #expect(o.metadata.iccProfileName == "sRGB IEC61966-2.1")
        // Mid grey is 0x8000 at 16 bits; through 8 bits it would come back
        // as 0x8080.
        let v = ColorProbe.deepPixel(of: o.image, Self.grey.x, Self.grey.y)
        #expect(abs(Int(v[0]) - 0x8000) < 24 && abs(Int(v[1]) - 0x8000) < 24 && abs(Int(v[2]) - 0x8000) < 24)
    }

    // MARK: - Bit depth per format

    @Test(arguments: ICC.allCases)
    func depthFollowsTheFormatWhateverThePolicy(_ icc: ICC) throws {
        #expect(try Self.out(.sixteenBit, .tiff, icc).metadata.bitDepth == 16)
        #expect(try Self.out(.sixteenBit, .png, icc).metadata.bitDepth == 16)
        #expect(try Self.out(.sixteenBit, .heic, icc).metadata.bitDepth == 10)
        #expect(try Self.out(.sixteenBit, .jpeg, icc).metadata.bitDepth == 8)
        // An 8-bit source is never widened.
        for f in Self.formats { #expect(try Self.out(.displayP3, f, icc).metadata.bitDepth == 8) }
    }

    // MARK: - Convert to sRGB

    @Test(arguments: formats)
    func convertGivesSRGBPixels(_ format: OutputFormat) throws {
        let source = try Fixture.load(.displayP3)
        let o = try Self.out(.displayP3, format, .convertToSRGB)
        #expect(o.metadata.iccProfileName == "sRGB IEC61966-2.1")
        #expect(o.image.colorSpace?.name == CGColorSpace.sRGB)
        // P3 red is out of gamut: it clips to sRGB red, which reads about
        // (234, 51, 35) back in P3.
        #expect(ColorProbe.close(ColorProbe.pixel(of: o.image, in: Self.p3, Self.red.x, Self.red.y), [234, 51, 35], 8))
        #expect(ColorProbe.close(ColorProbe.pixel(of: o.image, in: Self.sRGB, Self.red.x, Self.red.y), [255, 0, 0], 8))
        // In gamut, the colour is the source's: the same sRGB reading.
        for p in [Self.grey, (x: 56, y: 40), (x: 8, y: 40)] {
            let want = ColorProbe.pixel(of: source.image, in: Self.sRGB, p.x, p.y)
            #expect(ColorProbe.close(ColorProbe.pixel(of: o.image, in: Self.sRGB, p.x, p.y), want, 8))
        }
    }

    /// Only TIFF holds an sRGB profile as ICC bytes. ImageIO tags the others
    /// compactly: EXIF ColorSpace in JPEG, the `sRGB` chunk in PNG, `nclx` in HEIC.
    @Test func convertTagsSRGBTheWayEachFormatDoes() throws {
        #expect(ColorProbe.hasEmbeddedProfile(try Self.out(.displayP3, .tiff, .convertToSRGB).data))
        #expect(!ColorProbe.hasEmbeddedProfile(try Self.out(.displayP3, .jpeg, .convertToSRGB).data))
        let png = try Self.out(.displayP3, .png, .convertToSRGB).data
        #expect(!ColorProbe.hasEmbeddedProfile(png) && ColorProbe.pngChunks(png).contains("sRGB"))
        #expect(!ColorProbe.hasEmbeddedProfile(try Self.out(.displayP3, .heic, .convertToSRGB).data))
    }

    // MARK: - Strip

    @Test(arguments: formats)
    func stripWritesNoProfile(_ format: OutputFormat) throws {
        for fixture in [Fixture.displayP3, .sixteenBit, .camera] {
            let o = try Self.out(fixture, format, .strip)
            #expect(!ColorProbe.hasEmbeddedProfile(o.data), "\(fixture.rawValue)")
        }
        // The pixels are the converted ones: untagged still means sRGB.
        let stripped = try Self.out(.displayP3, format, .strip)
        let converted = try Self.out(.displayP3, format, .convertToSRGB)
        for p in [Self.red, Self.grey] {
            #expect(ColorProbe.close(ColorProbe.pixel(of: stripped.image, in: Self.sRGB, p.x, p.y),
                                     ColorProbe.pixel(of: converted.image, in: Self.sRGB, p.x, p.y), 2))
        }
    }

    /// What is left after a strip, format by format — the notes in the
    /// capability table say the same.
    @Test func stripLeavesOnlyWhatTheFormatInsistsOn() throws {
        // TIFF and JPEG: nothing at all. ImageIO then reports no profile for
        // the TIFF and assumes sRGB for the JPEG.
        #expect(try Self.out(.displayP3, .tiff, .strip).metadata.iccProfileName == nil)
        let jpeg = try Self.out(.displayP3, .jpeg, .strip).data
        #expect(jpeg.count < (try Self.out(.displayP3, .jpeg, .convertToSRGB).data.count))   // no EXIF ColorSpace
        // PNG: ImageIO always writes the one-byte `sRGB` chunk.
        #expect(ColorProbe.pngChunks(try Self.out(.displayP3, .png, .strip).data).contains("sRGB"))
        #expect(MetadataPolicy.capability(of: .icc, in: .png).note?.contains("sRGB") == true)
        // HEIC: an sRGB HEIC never has a profile, so strip and convert are one file.
        #expect(try Self.out(.displayP3, .heic, .strip).data == (try Self.out(.displayP3, .heic, .convertToSRGB).data))
        #expect(MetadataPolicy.capability(of: .icc, in: .heic).note?.contains("HEIC") == true)
        #expect(MetadataPolicy.capability(of: .icc, in: .tiff) == .full)
        #expect(MetadataPolicy.capability(of: .icc, in: .jpeg) == .full)
    }

    // MARK: - Padding

    @Test(arguments: formats)
    func padColourLooksTheSameInEveryMode(_ format: OutputFormat) throws {
        let pad = PadColor(red: 0.8, green: 0.2, blue: 0.4)
        for fixture in [Fixture.displayP3, .sixteenBit] {
            for icc in ICC.allCases {
                let o = try fixture.roundTrip(spec: RenderSpec(target: PixelSize(64, 96), fit: .pad, padColor: pad,
                                                               format: format, metadata: MetadataPolicy(icc: icc)))
                let lossy = format == .jpeg || format == .heic
                #expect(ColorProbe.close(ColorProbe.pixel(of: o.image, in: Self.sRGB, 32, 6), [204, 51, 102], lossy ? 6 : 1),
                        "\(fixture.rawValue) \(icc)")
            }
        }
    }

    // MARK: - Alpha

    @Test func opaqueSourcesGainNoAlpha() throws {
        for fixture in [Fixture.camera, .displayP3, .sixteenBit] {
            for format in [OutputFormat.png, .tiff] {
                for icc in ICC.allCases {
                    let o = try Self.out(fixture, format, icc)
                    #expect(!o.metadata.hasAlpha, "\(fixture.rawValue) \(format) \(icc)")
                    #expect([.none, .noneSkipLast, .noneSkipFirst].contains(o.image.alphaInfo))
                }
            }
        }
        // Colour type 2 is RGB without alpha.
        #expect(ColorProbe.pngColourType(try Self.out(.camera, .png, .preserve).data) == 2)
        // Opaque padding does not need one either.
        let padded = try Fixture.camera.roundTrip(spec: RenderSpec(target: PixelSize(64, 96), fit: .pad, padColor: .black, format: .png))
        #expect(!padded.metadata.hasAlpha)
    }

    @Test func alphaIsKeptWhereItIsNeeded() throws {
        // Transparent padding.
        let padded = try Fixture.camera.roundTrip(spec: RenderSpec(target: PixelSize(64, 96), fit: .pad, padColor: nil, format: .png))
        #expect(padded.metadata.hasAlpha)
        #expect(ColorProbe.pixel(of: padded.image, in: Self.sRGB, 32, 4)[3] == 0)
        // A source with alpha of its own, at both depths.
        for bits in [8, 16] {
            let source = try ColorProbe.source(space: Self.sRGB, bits: bits, alpha: true, as: .png) { ctx in
                ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 48))
            }
            #expect(source.metadata.hasAlpha)
            for format in [OutputFormat.png, .tiff] {
                let o = try FixtureProbe.inspect(try Renderer.produce(source, spec: RenderSpec(target: source.size, format: format)))
                #expect(o.metadata.hasAlpha && o.metadata.bitDepth == bits)
                #expect(ColorProbe.pixel(of: o.image, in: Self.sRGB, 48, 24)[3] == 0)
                #expect(ColorProbe.pixel(of: o.image, in: Self.sRGB, 8, 24) == [255, 0, 0, 255])
            }
        }
    }

    // MARK: - CMYK and grey

    /// The loader hands a CMYK file over as sRGB, so `preserve` cannot keep
    /// it: the output is sRGB and the capability says why.
    @Test func cmykFileFallsBackToSRGBAndSaysSo() throws {
        let source = try Fixture.load(.cmyk)
        #expect(source.metadata.colorModel == "CMYK" && source.image.colorSpace?.model == .rgb)
        for format in [OutputFormat.keepOriginal, .tiff, .png] {
            let spec = RenderSpec(target: source.size, format: format)
            let o = try FixtureProbe.inspect(try Renderer.produce(source, spec: spec))
            #expect(o.metadata.colorModel == "RGB" && o.metadata.iccProfileName == "sRGB IEC61966-2.1")
            let plan = ColorPlan(source: source, spec: spec)
            #expect(plan.fallbackNote?.contains("CMYK") == true)
            let cap = MetadataPolicy.iccCapability(for: source, spec: spec)
            #expect(cap.canCarry && cap.note == plan.fallbackNote)
        }
        // Not a fallback when the policy did not ask to preserve; the
        // capability reports it all the same.
        var convert = RenderSpec(target: source.size)
        convert.metadata.icc = .convertToSRGB
        #expect(ColorPlan(source: source, spec: convert).fallbackNote == nil)
        #expect(MetadataPolicy.iccCapability(for: source, spec: convert).note?.contains("CMYK") == true)
    }

    /// The renderer itself keeps CMYK when it is given CMYK pixels and the
    /// format holds them (JPEG, TIFF).
    @Test func cmykPixelsArePreservedWhereTheFormatHoldsThem() throws {
        let loaded = try Fixture.load(.cmyk)
        let src = try #require(CGImageSourceCreateWithURL(Fixture.cmyk.url as CFURL, nil))
        let raw = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
        #expect(raw.colorSpace?.model == .cmyk)
        let source = SourceImage(url: loaded.url, image: raw, size: loaded.size, fileSize: loaded.fileSize,
                                 type: loaded.type, metadata: loaded.metadata, properties: loaded.properties)
        for format in [OutputFormat.jpeg, .tiff] {
            let spec = RenderSpec(target: PixelSize(32, 24), format: format)
            #expect(ColorPlan(source: source, spec: spec).fallbackNote == nil)
            let o = try FixtureProbe.inspect(try Renderer.produce(source, spec: spec))
            #expect(o.metadata.colorModel == "CMYK" && o.metadata.iccProfileName == "Generic CMYK Profile")
            #expect(ColorProbe.close(ColorProbe.pixel(of: o.image, in: Self.sRGB, 4, 4),
                                     ColorProbe.pixel(of: raw, in: Self.sRGB, 8, 8), 10))
        }
        for format in [OutputFormat.png, .heic] {
            let spec = RenderSpec(target: PixelSize(32, 24), format: format)
            #expect(ColorPlan(source: source, spec: spec).fallbackNote?.contains("cannot hold CMYK") == true)
            #expect(MetadataPolicy.iccCapability(for: source, spec: spec).note?.contains("CMYK") == true)
            let o = try FixtureProbe.inspect(try Renderer.produce(source, spec: spec))
            #expect(o.metadata.colorModel == "RGB" && o.metadata.iccProfileName == "sRGB IEC61966-2.1")
        }
        // Transparent padding needs alpha, which a CMYK bitmap has not.
        let padded = RenderSpec(target: PixelSize(64, 96), fit: .pad, padColor: nil, format: .tiff)
        #expect(ColorPlan(source: source, spec: padded).fallbackNote?.contains("transparency") == true)
        #expect(try FixtureProbe.inspect(try Renderer.produce(source, spec: padded)).metadata.colorModel == "RGB")
    }

    @Test func greyIsPreservedUnlessThePadIsColoured() throws {
        let grey = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!
        for bits in [8, 16] {
            let source = try ColorProbe.source(space: grey, bits: bits, alpha: false, as: .png) { ctx in
                ctx.setFillColor(gray: 0.25, alpha: 1)
                ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
            }
            #expect(source.image.colorSpace?.model == .monochrome)
            for format in Self.formats {
                let spec = RenderSpec(target: source.size, format: format)
                #expect(MetadataPolicy.iccCapability(for: source, spec: spec).note == MetadataPolicy.capability(of: .icc, format: format, source: .png).note)
                let o = try FixtureProbe.inspect(try Renderer.produce(source, spec: spec))
                #expect(o.metadata.colorModel == "Gray", "\(format)")
                #expect(o.metadata.iccProfileName == source.metadata.iccProfileName)
                #expect(!o.metadata.hasAlpha)
                let depth = format == .jpeg ? 8 : (format == .heic && bits == 16 ? 10 : bits)
                #expect(o.metadata.bitDepth == depth, "\(format)")
            }
            // Grey padding keeps the model; a coloured one cannot be held in it.
            let white = RenderSpec(target: PixelSize(64, 96), fit: .pad, padColor: .white, format: .png)
            #expect(try FixtureProbe.inspect(try Renderer.produce(source, spec: white)).metadata.colorModel == "Gray")
            let red = RenderSpec(target: PixelSize(64, 96), fit: .pad, padColor: PadColor(red: 1, green: 0, blue: 0), format: .png)
            #expect(MetadataPolicy.iccCapability(for: source, spec: red).note?.contains("pad colour") == true)
            let o = try FixtureProbe.inspect(try Renderer.produce(source, spec: red))
            #expect(o.metadata.colorModel == "RGB")
            #expect(ColorProbe.pixel(of: o.image, in: Self.sRGB, 32, 4) == [255, 0, 0, 255])
        }
        // Convert and strip are sRGB whatever the source.
        let source = try ColorProbe.source(space: grey, bits: 8, alpha: false, as: .png) { _ in }
        var spec = RenderSpec(target: source.size, format: .tiff)
        spec.metadata.icc = .convertToSRGB
        #expect(try FixtureProbe.inspect(try Renderer.produce(source, spec: spec)).metadata.colorModel == "RGB")
    }

    // MARK: - Limits and the plan itself

    @Test(arguments: ICC.allCases)
    func renderSizeLimitsStillHold(_ icc: ICC) throws {
        for fixture in [Fixture.displayP3, .sixteenBit] {
            let source = try Fixture.load(fixture)
            let policy = MetadataPolicy(icc: icc)
            for target in [PixelSize(Limits.maxDimension + 1, 8), PixelSize(8, Limits.maxDimension + 1), PixelSize(0, 8),
                           PixelSize(Limits.maxDimension, Limits.maxDimension)] {
                #expect(throws: Renderer.RenderError.self) {
                    try Renderer.render(source, spec: RenderSpec(target: target, metadata: policy))
                }
            }
            let small = try Renderer.render(source, spec: RenderSpec(target: PixelSize(16, 16), metadata: policy))
            #expect(small.width == 16 && small.height == 16)
        }
    }

    /// The preview asks the plan which of its two copies to show.
    @Test func planSaysWhetherTheSourceSpaceIsKept() throws {
        let p3 = try Fixture.load(.displayP3)
        func plan(_ icc: ICC) -> ColorPlan { ColorPlan(source: p3, spec: RenderSpec(target: p3.size, metadata: MetadataPolicy(icc: icc))) }
        #expect(plan(.preserve).keepsSourceSpace && plan(.preserve).embedsProfile)
        #expect(!plan(.convertToSRGB).keepsSourceSpace && plan(.convertToSRGB).embedsProfile)
        #expect(!plan(.strip).keepsSourceSpace && !plan(.strip).embedsProfile)
        #expect(ICC.allCases.allSatisfy { plan($0).fallbackNote == nil && !plan($0).hasAlpha && plan($0).bitsPerComponent == 8 })
        #expect(MetadataPolicy.iccCapability(for: p3, spec: RenderSpec(target: p3.size, format: .tiff)) == .full)
    }
}

/// Colour checks on output bytes and pixels.
enum ColorProbe {
    struct Failed: Error {}

    /// An ICC profile in the file itself: JPEG `APP2`, PNG `iCCP`, TIFF tag
    /// 34675, HEIF `colr` of type `prof` / `rICC`. ImageIO's profile *name* is
    /// no guide — it names sRGB for files that hold no profile.
    static func hasEmbeddedProfile(_ data: Data) -> Bool {
        let d = [UInt8](data)
        if d.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return pngChunks(data).contains("iCCP") }
        if d.starts(with: [0xFF, 0xD8]) {
            var i = 2
            while i + 4 <= d.count, d[i] == 0xFF, d[i + 1] != 0xDA, d[i + 1] != 0xD9 {
                let end = i + 2 + (Int(d[i + 2]) << 8 | Int(d[i + 3]))
                guard end <= d.count else { return false }
                if d[i + 1] == 0xE2, d[(i + 4)..<end].starts(with: Array("ICC_PROFILE".utf8)) { return true }
                i = end
            }
            return false
        }
        if d.starts(with: [0x49, 0x49, 0x2A, 0x00]) || d.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) {
            let little = d[0] == 0x49
            func u16(_ o: Int) -> Int { little ? Int(d[o]) | Int(d[o + 1]) << 8 : Int(d[o]) << 8 | Int(d[o + 1]) }
            func u32(_ o: Int) -> Int { little ? u16(o) | u16(o + 2) << 16 : u16(o) << 16 | u16(o + 2) }
            let ifd = u32(4)
            return (0..<u16(ifd)).contains { u16(ifd + 2 + 12 * $0) == 34675 }
        }
        return contains(d, Array("colrprof".utf8)) || contains(d, Array("colrrICC".utf8))
    }

    static func pngChunks(_ data: Data) -> [String] {
        let d = [UInt8](data)
        var names: [String] = [], i = 8
        while i + 8 <= d.count {
            let n = Int(d[i]) << 24 | Int(d[i + 1]) << 16 | Int(d[i + 2]) << 8 | Int(d[i + 3])
            names.append(String(decoding: d[(i + 4)..<(i + 8)], as: UTF8.self))
            i += 12 + n
        }
        return names
    }

    /// 0 grey, 2 RGB, 4 grey + alpha, 6 RGBA.
    static func pngColourType(_ data: Data) -> Int { Int([UInt8](data)[25]) }

    private static func contains(_ d: [UInt8], _ needle: [UInt8]) -> Bool {
        guard d.count >= needle.count else { return false }
        return (0...(d.count - needle.count)).contains { d[$0..<($0 + needle.count)].elementsEqual(needle) }
    }

    /// 8-bit RGBA of one pixel, read in `space`; `x`, `y` from the top-left.
    static func pixel(of image: CGImage, in space: CGColorSpace, _ x: Int, _ y: Int) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return px
    }

    /// 16-bit sRGB RGBA of one pixel.
    static func deepPixel(of image: CGImage, _ x: Int, _ y: Int) -> [UInt16] {
        var px = [UInt16](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 16, bytesPerRow: 8,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)!
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return px
    }

    /// Colour channels within `tolerance`; alpha is not compared.
    static func close(_ a: [UInt8], _ b: [UInt8], _ tolerance: Int) -> Bool {
        zip(a.prefix(3), b.prefix(3)).allSatisfy { abs(Int($0) - Int($1)) <= tolerance }
    }

    /// A 64 × 48 image drawn by `draw`, written as `type` and loaded back the
    /// way the app loads a file.
    static func source(space: CGColorSpace, bits: Int, alpha: Bool, as type: UTType,
                       draw: (CGContext) -> Void) throws -> SourceImage {
        let opaque: CGImageAlphaInfo = space.model == .rgb ? .noneSkipLast : .none
        var info = (alpha ? CGImageAlphaInfo.premultipliedLast : opaque).rawValue
        if bits == 16 { info |= CGBitmapInfo.byteOrder16Little.rawValue }
        guard let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: bits, bytesPerRow: 0,
                                  space: space, bitmapInfo: info) else { throw Failed() }
        draw(ctx)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("colorplan-\(UUID().uuidString)")
            .appendingPathExtension(type.preferredFilenameExtension ?? "png")
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
        else { throw Failed() }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw Failed() }
        defer { try? FileManager.default.removeItem(at: url) }
        return try SourceImage.load(url)
    }
}
