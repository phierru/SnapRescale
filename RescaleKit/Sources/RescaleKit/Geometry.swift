import CoreGraphics

/// Where the surviving region sits: (0,0) top-left … (0.5,0.5) centre … (1,1) bottom-right.
public struct CropAnchor: Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = min(max(x, 0), 1)
        self.y = min(max(y, 0), 1)
    }

    public static let center = CropAnchor(x: 0.5, y: 0.5)

    /// The 3×3 grid, row-major from top-left.
    public static let grid: [CropAnchor] = [0, 0.5, 1].flatMap { y in [0, 0.5, 1].map { x in CropAnchor(x: x, y: y) } }
}

/// Pure geometry for crop / pad / stretch. All rects use a top-left origin in
/// pixel units, so they can be drawn straight onto a preview.
public enum Geometry {
    /// Crop (cover): the region of the *source*, in source pixels, that survives.
    public static func cropRect(source: PixelSize, target: PixelSize, anchor: CropAnchor) -> CGRect {
        let sw = Double(source.width), sh = Double(source.height)
        let scale = max(Double(target.width) / sw, Double(target.height) / sh)
        let visW = min(sw, Double(target.width) / scale)
        let visH = min(sh, Double(target.height) / scale)
        return CGRect(x: (sw - visW) * anchor.x, y: (sh - visH) * anchor.y, width: visW, height: visH)
    }

    /// Pad (contain): where the whole source lands inside the *target* canvas, in target pixels.
    public static func padRect(source: PixelSize, target: PixelSize, anchor: CropAnchor) -> CGRect {
        let sw = Double(source.width), sh = Double(source.height)
        let tw = Double(target.width), th = Double(target.height)
        let scale = min(tw / sw, th / sh)
        let dw = sw * scale, dh = sh * scale
        return CGRect(x: (tw - dw) * anchor.x, y: (th - dh) * anchor.y, width: dw, height: dh)
    }

    /// Fraction of source pixels discarded by a crop, 0…1.
    public static func discardedFraction(source: PixelSize, target: PixelSize, anchor: CropAnchor) -> Double {
        let r = cropRect(source: source, target: target, anchor: anchor)
        return 1 - (r.width * r.height) / Double(source.pixelCount)
    }

    /// Fraction of the target canvas that is padding, 0…1.
    public static func paddedFraction(source: PixelSize, target: PixelSize) -> Double {
        let r = padRect(source: source, target: target, anchor: .center)
        return 1 - (r.width * r.height) / Double(target.pixelCount)
    }
}
