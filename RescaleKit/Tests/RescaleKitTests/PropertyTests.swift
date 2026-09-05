import Testing
@testable import RescaleKit

/// PRD §14 M0: "the solved size always honours the axis the user set, and
/// re-solving is idempotent." Plus the lattice and locality guarantees the
/// snap is built on. Exercised over a deterministic pseudo-random sample.
struct PropertyTests {
    /// SplitMix64: reproducible across runs and platforms.
    struct Generator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    struct Sample {
        let source: PixelSize
        let request: ResizeRequest
    }

    static func samples(count: Int, seed: UInt64) -> [Sample] {
        var g = Generator(state: seed)
        return (0..<count).map { _ in
            let source = PixelSize(Int.random(in: 16...8000, using: &g), Int.random(in: 16...8000, using: &g))
            let aspect = AspectRatio.all.randomElement(using: &g)!
            let multiple = Multiple.allCases.randomElement(using: &g)!
            let size: SizeParameter
            switch Int.random(in: 0..<4, using: &g) {
            case 0: size = .width(Int.random(in: 16...8192, using: &g))
            case 1: size = .height(Int.random(in: 16...8192, using: &g))
            case 2: size = .megapixels(Double.random(in: 0.05...48, using: &g))
            default: size = .scale(Double.random(in: 0.05...4, using: &g))
            }
            return Sample(source: source, request: ResizeRequest(aspect: aspect, size: size, multiple: multiple))
        }
    }

    /// Requests the solver would have to clamp (e.g. a 500:1 source at height
    /// 8192) are out of scope here; `ValidationTests` covers that they don't trap.
    static let samples = samples(count: 20_000, seed: 0x5E5CA1E)
        .filter { (try? $0.request.validate(for: $0.source)) != nil }

    @Test func mostSamplesAreValid() {
        #expect(Self.samples.count > 18_000)
    }

    @Test func resultIsOnTheLattice() {
        for s in Self.samples {
            let r = s.request.solve(for: s.source)
            let m = s.request.multiple.rawValue
            #expect(r.width >= m && r.height >= m, "\(s.request) → \(r)")
            #expect(r.width % m == 0 && r.height % m == 0, "\(s.request) → \(r)")
        }
    }

    @Test func pinnedAxisIsHonoured() {
        for s in Self.samples {
            let r = s.request.solve(for: s.source)
            let m = s.request.multiple.rawValue
            switch s.request.size {
            case let .width(w):
                // On the lattice: untouched. Off it: moved by less than one step, and reported.
                if w % m == 0 && w >= m {
                    #expect(r.width == w, "\(s.request) → \(r)")
                    #expect(!r.adjustments.contains { if case .pinnedValueSnapped = $0 { true } else { false } })
                } else {
                    #expect(abs(r.width - w) <= m / 2 || r.width == m, "\(s.request) → \(r)")
                    #expect(r.adjustments.contains(.pinnedValueSnapped(axis: .width, requested: w, actual: r.width)))
                }
            case let .height(h):
                if h % m == 0 && h >= m {
                    #expect(r.height == h, "\(s.request) → \(r)")
                } else {
                    #expect(abs(r.height - h) <= m / 2 || r.height == m, "\(s.request) → \(r)")
                    #expect(r.adjustments.contains(.pinnedValueSnapped(axis: .height, requested: h, actual: r.height)))
                }
            default:
                #expect(r.pinnedAxis == nil)
            }
        }
    }

    @Test func derivedAxisStaysWithinOneStepOfIdeal() {
        for s in Self.samples {
            let r = s.request.solve(for: s.source)
            let m = Double(s.request.multiple.rawValue)
            // When one axis is pinned, the other is a one-dimensional search whose
            // two terms share a minimiser, so the winner is floor or ceil of the ideal.
            switch r.pinnedAxis {
            case .width:
                #expect(abs(Double(r.height) - r.ideal.height) < m || r.height == Int(m), "\(s.request) → \(r)")
            case .height:
                #expect(abs(Double(r.width) - r.ideal.width) < m || r.width == Int(m), "\(s.request) → \(r)")
            case nil:
                // Both free: bounded by the search window.
                let span = Double(Solver.searchSpan + 1) * m
                #expect(abs(Double(r.width) - r.ideal.width) <= span, "\(s.request) → \(r)")
                #expect(abs(Double(r.height) - r.ideal.height) <= span, "\(s.request) → \(r)")
            }
        }
    }

    @Test func resolvingThePinnedAxisIsAFixedPoint() {
        for s in Self.samples {
            let r = s.request.solve(for: s.source)
            guard let axis = r.pinnedAxis else { continue }
            var again = s.request
            again.size = axis == .width ? .width(r.width) : .height(r.height)
            let r2 = again.solve(for: s.source)
            #expect(r2.size == r.size, "\(s.request) → \(r) → \(r2)")
            #expect(!r2.adjustments.contains { if case .pinnedValueSnapped = $0 { true } else { false } })
        }
    }

    @Test func multipleOneIsPlainRounding() {
        for s in Self.samples where s.request.multiple == .one {
            let r = s.request.solve(for: s.source)
            #expect(abs(Double(r.width) - r.ideal.width) <= 0.5 || r.width == 1)
            #expect(abs(Double(r.height) - r.ideal.height) <= 0.5 || r.height == 1)
            #expect(!r.adjustments.contains { if case .derivedAxisForced = $0 { true } else { false } })
        }
    }

    @Test func originalAspectPreservesSourceRatioAtLargeSizes() {
        // Under Original, a comfortably large target keeps the source ratio to well under a percent.
        for s in Self.samples where s.request.aspect == .original {
            let r = s.request.solve(for: s.source)
            if min(r.width, r.height) >= 1024 {
                #expect(r.aspectError < 0.01, "\(s.source) \(s.request) → \(r)")
            }
        }
    }

    @Test func scaleAndMegapixelsRoundTrip() {
        for s in Self.samples {
            let r = s.request.solve(for: s.source)
            // The readouts are consistent with the pinned view of the same number.
            if case let .scale(k) = s.request.size, s.request.multiple == .one, min(r.width, r.height) >= 256 {
                #expect(abs(r.scale(relativeTo: s.source) / k - 1) < 0.01, "\(s.request) → \(r)")
            }
            if case let .megapixels(mp) = s.request.size, s.request.multiple == .one, min(r.width, r.height) >= 256 {
                #expect(abs(r.megapixels / mp - 1) < 0.01, "\(s.request) → \(r)")
            }
        }
    }
}
