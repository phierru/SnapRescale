import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Everything about one output: geometry, fit and encoder.
public struct RenderSpec: Hashable, Sendable {
    public var target: PixelSize
    public var fit: FitPolicy
    public var anchor: CropAnchor
    /// Pad fill. `nil` or a translucent colour needs alpha, which falls back to
    /// compositing over white for opaque formats (PRD §7).
    public var padColor: PadColor?
    public var format: OutputFormat
    /// 0…1, used by lossy encoders only.
    public var quality: Double

    /// Whether the padding in this spec needs an alpha channel and the format
    /// can carry one. When false, translucent padding is composited over white.
    /// The preview and the renderer both consult this, so they agree (PRD §7).
    public func padNeedsAlpha(sourceType: UTType) -> Bool {
        guard fit == .pad else { return false }
        let translucent = padColor.map(\.isTranslucent) ?? true
        return translucent && format.supportsAlpha(for: sourceType)
    }

    public init(target: PixelSize, fit: FitPolicy = .crop, anchor: CropAnchor = .center,
                padColor: PadColor? = nil, format: OutputFormat = .keepOriginal, quality: Double = 0.95) {
        self.target = target
        self.fit = fit
        self.anchor = anchor
        self.padColor = padColor
        self.format = format
        self.quality = quality
    }
}

public struct PadColor: Hashable, Sendable, Codable {
    public var red: Double, green: Double, blue: Double
    /// 0 is fully transparent. Anything below 1 needs an alpha channel; formats
    /// without one composite over white (PRD §7).
    public var alpha: Double
    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }
    public static let white = PadColor(red: 1, green: 1, blue: 1)
    public static let black = PadColor(red: 0, green: 0, blue: 0)
    public static let transparent = PadColor(red: 1, green: 1, blue: 1, alpha: 0)
    public var isTranslucent: Bool { alpha < 1 }
}

/// decode → resize → crop/pad → encode, for one image. M1 slice: sRGB output,
/// CoreGraphics resampling, metadata stripped. §10 rules come later.
public enum Renderer {
    public enum RenderError: Error, LocalizedError {
        case contextFailed
        case encodeFailed(UTType)
        case cannotKeepFormat(UTType)
        public var errorDescription: String? {
            switch self {
            case .contextFailed: return "Could not create a drawing context."
            case .encodeFailed(let t): return "Could not encode as \(t.preferredFilenameExtension ?? t.identifier)."
            case .cannotKeepFormat(let t): return "\(t.preferredFilenameExtension?.uppercased() ?? t.identifier) cannot be written; choose JPEG, PNG, HEIC or TIFF."
            }
        }
    }

    public static func render(_ source: SourceImage, spec: RenderSpec) throws -> CGImage {
        let t = spec.target
        let wantsAlpha = spec.padNeedsAlpha(sourceType: source.type)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: t.width, height: t.height,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw RenderError.contextFailed }
        ctx.interpolationQuality = .high

        let canvas = CGRect(x: 0, y: 0, width: t.width, height: t.height)
        let drawRect: CGRect
        switch spec.fit {
        case .crop:
            let crop = Geometry.cropRect(source: source.size, target: t, anchor: spec.anchor)
            let scale = Double(t.width) / crop.width
            // Draw the whole source scaled so that `crop` covers the canvas exactly.
            let dw = Double(source.size.width) * scale, dh = Double(source.size.height) * scale
            let x = -crop.minX * scale
            let yTop = -crop.minY * scale
            drawRect = CGRect(x: x, y: Double(t.height) - yTop - dh, width: dw, height: dh)
        case .pad:
            let r = Geometry.padRect(source: source.size, target: t, anchor: spec.anchor)
            drawRect = CGRect(x: r.minX, y: Double(t.height) - r.minY - r.height, width: r.width, height: r.height)
            if !wantsAlpha {
                ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
                ctx.fill(canvas)
            }
            if let c = spec.padColor, c.alpha > 0 {
                ctx.setFillColor(CGColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha))
                ctx.fill(canvas)
            }
        case .stretch:
            drawRect = canvas
        }
        ctx.draw(source.image, in: drawRect)
        guard let out = ctx.makeImage() else { throw RenderError.contextFailed }
        return out
    }

    public static func encode(_ image: CGImage, spec: RenderSpec, sourceType: UTType) throws -> Data {
        guard let type = spec.format.resolvedType(for: sourceType) else {
            throw RenderError.cannotKeepFormat(sourceType)
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)
        else { throw RenderError.encodeFailed(type) }
        var props: [CFString: Any] = [:]
        if spec.format.isLossy(for: sourceType) {
            props[kCGImageDestinationLossyCompressionQuality] = spec.quality
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw RenderError.encodeFailed(type) }
        return data as Data
    }

    /// Render and encode in one go; the byte count is what the UI shows (PRD §8).
    public static func produce(_ source: SourceImage, spec: RenderSpec) throws -> Data {
        try encode(try render(source, spec: spec), spec: spec, sourceType: source.type)
    }
}

/// `{name}_{w}x{h}.{ext}` next to the original; collisions append a counter (PRD §11).
public enum OutputNaming {
    public static func url(for source: SourceImage, spec: RenderSpec, in directory: URL? = nil) -> URL {
        let dir = directory ?? source.url.deletingLastPathComponent()
        let ext = spec.format.resolvedType(for: source.type)?.preferredFilenameExtension ?? "jpg"
        let base = source.url.deletingPathExtension().lastPathComponent + "_\(spec.target.width)x\(spec.target.height)"
        var candidate = dir.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base)_\(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }
}
