import Testing
@testable import RescaleKit

/// The worked examples from the PRD, pinned so the document and the code cannot drift.
struct TableTests {
    let source = PixelSize(6000, 4000)   // 3:2, 24 MP

    func solve(_ aspect: AspectRatio, _ size: SizeParameter, _ multiple: Multiple = .one) -> Solution {
        ResizeRequest(aspect: aspect, size: size, multiple: multiple).solve(for: source)
    }

    // PRD §6 — snapping must not move what the user typed.
    @Test func width1920At16by9Multiple16HoldsTheWidth() {
        let s = solve(.fixed(width: 16, height: 9), .width(1920), .sixteen)
        #expect(s.size == PixelSize(1920, 1088))
        #expect(s.aspectError < 0.0075 && s.aspectError > 0.0073)   // "AR off 0.74 %"
        #expect(s.adjustments == [.derivedAxisForced(axis: .height, ideal: 1080, actual: 1088)])
    }

    @Test func width1032At3by2Multiple16SnapsTheWidthDown() {
        let s = solve(.fixed(width: 3, height: 2), .width(1032), .sixteen)
        #expect(s.size == PixelSize(1024, 688))
        #expect(s.adjustments.contains(.pinnedValueSnapped(axis: .width, requested: 1032, actual: 1024)))
    }

    @Test func width1500At16by9Multiple8() {
        #expect(solve(.fixed(width: 16, height: 9), .width(1500), .eight).size == PixelSize(1504, 848))
    }

    @Test func twoMegapixelsAt16by9Multiple8() {
        #expect(solve(.fixed(width: 16, height: 9), .megapixels(2), .eight).size == PixelSize(1888, 1064))
    }

    // PRD §5 / prototype cases.py
    @Test func continuousCases() {
        #expect(solve(.fixed(width: 16, height: 9), .megapixels(2)).size == PixelSize(1886, 1061))
        #expect(solve(.fixed(width: 16, height: 9), .width(1600)).size == PixelSize(1600, 900))
        #expect(solve(.fixed(width: 16, height: 9), .height(900)).size == PixelSize(1600, 900))
        #expect(solve(.original, .scale(0.5)).size == PixelSize(3000, 2000))
        #expect(solve(.fixed(width: 1, height: 1), .megapixels(source.megapixels)).size == PixelSize(4899, 4899))
        #expect(solve(.original, .megapixels(2)).size == PixelSize(1732, 1155))
    }

    @Test func noAdjustmentsWhenEverythingFits() {
        let s = solve(.fixed(width: 16, height: 9), .width(1920), .eight)
        #expect(s.size == PixelSize(1920, 1080))
        #expect(s.adjustments.isEmpty)
    }

    // prototype ladder.py — the detent ladder under each aspect, width pinned, multiple 16.
    @Test func ladderTable() {
        let ladder = [512, 768, 1024, 2048]
        let expected: [AspectRatio: [PixelSize]] = [
            .fixed(width: 1, height: 1):  [PixelSize(512, 512), PixelSize(768, 768), PixelSize(1024, 1024), PixelSize(2048, 2048)],
            .fixed(width: 4, height: 3):  [PixelSize(512, 384), PixelSize(768, 576), PixelSize(1024, 768),  PixelSize(2048, 1536)],
            .fixed(width: 3, height: 2):  [PixelSize(512, 336), PixelSize(768, 512), PixelSize(1024, 688),  PixelSize(2048, 1360)],
            .fixed(width: 16, height: 9): [PixelSize(512, 288), PixelSize(768, 432), PixelSize(1024, 576),  PixelSize(2048, 1152)],
            .fixed(width: 21, height: 9): [PixelSize(512, 224), PixelSize(768, 336), PixelSize(1024, 432),  PixelSize(2048, 880)],
        ]
        for (aspect, sizes) in expected {
            for (v, size) in zip(ladder, sizes) {
                #expect(solve(aspect, .width(v), .sixteen).size == size, "\(aspect.label) @ \(v)")
            }
        }
    }

    @Test func ladderIsLatticeSafe() {
        for v in [512, 768, 1024, 2048] {
            for m in Multiple.allCases {
                #expect(v % m.rawValue == 0)
            }
        }
    }

    // Readouts — the four views of one number.
    @Test func fourViewsAgree() {
        let s = solve(.original, .width(3000))
        #expect(s.height == 2000)
        #expect(abs(s.megapixels - 6.0) < 1e-9)
        #expect(abs(s.scale(relativeTo: source) - 0.5) < 1e-9)
    }

    @Test func upscaleDetection() {
        let small = PixelSize(1200, 800)
        let s = ResizeRequest(aspect: .original, size: .width(2048)).solve(for: small)
        #expect(s.isUpscale(from: small))
        let t = ResizeRequest(aspect: .original, size: .width(1024)).solve(for: small)
        #expect(!t.isUpscale(from: small))
        // 1:1 crop of a 1200×800 at 1000 needs a cover scale of 1.25 — an upscale; pad does not.
        let sq = ResizeRequest(aspect: .fixed(width: 1, height: 1), size: .width(1000)).solve(for: small)
        #expect(sq.isUpscale(from: small, fit: .crop))
        #expect(!sq.isUpscale(from: small, fit: .pad))
    }

    @Test func originalNeverReframes() {
        #expect(!AspectRatio.original.reframes(source))
        #expect(!AspectRatio.fixed(width: 3, height: 2).reframes(source))
        #expect(AspectRatio.fixed(width: 16, height: 9).reframes(source))
    }
}
