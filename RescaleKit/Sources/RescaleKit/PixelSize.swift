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

    public var pixelCount: Int { width * height }

    /// width ÷ height. Greater than 1 is landscape.
    public var aspectRatio: Double { Double(width) / Double(height) }

    /// Decimal megapixels (10⁶ px), see `Megapixel`.
    public var megapixels: Double { Double(pixelCount) / Megapixel.pixels }

    public var isLandscape: Bool { width > height }
    public var isPortrait: Bool { height > width }
    public var isSquare: Bool { width == height }
}

extension PixelSize: CustomStringConvertible {
    public var description: String { "\(width)×\(height)" }
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
