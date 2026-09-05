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

    public func resolvedType(for source: UTType) -> UTType {
        switch self {
        case .keepOriginal:
            return Self.writable.first { source.conforms(to: $0) } ?? .jpeg
        case .jpeg: return .jpeg
        case .png: return .png
        case .heic: return .heic
        case .tiff: return .tiff
        }
    }

    /// Whether the resolved encoder takes a quality setting.
    public func isLossy(for source: UTType) -> Bool {
        let t = resolvedType(for: source)
        return t == .jpeg || t == .heic
    }

    public func supportsAlpha(for source: UTType) -> Bool {
        let t = resolvedType(for: source)
        return t == .png || t == .heic || t == .tiff
    }
}
