import Foundation
import Testing
import UniformTypeIdentifiers
@testable import RescaleKit

/// "Keep AI workflow" for PNG output (PRD §10.2, §10.4 step 3; issue #14).
struct PNGSplicerTests {
    /// A raw chunk: length, type, body, CRC.
    static func chunk(_ type: String, _ body: Data) -> Data {
        var raw = Data(type.utf8)
        raw.append(body)
        var out = Data()
        withUnsafeBytes(of: UInt32(body.count).bigEndian) { out.append(contentsOf: $0) }
        out.append(raw)
        withUnsafeBytes(of: PNGScanner.crc32(raw).bigEndian) { out.append(contentsOf: $0) }
        return out
    }

    static func text(_ keyword: String, _ value: String) -> PNGScanner.TextChunk {
        PNGScanner.TextChunk(type: "tEXt", keyword: keyword, text: value, isCompressed: false, languageTag: "",
                             translatedKeyword: "", raw: Data("tEXt\(keyword)\0\(value)".utf8))
    }

    /// Every chunk of a PNG as (type, CRC valid); nil when the chunk run is broken
    /// or does not end exactly at `IEND`.
    static func walk(_ png: Data) -> [(type: String, crcValid: Bool)]? {
        let d = [UInt8](png)
        guard d.count >= 8, Array(d[0..<8]) == PNGScanner.signature else { return nil }
        var out: [(type: String, crcValid: Bool)] = []
        var i = 8
        while i + 12 <= d.count {
            let length = d[i..<i + 4].reduce(0) { $0 << 8 | Int($1) }
            guard i + 12 + length <= d.count else { return nil }
            let type = String(decoding: d[i + 4..<i + 8], as: UTF8.self)
            let stored = d[i + 8 + length..<i + 12 + length].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            out.append((type, PNGScanner.crc32(Data(d[i + 4..<i + 8 + length])) == stored))
            i += 12 + length
            if type == "IEND" { return i == d.count ? out : nil }
        }
        return nil
    }

    /// Loads `png` as a source through a temporary file.
    static func source(fromPNG png: Data) throws -> SourceImage {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("splice-\(UUID().uuidString).png")
        try png.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try SourceImage.load(url)
    }

    static let half = PixelSize(32, 24)

    // MARK: - Round trips

    @Test func resizedComfyUIKeepsItsGraphsByteForByte() throws {
        let original = PNGScanner.textChunks(in: Fixture.comfyUI.data)
        let out = try Fixture.comfyUI.roundTrip(spec: RenderSpec(target: Self.half, metadata: .keepMost))
        #expect(out.type == .png && out.size == Self.half)
        #expect(out.metadata.provenance == [.comfyUI])
        let kept = out.metadata.pngTextChunks
        #expect(kept.map(\.keyword) == ["prompt", "workflow"])
        #expect(kept.map(\.text) == original.map(\.text))
        #expect(kept.map(\.raw) == original.map(\.raw))
        #expect(out.metadata.aiPayloads.map(\.name) == ["prompt", "workflow"])
    }

    @Test func compressedChunksSurviveAndStillInflate() throws {
        let original = PNGScanner.textChunks(in: Fixture.compressedText.data)
        let out = try Fixture.compressedText.roundTrip(spec: RenderSpec(target: Self.half, metadata: .keepMost))
        let kept = out.metadata.pngTextChunks
        #expect(kept.map(\.raw) == original.map(\.raw))
        #expect(kept.map(\.type) == original.map(\.type))
        #expect(kept.allSatisfy { $0.isCompressed && $0.text != nil })
        #expect(kept.map(\.text) == PNGScanner.textChunks(in: Fixture.comfyUI.data).map(\.text))
        #expect(out.metadata.provenance == [.comfyUI])
    }

    @Test func a1111ParametersSurvive() throws {
        let original = PNGScanner.textChunks(in: Fixture.a1111PNG.data)
        let out = try Fixture.a1111PNG.roundTrip(spec: RenderSpec(target: Self.half, metadata: .keepMost))
        #expect(out.metadata.provenance == [.a1111])
        #expect(out.metadata.pngTextChunks.map(\.raw) == original.map(\.raw))
        #expect(out.metadata.pngTextChunks.first?.keyword == "parameters")
    }

    @Test(arguments: [Fixture.comfyUI, .a1111PNG, .compressedText])
    func outputIsAValidPNG(_ fixture: Fixture) throws {
        let out = try fixture.roundTrip(spec: RenderSpec(target: Self.half, metadata: .keepMost))
        let chunks = try #require(Self.walk(out.data))
        #expect(chunks.allSatisfy { $0.crcValid })
        #expect(chunks.first?.type == "IHDR" && chunks.last?.type == "IEND")
        // The carried chunks sit immediately before IEND, in source order.
        let sourceTypes = PNGScanner.textChunks(in: fixture.data).map(\.type)
        #expect(chunks.dropLast().suffix(sourceTypes.count).map(\.type) == sourceTypes)
        // ImageIO decoded it (`roundTrip` would have thrown) at the right size.
        #expect(out.size == Self.half)
    }

    @Test(arguments: [Fixture.comfyUI, .a1111PNG, .compressedText])
    func stripLeavesNoWorkflowChunks(_ fixture: Fixture) throws {
        let out = try fixture.roundTrip { $0.metadata.aiWorkflow = .strip }
        #expect(PNGSplicer.aiWorkflowChunks(in: out.metadata.pngTextChunks).isEmpty)
        #expect(out.metadata.provenance.isEmpty)
        #expect(out.metadata.aiPayloads.isEmpty)
    }

    @Test func jpegOutputGetsNothingAndIsNotCorrupted() throws {
        let source = try Fixture.load(.comfyUI)
        var spec = RenderSpec(target: Self.half, format: .jpeg)
        let kept = try Renderer.produce(source, spec: spec)
        // Exactly what the encoder wrote: nothing was added.
        let plain = try Renderer.encode(try Renderer.render(source, spec: spec), spec: spec, sourceType: source.type)
        #expect(kept == plain)
        #expect(kept.prefix(2) == Data([0xFF, 0xD8]) && kept.suffix(2) == Data([0xFF, 0xD9]))
        #expect(kept.range(of: Data("workflow".utf8)) == nil)
        let out = try FixtureProbe.inspect(kept)
        #expect(out.type == .jpeg && out.size == Self.half)
        #expect(out.metadata.provenance.isEmpty && out.metadata.pngTextChunks.isEmpty)
        spec.metadata.aiWorkflow = .strip
        #expect(try Renderer.produce(source, spec: spec) == kept)
    }

    @Test func nonPNGSourceWrittenAsPNGGetsNothing() throws {
        let out = try Fixture.a1111JPEG.roundTrip { $0.format = .png }
        #expect(out.type == .png)
        #expect(PNGSplicer.aiWorkflowChunks(in: out.metadata.pngTextChunks).isEmpty)
    }

    @Test func xmpAndC2PAChunksAreNotCarried() throws {
        let packet = #"<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/" dc:format="image/png"/></rdf:RDF></x:xmpmeta>"#
        let xmp = Self.chunk("iTXt", Data("XML:com.adobe.xmp\0\0\0\0\0\(packet)".utf8))
        let c2pa = Self.chunk("caBX", Data("jumb c2pa not a real manifest".utf8))
        var png = Fixture.comfyUI.data
        let iend = try #require(PNGSplicer.iendOffset(in: png))
        png.insert(contentsOf: xmp + c2pa, at: iend)

        let source = try Self.source(fromPNG: png)
        #expect(source.metadata.pngTextKeywords == ["prompt", "workflow", "XML:com.adobe.xmp"])
        #expect(source.metadata.provenance.contains(.c2pa))
        #expect(PNGSplicer.aiWorkflowChunks(in: source.metadata.pngTextChunks).map(\.keyword) == ["prompt", "workflow"])

        // XMP switched off, so whatever the XMP writer does, no packet belongs here.
        var spec = RenderSpec(target: Self.half)
        spec.metadata.xmp = .strip
        let out = try FixtureProbe.inspect(try Renderer.produce(source, spec: spec))
        #expect(out.metadata.pngTextKeywords == ["prompt", "workflow"])
        #expect(!PNGScanner.hasChunk("caBX", in: out.data))
        #expect(out.metadata.provenance == [.comfyUI])
        #expect(try #require(Self.walk(out.data)).allSatisfy { $0.crcValid })
    }

    // MARK: - Selection

    @Test func selectionTakesToolKeywordsInSourceOrder() {
        let chunks = ["Title", "sd-metadata", "XML:com.adobe.xmp", "invokeai_graph", "Software", "parameters",
                      "fooocus_scheme", "Comment", "invokeai_metadata", "workflow", "prompt", "Author"]
            .map { Self.text($0, "x") }
        #expect(PNGSplicer.aiWorkflowChunks(in: chunks).map(\.keyword)
                == ["sd-metadata", "invokeai_graph", "parameters", "fooocus_scheme", "invokeai_metadata", "workflow", "prompt"])
    }

    @Test func selectionTakesNovelAIChunksOnlyFromNovelAI() {
        let keys = ["Title", "Description", "Software", "Source", "Comment", "Author", "XML:com.adobe.xmp"]
        let novel = keys.map { Self.text($0, $0 == "Software" ? "NovelAI" : "{}") }
        #expect(PNGSplicer.aiWorkflowChunks(in: novel).map(\.keyword)
                == ["Title", "Description", "Software", "Source", "Comment"])
        let other = keys.map { Self.text($0, $0 == "Software" ? "GIMP" : "{}") }
        #expect(PNGSplicer.aiWorkflowChunks(in: other).isEmpty)
    }

    @Test func selectionTakesMidjourneyDescriptionOnly() {
        let chunks = [Self.text("Description", "a cat --v 6 Job ID: 1234"), Self.text("Software", "x"),
                      Self.text("Comment", "y")]
        #expect(PNGSplicer.aiWorkflowChunks(in: chunks).map(\.keyword) == ["Description"])
        #expect(PNGSplicer.aiWorkflowChunks(in: [Self.text("Description", "a holiday photo")]).isEmpty)
    }

    // MARK: - Disclosure (review 2026-09-30, S3)

    static let privateNote = "Placeholder private note, nothing to do with AI"

    /// A plain PNG holding `chunks`, loaded as a source.
    static func source(holding chunks: [PNGScanner.TextChunk]) throws -> SourceImage {
        try source(fromPNG: PNGSplicer.splice(chunks, into: MetadataTests.encode(.png)))
    }

    /// Whatever Keep carries is listed in the AI workflow section, reachable
    /// from a badge, and removed by Strip: ordinary text under a tool keyword too.
    @Test(arguments: PNGSplicer.workflowKeywords.sorted())
    func ordinaryTextUnderAToolKeywordIsShownAndFollowsTheSwitch(_ keyword: String) throws {
        let source = try Self.source(holding: [Self.text(keyword, Self.privateNote)])
        let section = try #require(source.metadata.section(.aiWorkflow))
        #expect(section.fields.contains { $0.value == Self.privateNote })
        #expect(section.text.contains(Self.privateNote))
        #expect(source.metadata.badges.contains { $0.tone == .provenance })

        // The default policy keeps the AI workflow, and with it this chunk.
        let kept = try FixtureProbe.inspect(try Renderer.produce(source, spec: RenderSpec(target: source.size)))
        #expect(kept.metadata.pngTextChunks.map(\.raw) == source.metadata.pngTextChunks.map(\.raw))
        let state = MetadataPolicy.switchState(of: .aiWorkflow, for: source, spec: RenderSpec(target: source.size))
        #expect(state.isEnabled)

        var spec = RenderSpec(target: source.size)
        spec.metadata.aiWorkflow = .strip
        let stripped = try FixtureProbe.inspect(try Renderer.produce(source, spec: spec))
        #expect(stripped.metadata.pngTextChunks.isEmpty && !stripped.contains(Self.privateNote))
        #expect(stripped.metadata.section(.aiWorkflow) == nil)

        // A text chunk has nowhere to go outside PNG, and the switch says so.
        for format in [OutputFormat.jpeg, .heic, .tiff] {
            let spec = RenderSpec(target: source.size, format: format)
            let state = MetadataPolicy.switchState(of: .aiWorkflow, for: source, spec: spec)
            #expect(!state.isEnabled && state.note == MetadataPolicy.requiresPNGNote, "\(format)")
        }
        #expect(!(try FixtureProbe.inspect(try Renderer.produce(source, spec: RenderSpec(target: source.size, format: .jpeg))))
            .contains(Self.privateNote))
    }

    @Test(arguments: ["prompt", "parameters"])
    func unrecognisedTextIsNamedAsSuch(_ keyword: String) throws {
        let metadata = try Self.source(holding: [Self.text(keyword, Self.privateNote)]).metadata
        #expect(metadata.provenance.isEmpty && metadata.aiPayloads.isEmpty)
        #expect(metadata.unrecognisedAIChunks.map(\.keyword) == [keyword])
        let section = try #require(metadata.section(.aiWorkflow))
        #expect(section["Source"] == "Not recognised" && section[keyword] == Self.privateNote)
        #expect(section.note?.contains("“\(keyword)”") == true && section.note?.contains("kept or stripped with the AI workflow") == true)
        #expect(metadata.badges.filter { $0.tone == .provenance }.map(\.label) == ["AI text"])
    }

    /// Beside a detected source the text is listed after its payloads, under the same switch.
    @Test func unrecognisedTextBesideADetectedSource() throws {
        let graphs = PNGScanner.textChunks(in: Fixture.comfyUI.data)
        let source = try Self.source(holding: graphs + [Self.text("parameters", Self.privateNote)])
        #expect(source.metadata.provenance == [.comfyUI])
        #expect(source.metadata.aiPayloads.map(\.name) == ["prompt", "workflow"])
        let section = try #require(source.metadata.section(.aiWorkflow))
        #expect(section.fields.map(\.key) == ["Source", "prompt", "workflow", "parameters"])
        #expect(section["Source"] == "ComfyUI" && section["parameters"] == Self.privateNote)
        #expect(section.note?.contains("“parameters”") == true)
        #expect(source.metadata.badges.filter { $0.tone == .provenance }.map(\.label) == ["ComfyUI"])
    }

    /// Recognised payloads and plain files are as before: every carried chunk is a listed payload, with no remark.
    @Test(arguments: [Fixture.comfyUI, .a1111PNG, .compressedText])
    func everyCarriedChunkOfAFixtureIsAListedPayload(_ fixture: Fixture) throws {
        let metadata = try Fixture.load(fixture).metadata
        let carried = PNGSplicer.aiWorkflowChunks(in: metadata.pngTextChunks)
        #expect(!carried.isEmpty && metadata.unrecognisedAIChunks.isEmpty)
        let section = try #require(metadata.section(.aiWorkflow))
        #expect(section.note == nil)
        for chunk in carried { #expect(section[chunk.keyword] == chunk.text) }
        #expect(carried.map(\.text) == metadata.aiPayloads.map(\.text))
    }

    @Test func textUnderOtherKeywordsIsNeitherCarriedNorShown() throws {
        let source = try Self.source(holding: ["Comment", "Description", "Title", "Author"].map { Self.text($0, Self.privateNote) })
        #expect(source.metadata.section(.aiWorkflow) == nil && source.metadata.unrecognisedAIChunks.isEmpty)
        #expect(!source.metadata.badges.contains { $0.tone == .provenance })
        let out = try FixtureProbe.inspect(try Renderer.produce(source, spec: RenderSpec(target: source.size)))
        #expect(!out.contains(Self.privateNote))
    }

    // MARK: - Splice

    @Test func spliceInsertsBeforeIENDAndTouchesNothingElse() throws {
        let png = try Renderer.produce(try Fixture.load(.camera), spec: RenderSpec(target: Self.half, format: .png,
                                                                                       metadata: .stripAll))
        let chunks = [Self.text("prompt", "{\"1\":{}}"), Self.text("workflow", "{}")]
        let out = PNGSplicer.splice(chunks, into: png)
        let inserted = chunks[0].encoded + chunks[1].encoded
        #expect(out == Data(png.dropLast(12)) + inserted + Data(png.suffix(12)))
        #expect(PNGScanner.textChunks(in: out).map(\.raw) == chunks.map(\.raw))
        #expect(try #require(Self.walk(out)).allSatisfy { $0.crcValid })
        // A slice with a non-zero start index splices the same way.
        let padded = Data([1, 2, 3]) + png
        #expect(PNGSplicer.splice(chunks, into: padded[3...]) == out)
    }

    @Test func spliceReturnsTheInputWhenItCannotSplice() throws {
        let chunks = [Self.text("prompt", "{}")]
        let png = Fixture.comfyUI.data
        let jpeg = Fixture.camera.data
        #expect(PNGSplicer.splice(chunks, into: jpeg) == jpeg)
        #expect(PNGSplicer.splice(chunks, into: Data()) == Data())
        let truncated = Data(png.dropLast(12))            // no IEND
        #expect(PNGSplicer.splice(chunks, into: truncated) == truncated)
        let cut = Data(png.prefix(40))                    // ends mid-chunk
        #expect(PNGSplicer.splice(chunks, into: cut) == cut)
        #expect(PNGSplicer.splice([], into: png) == png)
    }

    @Test func aKeywordAlreadyWrittenIsNotDuplicated() throws {
        let source = try Fixture.load(.comfyUI)
        let spec = Fixture.spec(for: source)
        let once = try Renderer.produce(source, spec: spec)
        #expect(PNGSplicer.keepingAIWorkflow(once, from: source, spec: spec) == once)
        // Only `prompt` present: `workflow` alone is added.
        let plain = try Renderer.encode(try Renderer.render(source, spec: spec), spec: spec, sourceType: source.type)
        let partial = PNGSplicer.splice([source.metadata.pngTextChunks[0]], into: plain)
        let out = PNGSplicer.keepingAIWorkflow(partial, from: source, spec: spec)
        #expect(PNGScanner.textChunks(in: out).map(\.keyword) == ["prompt", "workflow"])
    }
}
