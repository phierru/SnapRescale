import Foundation

/// Everything the user can set about the target geometry.
public struct ResizeRequest: Hashable, Sendable, Codable {
    public var aspect: AspectRatio
    public var size: SizeParameter
    public var multiple: Multiple

    public init(aspect: AspectRatio = .original, size: SizeParameter, multiple: Multiple = .one) {
        self.aspect = aspect
        self.size = size
        self.multiple = multiple
    }

    public func solve(for source: PixelSize) -> Solution {
        Solver.solve(self, source: source)
    }
}

/// The dimension solver, ported from `prototype/solver.py` (`solve2`).
///
/// Two stages:
/// 1. **Continuous solve.** Aspect + one size parameter give an exact real-valued
///    (W*, H*). There is no competition between constraints, so no pins to
///    arbitrate — the aspect is always known and the size is one number.
/// 2. **Pin-respecting snap.** The axis the user typed snaps to its own nearest
///    lattice value and is then held fixed; only the derived axis is searched
///    for the lattice point with least aspect deviation, ties broken by pixel
///    count (PRD §6).
public enum Solver {
    /// Aspect-ratio deviation dominates; pixel-count deviation only breaks ties.
    static let aspectWeight = 1.0
    static let pixelWeight = 0.05
    /// How many lattice steps either side of the ideal a free axis is searched.
    static let searchSpan = 3

    public static func solve(_ request: ResizeRequest, source: PixelSize) -> Solution {
        precondition(source.width > 0 && source.height > 0, "source must have positive dimensions")

        let pinned = request.size.pinnedAxis
        let typed = solveContinuous(request, source: source)
        let ideal = holdPinnedAxis(typed, multiple: request.multiple.rawValue, pinned: pinned)
        let size = snap(ideal, multiple: request.multiple.rawValue, pinned: pinned)

        return Solution(
            size: size,
            ideal: ideal,
            pinnedAxis: pinned,
            adjustments: adjustments(request: request, ideal: ideal, size: size)
        )
    }

    // MARK: - Stage 1: continuous solve

    static func solveContinuous(_ request: ResizeRequest, source: PixelSize) -> ContinuousSize {
        let ar = request.aspect.ratio(for: source)
        switch request.size {
        case let .width(w):
            let w = Double(w)
            return ContinuousSize(width: w, height: w / ar)
        case let .height(h):
            let h = Double(h)
            return ContinuousSize(width: h * ar, height: h)
        case let .megapixels(mp):
            return fromPixelCount(mp * Megapixel.pixels, aspect: ar)
        case let .scale(s):
            // A linear scale of the source is a pixel budget of source × s².
            // Routed through megapixels exactly as the prototype does, so the
            // two stay numerically identical.
            let mp = Double(source.pixelCount) * s * s / Megapixel.pixels
            return fromPixelCount(mp * Megapixel.pixels, aspect: ar)
        }
    }

    private static func fromPixelCount(_ px: Double, aspect ar: Double) -> ContinuousSize {
        ContinuousSize(width: (px * ar).squareRoot(), height: (px / ar).squareRoot())
    }

    // MARK: - Stage 2: pin-respecting snap

    /// Snap the pinned axis to the lattice first, then re-derive the free axis
    /// from the value the user will actually get. Typing 1500 at 16:9 with
    /// multiple 8 yields a width of 1504, so the height should be the best
    /// match for 1504, not for 1500. This also makes re-solving with the
    /// solved value a true fixed point.
    static func holdPinnedAxis(_ typed: ContinuousSize, multiple: Int, pinned: Axis?) -> ContinuousSize {
        guard multiple > 1 else { return typed }
        let ar = typed.aspectRatio
        switch pinned {
        case .width:
            let w = Double(nearestLattice(typed.width, multiple))
            return ContinuousSize(width: w, height: w / ar)
        case .height:
            let h = Double(nearestLattice(typed.height, multiple))
            return ContinuousSize(width: h * ar, height: h)
        case nil:
            return typed
        }
    }

    static func snap(_ ideal: ContinuousSize, multiple: Int, pinned: Axis?) -> PixelSize {
        if multiple <= 1 {
            return PixelSize(width: max(1, roundHalfEven(ideal.width)),
                             height: max(1, roundHalfEven(ideal.height)))
        }

        let targetAR = ideal.aspectRatio
        let targetPx = ideal.pixelCount

        let widths = pinned == .width ? [nearestLattice(ideal.width, multiple)] : window(ideal.width, multiple)
        let heights = pinned == .height ? [nearestLattice(ideal.height, multiple)] : window(ideal.height, multiple)

        var best = PixelSize(width: widths[0], height: heights[0])
        var bestScore = Double.infinity
        // Iteration order matters for ties: smallest candidates win, as in the prototype.
        for w in widths {
            for h in heights {
                let cw = Double(w), ch = Double(h)
                let arTerm = log((cw / ch) / targetAR)
                let pxTerm = log((cw * ch) / targetPx)
                let score = aspectWeight * arTerm * arTerm + pixelWeight * pxTerm * pxTerm
                if score < bestScore {
                    best = PixelSize(width: w, height: h)
                    bestScore = score
                }
            }
        }
        return best
    }

    /// The nearest lattice value, never below one step. Half-way cases round to
    /// even (1032 at 16 → 64.5 steps → 64 → 1024), matching the prototype and PRD §6.
    static func nearestLattice(_ v: Double, _ multiple: Int) -> Int {
        max(multiple, roundHalfEven(v / Double(multiple)) * multiple)
    }

    /// Lattice values from `searchSpan` steps below the ideal to `searchSpan + 1` above.
    static func window(_ v: Double, _ multiple: Int) -> [Int] {
        let base = Int((v / Double(multiple)).rounded(.down))
        return (-searchSpan...(searchSpan + 1))
            .map { (base + $0) * multiple }
            .filter { $0 >= multiple }
    }

    static func roundHalfEven(_ v: Double) -> Int {
        Int(v.rounded(.toNearestOrEven))
    }

    // MARK: - Reporting

    static func adjustments(request: ResizeRequest, ideal: ContinuousSize, size: PixelSize) -> [Solution.Adjustment] {
        var out: [Solution.Adjustment] = []
        switch request.size {
        case let .width(w) where w != size.width:
            out.append(.pinnedValueSnapped(axis: .width, requested: w, actual: size.width))
        case let .height(h) where h != size.height:
            out.append(.pinnedValueSnapped(axis: .height, requested: h, actual: size.height))
        default:
            break
        }
        if request.multiple.isIdentity { return out }

        // The derived axis was "forced" when the multiple, not rounding, moved it.
        let idealW = roundHalfEven(ideal.width)
        let idealH = roundHalfEven(ideal.height)
        if request.size.pinnedAxis != .width, idealW != size.width {
            out.append(.derivedAxisForced(axis: .width, ideal: idealW, actual: size.width))
        }
        if request.size.pinnedAxis != .height, idealH != size.height {
            out.append(.derivedAxisForced(axis: .height, ideal: idealH, actual: size.height))
        }
        return out
    }
}
