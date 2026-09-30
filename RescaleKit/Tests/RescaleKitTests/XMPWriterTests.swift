import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import RescaleKit

extension Fixture.Output {
    /// The packet in the output, read from the container (`XMPScanner`).
    var packet: String { metadata.xmpPacket ?? "" }
    /// A property of that packet, by `prefix:name`.
    func xmp(_ path: String) -> String? { metadata.section(.xmp)?[path] }
    func contains(_ text: String) -> Bool { data.range(of: Data(text.utf8)) != nil }
}

/// The XMP switch, its mirrors and the AI payloads in EXIF (PRD §10.2–10.4,
/// issue #18), on each of the four output formats.
struct XMPWriterTests {
    static let formats = MetadataWriterTests.formats

    /// Everything stripped but what is named.
    static func only(exif: MetadataPolicy.Action = .strip, gps: MetadataPolicy.Action = .strip,
                     iptc: MetadataPolicy.Action = .strip, xmp: MetadataPolicy.Action = .strip,
                     aiWorkflow: MetadataPolicy.Action = .strip) -> MetadataPolicy {
        MetadataPolicy(exif: exif, gps: gps, iptc: iptc, xmp: xmp, icc: .preserve, aiWorkflow: aiWorkflow)
    }

    /// A packet as a raw processor or Lightroom might leave it: mirrors of every
    /// section, a thumbnail, a sideways orientation, the original's dimensions
    /// and a namespace ImageIO has never heard of.
    static let richPacket = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\
        <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" \
        xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:exif="http://ns.adobe.com/exif/1.0/" \
        xmlns:tiff="http://ns.adobe.com/tiff/1.0/" xmlns:exifEX="http://cipa.jp/exif/1.0/" \
        xmlns:aux="http://ns.adobe.com/exif/1.0/aux/" xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/" \
        xmlns:Iptc4xmpCore="http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/" \
        xmlns:xmpGImg="http://ns.adobe.com/xap/1.0/g/img/" xmlns:acme="http://example.com/acme/1.0/" \
        xmp:Rating="5" xmp:Label="Packet label" xmp:CreateDate="2021-02-03T04:05:06" \
        tiff:Orientation="6" tiff:Make="PacketCam" tiff:ImageWidth="4000" tiff:ImageLength="3000" \
        exif:PixelXDimension="4000" exif:PixelYDimension="3000" exif:FNumber="28/10" \
        exif:GPSLatitude="47,22.2N" exif:GPSLongitude="8,32.4E" \
        exifEX:LensModel="Packet 50mm" aux:Lens="Packet Lens" \
        photoshop:City="Packetville" photoshop:ColorMode="3" Iptc4xmpCore:Location="Packet Square" \
        acme:Note="Packet note">\
        <dc:title><rdf:Alt><rdf:li xml:lang="x-default">Packet title</rdf:li></rdf:Alt></dc:title>\
        <dc:format>image/jpeg</dc:format>\
        <xmp:Thumbnails><rdf:Alt><rdf:li rdf:parseType="Resource"><xmpGImg:format>JPEG</xmpGImg:format>\
        <xmpGImg:width>256</xmpGImg:width><xmpGImg:height>192</xmpGImg:height>\
        <xmpGImg:image>PACKETTHUMBNAILBASE64</xmpGImg:image></rdf:li></rdf:Alt></xmp:Thumbnails>\
        </rdf:Description></rdf:RDF></x:xmpmeta>
        """

    /// A JPEG carrying `packet` (and `extended`, in extension segments), loaded as a source.
    static func source(packet: String, extended: String? = nil) throws -> SourceImage {
        var jpeg = MetadataTests.encode(.jpeg)
        if let extended {
            let bytes = Array(extended.utf8)
            let be = { (n: Int) in [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)] }
            // Inserted after SOI each time, so last portion first.
            for offset in stride(from: 0, to: bytes.count, by: 60_000).reversed() {
                jpeg = XMPDetectionTests.withSegment(jpeg, marker: 0xE1, body: XMPScanner.jpegExtensionNamespace
                    + Array(repeating: UInt8(ascii: "A"), count: 32) + be(bytes.count) + be(offset)
                    + bytes[offset..<min(offset + 60_000, bytes.count)])
            }
        }
        jpeg = XMPDetectionTests.withSegment(jpeg, marker: 0xE1, body: XMPScanner.jpegNamespace + Array(packet.utf8))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("xmp-\(UUID().uuidString).jpg")
        try jpeg.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try SourceImage.load(url)
    }

    static func render(_ source: SourceImage, _ format: OutputFormat, _ policy: MetadataPolicy) throws -> Fixture.Output {
        try FixtureProbe.inspect(try Renderer.produce(source, spec: RenderSpec(target: source.size, format: format,
                                                                               metadata: policy)))
    }

    // MARK: The switch

    @Test(arguments: formats)
    func keepCarriesTheSourcePacket(_ format: OutputFormat) throws {
        let out = try MetadataWriterTests.render(.iptcXMP, format, Self.only(xmp: .keep))
        #expect(out.metadata.hasXMP)
        #expect(out.xmp("xmp:Rating") == "4" && out.xmp("xmp:Label") == "Placeholder label")
        // The same through ImageIO, with everything else kept too.
        let all = try MetadataWriterTests.render(.iptcXMP, format, .keepAll)
        #expect(all.xmp("xmp:Rating") == "4" && all.xmp("xmp:Label") == "Placeholder label")
        #expect(all.metadataTags.contains("xmp:Rating") && all.metadataTags.contains("xmp:Label"))
        #expect(all.metadata.hasIPTC && all.metadata.hasGPS)
    }

    @Test(arguments: formats)
    func stripLeavesNothingOfTheSourcePacket(_ format: OutputFormat) throws {
        var policy = MetadataPolicy.keepAll
        policy.xmp = .strip
        let out = try MetadataWriterTests.render(.iptcXMP, format, policy)
        #expect(out.xmp("xmp:Rating") == nil && out.xmp("xmp:Label") == nil)
        #expect(!out.metadataTags.contains("xmp:Rating") && !out.metadataTags.contains("xmp:Label"))
        #expect(out.dictionary(kCGImagePropertyIPTCDictionary)["StarRating"] == nil)
        #expect(!out.contains("Placeholder label") && !out.contains("xmp:Rating"))
        // IPTC is kept all the same.
        #expect(out.metadata.hasIPTC)

        let bare = try MetadataWriterTests.render(.iptcXMP, format, Self.only())
        #expect(!bare.metadata.hasXMP && !bare.contains("xmpmeta"))
    }

    /// Issue #18, rule 2: on PNG and HEIC, IPTC can only be written as XMP, so
    /// "strip XMP, keep IPTC" writes the packet ImageIO derives — and only that.
    @Test(arguments: [OutputFormat.png, .heic])
    func derivedPacketBelongsToItsSection(_ format: OutputFormat) throws {
        let out = try MetadataWriterTests.render(.iptcXMP, format, Self.only(iptc: .keep))
        #expect(out.metadata.hasXMP && out.metadata.hasIPTC)
        #expect(out.xmp("dc:description") == "Synthetic test caption")
        #expect(out.xmp("xmp:Rating") == nil && out.xmp("xmp:Label") == nil)
        #expect(!out.contains("Placeholder label") && !out.showsLocation)
        // With IPTC stripped as well there is no packet at all.
        #expect(!(try MetadataWriterTests.render(.iptcXMP, format, Self.only())).metadata.hasXMP)
    }

    @Test(arguments: formats)
    func sourceWithoutAPacketGetsNoneOfItsOwn(_ format: OutputFormat) throws {
        var stripped = MetadataPolicy.keepAll
        stripped.xmp = .strip
        let kept = try MetadataWriterTests.render(.camera, format, .keepAll)
        #expect(kept.data == (try MetadataWriterTests.render(.camera, format, stripped)).data)
    }

    // MARK: Mirrors (PRD §10.3)

    /// The fixture has its coordinates only as an XMP mirror.
    @Test(arguments: formats)
    func strippingGPSRemovesItsMirrorFromTheKeptPacket(_ format: OutputFormat) throws {
        var policy = MetadataPolicy.keepAll
        policy.gps = .strip
        for source in [try Fixture.load(.iptcXMP), try Self.source(packet: Self.richPacket)] {
            #expect(source.metadata.hasGPS)
            let out = try Self.render(source, format, policy)
            #expect(out.xmp("xmp:Rating") != nil)
            #expect(!out.metadata.hasGPS && !out.showsLocation)
            #expect(out.properties[kCGImagePropertyGPSDictionary as String] == nil)
            #expect(!out.packet.contains("GPS") && out.metadata.section(.xmp)?.fields.contains { $0.key.contains("GPS") } == false)
            #expect(!out.contains("GPSLatitude") && !out.contains("GPSLongitude") && !out.contains("47,22"))
        }
    }

    @Test(arguments: formats)
    func keptGPSMirrorSurvives(_ format: OutputFormat) throws {
        let out = try MetadataWriterTests.render(.iptcXMP, format, Self.only(gps: .keep, xmp: .keep))
        #expect(out.metadata.hasGPS && out.showsLocation)
        #expect(out.xmp("dc:description") == nil && !out.contains("Synthetic test caption"))
    }

    @Test(arguments: formats)
    func strippingEXIFRemovesItsMirrors(_ format: OutputFormat) throws {
        let source = try Self.source(packet: Self.richPacket)
        let out = try Self.render(source, format, Self.only(iptc: .keep, xmp: .keep))
        #expect(out.xmp("xmp:Rating") == "5" && out.xmp("photoshop:City") == "Packetville")
        let fields = try #require(out.metadata.section(.xmp)).fields.map(\.key)
        for prefix in ["exif:", "exifEX:", "tiff:", "aux:"] {
            #expect(!fields.contains { $0.hasPrefix(prefix) }, "\(prefix)")
        }
        #expect(!fields.contains("xmp:CreateDate"))
        for text in ["PacketCam", "Packet 50mm", "Packet Lens", "28/10", "2021-02-03", "2021:02:03"] {
            #expect(!out.contains(text), "\(text)")
        }
        #expect(!out.metadata.hasEXIF && !out.metadata.hasGPS)
        #expect(out.dictionary(kCGImagePropertyTIFFDictionary)["Make"] == nil)
        #expect(out.dictionary(kCGImagePropertyExifDictionary)["FNumber"] == nil)
    }

    @Test(arguments: formats)
    func strippingIPTCRemovesItsMirrors(_ format: OutputFormat) throws {
        for source in [try Fixture.load(.iptcXMP), try Self.source(packet: Self.richPacket)] {
            let out = try Self.render(source, format, Self.only(exif: .keep, gps: .keep, xmp: .keep))
            #expect(out.xmp("xmp:Rating") != nil && out.xmp("xmp:Label") != nil)
            let fields = try #require(out.metadata.section(.xmp)).fields.map(\.key)
            for path in ["dc:description", "dc:subject", "dc:rights", "dc:creator", "dc:title", "photoshop:City",
                         "photoshop:Credit", "Iptc4xmpCore:Location"] {
                #expect(!fields.contains(path), "\(path)")
            }
            for text in ["Synthetic test caption", "Placeholder Author", "Placeholder copyright", "Placeholder Agency",
                         "Null Island", "Packetville", "Packet Square", "Packet title", "8BIM"] {
                #expect(!out.contains(text), "\(text)")
            }
            // ImageIO reports `xmp:Rating` as an IPTC star rating and the kept
            // `xmp:CreateDate` as IPTC dates; nothing of the source's IPTC is left.
            let derived: Set = ["StarRating", "DigitalCreationDate", "DigitalCreationTime"]
            #expect(Set(out.dictionary(kCGImagePropertyIPTCDictionary).keys).isSubset(of: derived))
            let tiff = out.dictionary(kCGImagePropertyTIFFDictionary)
            #expect(tiff["ImageDescription"] == nil && tiff["Artist"] == nil && tiff["Copyright"] == nil)
        }
    }

    /// What belongs to no other section stays: Photoshop's own properties, plain
    /// Dublin Core, and a namespace ImageIO does not know.
    @Test(arguments: formats)
    func unrelatedPropertiesSurviveEveryOtherStrip(_ format: OutputFormat) throws {
        let out = try Self.render(try Self.source(packet: Self.richPacket), format, Self.only(xmp: .keep))
        #expect(out.xmp("xmp:Rating") == "5" && out.xmp("xmp:Label") == "Packet label")
        #expect(out.xmp("photoshop:ColorMode") == "3" && out.xmp("dc:format") == "image/jpeg")
        #expect(out.xmp("acme:Note") == "Packet note")
    }

    // MARK: PRD §10.4 in the packet

    @Test(arguments: formats)
    func packetIsUprightHasTheOutputSizeAndNoThumbnail(_ format: OutputFormat) throws {
        let source = try Self.source(packet: Self.richPacket)
        let target = PixelSize(6, 4)
        let out = try FixtureProbe.inspect(try Renderer.produce(source, spec: RenderSpec(target: target, format: format,
                                                                                         metadata: .keepAll)))
        #expect(out.size == target && out.xmp("xmp:Rating") == "5")
        MetadataWriterTests.expectUpright(out)
        let xmp = try #require(out.metadata.section(.xmp))
        #expect(xmp["tiff:Orientation"] ?? "1" == "1")
        #expect(xmp["exif:PixelXDimension"] ?? "6" == "6" && xmp["exif:PixelYDimension"] ?? "4" == "4")
        #expect(xmp["tiff:ImageWidth"] ?? "6" == "6" && xmp["tiff:ImageLength"] ?? "4" == "4")
        let exif = out.dictionary(kCGImagePropertyExifDictionary)
        #expect(exif["PixelXDimension"] as? Int ?? 6 == 6 && exif["PixelYDimension"] as? Int ?? 4 == 4)
        #expect(out.properties["PixelWidth"] as? Int == 6)
        #expect(!out.contains("4000") && !out.contains("3000"))
        #expect(xmp["xmp:Thumbnails"] == nil)
        #expect(!out.contains("Thumbnails") && !out.contains("xmpGImg") && !out.contains("PACKETTHUMBNAILBASE64"))
        #expect(!out.hasEmbeddedThumbnail)
    }

    @Test func filterFixesAndDropsByNamespaceNotPrefix() throws {
        // The same EXIF namespace under another prefix.
        let packet = Self.richPacket.replacingOccurrences(of: "exif:", with: "e:").replacingOccurrences(of: "xmlns:exif=", with: "xmlns:e=")
        let kept = XMPWriter.Kept(exif: false, gps: false, iptc: true, aiWorkflow: true)
        let tree = try #require(XMPWriter.metadata(packet: packet, extended: nil, kept: kept, size: PixelSize(6, 4)))
        let tags = try #require(CGImageMetadataCopyTags(tree) as? [CGImageMetadataTag])
        let namespaces = Set(tags.compactMap { CGImageMetadataTagCopyNamespace($0) as String? })
        #expect(namespaces.isDisjoint(with: XMPWriter.exifNamespaces))
        #expect(namespaces.contains(XMPWriter.photoshop) && namespaces.contains("http://example.com/acme/1.0/"))

        // Nothing left, no tree: the encoder then writes no packet of the source's.
        let gpsOnly = XMPDetectionTests.packet.replacingOccurrences(of: "xmp:Rating=\"4\"", with: "")
        #expect(XMPWriter.metadata(packet: gpsOnly, extended: nil, kept: XMPWriter.Kept(gps: false, iptc: false),
                                   size: PixelSize(6, 4)) == nil)
        #expect(XMPWriter.metadata(packet: "not xml", extended: nil, kept: XMPWriter.Kept(), size: PixelSize(6, 4)) == nil)
    }

    // MARK: Structures and arrays (review 2026-09-30, S2)

    /// Mirrors, a thumbnail, a sideways orientation and the original's
    /// dimensions again, this time inside a structure, a structure in a
    /// structure and the items of an array, next to fields of the tool's own.
    static let nestedPacket = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\
        <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" \
        xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:exif="http://ns.adobe.com/exif/1.0/" \
        xmlns:tiff="http://ns.adobe.com/tiff/1.0/" xmlns:xmpGImg="http://ns.adobe.com/xap/1.0/g/img/" \
        xmlns:acme="http://example.com/acme/1.0/" xmp:Rating="5">\
        <dc:title><rdf:Alt><rdf:li xml:lang="x-default">Packet title</rdf:li></rdf:Alt></dc:title>\
        <acme:Place rdf:parseType="Resource"><acme:Name>Nested name</acme:Name>\
        <exif:GPSLatitude>0,0.0N</exif:GPSLatitude><tiff:Orientation>6</tiff:Orientation>\
        <exif:PixelXDimension>4000</exif:PixelXDimension><exif:PixelYDimension>3000</exif:PixelYDimension>\
        <acme:Inner rdf:parseType="Resource"><exif:GPSLongitude>0,0.0E</exif:GPSLongitude>\
        <acme:Deep>Deep note</acme:Deep></acme:Inner>\
        <acme:Preview rdf:parseType="Resource"><xmpGImg:format>JPEG</xmpGImg:format>\
        <xmpGImg:image>NESTEDTHUMBNAILBASE64</xmpGImg:image></acme:Preview>\
        <acme:Hidden rdf:parseType="Resource"><exif:GPSAltitude>0/1</exif:GPSAltitude></acme:Hidden>\
        </acme:Place>\
        <acme:Items><rdf:Seq>\
        <rdf:li rdf:parseType="Resource"><exif:GPSAltitude>0/1</exif:GPSAltitude><acme:Label>First item</acme:Label></rdf:li>\
        <rdf:li>Plain item</rdf:li>\
        <rdf:li rdf:parseType="Resource"><tiff:ImageWidth>4000</tiff:ImageWidth><tiff:ImageLength>3000</tiff:ImageLength>\
        <acme:Label>Third item</acme:Label></rdf:li>\
        </rdf:Seq></acme:Items>\
        </rdf:Description></rdf:RDF></x:xmpmeta>
        """

    /// Every tag of a tree at any depth as `namespace name value`, containers without a value.
    static func leaves(_ tree: CGImageMetadata) -> [String] {
        var out: [String] = []
        CGImageMetadataEnumerateTagsUsingBlock(tree, nil, [kCGImageMetadataEnumerateRecursively: true] as CFDictionary) { _, tag in
            let value = CGImageMetadataTagCopyValue(tag) as? String ?? ""
            out.append("\(CGImageMetadataTagCopyNamespace(tag) as String? ?? "") \(CGImageMetadataTagCopyName(tag) as String? ?? "") \(value)")
            return true
        }
        return out
    }

    @Test func filterReachesEveryDescendant() throws {
        let kept = XMPWriter.Kept(exif: true, gps: false, iptc: true, aiWorkflow: true)
        let tree = try #require(XMPWriter.metadata(packet: Self.nestedPacket, extended: nil, kept: kept, size: PixelSize(6, 4)))
        let leaves = Self.leaves(tree)
        #expect(!leaves.contains { $0.contains(" GPS") })
        #expect(!leaves.contains { $0.hasPrefix(XMPWriter.thumbnailImage) })
        // A structure left with nothing goes with its contents.
        #expect(!leaves.contains { $0.contains(" Hidden") || $0.contains(" Preview") })
        // PRD §10.4 at every depth.
        let acme = "http://example.com/acme/1.0/"
        #expect(leaves.contains("\(XMPWriter.tiff) Orientation 1"))
        #expect(leaves.contains("\(XMPWriter.exif) PixelXDimension 6") && leaves.contains("\(XMPWriter.exif) PixelYDimension 4"))
        #expect(leaves.contains("\(XMPWriter.tiff) ImageWidth 6") && leaves.contains("\(XMPWriter.tiff) ImageLength 4"))
        // The tool's own fields are untouched, in order.
        for own in ["Name Nested name", "Deep Deep note", "Label First item", "[1] Plain item", "Label Third item"] {
            #expect(leaves.contains("\(acme) \(own)"), "\(own)")
        }
        #expect(leaves.contains("\(XMPWriter.xmp) Rating 5"))
        // An untouched property keeps its qualifiers.
        let title = try #require(CGImageMetadataCopyTagWithPath(tree, nil, "dc:title" as CFString))
        let item = try #require((CGImageMetadataTagCopyValue(title) as? [CGImageMetadataTag])?.first)
        #expect((CGImageMetadataTagCopyQualifiers(item) as? [CGImageMetadataTag])?.count == 1)

        // Kept GPS stays where it was; stripped EXIF goes at every depth.
        let noEXIF = try #require(XMPWriter.metadata(packet: Self.nestedPacket, extended: nil,
                                                     kept: XMPWriter.Kept(exif: false), size: PixelSize(6, 4)))
        let rest = Self.leaves(noEXIF)
        #expect(rest.filter { $0.contains(" GPS") }.count == 4)
        #expect(!rest.contains { $0.hasPrefix(XMPWriter.tiff) || $0.contains("PixelXDimension") })
        #expect(rest.contains("\(acme) Label Third item"))
    }

    @Test(arguments: formats)
    func nestedMirrorsFollowTheirSwitchInTheSavedFile(_ format: OutputFormat) throws {
        let source = try Self.source(packet: Self.nestedPacket)
        var policy = MetadataPolicy.keepAll
        policy.gps = .strip
        let out = try FixtureProbe.inspect(try Renderer.produce(source, spec: RenderSpec(target: PixelSize(6, 4), format: format,
                                                                                         metadata: policy)))
        #expect(out.xmp("xmp:Rating") == "5")
        for text in ["GPSLatitude", "GPSLongitude", "GPSAltitude", "0,0.0N", "0,0.0E", "NESTEDTHUMBNAILBASE64", "xmpGImg",
                     "4000", "3000", "<tiff:Orientation>6"] {
            #expect(!out.contains(text), "\(text)")
        }
        for text in ["Nested name", "Deep note", "First item", "Plain item", "Third item", "Packet title"] {
            #expect(out.packet.contains(text), "\(text)")
        }
        #expect(!out.metadata.hasGPS && !out.showsLocation)
        // Default and Strip all write nothing of the packet at all.
        for policy in [MetadataPolicy.default, .stripAll] {
            let bare = try Self.render(source, format, policy)
            #expect(!bare.contains("Nested name") && !bare.contains("GPS"))
        }
    }

    // MARK: Extended XMP

    /// A JPEG's extended packet is folded into the one packet that is written,
    /// and filtered like the rest.
    @Test(arguments: formats)
    func extendedPacketIsMergedAndFiltered(_ format: OutputFormat) throws {
        let extended = XMPDetectionTests.packet.replacingOccurrences(of: "xmp:Rating=\"4\"", with: "xmp:Label=\"Blue\"")
        let main = """
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\
            <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" \
            xmlns:xmpNote="http://ns.adobe.com/xmp/note/" xmp:Rating="4" \
            xmpNote:HasExtendedXMP="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"/></rdf:RDF></x:xmpmeta>
            """
        let source = try Self.source(packet: main, extended: extended)
        #expect(source.metadata.xmpExtendedPacket == extended)
        let out = try Self.render(source, format, .keepMost)
        #expect(out.xmp("xmp:Rating") == "4" && out.xmp("xmp:Label") == "Blue")
        #expect(out.xmp("dc:subject") == "alps, lake")
        #expect(out.metadata.xmpExtendedPacket == nil && !out.contains("HasExtendedXMP"))
        // The default policy strips GPS, in the extended part too.
        #expect(!out.showsLocation && !out.contains("GPSLatitude") && !out.contains("47,22"))
    }

    /// Over 64 KB, ImageIO splits the packet into extended segments again on
    /// JPEG; the other containers hold it whole.
    @Test(arguments: formats)
    func packetOverTheJPEGSegmentLimit(_ format: OutputFormat) throws {
        let long = String(repeating: "lorem ipsum ", count: 9000)   // 108 KB
        let packet = XMPDetectionTests.packet.replacingOccurrences(of: "xmp:Rating=\"4\"", with: "xmp:Rating=\"4\" xmp:Nickname=\"\(long)\"")
        let source = try Self.source(packet: XMPDetectionTests.packet, extended: packet)
        let out = try Self.render(source, format, .keepMost)
        #expect(out.xmp("xmp:Rating") == "4" && out.xmp("xmp:Nickname") == long)
        #expect((out.metadata.xmpExtendedPacket != nil) == (format == .jpeg))
        #expect(!out.showsLocation && !out.contains("GPSLatitude"))
    }

    // MARK: PNG

    /// One `iTXt XML:com.adobe.xmp`, written by ImageIO, next to the spliced
    /// AI workflow chunks (#14).
    @Test func pngKeepsOnePacketNextToTheWorkflow() throws {
        let packet = try #require(try Fixture.load(.iptcXMP).metadata.xmpPacket)
        let xmp = PNGSplicerTests.chunk("iTXt", Data("XML:com.adobe.xmp\0\0\0\0\0\(packet)".utf8))
        var png = Fixture.comfyUI.data
        png.insert(contentsOf: xmp, at: try #require(PNGSplicer.iendOffset(in: png)))
        let source = try PNGSplicerTests.source(fromPNG: png)
        #expect(source.metadata.pngTextKeywords == ["prompt", "workflow", "XML:com.adobe.xmp"])

        let out = try FixtureProbe.inspect(try Renderer.produce(source, spec: RenderSpec(target: PNGSplicerTests.half, metadata: .keepMost)))
        #expect(out.metadata.pngTextKeywords.sorted() == ["XML:com.adobe.xmp", "prompt", "workflow"])
        #expect(out.metadata.provenance == [.comfyUI])
        #expect(out.xmp("xmp:Rating") == "4" && out.xmp("xmp:Label") == "Placeholder label")
        #expect(!out.contains("GPSLatitude"))
        #expect(try #require(PNGSplicerTests.walk(out.data)).allSatisfy { $0.crcValid })
        let graphs = PNGScanner.textChunks(in: Fixture.comfyUI.data).map(\.raw)
        #expect(out.metadata.pngTextChunks.filter { $0.keyword != "XML:com.adobe.xmp" }.map(\.raw) == graphs)

        // Each switch on its own.
        var spec = RenderSpec(target: PNGSplicerTests.half, metadata: .keepMost)
        spec.metadata.aiWorkflow = .strip
        #expect(try FixtureProbe.inspect(try Renderer.produce(source, spec: spec)).metadata.pngTextKeywords == ["XML:com.adobe.xmp"])
        spec.metadata = Self.only(aiWorkflow: .keep)
        #expect(try FixtureProbe.inspect(try Renderer.produce(source, spec: spec)).metadata.pngTextKeywords == ["prompt", "workflow"])
    }

    @Test(arguments: [Fixture.iptcXMP, .camera])
    func pngNeverHoldsTwoPackets(_ fixture: Fixture) throws {
        for policy in [MetadataPolicy.keepAll, .keepMost, Self.only(iptc: .keep), Self.only(xmp: .keep)] {
            let out = try MetadataWriterTests.render(fixture, .png, policy)
            #expect(out.metadata.pngTextKeywords.filter { $0 == "XML:com.adobe.xmp" }.count <= 1)
        }
    }
}

/// The AI workflow switch owns the AI payloads stored in EXIF / TIFF (issue #18, rule 5).
struct AIWorkflowInEXIFTests {
    static let formats = MetadataWriterTests.formats

    static func userComment(_ out: Fixture.Output) -> String? {
        out.dictionary(kCGImagePropertyExifDictionary)["UserComment"] as? String
    }

    @Test(arguments: formats, [MetadataPolicy.Action.keep, .strip])
    func keepWritesTheParametersWhateverEXIFSays(_ format: OutputFormat, _ exif: MetadataPolicy.Action) throws {
        let parameters = try #require(try Fixture.load(.a1111JPEG).metadata.aiPayloads.first?.text)
        let out = try MetadataWriterTests.render(.a1111JPEG, format, XMPWriterTests.only(exif: exif, aiWorkflow: .keep))
        #expect(Self.userComment(out) == parameters)
        #expect(out.metadata.provenance == [.a1111])
        #expect(out.metadata.aiPayloads.map(\.text) == [parameters])
        MetadataWriterTests.expectUpright(out)
    }

    @Test(arguments: formats, [MetadataPolicy.Action.keep, .strip])
    func stripRemovesTheParametersWhateverEXIFSays(_ format: OutputFormat, _ exif: MetadataPolicy.Action) throws {
        var policy = MetadataPolicy.keepAll
        policy.exif = exif
        policy.aiWorkflow = .strip
        let out = try MetadataWriterTests.render(.a1111JPEG, format, policy)
        #expect(Self.userComment(out) == nil)
        #expect(out.metadata.provenance.isEmpty && out.metadata.aiPayloads.isEmpty)
        #expect(!out.contains("Steps:") && !out.contains("Sampler") && !out.metadataTags.contains("exif:UserComment"))
    }

    /// A comment that is not an AI payload stays with EXIF.
    @Test func ordinaryUserCommentFollowsEXIF() {
        let source: [CFString: Any] = [kCGImagePropertyExifDictionary: ["UserComment": "Holiday, day 3", "FNumber": 2.8]]
        func comment(_ policy: MetadataPolicy) -> String? {
            let out = MetadataWriter.properties(from: source, policy: policy, type: .jpeg, size: PixelSize(8, 8))
            return (out[kCGImagePropertyExifDictionary] as? [String: Any])?["UserComment"] as? String
        }
        #expect(comment(XMPWriterTests.only(exif: .keep)) == "Holiday, day 3")
        #expect(comment(XMPWriterTests.only(aiWorkflow: .keep)) == nil)
        #expect(MetadataWriter.properties(from: source, policy: XMPWriterTests.only(aiWorkflow: .keep), type: .jpeg,
                                          size: PixelSize(8, 8)).isEmpty)
    }

    @Test(arguments: [UTType.jpeg, .heic, .tiff, .png])
    func midjourneyDescriptionFollowsTheAISwitch(_ type: UTType) {
        let prompt = "a lighthouse at dusk --v 6 Job ID: 0000-placeholder"
        let source: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: ["ImageDescription": prompt, "Make": "Synthetic", "Artist": "Someone"],
            kCGImagePropertyIPTCDictionary: ["Caption/Abstract": prompt, "Byline": ["Someone"]],
        ]
        func written(_ policy: MetadataPolicy) -> (tiff: [String: Any], exif: [String: Any], iptc: [String: Any]) {
            let out = MetadataWriter.properties(from: source, policy: policy, type: type, size: PixelSize(8, 8))
            return (out[kCGImagePropertyTIFFDictionary] as? [String: Any] ?? [:],
                    out[kCGImagePropertyExifDictionary] as? [String: Any] ?? [:],
                    out[kCGImagePropertyIPTCDictionary] as? [String: Any] ?? [:])
        }
        // Kept with EXIF and IPTC stripped: the description, the §10.4 fixes, nothing else.
        let alone = written(XMPWriterTests.only(aiWorkflow: .keep))
        #expect(alone.tiff["ImageDescription"] as? String == prompt)
        #expect(Set(alone.tiff.keys) == ["ImageDescription", "Orientation"])
        #expect(Set(alone.exif.keys) == ["PixelXDimension", "PixelYDimension"] && alone.iptc.isEmpty)
        // Stripped with EXIF and IPTC kept: gone from the TIFF tags and from the caption.
        let stripped = written(XMPWriterTests.only(exif: .keep, iptc: .keep))
        #expect(stripped.tiff["ImageDescription"] == nil && stripped.tiff["Make"] as? String == "Synthetic")
        #expect(stripped.iptc["Caption/Abstract"] == nil && stripped.iptc["Byline"] != nil)
        // Kept along with them.
        let all = written(.keepAll)
        #expect(all.tiff["ImageDescription"] as? String == prompt && all.iptc["Caption/Abstract"] as? String == prompt)
        // An ordinary description still goes with IPTC.
        let plain: [CFString: Any] = [kCGImagePropertyTIFFDictionary: ["ImageDescription": "A caption", "Make": "Synthetic"]]
        let out = MetadataWriter.properties(from: plain, policy: XMPWriterTests.only(exif: .keep, aiWorkflow: .keep),
                                            type: type, size: PixelSize(8, 8))
        #expect((out[kCGImagePropertyTIFFDictionary] as? [String: Any])?["ImageDescription"] == nil)
    }

    /// The same payloads mirrored in a kept packet.
    @Test func packetMirrorsOfAIPayloadsFollowTheAISwitch() {
        let a1111 = "a cat\nSteps: 20, Sampler: Euler a, CFG scale: 7"
        func keeps(_ namespace: String, _ name: String, _ value: String, _ kept: XMPWriter.Kept) -> Bool {
            XMPWriter.keeps(namespace: namespace, name: name, value: value, kept: kept)
        }
        let aiOnly = XMPWriter.Kept(exif: false, gps: false, iptc: false, aiWorkflow: true)
        let noAI = XMPWriter.Kept(aiWorkflow: false)
        #expect(keeps(XMPWriter.exif, "UserComment", a1111, aiOnly) && !keeps(XMPWriter.exif, "UserComment", a1111, noAI))
        #expect(!keeps(XMPWriter.exif, "UserComment", "Holiday", aiOnly) && keeps(XMPWriter.exif, "UserComment", "Holiday", noAI))
        for (namespace, name) in [(XMPWriter.dublinCore, "description"), (XMPWriter.tiff, "ImageDescription")] {
            #expect(keeps(namespace, name, "x Job ID: 1", aiOnly) && !keeps(namespace, name, "x Job ID: 1", noAI))
            #expect(!keeps(namespace, name, "A caption", aiOnly) && keeps(namespace, name, "A caption", noAI))
        }
    }
}
