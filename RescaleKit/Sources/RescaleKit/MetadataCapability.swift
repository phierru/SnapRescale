import Foundation
import UniformTypeIdentifiers

/// The capability table read for one source (PRD §10.3, GitHub #19): whether a
/// section's switch is live for *this* file in the chosen output format, and
/// the short note the inspector shows under the section title.
extension MetadataPolicy {
    /// The reason an AI workflow switch is disabled outside PNG.
    public static let requiresPNGNote = "Requires PNG output"

    /// Whether `type` can carry a section of this source. Differs from the
    /// plain table for the AI workflow: a ComfyUI / InvokeAI graph lives in PNG
    /// text chunks and survives only in PNG, while A1111-style parameters also
    /// ride in the EXIF user comment. `type` is the resolved output type; `nil`
    /// (a source "Keep original" cannot keep) carries nothing.
    public static func capability(of section: Section, in type: UTType?, carrying metadata: ImageMetadata) -> Capability {
        guard let type else { return .none("This format cannot be written.") }
        let table = capability(of: section, in: type)
        guard section == .aiWorkflow, table.canCarry, !type.conforms(to: .png) else { return table }
        let payloads = metadata.aiPayloads
        guard payloads.contains(where: isPNGOnly) else { return table }
        if payloads.allSatisfy(isPNGOnly) { return .none(requiresPNGNote) }
        return .limited("Only the generation parameters are kept; the graph requires PNG output.")
    }

    /// The same for a loaded source and a render spec. The ICC row goes through
    /// `iccCapability(for:spec:)`, so a CMYK or Lab source that `preserve`
    /// cannot keep says so.
    public static func capability(of section: Section, for source: SourceImage, spec: RenderSpec) -> Capability {
        if section == .icc { return iccCapability(for: source, spec: spec) }
        return capability(of: section, in: spec.format.resolvedType(for: source.type), carrying: source.metadata)
    }

    /// What the inspector shows for one switch.
    public struct SwitchState: Hashable, Sendable {
        /// False when the output format cannot carry the section for this source.
        public var isEnabled: Bool
        /// The note for the option selected in the spec's policy: the reason the
        /// switch is disabled, a limit of the format that applies to this
        /// option, or that stripping also removes the copies held in XMP.
        public var note: String?
        /// Every note any option of this switch can show for this source and
        /// format, so a view can reserve their room and not reflow on a toggle.
        public var possibleNotes: [String]
    }

    public static func switchState(of section: Section, for source: SourceImage, spec: RenderSpec) -> SwitchState {
        let type = spec.format.resolvedType(for: source.type)
        let cap = capability(of: section, for: source, spec: spec)
        guard cap.canCarry else {
            let reason = cap.note ?? "This format cannot carry it."
            return SwitchState(isEnabled: false, note: reason, possibleNotes: [reason])
        }
        // The ICC fallback (CMYK, Lab, grey padded in colour) is whatever the
        // source-aware row adds to the format's own.
        let fallback = section == .icc && cap.note != type.flatMap({ capability(of: .icc, in: $0).note }) ? cap.note : nil

        func note(_ policy: MetadataPolicy, reserving: Bool) -> String? {
            guard let type else { return nil }
            let png = type.conforms(to: .png), heic = type.conforms(to: .heic)
            let format = png ? "PNG" : heic ? "HEIC" : "This format"
            switch section {
            case .icc:
                switch policy.icc {
                case .preserve: return fallback
                case .convertToSRGB: return heic ? "HEIC tags sRGB without a profile: same file as Strip." : nil
                case .strip:
                    if png { return "A PNG still carries a one-byte sRGB marker." }
                    return heic ? "HEIC tags sRGB without a profile: same file as sRGB." : nil
                }
            case .iptc:
                if policy.iptc == .keep { return png || heic ? "\(format) has no IPTC block; kept as the XMP copies." : nil }
            case .aiWorkflow:
                if policy.aiWorkflow == .keep {
                    if cap.note != nil, source.metadata.aiPayloads.contains(where: isPNGOnly) { return cap.note }
                    let moved = !png && source.metadata.aiPayloads.contains { isPNGChunk($0) && !isPNGOnly($0) }
                    return moved ? "Kept in the EXIF user comment." : nil
                }
                return nil
            case .exif, .gps, .xmp:
                if policy.keeps(section) { return nil }
            }
            // Stripping: the copies in a kept XMP packet go too (PRD §10.3).
            guard section != .xmp, source.metadata.hasXMP, reserving || policy.xmp == .keep,
                  capability(of: .xmp, in: type).canCarry, mirrors(section, in: source.metadata.xmpPacket)
            else { return nil }
            return "Also removed from XMP"
        }

        var all: [String] = []
        for option in options(of: section, from: spec.metadata) {
            if let n = note(option, reserving: true), !all.contains(n) { all.append(n) }
        }
        return SwitchState(isEnabled: true, note: note(spec.metadata, reserving: false), possibleNotes: all)
    }

    /// The policy with this section set to each of its options in turn.
    private static func options(of section: Section, from policy: MetadataPolicy) -> [MetadataPolicy] {
        if section == .icc {
            return ICC.allCases.map { var p = policy; p.icc = $0; return p }
        }
        return Action.allCases.map { var p = policy; p[section] = $0; return p }
    }

    /// Keep or strip for a two-way section. ICC reads `strip` or `keep`
    /// (preserve and sRGB both embed a profile) and is set to `preserve` / `strip`.
    public subscript(section: Section) -> Action {
        get { keeps(section) ? .keep : .strip }
        set {
            switch section {
            case .exif: exif = newValue
            case .gps: gps = newValue
            case .iptc: iptc = newValue
            case .xmp: xmp = newValue
            case .icc: icc = newValue == .keep ? .preserve : .strip
            case .aiWorkflow: aiWorkflow = newValue
            }
        }
    }

    // MARK: - Pieces

    private static func isPNGChunk(_ payload: ImageMetadata.AIPayload) -> Bool {
        payload.location.hasPrefix("PNG ")
    }

    /// A payload only PNG text chunks can hold: everything found in one except
    /// A1111-style `parameters` (A1111, Forge, Fooocus, SwarmUI), which the
    /// other formats take as the EXIF user comment.
    private static func isPNGOnly(_ payload: ImageMetadata.AIPayload) -> Bool {
        isPNGChunk(payload) && payload.name != "parameters"
    }

    /// Whether an XMP packet repeats fields of a section. A packet that was not
    /// read (containers `XMPScanner` does not walk) is assumed to.
    private static func mirrors(_ section: Section, in packet: String?) -> Bool {
        guard let packet else { return true }
        switch section {
        case .gps: return packet.contains("exif:GPS")
        case .exif: return packet.contains("tiff:") || packet.replacingOccurrences(of: "exif:GPS", with: "").contains("exif:")
        case .iptc: return ["dc:", "photoshop:", "Iptc4xmp"].contains { packet.contains($0) }
        default: return false
        }
    }
}
