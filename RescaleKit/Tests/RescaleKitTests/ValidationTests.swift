import Foundation
import Testing
import UniformTypeIdentifiers
@testable import RescaleKit

/// Review 2026-09-05, findings 3 and 5: garbage input must not trap, and
/// "Keep original" must never silently convert.
struct ValidationTests {
    let source = PixelSize(6000, 4000)

    @Test func garbageNeverTraps() {
        let garbage: [SizeParameter] = [
            .width(0), .width(-5), .width(Int.max), .height(0), .height(-1),
            .megapixels(-1), .megapixels(.infinity), .megapixels(.nan), .megapixels(0), .megapixels(1e12),
            .scale(0), .scale(-2), .scale(.infinity), .scale(.nan), .scale(1e6),
        ]
        for g in garbage {
            for m in Multiple.allCases {
                let s = ResizeRequest(aspect: .fixed(width: 16, height: 9), size: g, multiple: m).solve(for: source)
                #expect(s.width >= 1 && s.height >= 1, "\(g) ×\(m.rawValue) → \(s)")
                #expect(s.width <= Limits.maxDimension && s.height <= Limits.maxDimension, "\(g) → \(s)")
                #expect(s.size.pixelCount <= Limits.maxPixels, "\(g) → \(s)")
            }
        }
        // Degenerate aspect and source do not trap either.
        let s = ResizeRequest(aspect: .fixed(width: 0, height: 9), size: .width(100)).solve(for: PixelSize(0, 0))
        #expect(s.width == 100)
    }

    /// Review 2026-09-06, C6: holding a tiny pinned value can push the derived
    /// axis past the limit; the search must stay total.
    @Test func extremeAspectsNeverTrap() {
        let cases: [(AspectRatio, SizeParameter, PixelSize)] = [
            (.fixed(width: 1, height: 10000), .width(1), PixelSize(100, 100)),
            (.fixed(width: 10000, height: 1), .height(1), PixelSize(100, 100)),
            (.original, .width(8), PixelSize(1, 60000)),
            (.original, .height(16), PixelSize(60000, 1)),
            (.fixed(width: 1, height: 10000), .megapixels(400), PixelSize(100, 100)),
        ]
        for (aspect, size, src) in cases {
            for m in Multiple.allCases {
                let s = ResizeRequest(aspect: aspect, size: size, multiple: m).solve(for: src)
                #expect(s.width >= 1 && s.height >= 1, "\(aspect.label) \(size) ×\(m.rawValue)")
                #expect(s.width <= Limits.maxDimension && s.height <= Limits.maxDimension, "\(aspect.label) \(size) ×\(m.rawValue) → \(s)")
                #expect(s.width % m.rawValue == 0 && s.height % m.rawValue == 0)
            }
        }
        #expect(throws: ValidationError.self) {
            try ResizeRequest(aspect: .fixed(width: 1, height: 10000), size: .width(1), multiple: .eight).validate(for: PixelSize(100, 100))
        }
    }

    /// Review 2026-09-30, S4: a source whose area does not fit in `Int` must
    /// not trap the solver, the validator or the megapixel readout.
    @Test func oversizedSourceNeverTraps() {
        let sources = [PixelSize(Int.max, Int.max), PixelSize(Int.max, 2), PixelSize(1 << 32, 1 << 32),
                       PixelSize(3_037_000_500, 3_037_000_500)]
        let sizes: [SizeParameter] = [.scale(1), .scale(0.001), .scale(64), .megapixels(12), .width(1920), .height(1080)]
        for src in sources {
            for size in sizes {
                for m in Multiple.allCases {
                    let request = ResizeRequest(size: size, multiple: m)
                    let s = request.solve(for: src)
                    #expect(s.width >= 1 && s.height >= 1, "\(src) \(size) → \(s)")
                    #expect(s.width <= Limits.maxDimension && s.height <= Limits.maxDimension, "\(src) \(size) → \(s)")
                    #expect(s.size.pixelCount <= Limits.maxPixels, "\(src) \(size) → \(s)")
                    #expect(s.scale(relativeTo: src).isFinite)
                    // Validation answers with its own error or not at all.
                    _ = try? request.validate(for: src)
                }
            }
        }
        #expect(throws: ValidationError.self) {
            try ResizeRequest(size: .scale(1)).validate(for: PixelSize(Int.max, Int.max))
        }
    }

    @Test func sourceAreaIsCheckedAtTheBoundary() {
        // 3_037_000_499² is the largest square that fits in a 64-bit Int.
        let fits = PixelSize(3_037_000_499, 3_037_000_499)
        #expect(fits.checkedPixelCount == 9_223_372_030_926_249_001)
        #expect(fits.pixelCount == 9_223_372_030_926_249_001)
        let over = PixelSize(3_037_000_500, 3_037_000_500)
        #expect(over.checkedPixelCount == nil)
        #expect(over.pixelCount == Int.max)
        #expect(over.megapixels > fits.megapixels && over.megapixels.isFinite)
        #expect(PixelSize(Int.max, 1).checkedPixelCount == Int.max)
        #expect(PixelSize(Int.max, 2).checkedPixelCount == nil)
        #expect(PixelSize(6000, 4000).megapixels == 24)
    }

    /// Composite arguments need exactly two valid components (the CLI's `--source` and `--aspect`).
    @Test func compositeArgumentsNeedExactlyTwoComponents() {
        #expect(PixelSize(parsing: "6000x4000") == PixelSize(6000, 4000))
        #expect(PixelSize(parsing: "6000X4000") == PixelSize(6000, 4000))
        #expect(PixelSize(parsing: "3037000499x3037000499") != nil)
        let bad = ["6000xjunkx4000", "6000xx4000", "x6000x4000", "6000x4000x", "6000x", "6000", "", "0x10", "10x-1",
                   "6000x4000x3", "1.5x2", "3037000500x3037000500", "4294967296x4294967296", "99999999999999999999x1"]
        for s in bad { #expect(PixelSize(parsing: s) == nil, "\(s)") }

        #expect(NumberPair.parse("16:9", separator: ":", as: Int.self).map { [$0.0, $0.1] } == [16, 9])
        #expect(NumberPair.parse("1440x900", separator: "x", as: Double.self).map { [$0.0, $0.1] } == [1440, 900])
        for s in ["16:x:9", "16::9", ":16:9", "16:9:", "16", "16:", "a:9", "16:9:4"] {
            #expect(NumberPair.parse(s, separator: ":", as: Int.self) == nil, "\(s)")
        }
    }

    @Test func validateReportsTheProblem() {
        #expect(throws: ValidationError.sizeNotPositive(.width(0))) {
            try ResizeRequest(size: .width(0)).validate(for: source)
        }
        #expect(throws: ValidationError.sizeNotFinite(.megapixels(.infinity))) {
            try ResizeRequest(size: .megapixels(.infinity)).validate(for: source)
        }
        #expect(throws: ValidationError.sizeNotPositive(.megapixels(-1))) {
            try ResizeRequest(size: .megapixels(-1)).validate(for: source)
        }
        #expect(throws: ValidationError.sizeTooLarge(.scale(1000))) {
            try ResizeRequest(size: .scale(1000)).validate(for: source)
        }
        #expect(throws: ValidationError.aspectNotPositive(width: 0, height: 9)) {
            try ResizeRequest(aspect: .fixed(width: 0, height: 9), size: .width(100)).validate(for: source)
        }
        // A legal parameter that still produces an impossible target.
        #expect(throws: ValidationError.self) {
            try ResizeRequest(size: .width(60_000)).validate(for: PixelSize(1, 100))
        }
        #expect(throws: Never.self) {
            try ResizeRequest(aspect: .fixed(width: 16, height: 9), size: .width(1920), multiple: .sixteen).validate(for: source)
        }
    }

    @Test func keepOriginalNeverSubstitutes() {
        #expect(OutputFormat.keepOriginal.resolvedType(for: .jpeg) == .jpeg)
        #expect(OutputFormat.keepOriginal.resolvedType(for: .heic) == .heic)
        #expect(OutputFormat.keepOriginal.resolvedType(for: .gif) == nil)
        #expect(OutputFormat.keepOriginal.resolvedType(for: .webP) == nil)
        #expect(!OutputFormat.keepOriginal.isAvailable(for: .gif))
        #expect(OutputFormat.fallback(for: .gif, hasAlpha: true) == .png)
        #expect(OutputFormat.fallback(for: .webP, hasAlpha: false) == .jpeg)
    }

    @Test func padPolicyIsShared() {
        var spec = RenderSpec(target: PixelSize(100, 100), fit: .pad, padColor: nil, format: .png)
        #expect(spec.padNeedsAlpha(sourceType: .png))
        spec.format = .jpeg
        #expect(!spec.padNeedsAlpha(sourceType: .png))
        spec.format = .png
        spec.padColor = .white
        #expect(!spec.padNeedsAlpha(sourceType: .png))
        spec.padColor = PadColor(red: 1, green: 0, blue: 0, alpha: 0.5)
        #expect(spec.padNeedsAlpha(sourceType: .png))
        spec.fit = .crop
        #expect(!spec.padNeedsAlpha(sourceType: .png))
    }
}
