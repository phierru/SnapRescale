import Foundation
import ImageIO
import Testing
@testable import RescaleKit

/// Review 2026-09-30, hardening: the declared size is budgeted before any pixels are decoded.
struct SourceImageTests {
    static let url = URL(fileURLWithPath: "/tmp/picture.png")

    static func props(_ width: Int, _ height: Int, depth: Int? = 8) -> [CFString: Any] {
        var p: [CFString: Any] = [kCGImagePropertyPixelWidth: width, kCGImagePropertyPixelHeight: height]
        p[kCGImagePropertyDepth] = depth
        return p
    }

    @Test func budgetIsGenerous() throws {
        #expect(SourceImage.maxDecodedBytes == 4_294_967_296)
        // Large photographs, stitched panoramas and AI upscales all open.
        let fine: [(Int, Int, Int)] = [(6000, 4000, 8), (30_000, 20_000, 8), (32_768, 32_768, 8), (200_000, 5_000, 8),
                                       (23_000, 23_000, 16), (16_000, 16_000, 32)]
        for (w, h, depth) in fine {
            #expect(try SourceImage.checkDecodeBudget(Self.props(w, h, depth: depth), url: Self.url) == PixelSize(w, h))
        }
        // Whatever the renderer can write can be opened again, at 16 bits too.
        #expect(try #require(SourceImage.estimatedDecodedBytes(width: Limits.maxPixels, height: 1, bitsPerComponent: 16))
                <= SourceImage.maxDecodedBytes)
        // No depth stated: 8 bits.
        #expect(try SourceImage.checkDecodeBudget(Self.props(32_768, 32_768, depth: nil), url: Self.url) == PixelSize(32_768, 32_768))
    }

    @Test func estimateCountsDepth() {
        #expect(SourceImage.estimatedDecodedBytes(width: 100, height: 10, bitsPerComponent: 8) == 4_000)
        #expect(SourceImage.estimatedDecodedBytes(width: 100, height: 10, bitsPerComponent: 1) == 4_000)
        #expect(SourceImage.estimatedDecodedBytes(width: 100, height: 10, bitsPerComponent: 10) == 8_000)
        #expect(SourceImage.estimatedDecodedBytes(width: 100, height: 10, bitsPerComponent: 16) == 8_000)
        #expect(SourceImage.estimatedDecodedBytes(width: 100, height: 10, bitsPerComponent: 32) == 16_000)
        #expect(SourceImage.estimatedDecodedBytes(width: Int.max, height: Int.max, bitsPerComponent: 8) == nil)
        #expect(SourceImage.estimatedDecodedBytes(width: Int.max / 2, height: 1, bitsPerComponent: 8) == nil)
        #expect(SourceImage.estimatedDecodedBytes(width: 0, height: 10, bitsPerComponent: 8) == nil)
    }

    @Test func overBudgetIsRejectedAtTheBoundary() throws {
        // 32768² × 4 bytes is the limit exactly; one more row is over.
        #expect(throws: Never.self) { try SourceImage.checkDecodeBudget(Self.props(32_768, 32_768), url: Self.url) }
        let over: [(Int, Int, Int)] = [(32_768, 32_769, 8), (40_000, 40_000, 8), (32_768, 32_768, 16), (24_000, 24_000, 16),
                                       (Int.max, Int.max, 8), (1 << 40, 1 << 40, 8)]
        for (w, h, depth) in over {
            #expect("\(w)×\(h) at \(depth)") {
                try SourceImage.checkDecodeBudget(Self.props(w, h, depth: depth), url: Self.url)
            } throws: { error in
                guard case let SourceImage.LoadError.tooLarge(_, size, bits) = error else { return false }
                return size == PixelSize(w, h) && bits == depth
            }
        }
        let message = SourceImage.LoadError.tooLarge(Self.url, size: PixelSize(40_000, 40_000), bitsPerComponent: 8).errorDescription
        #expect(message == "picture.png is too large to open: 40000×40000, 1600 MP (limit 1073 MP at 8 bits per channel).")
    }

    @Test func missingOrNonPositiveDimensionsAreUndecodable() {
        let bad: [[CFString: Any]] = [[:], [kCGImagePropertyPixelWidth: 10], Self.props(0, 10), Self.props(10, -1)]
        for p in bad {
            #expect { try SourceImage.checkDecodeBudget(p, url: Self.url) } throws: { error in
                if case SourceImage.LoadError.undecodable = error { return true } else { return false }
            }
        }
    }

    /// `load` applies the budget before asking for pixels. A small budget stands in
    /// for a huge file: every fixture is 64 × 48, 12288 bytes at 8 bits per channel.
    @Test func loadRefusesASourceOverBudget() throws {
        #expect(try SourceImage.load(Fixture.camera.url, maxDecodedBytes: 12_288).size == Fixture.storedSize)
        #expect { try SourceImage.load(Fixture.camera.url, maxDecodedBytes: 12_287) } throws: { error in
            guard case let SourceImage.LoadError.tooLarge(_, size, bits) = error else { return false }
            return size == Fixture.storedSize && bits == 8
        }
        // Twice the bytes at 16 bits per channel.
        #expect(throws: SourceImage.LoadError.self) { try SourceImage.load(Fixture.sixteenBit.url, maxDecodedBytes: 12_288) }
        #expect(try SourceImage.load(Fixture.sixteenBit.url, maxDecodedBytes: 24_576).size == Fixture.storedSize)
    }

    /// The estimate is an upper bound on what ImageIO hands back for the fixtures.
    @Test(arguments: Fixture.allCases)
    func estimateBoundsTheDecodedFixture(_ fixture: Fixture) throws {
        let source = try Fixture.load(fixture)
        let depth = source.properties[kCGImagePropertyDepth] as? Int ?? 8
        let estimate = try #require(SourceImage.estimatedDecodedBytes(width: source.size.width, height: source.size.height,
                                                                     bitsPerComponent: depth))
        #expect(source.image.bytesPerRow * source.image.height <= estimate, "\(fixture.rawValue): depth \(depth), \(source.image.bitsPerPixel) bpp")
    }
}
