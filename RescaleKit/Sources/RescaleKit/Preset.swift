import Foundation

/// A named bundle of every geometry and encoder setting (PRD §12): the thing
/// that turns the panel into one click. Stored as JSON so it is editable,
/// diffable and shareable.
public struct Preset: Hashable, Sendable, Codable, Identifiable {
    public var name: String
    public var aspect: AspectRatio
    public var size: SizeParameter
    public var multiple: Multiple
    public var fit: FitPolicy
    public var padColor: PadColor?
    public var format: OutputFormat
    public var quality: Double

    public var id: String { name }

    public init(name: String, aspect: AspectRatio = .original, size: SizeParameter, multiple: Multiple = .eight,
                fit: FitPolicy = .crop, padColor: PadColor? = .white, format: OutputFormat = .keepOriginal,
                quality: Double = 0.95) {
        self.name = name
        self.aspect = aspect
        self.size = size
        self.multiple = multiple
        self.fit = fit
        self.padColor = padColor
        self.format = format
        self.quality = quality
    }

    public var request: ResizeRequest { ResizeRequest(aspect: aspect, size: size, multiple: multiple) }

    /// One-line summary for menus: "Original · 1.5 MP · JPEG 80".
    public var summary: String {
        var parts = [aspect.label]
        switch size {
        case .width(let w): parts.append("\(w) px wide")
        case .height(let h): parts.append("\(h) px tall")
        case .megapixels(let mp): parts.append(String(format: "%g MP", mp))
        case .scale(let s): parts.append(String(format: "%g %%", s * 100))
        }
        if multiple != .one { parts.append("×\(multiple.rawValue)") }
        if fit == .pad { parts.append("pad") }
        parts.append(format == .keepOriginal ? "keep format" : "\(format.label) \(Int((quality * 100).rounded()))")
        return parts.joined(separator: " · ")
    }

    /// The presets that ship (PRD §12). Email and Discord/Slack wait for the
    /// target-file-size search (roadmap v1.2).
    public static let shipped: [Preset] = [
        Preset(name: "Web", aspect: .original, size: .megapixels(1.5), multiple: .one, format: .jpeg, quality: 0.8),
        Preset(name: "Thumbnail", aspect: .fixed(width: 1, height: 1), size: .width(320), multiple: .one, fit: .crop),
        Preset(name: "Social 16:9", aspect: .fixed(width: 16, height: 9), size: .width(1920), multiple: .eight, fit: .crop),
        Preset(name: "SDXL 1024", aspect: .fixed(width: 1, height: 1), size: .width(1024), multiple: .sixteen, fit: .crop, format: .png),
    ]

    // MARK: - JSON

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    public func jsonData() throws -> Data { try Self.encoder.encode(self) }
    public static func from(json: Data) throws -> Preset { try JSONDecoder().decode(Preset.self, from: json) }

    /// Safe file name: "Social 16:9" → "Social 16-9.json".
    public var fileName: String {
        let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        return name.components(separatedBy: bad).joined(separator: "-") + ".json"
    }
}
