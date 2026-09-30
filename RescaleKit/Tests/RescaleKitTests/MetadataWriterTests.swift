import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import RescaleKit

extension Fixture.Output {
    /// ImageIO's property dictionary of the output.
    var properties: [String: Any] {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return [:] }
        return CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] ?? [:]
    }

    func dictionary(_ key: CFString) -> [String: Any] { properties[key as String] as? [String: Any] ?? [:] }

    /// `prefix:name` of every tag in ImageIO's metadata view, XMP mirrors included.
    var metadataTags: [String] {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let metadata = CGImageSourceCopyMetadataAtIndex(src, 0, nil),
              let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] else { return [] }
        return tags.map { "\(CGImageMetadataTagCopyPrefix($0) as String? ?? ""):\(CGImageMetadataTagCopyName($0) as String? ?? "")" }
    }

    /// Whether coordinates show anywhere ImageIO looks: the GPS dictionary or a GPS tag.
    var showsLocation: Bool {
        properties[kCGImagePropertyGPSDictionary as String] != nil || metadataTags.contains { $0.contains("GPS") }
    }

    /// An embedded preview in any container: a JPEG stream after the first
    /// byte (EXIF IFD1 thumbnails are JPEGs), or a second image in the file.
    var hasEmbeddedThumbnail: Bool {
        if type.conforms(to: .jpeg) { return hasEXIFThumbnail }
        let d = [UInt8](data)
        let jpegStream = d.indices.dropFirst().dropLast(3).contains {
            d[$0] == 0xFF && d[$0 + 1] == 0xD8 && d[$0 + 2] == 0xFF && [0xE0, 0xE1, 0xDB, 0xC0].contains(d[$0 + 3])
        }
        let images = CGImageSourceCreateWithData(data as CFData, nil).map(CGImageSourceGetCount) ?? 0
        return jpegStream || images != 1
    }
}

/// The EXIF, GPS and IPTC switches (PRD §10.2–10.4, issue #13), one test per
/// switch on each of the four output formats.
struct MetadataWriterTests {
    static let formats: [OutputFormat] = [.jpeg, .heic, .tiff, .png]

    static func policy(exif: MetadataPolicy.Action = .strip, gps: MetadataPolicy.Action = .strip,
                       iptc: MetadataPolicy.Action = .strip) -> MetadataPolicy {
        MetadataPolicy(exif: exif, gps: gps, iptc: iptc)
    }

    static func render(_ fixture: Fixture, _ format: OutputFormat, _ policy: MetadataPolicy) throws -> Fixture.Output {
        try fixture.roundTrip { $0.format = format; $0.metadata = policy }
    }

    // MARK: EXIF

    @Test(arguments: formats)
    func keepEXIF(_ format: OutputFormat) throws {
        let out = try Self.render(.camera, format, Self.policy(exif: .keep))
        #expect(out.metadata.hasEXIF)
        let source = try #require(try Fixture.load(.camera).metadata.sections.first { $0.kind == .exif })
        let exif = try #require(out.metadata.sections.first { $0.kind == .exif })
        // Camera, lens, exposure and date, TIFF tags included, come through unchanged.
        for key in ["Make", "Model", "Software", "DateTime", "DateTimeOriginal", "LensModel", "ExposureTime",
                    "FNumber", "ISOSpeedRatings", "FocalLength"] {
            #expect(source[key] != nil && exif[key] == source[key], "\(key)")
        }
    }

    @Test(arguments: formats)
    func stripEXIF(_ format: OutputFormat) throws {
        let out = try Self.render(.camera, format, Self.policy(exif: .strip))
        #expect(!out.metadata.hasEXIF)
        let tiff = out.dictionary(kCGImagePropertyTIFFDictionary)
        #expect(tiff["Make"] == nil && tiff["Model"] == nil && tiff["DateTime"] == nil && tiff["Software"] == nil)
        #expect(out.dictionary(kCGImagePropertyExifDictionary)["LensModel"] == nil)
        #expect(out.properties[kCGImagePropertyExifAuxDictionary as String] == nil)
    }

    // MARK: GPS

    @Test(arguments: formats)
    func keepGPS(_ format: OutputFormat) throws {
        let out = try Self.render(.camera, format, Self.policy(exif: .keep, gps: .keep))
        #expect(out.metadata.hasEXIF && out.metadata.hasGPS)
        let gps = out.dictionary(kCGImagePropertyGPSDictionary)
        #expect(gps["Latitude"] as? Double == 0 && gps["Longitude"] as? Double == 0)
        #expect(gps["LatitudeRef"] as? String == "N" && gps["LongitudeRef"] as? String == "E")
        #expect(gps["DateStamp"] != nil)
    }

    @Test(arguments: formats)
    func stripGPS(_ format: OutputFormat) throws {
        let out = try Self.render(.camera, format, Self.policy(exif: .keep, gps: .strip))
        #expect(out.metadata.hasEXIF && !out.metadata.hasGPS)
        #expect(!out.showsLocation)
    }

    /// GPS is independent of EXIF (PRD §10.2).
    @Test(arguments: formats)
    func keepGPSWithoutEXIF(_ format: OutputFormat) throws {
        let out = try Self.render(.camera, format, Self.policy(exif: .strip, gps: .keep))
        #expect(!out.metadata.hasEXIF && out.metadata.hasGPS)
        #expect(out.dictionary(kCGImagePropertyGPSDictionary)["Latitude"] as? Double == 0)
        #expect(out.dictionary(kCGImagePropertyTIFFDictionary)["Make"] == nil)
    }

    @Test(arguments: formats)
    func stripBothEXIFAndGPS(_ format: OutputFormat) throws {
        let out = try Self.render(.camera, format, Self.policy())
        #expect(!out.metadata.hasEXIF && !out.metadata.hasGPS && !out.showsLocation)
    }

    /// Nothing ImageIO reports about the output mentions a location, with every
    /// other switch on. `iptc-xmp.jpg` has its GPS only as an XMP mirror: it
    /// passes here because no XMP packet of the source is written yet; once #18
    /// keeps XMP, that issue has to drop the `exif:GPS*` properties itself.
    @Test(arguments: formats)
    func strippingGPSLeavesNoCoordinates(_ format: OutputFormat) throws {
        for fixture in [Fixture.camera, .iptcXMP] {
            #expect(try Fixture.load(fixture).metadata.hasGPS)
            let out = try Self.render(fixture, format, .default)
            #expect(!out.metadata.hasGPS && !out.showsLocation, "\(fixture.rawValue)")
            #expect(out.data.range(of: Data("GPSLatitude".utf8)) == nil, "\(fixture.rawValue)")
        }
    }

    // MARK: IPTC

    @Test(arguments: formats)
    func keepIPTC(_ format: OutputFormat) throws {
        let out = try Self.render(.iptcXMP, format, Self.policy(iptc: .keep))
        #expect(out.metadata.hasIPTC && !out.metadata.hasEXIF && !out.metadata.hasGPS)
        let source = try #require(try Fixture.load(.iptcXMP).metadata.sections.first { $0.kind == .iptc })
        let iptc = try #require(out.metadata.sections.first { $0.kind == .iptc })
        for key in ["Caption/Abstract", "Keywords", "Byline", "Credit", "CopyrightNotice", "City"] {
            #expect(source[key] != nil && iptc[key] == source[key], "\(key)")
        }
    }

    /// The caption, byline and copyright mirrors in the TIFF tags go too (PRD §10.3).
    @Test(arguments: formats)
    func stripIPTC(_ format: OutputFormat) throws {
        let out = try Self.render(.iptcXMP, format, Self.policy(exif: .keep, gps: .keep, iptc: .strip))
        #expect(!out.metadata.hasIPTC)
        #expect(out.properties[kCGImagePropertyIPTCDictionary as String] == nil)
        let tiff = out.dictionary(kCGImagePropertyTIFFDictionary)
        #expect(tiff["ImageDescription"] == nil && tiff["Artist"] == nil && tiff["Copyright"] == nil)
        for text in ["Synthetic test caption", "Placeholder Author", "Placeholder copyright", "Placeholder Agency"] {
            #expect(out.data.range(of: Data(text.utf8)) == nil, "\(text)")
        }
    }

    /// ImageIO's JPEG encoder mirrors EXIF dates into an IPTC block of its own;
    /// a source without IPTC must not gain one, whatever the switch says.
    @Test(arguments: formats, [MetadataPolicy.Action.keep, .strip])
    func exifDoesNotBringIPTCAlong(_ format: OutputFormat, _ iptc: MetadataPolicy.Action) throws {
        let out = try Self.render(.camera, format, Self.policy(exif: .keep, gps: .keep, iptc: iptc))
        #expect(out.metadata.hasEXIF && !out.metadata.hasIPTC)
        #expect(out.data.range(of: Data("8BIM".utf8)) == nil)
    }

    // MARK: PRD §10.4

    @Test(arguments: formats)
    func keptEXIFHasNoThumbnailAndTheOutputSize(_ format: OutputFormat) throws {
        #expect(FixtureProbe.hasEXIFThumbnail(jpeg: Fixture.camera.data))
        let cases: [(Fixture, PixelSize)] = [(.camera, PixelSize(64, 48)), (.camera, PixelSize(32, 24)),
                                             (.a1111JPEG, PixelSize(40, 40))]
        for (fixture, target) in cases {
            let out = try fixture.roundTrip(spec: RenderSpec(target: target, format: format, metadata: .keepAll))
            #expect(out.metadata.hasEXIF && out.size == target)
            #expect(!out.hasEmbeddedThumbnail)
            let exif = out.dictionary(kCGImagePropertyExifDictionary)
            #expect(exif["PixelXDimension"] as? Int == target.width && exif["PixelYDimension"] as? Int == target.height)
            #expect(out.properties["PixelWidth"] as? Int == target.width)
            Self.expectUpright(out)
        }
    }

    /// The orientation-6 fixture comes out upright, and says so everywhere.
    @Test(arguments: formats)
    func rotatedSourceIsWrittenUpright(_ format: OutputFormat) throws {
        let out = try Fixture.rotated.roundTrip { $0.format = format; $0.metadata = .keepAll }
        #expect(out.size == PixelSize(48, 64))
        Self.expectUpright(out)
        #expect(!out.hasEmbeddedThumbnail)
        let exif = out.dictionary(kCGImagePropertyExifDictionary)
        if let x = exif["PixelXDimension"] as? Int, let y = exif["PixelYDimension"] as? Int {
            #expect(x == 48 && y == 64)
        }
    }

    static func expectUpright(_ out: Fixture.Output) {
        #expect(out.metadata.orientation == 1)
        #expect(out.properties["Orientation"] as? Int ?? 1 == 1)
        #expect(out.dictionary(kCGImagePropertyTIFFDictionary)["Orientation"] as? Int ?? 1 == 1)
        #expect(out.dictionary(kCGImagePropertyIPTCDictionary)["ImageOrientation"] == nil)
    }

    /// The fixture has no tag besides its orientation, so the filter is also
    /// checked on a camera-like dictionary turned on its side.
    @Test func filterResetsOrientationAndDimensions() {
        let source: [CFString: Any] = [
            kCGImagePropertyOrientation: 6, kCGImagePropertyPixelWidth: 4000, kCGImagePropertyPixelHeight: 3000,
            kCGImagePropertyTIFFDictionary: ["Orientation": 6, "Make": "Synthetic", "Compression": 5,
                                             "ImageDescription": "A caption"],
            kCGImagePropertyExifDictionary: ["PixelXDimension": 4000, "PixelYDimension": 3000, "ColorSpace": 65535,
                                             "FNumber": 2.8],
            kCGImagePropertyExifAuxDictionary: ["LensID": 7],
            kCGImagePropertyGPSDictionary: ["Latitude": 1.5],
        ]
        let out = MetadataWriter.properties(from: source, policy: .default, type: .jpeg, size: PixelSize(300, 400))
        #expect(out[kCGImagePropertyOrientation] as? Int == 1)
        let tiff = out[kCGImagePropertyTIFFDictionary] as? [String: Any] ?? [:]
        #expect(tiff["Orientation"] as? Int == 1 && tiff["Make"] as? String == "Synthetic")
        #expect(tiff["Compression"] == nil && tiff["ImageDescription"] as? String == "A caption")
        let exif = out[kCGImagePropertyExifDictionary] as? [String: Any] ?? [:]
        #expect(exif["PixelXDimension"] as? Int == 300 && exif["PixelYDimension"] as? Int == 400)
        #expect(exif["ColorSpace"] == nil && exif["FNumber"] as? Double == 2.8)
        #expect(out[kCGImagePropertyExifAuxDictionary] != nil)
        #expect(out[kCGImagePropertyGPSDictionary] == nil)
        #expect(out[kCGImagePropertyPixelWidth] == nil && out.keys.allSatisfy { !($0 as String).contains("Thumbnail") })

        // Stripping IPTC takes the caption mirror out of the kept TIFF tags.
        let noIPTC = MetadataWriter.properties(from: source, policy: MetadataPolicy(iptc: .strip), type: .jpeg,
                                               size: PixelSize(300, 400))
        #expect((noIPTC[kCGImagePropertyTIFFDictionary] as? [String: Any])?["ImageDescription"] == nil)
    }

    // MARK: Capability and sources without metadata

    /// A section the format cannot carry is simply not written (PRD §10.3).
    @Test func formatsThatCarryNothingGetNothing() throws {
        let source = try Fixture.load(.camera)
        for type in [UTType.gif, .bmp] {
            #expect(MetadataWriter.properties(from: source.properties, policy: .keepAll, type: type,
                                              size: source.size).isEmpty)
        }
        #expect(!MetadataWriter.properties(from: source.properties, policy: .keepAll, type: .jpeg,
                                           size: source.size).isEmpty)
    }

    /// Keeping what is not there writes nothing: the bytes match a strip-all output.
    @Test(arguments: formats)
    func sourceWithoutMetadataIsWrittenBare(_ format: OutputFormat) throws {
        // The AI workflow is spliced into PNG output (#14); leave it out here.
        var policy = MetadataPolicy.keepAll
        policy.aiWorkflow = .strip
        let kept = try Self.render(.comfyUI, format, policy)
        let stripped = try Self.render(.comfyUI, format, .stripAll)
        #expect(kept.data == stripped.data)
    }

    /// `encode` without a source has nothing to keep; with one it follows the policy.
    @Test func encodeOverloads() throws {
        let source = try Fixture.load(.camera)
        var spec = Fixture.spec(for: source)
        spec.metadata = .keepAll
        let image = try Renderer.render(source, spec: spec)
        let bare = try FixtureProbe.inspect(try Renderer.encode(image, spec: spec, sourceType: source.type))
        #expect(!bare.metadata.hasEXIF && !bare.metadata.hasGPS)
        let full = try Renderer.encode(image, spec: spec, source: source)
        #expect(full == (try Renderer.produce(source, spec: spec)))
        #expect(try FixtureProbe.inspect(full).metadata.hasGPS)
    }

    @Test func photoshopSegmentRemovalLeavesOtherJPEGsAlone() throws {
        let data = try Fixture.cmyk.roundTrip { $0.metadata = .stripAll }.data
        #expect(MetadataWriter.removingPhotoshopSegments(fromJPEG: data) == data)
        let iptc = Fixture.iptcXMP.data
        let removed = MetadataWriter.removingPhotoshopSegments(fromJPEG: iptc)
        #expect(removed.count < iptc.count && removed.range(of: Data("Photoshop 3.0".utf8)) == nil)
        #expect((try? FixtureProbe.inspect(removed))?.size == Fixture.storedSize)
    }
}
