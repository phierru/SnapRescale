import Foundation
import CoreGraphics
import ImageIO

/// One key / value row of the metadata inspector. The value is display-ready.
public struct MetadataField: Hashable, Sendable, Identifiable {
    public let key: String
    public let value: String
    public var id: String { key }

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// One inspector section (PRD §10.2) with its fields in display order. Keys are unique within a section.
public struct MetadataSection: Hashable, Sendable, Identifiable {
    /// Declared in inspector order.
    public enum Kind: String, CaseIterable, Hashable, Sendable {
        case exif = "EXIF"
        case gps = "GPS"
        case iptc = "IPTC"
        case xmp = "XMP"
        case icc = "ICC profile"
        case aiWorkflow = "AI workflow"
        case c2pa = "C2PA"
        case structure = "Structure"
    }

    public let kind: Kind
    public var fields: [MetadataField]
    public var id: Kind { kind }
    public var title: String { kind.rawValue }

    public init(kind: Kind, fields: [MetadataField] = []) {
        self.kind = kind
        self.fields = fields
    }

    /// The value for a key, if the section has it.
    public subscript(key: String) -> String? {
        fields.first { $0.key == key }?.value
    }

    /// Readable `Key: value` lines, for Copy (PRD §10.5).
    public var text: String {
        fields.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
    }

    /// Appends a field; a key already present gets a numeric suffix so ids stay unique.
    mutating func add(_ key: String, _ value: String) {
        var unique = key
        var n = 2
        while fields.contains(where: { $0.key == unique }) { unique = "\(key) (\(n))"; n += 1 }
        fields.append(MetadataField(key: unique, value: value))
    }

    /// Appends the fields whose keys are not there yet.
    mutating func addMissing(_ more: [MetadataField]) {
        for f in more where self[f.key] == nil { fields.append(f) }
    }
}

extension ImageMetadata {
    /// One AI-generation payload as found in the file: a ComfyUI graph, A1111 parameters, …
    public struct AIPayload: Hashable, Sendable, Identifiable {
        public let source: Provenance
        /// PNG text keyword (`prompt`, `workflow`, `parameters`, …) or tag name (`UserComment`, `ImageDescription`).
        public let name: String
        /// Where it was found, e.g. "PNG tEXt chunk", "EXIF UserComment".
        public let location: String
        /// The payload in full.
        public let text: String
        public var id: String { "\(source.rawValue).\(name)" }

        /// True when the text parses as a JSON object or array (export as `.json`, else `.txt`).
        public var isJSON: Bool {
            guard let first = text.first(where: { !$0.isWhitespace }), first == "{" || first == "[" else { return false }
            return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) != nil
        }
    }

    /// The section of a kind; nil when the source carries none of it.
    public func section(_ kind: MetadataSection.Kind) -> MetadataSection? {
        sections.first { $0.kind == kind }
    }

    /// Payloads of one AI source, in file order.
    public func aiPayloads(from source: Provenance) -> [AIPayload] {
        aiPayloads.filter { $0.source == source }
    }
}

// MARK: - Display values

enum MetadataFormat {
    static func bytes(_ count: Int) -> String { "‹\(count) bytes›" }

    /// Up to six decimals, trailing zeros trimmed.
    static func number(_ d: Double) -> String {
        if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
        var s = String(format: "%.6f", d)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    /// Any ImageIO property value as a display string; blobs become a byte-count placeholder.
    static func display(_ value: Any) -> String {
        switch value {
        case let s as String:
            return s
        case let d as Data:
            return bytes(d.count)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "Yes" : "No" }
            return number(n.doubleValue)
        case let a as [Any]:
            return a.map(display).joined(separator: ", ")
        case let d as [String: Any]:
            return d.keys.sorted().map { "\($0): \(display(d[$0]!))" }.joined(separator: "; ")
        default:
            return "\(value)"
        }
    }

    /// EXIF values with their customary units.
    static func exif(_ key: String, _ value: Any) -> String {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return display(value) }
        let d = n.doubleValue
        switch key {
        case "ExposureTime": return d > 0 && d < 1 ? "1/\(number((1 / d).rounded())) s" : "\(number(d)) s"
        case "FNumber": return "f/\(number(d))"
        case "FocalLength", "FocalLenIn35mmFilm": return "\(number(d)) mm"
        default: return display(value)
        }
    }

    /// A property dictionary as fields: the `first` keys in that order, then the rest alphabetically.
    static func fields(_ dict: [String: Any], first: [String] = [], skipping: Set<String> = [],
                       format: (String, Any) -> String = { display($1) }) -> [MetadataField] {
        let lead = first.filter { dict[$0] != nil }
        let rest = dict.keys.filter { !lead.contains($0) }.sorted()
        return (lead + rest).filter { !skipping.contains($0) }
            .map { MetadataField(key: $0, value: format($0, dict[$0]!)) }
    }

    static func orientation(_ o: Int) -> String {
        let names = [1: "upright", 2: "mirrored horizontally", 3: "rotated 180°", 4: "mirrored vertically",
                     5: "mirrored, rotated 90° CCW", 6: "rotated 90° CW", 7: "mirrored, rotated 90° CW",
                     8: "rotated 90° CCW"]
        guard let name = names[o] else { return "\(o)" }
        return o == 1 ? "1 (\(name))" : "\(o) (\(name)), normalised on load"
    }
}

// MARK: - XMP

enum XMPReader {
    /// ImageIO folds EXIF/TIFF into the metadata tree; in the fallback only other namespaces count.
    static let synthesisedPrefixes: Set<String> = ["exif", "exifEX", "exifAux", "tiff", "GPS", "gps"]
    /// ImageIO's own bookkeeping (`iio:hasXMP`, `iio:hasIIM`), never in a packet.
    static let internalPrefix = "iio"
    /// What ImageIO derives from the TIFF / EXIF dates and Software when there is no packet.
    static let derivedPaths: Set<String> = ["xmp:CreateDate", "xmp:ModifyDate", "xmp:CreatorTool", "photoshop:DateCreated"]
    /// Namespaces ImageIO fills from IPTC IIM and from TIFF description / artist / copyright.
    static let mirrorPrefixes: Set<String> = ["dc", "photoshop", "Iptc4xmpCore", "Iptc4xmpExt"]

    /// The properties really in a packet, mirrored `exif:` / `tiff:` ones included, as
    /// `prefix:name` paths, sorted. Nil when the packet does not parse.
    static func fields(packet: String) -> [MetadataField]? {
        guard let meta = CGImageMetadataCreateFromXMPData(Data(packet.utf8) as CFData) else { return nil }
        return fields(meta) { prefix, _ in prefix != internalPrefix }
    }

    /// Fallback for containers `XMPScanner` does not walk: ImageIO's merged tree
    /// minus what it synthesises. With ImageIO's `iio:hasXMP` marker the other
    /// namespaces are trusted; without it the derived dates and, when the file has
    /// IPTC or TIFF text tags to mirror, the mirror namespaces are dropped too.
    static func fields(_ source: CGImageSource, hasMirrorSources: Bool) -> [MetadataField] {
        guard let meta = CGImageSourceCopyMetadataAtIndex(source, 0, nil) else { return [] }
        let marked = CGImageMetadataCopyTagWithPath(meta, nil, "\(internalPrefix):hasXMP" as CFString) != nil
        return fields(meta) { prefix, path in
            guard prefix != internalPrefix, !synthesisedPrefixes.contains(prefix) else { return false }
            return marked || !(derivedPaths.contains(path) || (hasMirrorSources && mirrorPrefixes.contains(prefix)))
        }
    }

    private static func fields(_ meta: CGImageMetadata, where keep: (_ prefix: String, _ path: String) -> Bool) -> [MetadataField] {
        guard let tags = CGImageMetadataCopyTags(meta) as? [CGImageMetadataTag] else { return [] }
        var section = MetadataSection(kind: .xmp)
        let named: [(String, CGImageMetadataTag)] = tags.compactMap { tag in
            guard let prefix = CGImageMetadataTagCopyPrefix(tag) as String? else { return nil }
            let path = "\(prefix):\(CGImageMetadataTagCopyName(tag) as String? ?? "")"
            return keep(prefix, path) ? (path, tag) : nil
        }
        for (path, tag) in named.sorted(by: { $0.0 < $1.0 }) { section.add(path, value(tag)) }
        return section.fields
    }

    /// Flattens arrays (comma-separated) and structures (`{name: value; …}`).
    static func value(_ tag: CGImageMetadataTag) -> String {
        guard let v = CGImageMetadataTagCopyValue(tag) else { return "" }
        return render(v)
    }

    private static func render(_ any: Any) -> String {
        let ref = any as CFTypeRef
        if CFGetTypeID(ref) == CGImageMetadataTagGetTypeID() { return value(ref as! CGImageMetadataTag) }
        if let s = any as? String { return s }
        if let a = any as? [Any] { return a.map(render).joined(separator: ", ") }
        if let d = any as? [String: Any] {
            return "{" + d.keys.sorted().map { "\($0): \(render(d[$0]!))" }.joined(separator: "; ") + "}"
        }
        return MetadataFormat.display(any)
    }
}

// MARK: - ICC

/// Reads the few header fields and the description tag of an ICC profile.
enum ICCReader {
    static func fields(name: String?, colorModel: String?, profile: Data?) -> [MetadataField] {
        var s = MetadataSection(kind: .icc)
        if let name { s.add("Name", name) }
        let b = profile.map { [UInt8]($0) } ?? []
        if let d = description(b), !d.isEmpty { s.add("Description", d) }
        if let colorModel { s.add("Colour model", colorModel) }
        if b.count >= 128 {
            s.add("Version", "\(b[8]).\(b[9] >> 4).\(b[9] & 0x0F)")
            let classes = ["scnr": "Input device", "mntr": "Display device", "prtr": "Output device",
                           "link": "Device link", "spac": "Colour space", "abst": "Abstract", "nmcl": "Named colour"]
            let code = fourCC(b, 12)
            s.add("Profile class", classes[code] ?? code)
            s.add("Size", "\(b.count) bytes")
        }
        return s.fields
    }

    private static func u32(_ b: [UInt8], _ i: Int) -> Int? {
        guard i >= 0, i + 4 <= b.count else { return nil }
        return Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
    }

    private static func fourCC(_ b: [UInt8], _ i: Int) -> String {
        guard i + 4 <= b.count else { return "" }
        return String(decoding: b[i..<i + 4], as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    /// The `desc` tag: ASCII in v2 profiles, `mluc` (UTF-16BE) in v4.
    static func description(_ b: [UInt8]) -> String? {
        guard let count = u32(b, 128), count < 1024 else { return nil }
        for t in 0..<count {
            let entry = 132 + t * 12
            guard fourCC(b, entry) == "desc", let offset = u32(b, entry + 4), let size = u32(b, entry + 8),
                  offset + size <= b.count, size >= 12 else { continue }
            switch fourCC(b, offset) {
            case "desc":
                guard let n = u32(b, offset + 8), n > 0, offset + 12 + n <= b.count else { return nil }
                return String(decoding: b[(offset + 12)..<(offset + 12 + n)].prefix { $0 != 0 }, as: UTF8.self)
            case "mluc":
                guard let records = u32(b, offset + 8), records > 0,
                      let length = u32(b, offset + 20), let at = u32(b, offset + 24),
                      offset + at + length <= b.count else { return nil }
                return String(data: Data(b[(offset + at)..<(offset + at + length)]), encoding: .utf16BigEndian)
            default:
                return nil
            }
        }
        return nil
    }
}
