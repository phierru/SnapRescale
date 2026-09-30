import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// A decoded source image with its EXIF orientation already baked into the
/// pixels (PRD §10: orientation is always normalised).
public struct SourceImage: @unchecked Sendable {
    public let url: URL
    public let image: CGImage
    public let size: PixelSize
    public let fileSize: Int
    public let type: UTType
    public let metadata: ImageMetadata
    /// ImageIO's property dictionary of the file, as captured at load: what the
    /// encoder filters by the metadata policy (PRD §10.2). Read-only by convention.
    public let properties: [CFString: Any]

    public var hasAlpha: Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    public enum LoadError: Error, LocalizedError {
        case notAnImage(URL)
        case undecodable(URL)
        /// The declared pixels would decode to more than `maxDecodedBytes`.
        case tooLarge(URL, size: PixelSize, bitsPerComponent: Int)

        public var errorDescription: String? {
            switch self {
            case .notAnImage(let url): return "\(url.lastPathComponent) is not an image."
            case .undecodable(let url): return "\(url.lastPathComponent) could not be decoded."
            case let .tooLarge(url, size, bits):
                let limit = SourceImage.maxDecodedBytes / SourceImage.bytesPerPixel(bitsPerComponent: bits) / Int(Megapixel.pixels)
                return "\(url.lastPathComponent) is too large to open: \(size), \(String(format: "%.0f", size.megapixels)) MP "
                    + "(limit \(limit) MP at \(bits) bits per channel)."
            }
        }
    }

    /// The most memory the decoded source pixels may take: 4 GiB. That is about
    /// 1070 MP at 8 bits per channel and 530 MP at 16, so any large photograph or
    /// AI upscale opens, as does everything the renderer can write (`Limits.maxPixels`
    /// at 16 bits is 4 GB), while a small file that merely declares billions of
    /// pixels is refused before ImageIO allocates them (review 2026-09-30, hardening).
    /// Above the limit `load` throws `LoadError.tooLarge`; it never downsamples.
    public static let maxDecodedBytes = 4 << 30

    /// Decoded size of one pixel: four channels, each rounded up to whole bytes.
    /// An upper bound; ImageIO may decode grey or opaque sources to less.
    static func bytesPerPixel(bitsPerComponent: Int) -> Int { 4 * max(1, (min(max(bitsPerComponent, 1), 64) + 7) / 8) }

    /// What decoding `width` × `height` would take, nil when that does not fit in `Int`.
    static func estimatedDecodedBytes(width: Int, height: Int, bitsPerComponent: Int) -> Int? {
        guard width > 0, height > 0, let pixels = PixelSize(width, height).checkedPixelCount else { return nil }
        let (bytes, overflow) = pixels.multipliedReportingOverflow(by: bytesPerPixel(bitsPerComponent: bitsPerComponent))
        return overflow ? nil : bytes
    }

    /// Checks the dimensions and depth a file declares against the budget, from
    /// its properties alone: no pixels are requested.
    static func checkDecodeBudget(_ props: [CFString: Any], url: URL, limit: Int = maxDecodedBytes) throws -> PixelSize {
        guard let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0
        else { throw LoadError.undecodable(url) }
        let bits = props[kCGImagePropertyDepth] as? Int ?? 8
        guard let bytes = estimatedDecodedBytes(width: w, height: h, bitsPerComponent: bits), bytes <= limit
        else { throw LoadError.tooLarge(url, size: PixelSize(w, h), bitsPerComponent: bits) }
        return PixelSize(w, h)
    }

    public static func load(_ url: URL) throws -> SourceImage {
        try load(url, maxDecodedBytes: maxDecodedBytes)
    }

    /// `load` with a budget of the caller's choosing, for tests.
    static func load(_ url: URL, maxDecodedBytes: Int) throws -> SourceImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let typeID = CGImageSourceGetType(source),
              let type = UTType(typeID as String), type.conforms(to: .image)
        else { throw LoadError.notAnImage(url) }

        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { throw LoadError.undecodable(url) }
        // Before any pixels: the header alone decides whether this is worth decoding.
        let declared = try checkDecodeBudget(props, url: url, limit: maxDecodedBytes)

        // Ask ImageIO for a full-size "thumbnail" with the orientation transform
        // applied: one call, and the result is upright at native resolution.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(declared.width, declared.height),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { throw LoadError.undecodable(url) }

        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let bytes = try? Data(contentsOf: url, options: .mappedIfSafe)
        let metadata = ImageMetadata.inspect(source: source, data: bytes, type: type)
        return SourceImage(url: url, image: image,
                           size: PixelSize(image.width, image.height),
                           fileSize: fileSize, type: type, metadata: metadata, properties: props)
    }
}
