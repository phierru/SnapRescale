import Foundation

// Readable JSON for the enums that appear in preset files (PRD §12: "editable,
// diffable, and shareable"). Swift's synthesised form — `{"megapixels":{"_0":1.5}}`,
// `{"original":{}}` — is not something a person edits.

extension AspectRatio {
    /// "original" or "16:9".
    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        if s.lowercased() == "original" { self = .original; return }
        let parts = s.split(separator: ":").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "aspect must be \"original\" or \"W:H\", got \"\(s)\""))
        }
        self = .fixed(width: parts[0], height: parts[1])
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(label)
    }
}

extension SizeParameter {
    /// `{"width": 1920}`, `{"height": 1080}`, `{"megapixels": 1.5}` or `{"scale": 0.5}`.
    private enum Key: String, CodingKey { case width, height, megapixels, scale }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        if let v = try c.decodeIfPresent(Int.self, forKey: .width) { self = .width(v); return }
        if let v = try c.decodeIfPresent(Int.self, forKey: .height) { self = .height(v); return }
        if let v = try c.decodeIfPresent(Double.self, forKey: .megapixels) { self = .megapixels(v); return }
        if let v = try c.decodeIfPresent(Double.self, forKey: .scale) { self = .scale(v); return }
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "size needs one of width, height, megapixels, scale"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .width(let v): try c.encode(v, forKey: .width)
        case .height(let v): try c.encode(v, forKey: .height)
        case .megapixels(let v): try c.encode(v, forKey: .megapixels)
        case .scale(let v): try c.encode(v, forKey: .scale)
        }
    }
}

extension OutputFormat {
    /// "keep", "jpeg", "png", "heic", "tiff".
    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self).lowercased()
        switch s {
        case "keep", "keeporiginal", "original": self = .keepOriginal
        case "jpeg", "jpg": self = .jpeg
        case "png": self = .png
        case "heic": self = .heic
        case "tiff", "tif": self = .tiff
        default: throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown format \"\(s)\""))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .keepOriginal: try c.encode("keep")
        case .jpeg: try c.encode("jpeg")
        case .png: try c.encode("png")
        case .heic: try c.encode("heic")
        case .tiff: try c.encode("tiff")
        }
    }
}

extension PadColor {
    /// "#rrggbb" or "#rrggbbaa".
    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let c = PadColor(hex: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "padColor must be #rrggbb or #rrggbbaa, got \"\(s)\""))
        }
        self = c
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(hex)
    }

    public init?(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6 || h.count == 8, let v = UInt32(h, radix: 16) else { return nil }
        let hasAlpha = h.count == 8
        let r = Double((v >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = Double((v >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = Double((v >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? Double(v & 0xFF) / 255 : 1
        self.init(red: r, green: g, blue: b, alpha: a)
    }

    public var hex: String {
        func byte(_ d: Double) -> String { String(format: "%02x", Int((min(max(d, 0), 1) * 255).rounded())) }
        return "#" + byte(red) + byte(green) + byte(blue) + (alpha < 1 ? byte(alpha) : "")
    }
}
