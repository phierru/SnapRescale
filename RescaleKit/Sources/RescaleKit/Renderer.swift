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
    /// What to keep of the source's metadata (PRD §10.2).
    public var metadata: MetadataPolicy

    /// Whether the padding in this spec needs an alpha channel and the format
    /// can carry one. When false, translucent padding is composited over white.
    /// The preview and the renderer both consult this, so they agree (PRD §7).
    public func padNeedsAlpha(sourceType: UTType) -> Bool {
        guard fit == .pad else { return false }
        let translucent = padColor.map(\.isTranslucent) ?? true
        return translucent && format.supportsAlpha(for: sourceType)
    }

    public init(target: PixelSize, fit: FitPolicy = .crop, anchor: CropAnchor = .center,
                padColor: PadColor? = nil, format: OutputFormat = .keepOriginal, quality: Double = 0.95,
                metadata: MetadataPolicy = .default) {
        self.target = target
        self.fit = fit
        self.anchor = anchor
        self.padColor = padColor
        self.format = format
        self.quality = quality
        self.metadata = metadata
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

/// decode → resize → crop/pad → encode, for one image. CoreGraphics
/// resampling; colour space and depth follow the ICC policy (`ColorPlan`).
public enum Renderer {
    public enum RenderError: Error, LocalizedError {
        case contextFailed
        case encodeFailed(UTType)
        case cannotKeepFormat(UTType)
        case targetTooLarge(PixelSize)
        public var errorDescription: String? {
            switch self {
            case .targetTooLarge(let s): return ValidationError.targetTooLarge(s).localizedDescription
            case .contextFailed: return "Could not create a drawing context."
            case .encodeFailed(let t): return "Could not encode as \(t.preferredFilenameExtension ?? t.identifier)."
            case .cannotKeepFormat(let t): return "\(t.preferredFilenameExtension?.uppercased() ?? t.identifier) cannot be written; choose JPEG, PNG, HEIC or TIFF."
            }
        }
    }

    public static func render(_ source: SourceImage, spec: RenderSpec) throws -> CGImage {
        let t = spec.target
        // The solver keeps inside Limits; a hand-built spec must too (review 2026-09-06).
        guard t.width >= 1, t.height >= 1, t.width <= Limits.maxDimension, t.height <= Limits.maxDimension,
              t.pixelCount <= Limits.maxPixels else { throw RenderError.targetTooLarge(t) }
        let wantsAlpha = spec.padNeedsAlpha(sourceType: source.type)
        // Colour space, depth and alpha follow the ICC policy (PRD §10.2).
        let plan = ColorPlan(source: source, spec: spec)
        guard let ctx = plan.makeContext(width: t.width, height: t.height) else { throw RenderError.contextFailed }
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
            // Pad colours are sRGB values; CoreGraphics matches them into the
            // working space, so padding looks the same whatever the ICC policy.
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
        // Strip: the same sRGB pixels, retagged as device RGB, which ImageIO
        // writes without a profile.
        if !plan.embedsProfile { return out.copy(colorSpace: CGColorSpaceCreateDeviceRGB()) ?? out }
        return out
    }

    /// Encodes without a source, so without metadata: nothing is there to keep.
    public static func encode(_ image: CGImage, spec: RenderSpec, sourceType: UTType) throws -> Data {
        try encode(image, spec: spec, sourceType: sourceType, sourceProperties: [:], sourceMetadata: nil)
    }

    /// Encodes keeping what `spec.metadata` says of the source's EXIF, GPS,
    /// IPTC and XMP packet (PRD §10.2), with the fixes of §10.4: no embedded
    /// thumbnail, pixel dimensions of the output, orientation 1.
    ///
    /// The XMP switch governs the source's own packet only. ImageIO derives a
    /// packet by itself from kept EXIF / TIFF / IPTC (always on PNG and HEIC,
    /// where IPTC can live only as XMP); that one belongs to those sections, so
    /// "strip XMP, keep IPTC" still writes it (issue #18).
    public static func encode(_ image: CGImage, spec: RenderSpec, source: SourceImage) throws -> Data {
        try encode(image, spec: spec, sourceType: source.type, sourceProperties: source.properties,
                   sourceMetadata: source.metadata)
    }

    private static func encode(_ image: CGImage, spec: RenderSpec, sourceType: UTType,
                               sourceProperties: [CFString: Any], sourceMetadata: ImageMetadata?) throws -> Data {
        guard let type = spec.format.resolvedType(for: sourceType) else {
            throw RenderError.cannotKeepFormat(sourceType)
        }
        let size = PixelSize(image.width, image.height)
        var kept = MetadataWriter.properties(from: sourceProperties, policy: spec.metadata, type: type, size: size,
                                             carrying: sourceMetadata)
        // The kept part of the source's packet; the dictionaries still say
        // what goes into the EXIF, GPS and IPTC blocks.
        let xmp = sourceMetadata.flatMap { XMPWriter.metadata(from: $0, policy: spec.metadata, type: type, size: size) }
        func write(_ kept: [CFString: Any]) throws -> Data {
            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)
            else { throw RenderError.encodeFailed(type) }
            var props = MetadataWriter.encoderProperties(kept)
            if spec.format.isLossy(for: sourceType) {
                props[kCGImageDestinationLossyCompressionQuality] = spec.quality
            }
            if let xmp {
                CGImageDestinationAddImageAndMetadata(dest, image, xmp, props as CFDictionary)
            } else {
                CGImageDestinationAddImage(dest, image, props as CFDictionary)
            }
            guard CGImageDestinationFinalize(dest) else { throw RenderError.encodeFailed(type) }
            return data as Data
        }
        var data = try write(kept)
        // An AI user comment outside ASCII is encoded after ImageIO (`MetadataWriter.PendingUserComment`).
        if let pending = kept[MetadataWriter.pendingUserCommentKey] as? MetadataWriter.PendingUserComment {
            if let done = pending.applied(to: data) {
                data = done
            } else {
                kept = MetadataWriter.lettingImageIOEncodeUserComment(kept)
                data = try write(kept)
            }
        }
        return MetadataWriter.finish(data, type: type, written: kept)
    }

    /// Render and encode in one go; the byte count is what the UI shows (PRD §8).
    public static func produce(_ source: SourceImage, spec: RenderSpec) throws -> Data {
        let encoded = try encode(try render(source, spec: spec), spec: spec, source: source)
        return PNGSplicer.keepingAIWorkflow(encoded, from: source, spec: spec)
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
