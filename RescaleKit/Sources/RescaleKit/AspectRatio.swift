/// The target aspect ratio. Always set; never a free field (PRD §5).
///
/// `.original` keeps whatever ratio the source has — any ratio, not a preset —
/// so nothing is cropped or padded. The fixed cases are exactly ComfyUI's
/// `ResolutionSelector` list.
public enum AspectRatio: Hashable, Sendable, Codable {
    case original
    case fixed(width: Int, height: Int)

    /// The eight preset ratios, in picker order.
    public static let presets: [AspectRatio] = [
        .fixed(width: 1, height: 1),
        .fixed(width: 2, height: 3),
        .fixed(width: 3, height: 2),
        .fixed(width: 3, height: 4),
        .fixed(width: 4, height: 3),
        .fixed(width: 9, height: 16),
        .fixed(width: 16, height: 9),
        .fixed(width: 21, height: 9),
    ]

    /// The full picker list: Original first, then the presets.
    public static let all: [AspectRatio] = [.original] + presets

    /// width ÷ height for a given source. `.original` resolves to the source's ratio.
    public func ratio(for source: PixelSize) -> Double {
        switch self {
        case .original:
            return source.aspectRatio
        case let .fixed(w, h):
            return Double(w) / Double(h)
        }
    }

    /// Whether choosing this ratio can change the framing of `source`.
    public func reframes(_ source: PixelSize) -> Bool {
        switch self {
        case .original:
            return false
        case .fixed:
            // Compare in integer space so 3000×2000 under 3:2 is not "reframed" by float noise.
            return ratio(for: source) != source.aspectRatio
        }
    }

    /// Picker label: "Original", "16:9", …
    public var label: String {
        switch self {
        case .original: return "Original"
        case let .fixed(w, h): return "\(w):\(h)"
        }
    }
}
