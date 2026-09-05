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

    public var hasAlpha: Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    public enum LoadError: Error, LocalizedError {
        case notAnImage(URL)
        case undecodable(URL)

        public var errorDescription: String? {
            switch self {
            case .notAnImage(let url): return "\(url.lastPathComponent) is not an image."
            case .undecodable(let url): return "\(url.lastPathComponent) could not be decoded."
            }
        }
    }

    public static func load(_ url: URL) throws -> SourceImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let typeID = CGImageSourceGetType(source),
              let type = UTType(typeID as String), type.conforms(to: .image)
        else { throw LoadError.notAnImage(url) }

        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { throw LoadError.undecodable(url) }

        // Ask ImageIO for a full-size "thumbnail" with the orientation transform
        // applied: one call, and the result is upright at native resolution.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { throw LoadError.undecodable(url) }

        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let bytes = try? Data(contentsOf: url, options: .mappedIfSafe)
        let metadata = ImageMetadata.inspect(source: source, data: bytes, type: type)
        return SourceImage(url: url, image: image,
                           size: PixelSize(image.width, image.height),
                           fileSize: fileSize, type: type, metadata: metadata)
    }
}
