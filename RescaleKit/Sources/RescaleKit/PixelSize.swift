/// An integer pixel size. Used for both the source image and solved targets.
public struct PixelSize: Hashable, Sendable, Codable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public init(_ width: Int, _ height: Int) {
        self.init(width: width, height: height)
    }

    /// width × height, or nil when the product does not fit in `Int`.
    public var checkedPixelCount: Int? {
        let (area, overflow) = width.multipliedReportingOverflow(by: height)
        return overflow ? nil : area
    }

    /// width × height. Never traps: an area that does not fit in `Int` saturates
    /// (review 2026-09-30, S4). Use `checkedPixelCount` to tell the two apart.
    public var pixelCount: Int { checkedPixelCount ?? ((width < 0) == (height < 0) ? Int.max : Int.min) }

    /// The area as a real number, for arithmetic that must not overflow.
    public var area: Double { Double(width) * Double(height) }

    /// width ÷ height. Greater than 1 is landscape.
    public var aspectRatio: Double { Double(width) / Double(height) }

    /// Decimal megapixels (10⁶ px), see `Megapixel`.
    public var megapixels: Double { area / Megapixel.pixels }

    public var isLandscape: Bool { width > height }
    public var isPortrait: Bool { height > width }
    public var isSquare: Bool { width == height }
}

extension PixelSize: CustomStringConvertible {
    public var description: String { "\(width)×\(height)" }
}

/// Composite numeric arguments: `6000x4000`, `16:9`.
public enum NumberPair {
    /// Exactly two components, both valid numbers, or nil. `16:x:9` and `6000xx4000`
    /// are malformed, not a pair with the bad part dropped (review 2026-09-30, S4).
    public static func parse<T: LosslessStringConvertible>(_ s: some StringProtocol, separator: Character,
                                                           as type: T.Type = T.self) -> (T, T)? {
        let parts = s.split(separator: separator, omittingEmptySubsequences: false)
        guard parts.count == 2, let a = T(String(parts[0])), let b = T(String(parts[1])) else { return nil }
        return (a, b)
    }
}

extension PixelSize {
    /// `WxH` with positive edges whose area fits in `Int`; nil otherwise.
    public init?(parsing s: String) {
        guard let (w, h) = NumberPair.parse(s.lowercased(), separator: "x", as: Int.self), w > 0, h > 0,
              PixelSize(w, h).checkedPixelCount != nil else { return nil }
        self.init(w, h)
    }
}

/// The megapixel convention.
///
/// ComfyUI uses 1024² (1,048,576 px). Cameras and photographers use 10⁶.
/// Rescale's users are photographers, so the decimal convention wins (PRD §15.1).
/// Everything that converts between pixels and megapixels goes through here so
/// the decision lives in one place.
public enum Megapixel {
    public static let pixels: Double = 1_000_000
}

/// A real-valued size: the ideal solve before quantisation to the lattice.
public struct ContinuousSize: Hashable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public var pixelCount: Double { width * height }
    public var aspectRatio: Double { width / height }
}
