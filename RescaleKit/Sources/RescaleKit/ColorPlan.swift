import Foundation
import CoreGraphics
import UniformTypeIdentifiers

/// How one render handles colour (PRD §10.2, ICC): the space the pixels are
/// drawn in, their depth, whether they carry alpha and whether the profile is
/// written. The renderer draws with it and the preview consults it, so what is
/// shown is what is written (PRD §7).
public struct ColorPlan: @unchecked Sendable {
    /// The working colour space: the source's own under `preserve` when it can
    /// be kept, sRGB otherwise.
    public let space: CGColorSpace
    /// 16 when the source has more than 8 bits per channel and the format can
    /// carry them (PNG 16, TIFF 16, HEIC 10); otherwise 8. JPEG is always 8.
    public let bitsPerComponent: Int
    /// An opaque source with opaque padding gets no alpha channel.
    public let hasAlpha: Bool
    /// False under `strip`: the pixels are sRGB and the file is left untagged.
    public let embedsProfile: Bool
    /// Whether the output stays in the source's colour space.
    public let keepsSourceSpace: Bool
    /// Why `preserve` could not keep the source's colour space, worded for the
    /// user; `nil` when it could, or when the policy did not ask for it.
    public let fallbackNote: String?

    public init(source: SourceImage, spec: RenderSpec) {
        let type = spec.format.resolvedType(for: source.type)
        // The decoder reports alpha for some opaque files (HEIC), so the file's
        // own properties have to agree.
        let alpha = (source.hasAlpha && source.metadata.hasAlpha) || spec.padNeedsAlpha(sourceType: source.type)
        let deep = source.image.bitsPerComponent > 8 && (type == .png || type == .tiff || type == .heic)
        let bits = deep ? 16 : 8
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        var space = sRGB
        var note: String?
        if spec.metadata.icc == .preserve {
            switch Self.sourceSpace(of: source, spec: spec, type: type, alpha: alpha, bits: bits) {
            case .kept(let s): space = s
            case .fallback(let reason): note = reason
            }
        }
        self.space = space
        self.bitsPerComponent = bits
        self.hasAlpha = alpha
        self.embedsProfile = spec.metadata.icc != .strip
        self.keepsSourceSpace = source.image.colorSpace.map { CFEqual($0, space) } ?? false
        self.fallbackNote = note
    }

    /// A bitmap context in the working space, or `nil` when CoreGraphics has none.
    public func makeContext(width: Int, height: Int) -> CGContext? {
        Self.context(space: space, bits: bitsPerComponent, alpha: hasAlpha, width: width, height: height)
    }

    // MARK: - Preserve, or say why not

    private enum Choice {
        case kept(CGColorSpace)
        case fallback(String)
    }

    private static func sourceSpace(of source: SourceImage, spec: RenderSpec, type: UTType?,
                                    alpha: Bool, bits: Int) -> Choice {
        let format = type?.preferredFilenameExtension?.uppercased() ?? "This format"
        guard let space = source.image.colorSpace else {
            return .fallback("The source has no colour space; the output is sRGB.")
        }
        // ImageIO hands CMYK and Lab files over already converted to RGB, so
        // their profile is gone before the renderer sees the pixels.
        if let named = source.metadata.colorModel, let decoded = name(of: space.model), named != decoded {
            return .fallback("\(named) source: it is decoded to \(decoded), so the output is sRGB and the \(named) profile is not kept.")
        }
        switch space.model {
        case .rgb:
            break
        case .monochrome:
            if spec.fit == .pad, let c = spec.padColor, c.alpha > 0, !(c.red == c.green && c.green == c.blue) {
                return .fallback("The pad colour is not grey, so the greyscale source is written as sRGB.")
            }
        case .cmyk:
            guard type == .jpeg || type == .tiff else {
                return .fallback("\(format) cannot hold CMYK pixels; the output is converted to sRGB.")
            }
            if alpha { return .fallback("CMYK cannot carry transparency; the output is converted to sRGB.") }
        default:
            return .fallback("This colour model cannot be rendered; the output is converted to sRGB.")
        }
        guard space.supportsOutput, context(space: space, bits: bits, alpha: alpha, width: 1, height: 1) != nil else {
            return .fallback("This colour space cannot be rendered\(alpha ? " with transparency" : ""); the output is converted to sRGB.")
        }
        return .kept(space)
    }

    /// The name ImageIO gives a colour model (`kCGImagePropertyColorModel`).
    private static func name(of model: CGColorSpaceModel) -> String? {
        switch model {
        case .rgb: return "RGB"
        case .monochrome: return "Gray"
        case .cmyk: return "CMYK"
        case .lab: return "Lab"
        default: return nil
        }
    }

    private static func context(space: CGColorSpace, bits: Int, alpha: Bool, width: Int, height: Int) -> CGContext? {
        // RGB has no three-byte pixel: an opaque one skips its fourth. ImageIO
        // writes that without an alpha channel.
        let opaque: CGImageAlphaInfo = space.model == .rgb ? .noneSkipLast : .none
        var info = (alpha ? CGImageAlphaInfo.premultipliedLast : opaque).rawValue
        if bits == 16 { info |= CGBitmapInfo.byteOrder16Little.rawValue }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: bits, bytesPerRow: 0,
                         space: space, bitmapInfo: info)
    }
}

extension MetadataPolicy {
    /// The ICC row of the capability table for one source (PRD §10.3): the
    /// format's own entry, or the reason `preserve` falls back to sRGB for this
    /// source — a CMYK file, a greyscale one padded in colour — so it is never
    /// silent.
    public static func iccCapability(for source: SourceImage, spec: RenderSpec) -> Capability {
        let table = capability(of: .icc, format: spec.format, source: source.type)
        guard table.canCarry else { return table }
        var preserving = spec
        preserving.metadata.icc = .preserve
        guard let note = ColorPlan(source: source, spec: preserving).fallbackNote else { return table }
        return .limited(note)
    }
}
