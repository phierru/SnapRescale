import UniformTypeIdentifiers

/// The encoder to use. `keepOriginal` resolves to the source's own type when
/// ImageIO can write it, so a resize is only a resize (PRD §9).
public enum OutputFormat: Hashable, Sendable, Codable, CaseIterable {
    case keepOriginal
    case jpeg
    case png
    case heic
    case tiff

    public var label: String {
        switch self {
        case .keepOriginal: return "Keep original"
        case .jpeg: return "JPEG"
        case .png: return "PNG"
        case .heic: return "HEIC"
        case .tiff: return "TIFF"
        }
    }

    /// Types ImageIO can encode on this platform that v1 exposes.
    static let writable: [UTType] = [.jpeg, .png, .heic, .tiff]

    /// The encoder type, or `nil` when `keepOriginal` cannot keep this source
    /// (GIF, WebP, RAW, …). Never silently substitutes a format.
    public func resolvedType(for source: UTType) -> UTType? {
        switch self {
        case .keepOriginal: return Self.writable.first { source.conforms(to: $0) }
        case .jpeg: return .jpeg
        case .png: return .png
        case .heic: return .heic
        case .tiff: return .tiff
        }
    }

    public func isAvailable(for source: UTType) -> Bool { resolvedType(for: source) != nil }

    /// What to switch to when the source cannot be kept: PNG if the source
    /// carries alpha, JPEG otherwise.
    public static func fallback(for source: UTType, hasAlpha: Bool) -> OutputFormat {
        hasAlpha ? .png : .jpeg
    }

    /// Whether the resolved encoder takes a quality setting.
    public func isLossy(for source: UTType) -> Bool {
        let t = resolvedType(for: source)
        return t == .jpeg || t == .heic
    }

    public func supportsAlpha(for source: UTType) -> Bool {
        guard let t = resolvedType(for: source) else { return false }
        return t == .png || t == .heic || t == .tiff
    }
}
