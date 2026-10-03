import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import RescaleKit

/// The per-image metadata budget (review S1): what the scanners decode and keep
/// is bounded for the whole file, not per element, and what did not fit is reported.
struct MetadataBudgetTests {
    typealias Chunk = (type: String, body: [UInt8])

    static func inspect(_ data: Data, _ type: UTType, _ budget: MetadataBudget) -> ImageMetadata {
        let src = CGImageSourceCreateWithData(data as CFData, nil)!
        return ImageMetadata.inspect(source: src, data: data, type: type, budget: budget)
    }

    static func text(_ count: Int) -> String { String(repeating: "lorem ", count: count / 6 + 1).prefix(count).description }

    // MARK: PNG text

    @Test func severalLegalChunksCannotExceedTheTotal() throws {
        let chunks: [Chunk] = [
            ("tEXt", MetadataTests.tEXt("Title", Self.text(40))),
            ("zTXt", MetadataContentsTests.zTXt("Comment", Self.text(40))),
            ("iTXt", MetadataContentsTests.iTXt("Author", Self.text(40), compressed: true)),
            ("iTXt", MetadataContentsTests.iTXt("Source", Self.text(40), compressed: false)),
            ("tEXt", MetadataTests.tEXt("Software", "tiny")),
        ]
        let png = MetadataContentsTests.png(chunks)
        // Each fits on its own; only two fit together. The small one after them still does.
        var budget = MetadataBudget(bytes: 100)
        let kept = PNGScanner.textChunks(in: png, budget: &budget)
        #expect(kept.map(\.keyword) == ["Title", "Comment", "Software"])
        #expect(kept.reduce(0) { $0 + ($1.text?.utf8.count ?? 0) } <= 100)
        #expect(budget.skipped == [.pngText(count: 2)] && budget.bytes == 16)

        let m = Self.inspect(png, .png, MetadataBudget(bytes: 100))
        #expect(m.pngTextKeywords == ["Title", "Comment", "Software"])
        #expect(m.skipped == [.pngText(count: 2)])
        let note = try #require(m.section(.structure)?.note)
        #expect(note.hasPrefix("2 PNG text chunks were over the metadata size limit"))
        #expect(note.contains("not carried into the saved file"))
    }

    @Test func chunkCountIsBounded() {
        let png = MetadataContentsTests.png((0..<6).map { ("tEXt", MetadataTests.tEXt("k\($0)", "")) })
        var budget = MetadataBudget(elements: 4)
        #expect(PNGScanner.textChunks(in: png, budget: &budget).map(\.keyword) == ["k0", "k1", "k2", "k3"])
        #expect(budget.skipped == [.pngText(count: 2)] && budget.elements == 0)
        #expect(MetadataBudget.Skip.pngText(count: 1).note.hasPrefix("1 PNG text chunk was over"))
    }

    /// The ceiling holds on the buffer that ends the stream too, not only between buffers.
    @Test func inflateCeilingIsCheckedBeforeTheStreamEnds() {
        let stream = Data(MetadataContentsTests.deflate(Self.text(100)))
        #expect(PNGScanner.inflated(stream, limit: 100) == .data(Data(Self.text(100).utf8)))
        #expect(PNGScanner.inflated(stream, limit: 99) == .overLimit)
        #expect(PNGScanner.inflated(stream, limit: 0) == .overLimit)
        #expect(PNGScanner.inflated(stream.dropLast(4)) == .damaged)
        // Across several 64 KiB buffers.
        let long = Data(MetadataContentsTests.deflate(Self.text(200_000)))
        #expect(PNGScanner.inflated(long, limit: 199_999) == .overLimit)
        #expect(PNGScanner.inflated(long, limit: 200_000) == .data(Data(Self.text(200_000).utf8)))
        // The work is what was inflated, kept or not: never more than a byte past the limit.
        for (limit, spent) in [(100, 100), (99, 100), (0, 1), (199_999, 200_000), (200_000, 200_000)] {
            var work = 0
            _ = PNGScanner.inflated(limit < 200 ? stream : long, limit: limit, work: &work)
            #expect(work == spent, "\(limit)")
        }
    }

    @Test func largeUncompressedTextAndCompressedTextShareTheBudget() {
        let png = MetadataContentsTests.png([
            ("tEXt", MetadataTests.tEXt("Comment", Self.text(5000))),
            ("zTXt", MetadataContentsTests.zTXt("Title", Self.text(900))),
            ("zTXt", MetadataContentsTests.zTXt("Author", Self.text(200))),
        ])
        var budget = MetadataBudget(bytes: 1000)
        let kept = PNGScanner.textChunks(in: png, budget: &budget)
        // The big plain chunk is not copied at all; the stream that inflates past what is left is dropped.
        #expect(kept.map(\.keyword) == ["Title"] && kept.first?.text == Self.text(900))
        #expect(budget.skipped == [.pngText(count: 2)])
    }

    /// A compressed chunk that could not be kept is not inflated at all.
    @Test func noElementLeftMeansNoInflate() {
        let png = MetadataContentsTests.png([
            ("tEXt", MetadataTests.tEXt("a", "")),
            ("zTXt", MetadataContentsTests.zTXt("b", Self.text(50))),
            ("iTXt", MetadataContentsTests.iTXt("c", Self.text(50), compressed: true)),
        ])
        var budget = MetadataBudget(elements: 1, work: 1000)
        #expect(PNGScanner.textChunks(in: png, budget: &budget).map(\.keyword) == ["a"])
        #expect(budget.work == 1000 && budget.skipped == [.pngText(count: 2)])
    }

    /// Every attempt spends what it inflated, kept or not, so a stream that is
    /// over the limit cannot be inflated again and again for free.
    @Test func rejectedStreamsCannotRepeatTheWork() {
        let png = MetadataContentsTests.png((0..<10).map { ("zTXt", MetadataContentsTests.zTXt("k\($0)", Self.text(1000))) }
            + [("tEXt", MetadataTests.tEXt("Software", "tiny"))])
        // Inflating stops one byte past the limit, well short of a buffer: each attempt costs one.
        var budget = MetadataBudget(bytes: 100, work: 11 * PNGScanner.inflateBuffer)
        #expect(PNGScanner.textChunks(in: png, budget: &budget).map(\.keyword) == ["Software"])
        #expect(budget.work == PNGScanner.inflateBuffer && budget.skipped == [.pngText(count: 10)])

        // Spent after three attempts; the rest are not inflated, and the plain chunk does not need to be.
        budget = MetadataBudget(bytes: 100, work: 3 * PNGScanner.inflateBuffer)
        #expect(PNGScanner.textChunks(in: png, budget: &budget).map(\.keyword) == ["Software"])
        #expect(budget.work == 0 && budget.skipped == [.pngText(count: 10)] && budget.bytes == 96)

        // Past a buffer, an attempt costs what it inflated: one byte past the limit.
        let long = MetadataContentsTests.png([("zTXt", MetadataContentsTests.zTXt("k", Self.text(300_000)))])
        budget = MetadataBudget(bytes: 200_000)
        #expect(PNGScanner.textChunks(in: long, budget: &budget).isEmpty)
        #expect(budget.work == MetadataBudget.defaultWork - 200_001 && budget.skipped == [.pngText(count: 1)])
    }

    /// However little an attempt inflates, it costs a buffer's worth of work,
    /// so the allowance bounds how many attempts are made, not only their output.
    @Test func everyAttemptCostsAtLeastABuffer() {
        let png = MetadataContentsTests.png((0..<5).map { ("zTXt", MetadataContentsTests.zTXt("k\($0)", "xx")) })
        var budget = MetadataBudget(work: 3 * PNGScanner.inflateBuffer)
        #expect(PNGScanner.textChunks(in: png, budget: &budget).map(\.keyword) == ["k0", "k1", "k2"])
        #expect(budget.work == 0 && budget.skipped == [.pngText(count: 2)])
    }

    /// A chunk is inflated no further than the work left, whatever room there is
    /// to keep it: a stream longer than that is over the limit.
    @Test func inflateLimitIsHeldToTheWorkLeft() {
        let png = MetadataContentsTests.png([("zTXt", MetadataContentsTests.zTXt("k", Self.text(1000)))])
        var budget = MetadataBudget(work: 999)
        #expect(PNGScanner.textChunks(in: png, budget: &budget).isEmpty)
        #expect(budget.work == 0 && budget.skipped == [.pngText(count: 1)])

        budget = MetadataBudget(work: 1000)
        #expect(PNGScanner.textChunks(in: png, budget: &budget).map(\.text) == [Self.text(1000)])
        #expect(budget.work == 0 && budget.skipped.isEmpty)
    }

    /// A damaged stream spends what it inflated before it broke off; once the
    /// work is spent, damaged chunks are skipped like any other.
    @Test func damagedStreamsSpendWork() {
        let damaged = Array("workflow".utf8) + [0, 0] + MetadataContentsTests.deflate(Self.text(100_000)).dropLast(4)
        let png = MetadataContentsTests.png(Array(repeating: ("zTXt", damaged), count: 5))
        var budget = MetadataBudget(work: 200_000)
        #expect(PNGScanner.textChunks(in: png, budget: &budget).map(\.text) == [nil, nil])
        #expect(budget.work == 0 && budget.skipped == [.pngText(count: 3)])
        #expect(budget.elements == MetadataBudget.defaultElements - 2)

        // Even one that breaks off at once: with no work left, nothing is attempted.
        let broken: [UInt8] = Array("workflow".utf8) + [0, 0, 0x78, 0x9C, 0xFF, 0xFF, 0xFF]
        budget = MetadataBudget(work: 0)
        #expect(PNGScanner.textChunks(in: MetadataContentsTests.png([("zTXt", broken)]), budget: &budget).isEmpty)
        #expect(budget.skipped == [.pngText(count: 1)])
    }

    /// A damaged stream is not a budget matter: kept without text, as before, and not reported.
    @Test func damagedChunkIsKeptNotSkipped() {
        let broken: [UInt8] = Array("workflow".utf8) + [0, 0, 0x78, 0x9C, 0xFF, 0xFF, 0xFF]
        var budget = MetadataBudget(bytes: 10)
        let kept = PNGScanner.textChunks(in: MetadataContentsTests.png([("zTXt", broken)]), budget: &budget)
        #expect(kept.map(\.text) == [nil] && budget.skipped.isEmpty && budget.elements == MetadataBudget.defaultElements - 1)
    }

    /// The default must not cut real files: a ComfyUI graph runs to a few MB.
    @Test func defaultBudgetReadsRealisticFiles() throws {
        for fixture in Fixture.allCases {
            let m = try Fixture.load(fixture).metadata
            #expect(m.skipped.isEmpty && m.section(.structure)?.note == nil, "\(fixture)")
        }
        let graph = #"{"3":{"class_type":"KSampler","inputs":{"text":""# + Self.text(4 << 20) + #""}}}"#
        let png = MetadataContentsTests.png([("tEXt", MetadataTests.tEXt("prompt", graph)),
                                             ("zTXt", MetadataContentsTests.zTXt("workflow", graph))])
        let m = MetadataTests.inspect(png, .png)
        #expect(m.skipped.isEmpty && m.provenance == [.comfyUI])
        #expect(m.pngTextChunks.map(\.text) == [graph, graph])
        // Only the compressed copy is inflated, once.
        var budget = MetadataBudget()
        _ = PNGScanner.textChunks(in: png, budget: &budget)
        #expect(budget.work == MetadataBudget.defaultWork - graph.utf8.count)
    }

    /// Keep re-emits the chunks the source holds, so a skipped one is not
    /// carried; the note says so rather than implying everything was kept.
    @Test func skippedChunkIsNotCarriedByKeep() throws {
        let png = MetadataContentsTests.png([
            ("tEXt", MetadataTests.tEXt("prompt", MetadataContentsTests.graph)),
            ("tEXt", MetadataTests.tEXt("workflow", MetadataContentsTests.workflow + Self.text(500))),
        ])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("budget-\(UUID().uuidString).png")
        try png.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let loaded = try SourceImage.load(url)
        #expect(loaded.metadata.skipped.isEmpty && loaded.metadata.pngTextKeywords == ["prompt", "workflow"])

        let metadata = Self.inspect(png, .png, MetadataBudget(bytes: 200))
        #expect(metadata.pngTextKeywords == ["prompt"] && metadata.skipped == [.pngText(count: 1)])
        #expect(metadata.provenance == [.comfyUI] && metadata.aiPayloads.map(\.name) == ["prompt"])
        let source = SourceImage(url: url, image: loaded.image, size: loaded.size, fileSize: loaded.fileSize,
                                 type: loaded.type, metadata: metadata, properties: loaded.properties)
        let out = try Renderer.produce(source, spec: RenderSpec(target: source.size, metadata: .keepMost))
        #expect(PNGScanner.textChunks(in: out).map(\.keyword) == ["prompt"])
        #expect(metadata.section(.structure)?.note?.contains("not carried into the saved file") == true)
    }

    // MARK: HEIF

    static func be(_ n: Int, _ size: Int = 4) -> [UInt8] { (0..<size).reversed().map { UInt8(n >> ($0 * 8) & 0xFF) } }
    static func box(_ type: String, _ payload: [UInt8]) -> [UInt8] { be(payload.count + 8) + Array(type.utf8) + payload }

    /// A bare ISO BMFF file whose XMP item is `packet`, read `extents` times over.
    static func heif(packet: String, extents: Int) -> Data {
        let ftyp = box("ftyp", Array("heic".utf8) + be(0))
        let infe = box("infe", [2, 0, 0, 0] + be(1, 2) + be(0, 2) + Array("mime".utf8) + [0]
            + Array(XMPScanner.mimeType.utf8) + [0])
        let iinf = box("iinf", be(0) + be(1, 2) + infe)
        func meta(at offset: Int) -> [UInt8] {
            let extent = be(offset) + be(packet.utf8.count)
            let iloc = box("iloc", be(0) + [0x44, 0x00] + be(1, 2) + be(1, 2) + be(0, 2) + be(extents, 2)
                + (0..<extents).flatMap { _ in extent })
            return box("meta", be(0) + iinf + iloc)
        }
        let offset = ftyp.count + meta(at: 0).count + 8
        return Data(ftyp + meta(at: offset) + box("mdat", Array(packet.utf8)))
    }

    @Test func joinedExtentsCannotExceedTheBudget() {
        let packet = XMPDetectionTests.packet, size = packet.utf8.count
        var budget = MetadataBudget(bytes: size * 3)
        #expect(XMPScanner.packet(in: Self.heif(packet: packet, extents: 1), type: .heic, pngChunks: nil, budget: &budget)
            == .found(packet: packet, extended: nil))
        #expect(budget.bytes == size * 2 && budget.skipped.isEmpty)

        // Extents may name the same bytes again: each is legal, the join is larger than the file.
        let repeated = Self.heif(packet: packet, extents: 4)
        #expect(repeated.count < size * 4)
        #expect(XMPScanner.packet(in: repeated, type: .heic, pngChunks: nil, budget: &budget) == .absent)
        #expect(budget.skipped == [.xmpPacket] && budget.bytes == size * 2)

        var enough = MetadataBudget(bytes: size * 4)
        #expect(XMPScanner.packet(in: repeated, type: .heic, pngChunks: nil, budget: &enough)
            == .found(packet: String(repeating: packet, count: 4), extended: nil))
        #expect(enough.bytes == 0)
        #expect(MetadataBudget.Skip.xmpPacket.note.contains("not carried into the saved file"))
    }
}
