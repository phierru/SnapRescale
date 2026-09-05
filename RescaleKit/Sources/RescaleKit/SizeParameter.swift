/// The one number the user set. With the aspect ratio always known, this is the
/// single remaining degree of freedom (PRD §5): "Aspect + one number = a complete answer."
///
/// Width, height, megapixels and scale are four views of the same value. The
/// solver produces the other three.
public enum SizeParameter: Hashable, Sendable, Codable {
    /// Target width in pixels. Height follows from the aspect ratio.
    case width(Int)
    /// Target height in pixels. Width follows from the aspect ratio.
    case height(Int)
    /// Target pixel count in decimal megapixels (see `Megapixel`).
    case megapixels(Double)
    /// Linear multiple of the source: 1.0 is 100 %, 0.5 halves each edge.
    /// Under a non-original aspect this means "the same pixel budget as scaling
    /// the source by this factor", reframed to the chosen ratio.
    case scale(Double)

    /// The axis the user set numerically, if any. It must survive snapping (PRD §6).
    public var pinnedAxis: Axis? {
        switch self {
        case .width: return .width
        case .height: return .height
        case .megapixels, .scale: return nil
        }
    }
}

public enum Axis: Hashable, Sendable, Codable {
    case width
    case height
}
