import Foundation

/// The result of solving a `ResizeRequest` against a source image.
public struct Solution: Hashable, Sendable {
    /// The final, lattice-aligned target size.
    public let size: PixelSize
    /// The exact real-valued target the lattice search was run against: the
    /// aspect ratio applied to the pinned axis *after* that axis snapped to the
    /// lattice. When nothing was pinned, or the typed value was already legal,
    /// this is simply the continuous solve of the request.
    public let ideal: ContinuousSize
    /// The axis the user set numerically, if any.
    public let pinnedAxis: Axis?
    /// Changes the multiple forced on the request, for the UI to state plainly (PRD §6).
    public let adjustments: [Adjustment]

    public init(size: PixelSize, ideal: ContinuousSize, pinnedAxis: Axis?, adjustments: [Adjustment]) {
        self.size = size
        self.ideal = ideal
        self.pinnedAxis = pinnedAxis
        self.adjustments = adjustments
    }

    /// A change the quantiser made that the user did not ask for.
    public enum Adjustment: Hashable, Sendable {
        /// The number the user typed was not on the lattice and was moved to the
        /// nearest legal value. `1032` at multiple 16 becomes `1024`.
        case pinnedValueSnapped(axis: Axis, requested: Int, actual: Int)
        /// The axis derived from the aspect ratio could not land on the lattice
        /// at its ideal value. `1920×1080` at multiple 16 becomes `1920×1088`.
        case derivedAxisForced(axis: Axis, ideal: Int, actual: Int)
    }

    public var width: Int { size.width }
    public var height: Int { size.height }
    public var megapixels: Double { size.megapixels }

    /// Relative aspect-ratio deviation from the ideal, as a fraction (0.0074 = 0.74 %).
    public var aspectError: Double {
        abs(size.aspectRatio / ideal.aspectRatio - 1)
    }

    /// Relative pixel-count deviation from the ideal, as a fraction.
    public var pixelError: Double {
        abs(Double(size.pixelCount) / ideal.pixelCount - 1)
    }

    /// The linear scale of this size relative to `source`, defined through pixel
    /// count so it is meaningful under a reframe: `√(target px ÷ source px)`.
    /// This is the inverse of `SizeParameter.scale`.
    public func scale(relativeTo source: PixelSize) -> Double {
        (Double(size.pixelCount) / Double(source.pixelCount)).squareRoot()
    }

    /// The factor the source pixels are resampled by under `fit`.
    /// - crop: the larger axis ratio (cover)
    /// - pad: the smaller axis ratio (contain)
    /// - stretch: the larger of the two, as the conservative upscale test
    public func resampleScale(from source: PixelSize, fit: FitPolicy) -> Double {
        let sx = Double(size.width) / Double(source.width)
        let sy = Double(size.height) / Double(source.height)
        switch fit {
        case .crop, .stretch: return max(sx, sy)
        case .pad: return min(sx, sy)
        }
    }

    /// True when producing this size from `source` would enlarge pixels (PRD §2, "never upscale").
    public func isUpscale(from source: PixelSize, fit: FitPolicy = .crop) -> Bool {
        resampleScale(from: source, fit: fit) > 1
    }
}

extension Solution: CustomStringConvertible {
    public var description: String {
        String(format: "%@ (ideal %.1f×%.1f, AR err %.3f%%, px err %.2f%%)",
               size.description, ideal.width, ideal.height, aspectError * 100, pixelError * 100)
    }
}
