import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import RescaleKit

/// The metadata fixture corpus in `Fixtures/metadata/` (issue #10): small
/// synthetic files, one per kind of source the writer has to cope with. What
/// each carries is listed in `Fixtures/metadata/README.md`; they are regenerated
/// by `Scripts/make-metadata-fixtures.swift`.
///
/// **For the writer issues (#13, #14, #15, #18).** `roundTrip` loads a fixture
/// as a `SourceImage`, runs it through `Renderer.produce` and re-inspects the
/// bytes that come out, so "kept" / "stripped" is one line per section:
///
///     let out = try Fixture.camera.roundTrip { $0.format = .jpeg /* + your policy */ }
///     #expect(out.metadata.hasEXIF)          // kept
///     #expect(!out.metadata.hasGPS)          // stripped
///     #expect(!out.hasEXIFThumbnail)         // §10.4, always dropped
///
/// The closure edits a same-size, keep-original `RenderSpec`; pass a whole spec
/// with `roundTrip(spec:)` instead when the geometry matters. Today's behaviour
/// is pinned in `MetadataRoundTripTests`: change those expectations on purpose,
/// in the same commit as the writer change that moves them.
enum Fixture: String, CaseIterable, Sendable {
    case camera = "camera-exif-gps-thumbnail.jpg"
    case iptcXMP = "iptc-xmp.jpg"
    case rotated = "rotated-orientation-6.jpg"
    case displayP3 = "display-p3.heic"
    case sixteenBit = "16-bit.tiff"
    case cmyk = "cmyk.jpg"
    case comfyUI = "comfyui.png"
    case a1111PNG = "a1111.png"
    case a1111JPEG = "a1111-usercomment.jpg"
    case compressedText = "compressed-text.png"

    /// Every fixture is stored at this size; `rotated` displays as 48 × 64.
    static let storedSize = PixelSize(64, 48)

    var url: URL {
        let name = rawValue as NSString
        return Bundle.module.url(forResource: name.deletingPathExtension, withExtension: name.pathExtension,
                                 subdirectory: "Fixtures/metadata")!
    }

    var data: Data { try! Data(contentsOf: url) }

    static func load(_ fixture: Fixture) throws -> SourceImage { try SourceImage.load(fixture.url) }

    /// A rendered fixture, re-inspected.
    struct Output {
        let data: Data
        let type: UTType
        let metadata: ImageMetadata
        /// The decoded output, as stored (no orientation transform applied).
        let image: CGImage

        var size: PixelSize { PixelSize(image.width, image.height) }
        /// An EXIF IFD1 thumbnail in a JPEG (PRD §10.4 says the writer never emits one).
        var hasEXIFThumbnail: Bool { FixtureProbe.hasEXIFThumbnail(jpeg: data) }

        /// sRGB 8-bit RGBA of the pixel at `x`, `y` from the top-left.
        func pixel(_ x: Int, _ y: Int) -> [UInt8] { FixtureProbe.pixel(of: image, x, y) }
    }

    /// Same size, keep original format, `keepMost`; everything else default.
    static func spec(for source: SourceImage) -> RenderSpec { RenderSpec(target: source.size, metadata: .keepMost) }

    /// Load → `Renderer.produce` → `ImageMetadata.inspect` on the output bytes.
    func roundTrip(spec: RenderSpec) throws -> Output {
        let source = try Fixture.load(self)
        return try FixtureProbe.inspect(try Renderer.produce(source, spec: spec))
    }

    /// As above, starting from `Fixture.spec(for:)` and letting the caller adjust it.
    func roundTrip(_ adjust: (inout RenderSpec) -> Void = { _ in }) throws -> Output {
        let source = try Fixture.load(self)
        var spec = Fixture.spec(for: source)
        adjust(&spec)
        return try FixtureProbe.inspect(try Renderer.produce(source, spec: spec))
    }
}

extension MetadataPolicy {
    /// Everything kept except GPS: the policy most writer tests start from, so
    /// that there is something to look at in the output. (It was the default
    /// until the default became strip-most.)
    static let keepMost = MetadataPolicy(exif: .keep, gps: .strip, iptc: .keep, xmp: .keep,
                                         icc: .preserve, aiWorkflow: .keep)

    /// `keepMost` with another ICC option.
    static func keepMost(icc: ICC) -> MetadataPolicy {
        var p = keepMost
        p.icc = icc
        return p
    }
}

/// Byte-level checks the detector does not make (yet).
enum FixtureProbe {
    struct NotAnImage: Error {}

    static func inspect(_ data: Data) throws -> Fixture.Output {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let id = CGImageSourceGetType(src), let type = UTType(id as String),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { throw NotAnImage() }
        return Fixture.Output(data: data, type: type,
                              metadata: ImageMetadata.inspect(source: src, data: data, type: type), image: image)
    }

    /// True when the Exif APP1 segment of a JPEG holds a second JPEG stream.
    static func hasEXIFThumbnail(jpeg data: Data) -> Bool {
        let d = [UInt8](data)
        guard d.count > 4, d[0] == 0xFF, d[1] == 0xD8 else { return false }
        var i = 2
        while i + 4 <= d.count, d[i] == 0xFF, d[i + 1] != 0xDA, d[i + 1] != 0xD9 {
            let end = i + 2 + (Int(d[i + 2]) << 8 | Int(d[i + 3]))
            guard end <= d.count else { return false }
            if d[i + 1] == 0xE1, d[(i + 4)..<end].starts(with: Array("Exif".utf8)) {
                let body = Array(d[(i + 4)..<end])
                return body.indices.dropLast(2).contains { body[$0] == 0xFF && body[$0 + 1] == 0xD8 && body[$0 + 2] == 0xFF }
            }
            i = end
        }
        return false
    }

    static func pixel(of image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .none
        // Shift the image so the wanted pixel lands on the 1 × 1 canvas.
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return px
    }
}
