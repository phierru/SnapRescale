import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import RescaleKit

/// JPEG extended XMP is merged only when it is the main packet's own and
/// assembles exactly (review G3, XMP Part 3 §1.1.3.1).
struct ExtendedXMPTests {
    static let guid = String(repeating: "A", count: 32)
    static let otherGUID = String(repeating: "B", count: 32)
    static let extended = XMPDetectionTests.packet.replacingOccurrences(of: "xmp:Rating=\"4\"", with: "xmp:Label=\"Blue\"")
    static let bytes = Array(extended.utf8)

    /// `XMPDetectionTests.packet`, naming `guid` as its extension.
    static func main(naming guid: String, prefix: String = "xmpNote") -> String {
        XMPDetectionTests.packet.replacingOccurrences(of: "xmp:Rating=\"4\"", with:
            "xmlns:\(prefix)=\"http://ns.adobe.com/xmp/note/\" xmp:Rating=\"4\" \(prefix):HasExtendedXMP=\"\(guid)\"")
    }

    struct Portion {
        var guid = ExtendedXMPTests.guid
        var total = ExtendedXMPTests.bytes.count
        let range: Range<Int>
        /// Where the portion says it goes; its own start unless the test lies about it.
        var offset: Int?

        init(_ range: Range<Int>, guid: String = ExtendedXMPTests.guid, total: Int = ExtendedXMPTests.bytes.count,
             offset: Int? = nil) {
            self.range = range
            self.guid = guid
            self.total = total
            self.offset = offset
        }

        var body: [UInt8] {
            XMPScanner.jpegExtensionNamespace + Array(guid.utf8) + MetadataBudgetTests.be(total)
                + MetadataBudgetTests.be(offset ?? range.lowerBound) + ExtendedXMPTests.bytes[range]
        }
    }

    /// A JPEG with the portions in the order given, then the main packet.
    static func jpeg(_ portions: [Portion], main: String = main(naming: guid), mainFirst: Bool = false) -> Data {
        var bodies = portions.map(\.body)
        let packet = XMPScanner.jpegNamespace + Array(main.utf8)
        bodies.insert(packet, at: mainFirst ? 0 : bodies.count)
        // Each goes in right after SOI, so the last inserted comes first.
        return bodies.reversed().reduce(MetadataTests.encode(.jpeg)) {
            XMPDetectionTests.withSegment($0, marker: 0xE1, body: $1)
        }
    }

    static var thirds: [Range<Int>] {
        let n = bytes.count
        return [0..<n / 3, n / 3..<2 * n / 3, 2 * n / 3..<n]
    }

    static func expectIgnored(_ jpeg: Data, _ comment: Comment) throws {
        let m = MetadataTests.inspect(jpeg, .jpeg)
        #expect(m.xmpExtendedPacket == nil && m.skipped == [.extendedXMP], comment)
        let xmp = try #require(m.section(.xmp))
        // The main packet stands; nothing of the extension is shown, and the section says why.
        #expect(xmp["xmp:Rating"] == "4" && xmp["xmp:Label"] == nil, comment)
        #expect(xmp.note == MetadataBudget.Skip.extendedXMP.note, comment)
        #expect(m.section(.structure)?.note == nil, comment)
    }

    @Test func matchingGroupIsMergedInAnyOrder() throws {
        let t = Self.thirds
        for order in [[0, 1, 2], [2, 1, 0], [1, 2, 0], [2, 0, 1]] {
            for mainFirst in [false, true] {
                let m = MetadataTests.inspect(Self.jpeg(order.map { Portion(t[$0]) }, mainFirst: mainFirst), .jpeg)
                #expect(m.xmpExtendedPacket == Self.extended && m.skipped.isEmpty, "\(order) \(mainFirst)")
                let xmp = try #require(m.section(.xmp))
                #expect(xmp["xmp:Rating"] == "4" && xmp["xmp:Label"] == "Blue" && xmp.note == nil)
            }
        }
        // Association is by namespace, whatever the prefix.
        let m = MetadataTests.inspect(Self.jpeg([Portion(0..<Self.bytes.count)],
                                                main: Self.main(naming: Self.guid, prefix: "n")), .jpeg)
        #expect(m.xmpExtendedPacket == Self.extended && m.skipped.isEmpty)
    }

    @Test func unrelatedGroupIsIgnored() throws {
        let whole = 0..<Self.bytes.count
        // Another packet's extension, and one the main packet does not ask for at all.
        try Self.expectIgnored(Self.jpeg([Portion(whole, guid: Self.otherGUID)]), "other GUID")
        try Self.expectIgnored(Self.jpeg([Portion(whole)], main: XMPDetectionTests.packet), "no reference")
        try Self.expectIgnored(Self.jpeg([Portion(whole)], main: Self.main(naming: "AAAA")), "short reference")

        // Its own extension is still merged next to a stranger's, which is reported.
        let m = MetadataTests.inspect(Self.jpeg([Portion(whole, guid: Self.otherGUID), Portion(whole)]), .jpeg)
        #expect(m.xmpExtendedPacket == Self.extended && m.skipped == [.extendedXMP])
        #expect(m.section(.xmp)?["xmp:Label"] == "Blue" && m.section(.xmp)?.note != nil)
    }

    @Test func incompleteOrInconsistentGroupIsIgnored() throws {
        let t = Self.thirds, n = Self.bytes.count
        try Self.expectIgnored(Self.jpeg([Portion(t[0]), Portion(t[2])]), "gap")
        try Self.expectIgnored(Self.jpeg([Portion(t[1]), Portion(t[2])]), "no start")
        try Self.expectIgnored(Self.jpeg([Portion(t[0]), Portion(t[1])]), "no end")
        try Self.expectIgnored(Self.jpeg([Portion(t[0]), Portion(t[0].lowerBound..<t[1].upperBound), Portion(t[2])]),
                               "overlap")
        try Self.expectIgnored(Self.jpeg([Portion(t[0]), Portion(t[1]), Portion(t[1]), Portion(t[2])]), "repeat")
        try Self.expectIgnored(Self.jpeg([Portion(t[0]), Portion(t[1], total: n + 1), Portion(t[2])]), "totals differ")
        try Self.expectIgnored(Self.jpeg([Portion(0..<n, total: n - 1)]), "longer than its total")
        try Self.expectIgnored(Self.jpeg([Portion(0..<n, total: n + 1)]), "shorter than its total")
        try Self.expectIgnored(Self.jpeg([Portion(t[0]), Portion(t[1], offset: t[2].lowerBound), Portion(t[2], offset: t[1].lowerBound)]),
                               "offsets that do not tile")
        try Self.expectIgnored(Self.jpeg([Portion(0..<0, total: 0)]), "empty")
    }

    @Test func extensionDrawsOnTheBudget() {
        let jpeg = Self.jpeg(Self.thirds.map { Portion($0) }), n = Self.bytes.count
        var budget = MetadataBudget(bytes: n - 1)
        guard case .found(_, let extended) = XMPScanner.packet(in: jpeg, type: .jpeg, pngChunks: nil, budget: &budget)
        else { Issue.record("no packet"); return }
        #expect(extended == nil && budget.skipped == [.extendedXMP] && budget.bytes == n - 1)

        budget = MetadataBudget(bytes: n)
        #expect(XMPScanner.packet(in: jpeg, type: .jpeg, pngChunks: nil, budget: &budget)
            == .found(packet: Self.main(naming: Self.guid), extended: Self.extended))
        #expect(budget.skipped.isEmpty && budget.bytes == 0)
    }

    /// What is ignored on load is not merged into the saved packet either.
    @Test func ignoredExtensionIsNotWritten() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("xmp-ext-\(UUID().uuidString).jpg")
        try Self.jpeg([Portion(0..<Self.bytes.count, guid: Self.otherGUID)]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try SourceImage.load(url)
        let out = try FixtureProbe.inspect(Renderer.produce(source, spec: RenderSpec(target: source.size, metadata: .keepMost)))
        #expect(out.metadata.section(.xmp)?["xmp:Rating"] == "4")
        #expect(out.metadata.section(.xmp)?["xmp:Label"] == nil && out.metadata.xmpExtendedPacket == nil)
    }
}
