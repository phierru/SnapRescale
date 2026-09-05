import Foundation

/// Hard limits that keep the solver and renderer inside what ImageIO and memory can take.
public enum Limits {
    /// Largest edge the renderer will draw.
    public static let maxDimension = 65_536
    /// Largest target pixel count (500 MP ≈ 2 GB of RGBA).
    public static let maxPixels = 500_000_000
    public static let maxMegapixels = Double(maxPixels) / Megapixel.pixels
    public static let maxScale = 64.0
}

public enum ValidationError: Error, LocalizedError, Equatable {
    case sizeNotPositive(SizeParameter)
    case sizeNotFinite(SizeParameter)
    case sizeTooLarge(SizeParameter)
    case aspectNotPositive(width: Int, height: Int)
    case targetTooLarge(PixelSize)

    public var errorDescription: String? {
        switch self {
        case .sizeNotPositive(let p): return "\(p.describe) must be greater than zero."
        case .sizeNotFinite(let p): return "\(p.describe) must be a number."
        case .sizeTooLarge(let p): return "\(p.describe) is too large (limit \(p.limitDescription))."
        case let .aspectNotPositive(w, h): return "Aspect ratio \(w):\(h) must have positive parts."
        case .targetTooLarge(let s): return "\(s) is too large to render (limit \(Limits.maxDimension) px per edge, \(Int(Limits.maxMegapixels)) MP)."
        }
    }
}

extension SizeParameter {
    var describe: String {
        switch self {
        case .width(let v): return "Width \(v)"
        case .height(let v): return "Height \(v)"
        case .megapixels(let v): return "\(v) MP"
        case .scale(let v): return "Scale \(v * 100)%"
        }
    }

    var limitDescription: String {
        switch self {
        case .width, .height: return "\(Limits.maxDimension) px"
        case .megapixels: return "\(Int(Limits.maxMegapixels)) MP"
        case .scale: return "\(Int(Limits.maxScale * 100))%"
        }
    }

    /// Throws when the value is not a positive, finite number inside `Limits`.
    public func validate() throws(ValidationError) {
        switch self {
        case .width(let v), .height(let v):
            if v <= 0 { throw .sizeNotPositive(self) }
            if v > Limits.maxDimension { throw .sizeTooLarge(self) }
        case .megapixels(let v):
            if !v.isFinite { throw .sizeNotFinite(self) }
            if v <= 0 { throw .sizeNotPositive(self) }
            if v > Limits.maxMegapixels { throw .sizeTooLarge(self) }
        case .scale(let v):
            if !v.isFinite { throw .sizeNotFinite(self) }
            if v <= 0 { throw .sizeNotPositive(self) }
            if v > Limits.maxScale { throw .sizeTooLarge(self) }
        }
    }

    /// The nearest valid value: non-finite or non-positive becomes the smallest
    /// legal value, oversized is capped. Used by the UI so typing garbage never crashes.
    public var clamped: SizeParameter {
        switch self {
        case .width(let v): return .width(min(max(v, 1), Limits.maxDimension))
        case .height(let v): return .height(min(max(v, 1), Limits.maxDimension))
        case .megapixels(let v): return .megapixels(v.isFinite ? min(max(v, 0.001), Limits.maxMegapixels) : 1)
        case .scale(let v): return .scale(v.isFinite ? min(max(v, 0.001), Limits.maxScale) : 1)
        }
    }
}

extension AspectRatio {
    public func validate() throws(ValidationError) {
        if case let .fixed(w, h) = self, w <= 0 || h <= 0 {
            throw .aspectNotPositive(width: w, height: h)
        }
    }
}

extension ResizeRequest {
    /// Validates the parameters and the size they would produce for `source`.
    /// Checks the *unclamped* ideal, so a request the solver would have to cap
    /// is reported rather than quietly shrunk.
    public func validate(for source: PixelSize) throws(ValidationError) {
        try aspect.validate()
        try size.validate()
        let ideal = Solver.solveContinuous(self, source: source)
        if !ideal.width.isFinite || !ideal.height.isFinite
            || ideal.width > Double(Limits.maxDimension) || ideal.height > Double(Limits.maxDimension)
            || ideal.pixelCount > Double(Limits.maxPixels) {
            let w = ideal.width.isFinite ? Int(min(ideal.width, 1e12)) : Int.max
            let h = ideal.height.isFinite ? Int(min(ideal.height, 1e12)) : Int.max
            throw .targetTooLarge(PixelSize(w, h))
        }
    }
}
