import UniformTypeIdentifiers

/// What Save keeps of the source's metadata, block by block (PRD §10.2). It
/// keeps or strips; it never edits a field.
///
/// Two inspector sections have no policy and so no property here: **C2PA** is
/// always stripped — the signature binds the original pixels, so a resized file
/// would read as tampered — and **Structure** (alpha, bit depth, HDR, depth,
/// frames, orientation) is read-only, because it describes the pixels rather
/// than metadata.
public struct MetadataPolicy: Hashable, Sendable, Codable {
    /// Keep or strip one block.
    public enum Action: String, CaseIterable, Hashable, Sendable, Codable {
        case keep
        case strip
    }

    /// The colour profile has three options, not two (PRD §10.2).
    public enum ICC: Hashable, Sendable, Codable, CaseIterable {
        /// Embed the source's profile unchanged.
        case preserve
        /// Convert the pixels to sRGB and embed that.
        case convertToSRGB
        /// Write no profile.
        case strip
    }

    /// The sections that have a switch, in inspector order.
    public enum Section: String, CaseIterable, Hashable, Sendable, Codable {
        case exif
        case gps
        case iptc
        case xmp
        case icc
        case aiWorkflow

        public var label: String {
            switch self {
            case .exif: return "EXIF"
            case .gps: return "GPS"
            case .iptc: return "IPTC"
            case .xmp: return "XMP"
            case .icc: return "ICC profile"
            case .aiWorkflow: return "AI workflow"
            }
        }
    }

    /// State of the master control: it reads `custom` as soon as sections differ.
    public enum Summary: Hashable, Sendable {
        case keepAll
        case stripAll
        case custom
    }

    /// Camera, lens, exposure, date; includes the TIFF tags.
    public var exif: Action
    /// Stored inside EXIF but switched on its own: the one people strip for privacy.
    public var gps: Action
    public var iptc: Action
    public var xmp: Action
    public var icc: ICC
    /// ComfyUI, A1111, InvokeAI, NovelAI, Fooocus, SwarmUI, Midjourney.
    public var aiWorkflow: Action

    /// The defaults are the default policy: keep everything except GPS.
    public init(exif: Action = .keep, gps: Action = .strip, iptc: Action = .keep, xmp: Action = .keep,
                icc: ICC = .preserve, aiWorkflow: Action = .keep) {
        self.exif = exif
        self.gps = gps
        self.iptc = iptc
        self.xmp = xmp
        self.icc = icc
        self.aiWorkflow = aiWorkflow
    }

    /// Keep everything except GPS: honours "never silently degrade" and still
    /// protects privacy (PRD §10.2).
    public static let `default` = MetadataPolicy()
    public static let keepAll = MetadataPolicy(gps: .keep)
    public static let stripAll = MetadataPolicy(exif: .strip, gps: .strip, iptc: .strip, xmp: .strip,
                                                icc: .strip, aiWorkflow: .strip)

    /// Converting to sRGB is neither keeping nor stripping, so it reads `custom`.
    public var summary: Summary {
        if self == .keepAll { return .keepAll }
        if self == .stripAll { return .stripAll }
        return .custom
    }

    /// Whether anything of the section is written. Converting to sRGB still
    /// embeds a profile, so it counts.
    public func keeps(_ section: Section) -> Bool {
        switch section {
        case .exif: return exif == .keep
        case .gps: return gps == .keep
        case .iptc: return iptc == .keep
        case .xmp: return xmp == .keep
        case .icc: return icc != .strip
        case .aiWorkflow: return aiWorkflow == .keep
        }
    }

    // MARK: - What each format can carry

    /// Whether an output format can carry a section. The inspector disables the
    /// switch of one it cannot and shows `note`, rather than dropping the data
    /// silently (PRD §10.3).
    public struct Capability: Hashable, Sendable {
        public var canCarry: Bool
        /// Worded for the user. Always set when `canCarry` is false; set when it
        /// is true only if something is lost all the same.
        public var note: String?

        public static let full = Capability(canCarry: true, note: nil)
        public static func limited(_ note: String) -> Capability { Capability(canCarry: true, note: note) }
        public static func none(_ reason: String) -> Capability { Capability(canCarry: false, note: reason) }
    }

    /// The capability table (PRD §10.3). Covers every type `OutputFormat` can
    /// resolve to, plus GIF and BMP; any other type carries nothing.
    public static func capability(of section: Section, in type: UTType) -> Capability {
        if type.conforms(to: .png) {
            switch section {
            case .iptc: return .limited("PNG has no IPTC block. Caption, keywords and copyright are kept as their XMP copies.")
            default: return .full
            }
        }
        if type.conforms(to: .jpeg) {
            switch section {
            case .aiWorkflow: return .limited(partialWorkflowNote("JPEG"))
            default: return .full
            }
        }
        if type.conforms(to: .heic) {
            switch section {
            case .iptc: return .limited("HEIC has no IPTC block. Caption, keywords and copyright are kept as their XMP copies.")
            case .aiWorkflow: return .limited(partialWorkflowNote("HEIC"))
            default: return .full
            }
        }
        if type.conforms(to: .tiff) {
            switch section {
            case .aiWorkflow: return .limited(partialWorkflowNote("TIFF"))
            default: return .full
            }
        }
        if type.conforms(to: .gif) { return .none(nothingNote("GIF", section)) }
        if type.conforms(to: .bmp) { return .none(nothingNote("BMP", section)) }
        return .none("This format cannot carry \(phrase(section)).")
    }

    /// The same for a format choice. `keepOriginal` of a source that cannot be
    /// kept (GIF, WebP, RAW, …) resolves to no encoder, so it carries nothing.
    public static func capability(of section: Section, format: OutputFormat, source: UTType) -> Capability {
        guard let type = format.resolvedType(for: source) else {
            return .none("This format cannot be written, so it cannot carry \(phrase(section)).")
        }
        return capability(of: section, in: type)
    }

    private static func partialWorkflowNote(_ format: String) -> String {
        "\(format) keeps A1111-style parameters in the EXIF user comment, but cannot hold a ComfyUI or InvokeAI graph. Save as PNG to keep the graph."
    }

    private static func nothingNote(_ format: String, _ section: Section) -> String {
        switch section {
        case .aiWorkflow: return "\(format) cannot carry an AI workflow. Save as PNG to keep it."
        default: return "\(format) cannot carry \(phrase(section))."
        }
    }

    private static func phrase(_ section: Section) -> String {
        switch section {
        case .exif: return "EXIF data"
        case .gps: return "a GPS location"
        case .iptc: return "IPTC data"
        case .xmp: return "XMP data"
        case .icc: return "a colour profile"
        case .aiWorkflow: return "an AI workflow"
        }
    }
}
