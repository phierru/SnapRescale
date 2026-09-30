import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import zlib
@testable import RescaleKit

/// Contents, not just presence: section fields, PNG text chunks (inflated and
/// raw), and AI workflow payloads.
struct MetadataContentsTests {
    static func deflate(_ text: String) -> [UInt8] {
        let input = Array(text.utf8)
        var length = compressBound(uLong(input.count))
        var out = [UInt8](repeating: 0, count: Int(length))
        let status = compress(&out, &length, input, uLong(input.count))
        precondition(status == Z_OK)
        return Array(out.prefix(Int(length)))
    }

    static func zTXt(_ keyword: String, _ text: String) -> [UInt8] {
        Array(keyword.utf8) + [0, 0] + deflate(text)
    }

    static func iTXt(_ keyword: String, _ text: String, compressed: Bool, language: String = "") -> [UInt8] {
        Array(keyword.utf8) + [0, compressed ? 1 : 0, 0] + Array(language.utf8) + [0, 0]
            + (compressed ? deflate(text) : Array(text.utf8))
    }

    /// Insert chunks right after IHDR, in the order given.
    static func png(_ chunks: [(type: String, body: [UInt8])]) -> Data {
        chunks.reversed().reduce(MetadataTests.encode(.png)) { MetadataTests.withChunk($0, type: $1.type, body: $1.body) }
    }

    static let graph = #"{"3":{"class_type":"KSampler","inputs":{"seed":42,"text":"città al tramonto"}}}"#
    static let workflow = #"{"nodes":[{"id":3,"type":"KSampler"}],"links":[],"version":0.4}"#
    static let parameters = "a cat, 8k\nNegative prompt: dog\nSteps: 20, Sampler: Euler a, CFG scale: 7, Seed: 1, Size: 512x512"

    // MARK: Fields

    @Test func exifGPSAndIPTCFieldsInJPEG() throws {
        let props: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "TestCam", kCGImagePropertyTIFFModel: "T-1"],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifLensModel: "Test 50mm", kCGImagePropertyExifISOSpeedRatings: [100],
                kCGImagePropertyExifExposureTime: 0.004, kCGImagePropertyExifFNumber: 2.8,
                kCGImagePropertyExifFocalLength: 50, kCGImagePropertyExifDateTimeOriginal: "2026:09:30 10:11:12",
            ],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 47.37, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 8.54, kCGImagePropertyGPSLongitudeRef: "E"],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCKeywords: ["alps", "lake"],
                                             kCGImagePropertyIPTCCaptionAbstract: "A lake in the Alps",
                                             kCGImagePropertyIPTCCopyrightNotice: "© Someone"],
        ]
        let m = MetadataTests.inspect(MetadataTests.encode(.jpeg, properties: props), .jpeg)
        #expect(m.hasEXIF && m.hasGPS && m.hasIPTC)

        let exif = try #require(m.section(.exif))
        #expect(exif["Make"] == "TestCam")
        #expect(exif["Model"] == "T-1")
        #expect(exif["LensModel"] == "Test 50mm")
        #expect(exif["ISOSpeedRatings"] == "100")
        #expect(exif["ExposureTime"] == "1/250 s")
        #expect(exif["FNumber"] == "f/2.8")
        #expect(exif["FocalLength"] == "50 mm")
        #expect(exif["DateTimeOriginal"] == "2026:09:30 10:11:12")
        // TIFF tags lead, and keys are unique.
        #expect(exif.fields.prefix(2).map(\.key) == ["Make", "Model"])
        #expect(Set(exif.fields.map(\.key)).count == exif.fields.count)

        let gps = try #require(m.section(.gps))
        #expect(gps.fields.prefix(4).map(\.key) == ["Latitude", "LatitudeRef", "Longitude", "LongitudeRef"])
        #expect(gps["Latitude"] == "47.37")
        #expect(gps["LongitudeRef"] == "E")
        #expect(gps.text.contains("Longitude: 8.54"))

        let iptc = try #require(m.section(.iptc))
        #expect(iptc["Keywords"] == "alps, lake")
        #expect(iptc["Caption/Abstract"] == "A lake in the Alps")
        #expect(iptc["CopyrightNotice"] == "© Someone")

        // Inspector order, Structure last.
        let kinds = m.sections.map(\.kind)
        #expect(kinds == MetadataSection.Kind.allCases.filter(kinds.contains))
        #expect(kinds.last == .structure)
    }

    @Test func plainPNGHasOnlyProfileAndStructure() throws {
        let m = MetadataTests.inspect(MetadataTests.encode(.png), .png)
        #expect(m.section(.exif) == nil && m.section(.gps) == nil && m.section(.aiWorkflow) == nil)
        #expect(m.pngTextChunks.isEmpty && m.aiPayloads.isEmpty)
        let structure = try #require(m.section(.structure))
        #expect(structure["Alpha"] == "Yes")
        #expect(structure["Bit depth"] == "8 bits per channel")
        #expect(structure["Frames"] == "1")
        #expect(structure["Orientation"] == "1 (upright)")
        if m.iccProfileName != nil {
            let icc = try #require(m.section(.icc))
            #expect(icc["Name"] == m.iccProfileName)
            #expect(icc["Colour model"] == "RGB")
        }
    }

    @Test func binaryValuesBecomePlaceholders() {
        #expect(MetadataFormat.display(Data(count: 1234)) == "‹1234 bytes›")
        #expect(MetadataFormat.display([1, 2.5, "x"] as [Any]) == "1, 2.5, x")
        #expect(MetadataFormat.display(true) == "Yes")
        let fields = MetadataFormat.fields(["MakerNote": Data(count: 9), "Zed": 1, "Alpha": "a"], first: ["Zed"])
        #expect(fields.map(\.key) == ["Zed", "Alpha", "MakerNote"])
        #expect(fields.last?.value == "‹9 bytes›")
    }

    // MARK: PNG text chunks

    @Test func pngTextChunksKeepTheirTextCompressedOrNot() {
        let bodies: [(type: String, body: [UInt8])] = [
            ("tEXt", MetadataTests.tEXt("Title", "plain")),
            ("zTXt", Self.zTXt("parameters", Self.parameters)),
            ("iTXt", Self.iTXt("prompt", Self.graph, compressed: true, language: "it")),
            ("iTXt", Self.iTXt("Comment", "già fatto ✓", compressed: false)),
        ]
        let m = MetadataTests.inspect(Self.png(bodies), .png)
        let chunks = m.pngTextChunks
        #expect(chunks.map(\.type) == ["tEXt", "zTXt", "iTXt", "iTXt"])
        #expect(chunks.map(\.keyword) == ["Title", "parameters", "prompt", "Comment"])
        #expect(m.pngTextKeywords == chunks.map(\.keyword))
        #expect(chunks.map(\.text) == ["plain", Self.parameters, Self.graph, "già fatto ✓"])
        #expect(chunks.map(\.isCompressed) == [false, true, true, false])
        #expect(chunks[2].languageTag == "it")
        // Detection now sees inside compressed chunks.
        #expect(m.provenance == [.comfyUI, .a1111])
    }

    @Test func latin1TextAndDamagedStreams() {
        let latin1: [UInt8] = Array("Author".utf8) + [0] + [0x52, 0x65, 0x6E, 0xE9]   // "René" in Latin-1
        let broken: [UInt8] = Array("workflow".utf8) + [0, 0, 0x78, 0x9C, 0xFF, 0xFF, 0xFF]
        let chunks = PNGScanner.textChunks(in: Self.png([("tEXt", latin1), ("zTXt", broken)]))
        #expect(chunks.map(\.text) == ["René", nil])
        // The damaged chunk is still kept, bytes intact.
        #expect(chunks[1].raw == Data(Array("zTXt".utf8) + broken))
    }

    @Test func rawChunksRoundTrip() throws {
        let bodies: [(type: String, body: [UInt8])] = [
            ("tEXt", MetadataTests.tEXt("workflow", Self.workflow)),
            ("zTXt", Self.zTXt("prompt", Self.graph)),
            ("iTXt", Self.iTXt("Comment", "ciao", compressed: true)),
        ]
        let chunks = PNGScanner.textChunks(in: Self.png(bodies))
        #expect(chunks.count == 3)
        for (chunk, source) in zip(chunks, bodies) {
            #expect(chunk.raw == Data(Array(source.type.utf8) + source.body))
        }

        // Splice them into a clean PNG before IEND, as the writer will.
        #expect(PNGScanner.crc32(Data("IEND".utf8)) == 0xAE42_6082)
        let clean = MetadataTests.encode(.png)
        var spliced = Data(clean.dropLast(12))
        for chunk in chunks { spliced.append(chunk.encoded) }
        spliced.append(clean.suffix(12))
        #expect(PNGScanner.textChunks(in: spliced) == chunks)

        let first = chunks[0].encoded
        #expect(first.count == chunks[0].raw.count + 8)
        #expect(Array(first.prefix(4)) == [0, 0, 0, UInt8(bodies[0].body.count)])
        let source = try #require(CGImageSourceCreateWithData(spliced as CFData, nil))
        #expect(CGImageSourceCreateImageAtIndex(source, 0, nil) != nil)
    }

    // MARK: AI workflow

    @Test func comfyUIPayloadsAreCaptured() throws {
        let m = MetadataTests.inspect(Self.png([("tEXt", MetadataTests.tEXt("prompt", Self.graph)),
                                                ("zTXt", Self.zTXt("workflow", Self.workflow))]), .png)
        #expect(m.provenance == [.comfyUI])
        #expect(m.aiPayloads.map(\.name) == ["prompt", "workflow"])
        #expect(m.aiPayloads.map(\.text) == [Self.graph, Self.workflow])
        #expect(m.aiPayloads.allSatisfy { $0.source == .comfyUI && $0.isJSON })
        #expect(m.aiPayloads.map(\.location) == ["PNG tEXt chunk", "PNG zTXt chunk"])
        #expect(m.aiPayloads(from: .comfyUI).count == 2)

        let section = try #require(m.section(.aiWorkflow))
        #expect(section.fields.map(\.key) == ["Source", "prompt", "workflow"])
        #expect(section["Source"] == "ComfyUI")
        #expect(section["workflow"] == Self.workflow)
    }

    @Test func a1111PayloadInPNGAndInEXIFUserComment() throws {
        let png = MetadataTests.inspect(Self.png([("tEXt", MetadataTests.tEXt("parameters", Self.parameters))]), .png)
        #expect(png.aiPayloads == [ImageMetadata.AIPayload(source: .a1111, name: "parameters",
                                                           location: "PNG tEXt chunk", text: Self.parameters)])
        #expect(png.aiPayloads.first?.isJSON == false)
        #expect(png.section(.aiWorkflow)?["parameters"] == Self.parameters)

        let props: [CFString: Any] = [kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: Self.parameters]]
        let jpeg = MetadataTests.inspect(MetadataTests.encode(.jpeg, properties: props), .jpeg)
        #expect(jpeg.provenance == [.a1111])
        let payload = try #require(jpeg.aiPayloads.first)
        #expect(payload.source == .a1111 && payload.name == "UserComment" && payload.location == "EXIF UserComment")
        #expect(payload.text == Self.parameters)
        #expect(jpeg.section(.exif)?["UserComment"] == Self.parameters)
    }

    @Test func otherSourcesKeepTheirPayloads() throws {
        let fooocus = MetadataTests.inspect(Self.png([("tEXt", MetadataTests.tEXt("parameters", #"{"prompt":"x"}"#)),
                                                      ("tEXt", MetadataTests.tEXt("fooocus_scheme", "fooocus"))]), .png)
        #expect(fooocus.aiPayloads.map(\.source) == [.fooocus, .fooocus])
        #expect(fooocus.aiPayloads.map(\.name) == ["parameters", "fooocus_scheme"])

        let novel = MetadataTests.inspect(Self.png([("tEXt", MetadataTests.tEXt("Software", "NovelAI")),
                                                    ("tEXt", MetadataTests.tEXt("Comment", #"{"steps":28}"#))]), .png)
        #expect(novel.provenance == [.novelAI])
        #expect(novel.aiPayloads(from: .novelAI).map(\.name) == ["Software", "Comment"])

        let props: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFImageDescription: "a castle --v 6 Job ID: 1234-abcd"],
        ]
        let mj = MetadataTests.inspect(MetadataTests.encode(.jpeg, properties: props), .jpeg)
        #expect(mj.aiPayloads.map(\.text) == ["a castle --v 6 Job ID: 1234-abcd"])
        #expect(mj.section(.aiWorkflow)?["Source"] == "Midjourney")
    }

    @Test func c2paSectionSaysWhereItWasFound() throws {
        let m = MetadataTests.inspect(MetadataTests.withChunk(MetadataTests.encode(.png), type: "caBX", body: [0, 0, 0, 0]), .png)
        let section = try #require(m.section(.c2pa))
        #expect(section["Manifest"] == "Present")
        #expect(section["Found in"] == "PNG caBX chunk")
        // C2PA is not an AI workflow.
        #expect(m.section(.aiWorkflow) == nil)
    }
}
