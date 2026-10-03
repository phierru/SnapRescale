import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import RescaleKit

/// XMP presence comes from the packet in the file, not from the tags ImageIO
/// derives from EXIF / TIFF / IPTC (issue #22).
struct XMPDetectionTests {
    static let packet = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\
        <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" \
        xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:exif="http://ns.adobe.com/exif/1.0/" \
        xmp:Rating="4" exif:GPSLatitude="47,22.2N">\
        <dc:subject><rdf:Bag><rdf:li>alps</rdf:li><rdf:li>lake</rdf:li></rdf:Bag></dc:subject>\
        </rdf:Description></rdf:RDF></x:xmpmeta>
        """

    /// Camera-style tags with nothing ImageIO would write a packet for.
    static var cameraProperties: [CFString: Any] {
        [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "TestCam", kCGImagePropertyTIFFModel: "T-1",
                                          kCGImagePropertyTIFFSoftware: "Firmware 1.0",
                                          kCGImagePropertyTIFFDateTime: "2026:09:30 10:11:12"],
         kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:09:30 10:11:12",
                                          kCGImagePropertyExifDateTimeDigitized: "2026:09:30 10:11:12",
                                          kCGImagePropertyExifFNumber: 2.8]]
    }

    /// Insert a segment right after SOI.
    static func withSegment(_ jpeg: Data, marker: UInt8, body: [UInt8]) -> Data {
        var out = Data(jpeg.prefix(2))
        out.append(contentsOf: [0xFF, marker, UInt8((body.count + 2) >> 8), UInt8((body.count + 2) & 0xFF)])
        out.append(contentsOf: body)
        out.append(jpeg.dropFirst(2))
        return out
    }

    /// Encoded by ImageIO from a parsed packet, as any XMP-aware writer would.
    static func encode(_ type: UTType, packet: String) throws -> Data {
        let meta = try #require(CGImageMetadataCreateFromXMPData(Data(packet.utf8) as CFData))
        let data = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImageAndMetadata(dest, MetadataTests.tinyImage(), meta, nil)
        try #require(CGImageDestinationFinalize(dest))
        return data as Data
    }

    static func expectPacketFields(_ m: ImageMetadata, mirror: Bool = true) throws {
        #expect(m.hasXMP)
        #expect(m.badges.contains { $0.label == "XMP" })
        let xmp = try #require(m.section(.xmp))
        #expect(xmp["xmp:Rating"] == "4")
        #expect(xmp["dc:subject"] == "alps, lake")
        // The mirror is in the packet, so it is listed.
        if mirror { #expect(xmp["exif:GPSLatitude"] == "47,22.2N") }
        #expect(xmp.fields.allSatisfy { !$0.key.hasPrefix("iio:") })
    }

    static func expectNoXMP(_ m: ImageMetadata) {
        #expect(!m.hasXMP)
        #expect(m.xmpPacket == nil && m.xmpExtendedPacket == nil)
        #expect(m.section(.xmp) == nil)
        #expect(!m.badges.contains { $0.label == "XMP" })
    }

    // MARK: PNG

    @Test(arguments: [false, true])
    func pngWithAnXMPTextChunk(compressed: Bool) throws {
        let body = MetadataContentsTests.iTXt(XMPScanner.pngKeyword, Self.packet, compressed: compressed)
        let m = MetadataTests.inspect(MetadataContentsTests.png([("iTXt", body)]), .png)
        #expect(m.xmpPacket == Self.packet)
        try Self.expectPacketFields(m)
        #expect(m.pngTextKeywords == [XMPScanner.pngKeyword])
    }

    @Test func pngWithoutAPacket() {
        Self.expectNoXMP(MetadataTests.inspect(MetadataTests.encode(.png), .png))
        let other = MetadataContentsTests.png([("tEXt", MetadataTests.tEXt("Comment", "<x:xmpmeta/> is not a packet here"))])
        Self.expectNoXMP(MetadataTests.inspect(other, .png))
    }

    // MARK: JPEG

    @Test func jpegWithAnAPP1Packet() throws {
        let jpeg = Self.withSegment(MetadataTests.encode(.jpeg, properties: Self.cameraProperties), marker: 0xE1,
                                    body: XMPScanner.jpegNamespace + Array(Self.packet.utf8))
        let m = MetadataTests.inspect(jpeg, .jpeg)
        #expect(m.hasEXIF)
        #expect(m.xmpPacket == Self.packet)
        #expect(m.xmpExtendedPacket == nil)
        try Self.expectPacketFields(m)
        // Derived from the TIFF tags, not in the packet: not listed.
        let xmp = try #require(m.section(.xmp))
        #expect(xmp["xmp:CreateDate"] == nil && xmp["xmp:CreatorTool"] == nil && xmp["photoshop:DateCreated"] == nil)
    }

    @Test func jpegWithEXIFOnly() throws {
        let jpeg = MetadataTests.encode(.jpeg, properties: Self.cameraProperties)
        #expect(XMPScanner.packet(in: jpeg, type: .jpeg) == .absent)
        let m = MetadataTests.inspect(jpeg, .jpeg)
        #expect(m.hasEXIF)
        #expect(m.section(.exif)?["Make"] == "TestCam")
        Self.expectNoXMP(m)
        // ImageIO does derive XMP tags for this file; that is what used to show the badge.
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let meta = try #require(CGImageSourceCopyMetadataAtIndex(source, 0, nil))
        #expect(CGImageMetadataCopyTagWithPath(meta, nil, "xmp:CreateDate" as CFString) != nil)
    }

    @Test func exifAPP1IsNotAPacket() {
        let jpeg = Self.withSegment(MetadataTests.encode(.jpeg), marker: 0xE1, body: Array("Exif".utf8) + [0, 0])
        #expect(XMPScanner.packet(in: jpeg, type: .jpeg) == .absent)
    }

    @Test func extendedXMPIsReassembled() throws {
        let rest = Self.packet.replacingOccurrences(of: "xmp:Rating=\"4\"", with: "xmp:Label=\"Blue\"")
        let bytes = Array(rest.utf8), half = bytes.count / 2
        func portion(_ offset: Int, _ part: ArraySlice<UInt8>) -> [UInt8] {
            let be = { (n: Int) in [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)] }
            return XMPScanner.jpegExtensionNamespace + Array(repeating: UInt8(ascii: "A"), count: 32)
                + be(bytes.count) + be(offset) + Array(part)
        }
        // Out of order in the file, on purpose.
        var jpeg = MetadataTests.encode(.jpeg)
        jpeg = Self.withSegment(jpeg, marker: 0xE1, body: portion(0, bytes[..<half]))
        jpeg = Self.withSegment(jpeg, marker: 0xE1, body: portion(half, bytes[half...]))
        let main = ExtendedXMPTests.main(naming: String(repeating: "A", count: 32))
        jpeg = Self.withSegment(jpeg, marker: 0xE1, body: XMPScanner.jpegNamespace + Array(main.utf8))
        let m = MetadataTests.inspect(jpeg, .jpeg)
        #expect(m.xmpPacket == main)
        #expect(m.xmpExtendedPacket == rest)
        let xmp = try #require(m.section(.xmp))
        #expect(xmp["xmp:Rating"] == "4" && xmp["xmp:Label"] == "Blue")
        #expect(Set(xmp.fields.map(\.key)).count == xmp.fields.count)

        // Extended portions without a standard packet do not make one.
        let orphan = Self.withSegment(MetadataTests.encode(.jpeg), marker: 0xE1, body: portion(0, bytes[...]))
        #expect(XMPScanner.packet(in: orphan, type: .jpeg) == .absent)
    }

    @Test func unparseablePacketStillCounts() throws {
        let jpeg = Self.withSegment(MetadataTests.encode(.jpeg), marker: 0xE1,
                                    body: XMPScanner.jpegNamespace + Array("<x:xmpmeta".utf8))
        let m = MetadataTests.inspect(jpeg, .jpeg)
        #expect(m.hasXMP && m.xmpPacket == "<x:xmpmeta")
        #expect(m.section(.xmp)?["Packet"] == "‹10 bytes›")
    }

    // MARK: TIFF and HEIC

    @Test(arguments: [UTType.tiff, .heic])
    func packetWrittenByImageIO(_ type: UTType) throws {
        let data = try Self.encode(type, packet: Self.packet)
        let m = MetadataTests.inspect(data, type)
        // ImageIO re-serialises the packet; the properties are what must survive.
        let packet = try #require(m.xmpPacket)
        #expect(packet.contains("<rdf:RDF") && packet.contains("Rating"))
        // ImageIO moves the `exif:GPS*` mirror into a native GPS IFD when it writes these.
        try Self.expectPacketFields(m, mirror: false)
        // The `tiff:` tags ImageIO reports for the container are not in the packet.
        #expect(m.section(.xmp)?["tiff:Orientation"] == nil)
    }

    /// ImageIO's HEIC encoder writes a real packet (`xmp:CreatorTool`, `xmp:ModifyDate`,
    /// `photoshop:DateCreated`) as soon as it is given TIFF Software or dates, so
    /// the HEIC case carries make and model only.
    @Test(arguments: [UTType.tiff, .heic])
    func exifOnlyHasNoPacket(_ type: UTType) {
        let makeOnly: [CFString: Any] = [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "TestCam",
                                                                          kCGImagePropertyTIFFModel: "T-1"]]
        let data = MetadataTests.encode(type, properties: type == .heic ? makeOnly : Self.cameraProperties)
        #expect(XMPScanner.packet(in: data, type: type) == .absent)
        let m = MetadataTests.inspect(data, type)
        #expect(m.hasEXIF)
        Self.expectNoXMP(m)
    }

    @Test func fixturesWithoutAPacket() throws {
        for f in [Fixture.camera, .sixteenBit, .displayP3, .a1111JPEG, .comfyUI] {
            Self.expectNoXMP(try Fixture.load(f).metadata)
        }
    }

    @Test func fixturePacketIsExposedWithItsMirrors() throws {
        let m = try Fixture.load(.iptcXMP).metadata
        let packet = try #require(m.xmpPacket)
        #expect(packet.contains("exif:GPSLatitude") && packet.contains("photoshop:City"))
        let xmp = try #require(m.section(.xmp))
        for key in ["xmp:Rating", "xmp:Label", "xmp:CreatorTool", "dc:subject", "photoshop:City", "exif:GPSLatitude"] {
            #expect(xmp[key] != nil, "\(key)")
        }
        #expect(xmp.fields.allSatisfy { !$0.key.hasPrefix("iio:") && !$0.key.hasPrefix("exif:Pixel") })
    }

    @Test func bigEndianTIFFTag700() {
        let text = Array("<x:xmpmeta/>".utf8)
        // Header, one-entry IFD at 8, then the packet at 26.
        var tiff: [UInt8] = [0x4D, 0x4D, 0, 42, 0, 0, 0, 8, 0, 1]
        tiff += [0x02, 0xBC, 0, 1, 0, 0, 0, UInt8(text.count), 0, 0, 0, 26] + [0, 0, 0, 0] + text
        #expect(XMPScanner.packet(in: Data(tiff), type: .tiff) == .found(packet: "<x:xmpmeta/>", extended: nil))
        tiff[10] = 0x01                                                   // some other tag
        #expect(XMPScanner.packet(in: Data(tiff), type: .tiff) == .absent)
        #expect(XMPScanner.packet(in: Data(tiff.prefix(12)), type: .tiff) == .notScanned)
    }

    // MARK: Other containers

    /// A RIFF chunk: ID, little-endian size, body, and a pad byte when the size is odd.
    static func riffChunk(_ id: String, _ body: [UInt8]) -> [UInt8] {
        let n = body.count
        return Array(id.utf8) + [UInt8(n & 0xFF), UInt8(n >> 8 & 0xFF), 0, 0] + body + (n % 2 == 1 ? [0] : [])
    }

    /// A bare WebP container around `chunks`.
    static func riff(_ chunks: [UInt8]) -> Data {
        let n = chunks.count + 4
        return Data(Array("RIFF".utf8) + [UInt8(n & 0xFF), UInt8(n >> 8 & 0xFF), 0, 0] + Array("WEBP".utf8) + chunks)
    }

    @Test func webPChunk() {
        let vp8x = Self.riffChunk("VP8X", [UInt8](repeating: 0, count: 10)), exif = Self.riffChunk("EXIF", [1, 2, 3])
        #expect(XMPScanner.packet(in: Self.riff(vp8x + exif + Self.riffChunk("XMP ", Array(Self.packet.utf8))), type: .webP)
            == .found(packet: Self.packet, extended: nil))
        #expect(XMPScanner.packet(in: Self.riff(vp8x + exif), type: .webP) == .absent)
    }

    /// GIF is not walked: ImageIO's tree decides, minus what it derives.
    @Test func unscannedContainersFallBackToImageIO() throws {
        let with = try Self.encode(.gif, packet: Self.packet)
        #expect(XMPScanner.packet(in: with, type: .gif) == .notScanned)
        let m = MetadataTests.inspect(with, .gif)
        #expect(m.hasXMP && m.xmpPacket == nil)
        let xmp = try #require(m.section(.xmp))
        #expect(xmp["xmp:Rating"] == "4")
        #expect(xmp.fields.allSatisfy { !$0.key.hasPrefix("iio:") && !$0.key.hasPrefix("exif:") })

        Self.expectNoXMP(MetadataTests.inspect(MetadataTests.encode(.gif), .gif))
    }

    /// Without the bytes there is nothing to walk; the derived tags still do not count.
    @Test func fallbackIgnoresDerivedTags() throws {
        let camera = try #require(CGImageSourceCreateWithURL(Fixture.camera.url as CFURL, nil))
        Self.expectNoXMP(ImageMetadata.inspect(source: camera, data: nil, type: .jpeg))
        let real = try #require(CGImageSourceCreateWithURL(Fixture.iptcXMP.url as CFURL, nil))
        let m = ImageMetadata.inspect(source: real, data: nil, type: .jpeg)
        #expect(m.hasXMP && m.xmpPacket == nil)
        #expect(m.section(.xmp)?["xmp:Rating"] != nil)
    }

    @Test func damagedFilesDoNotTrap() throws {
        let samples: [(Data, UTType)] = [
            (try Self.encode(.jpeg, packet: Self.packet), .jpeg), (try Self.encode(.tiff, packet: Self.packet), .tiff),
            (try Self.encode(.heic, packet: Self.packet), .heic), (try Self.encode(.png, packet: Self.packet), .png),
        ]
        for (data, type) in samples {
            guard case .found = XMPScanner.packet(in: data, type: type) else {
                Issue.record("no packet in \(type.identifier)")
                continue
            }
            for cut in stride(from: 0, to: data.count, by: max(1, data.count / 200)) {
                _ = XMPScanner.packet(in: data.prefix(cut), type: type)
                // A slice that does not start at index 0.
                _ = XMPScanner.packet(in: data.suffix(from: cut), type: type)
            }
            var noisy = data
            for i in stride(from: 4, to: noisy.count, by: 7) { noisy[i] = 0xFF }
            _ = XMPScanner.packet(in: noisy, type: type)
        }
    }
}
