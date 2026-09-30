import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What a source file carries besides pixels (PRD §10, `docs/reference/image-metadata.md`).
/// Presence flags for the badge row, and the contents for the inspector and the writer.
public struct ImageMetadata: Hashable, Sendable {
    public var hasEXIF = false
    public var hasGPS = false
    public var hasIPTC = false
    public var hasXMP = false
    /// The profile ImageIO names for the image. It names one even when the file
    /// carries none (sRGB by default): see `iccOrigin`.
    public var iccProfileName: String?
    /// Whether that profile is really in the file, only tagged, or assumed by macOS.
    public var iccOrigin: ICCOrigin = .assumed
    public var colorModel: String?
    public var bitDepth = 8
    public var hasAlpha = false
    public var hasHDR = false
    public var hasDepth = false
    /// EXIF orientation as found in the file, 1 = upright.
    public var orientation = 1
    public var frameCount = 1
    public var provenance: [Provenance] = []
    /// Keywords of PNG text chunks, in file order. Empty for other formats.
    public var pngTextKeywords: [String] = []
    /// What the file carries, section by section, in inspector order (PRD §10.2),
    /// as captured by `inspect`. Only sections with content appear; Structure always does.
    public var sections: [MetadataSection] = []
    /// Every PNG `tEXt` / `iTXt` / `zTXt` chunk in file order, with its text and
    /// raw bytes so the writer can splice it back unchanged. Empty for other formats.
    public var pngTextChunks: [PNGScanner.TextChunk] = []
    /// AI-generation payloads (ComfyUI graphs, A1111 parameters, …) in file order.
    public var aiPayloads: [AIPayload] = []
    /// Where the C2PA manifest was found, e.g. "JPEG APP11 segment (JUMBF)".
    public var c2paLocation: String?
    /// The XMP packet as stored in the file (JPEG APP1, PNG `iTXt`, TIFF tag 700,
    /// WebP `XMP ` chunk, HEIC `mime` item). Nil when the file has none, and for
    /// containers `XMPScanner` does not walk, where `hasXMP` comes from ImageIO.
    public var xmpPacket: String?
    /// A JPEG's extended XMP (the part over 64 KB), reassembled. A second RDF document.
    public var xmpExtendedPacket: String?

    public enum Provenance: String, CaseIterable, Hashable, Sendable {
        case comfyUI = "ComfyUI"
        case a1111 = "A1111"
        case invokeAI = "InvokeAI"
        case novelAI = "NovelAI"
        case fooocus = "Fooocus"
        case swarmUI = "SwarmUI"
        case midjourney = "Midjourney"
        case c2pa = "C2PA"

        public var detail: String {
            switch self {
            case .comfyUI: return "ComfyUI workflow embedded in PNG text chunks"
            case .a1111: return "Automatic1111 / Forge generation parameters"
            case .invokeAI: return "InvokeAI generation metadata"
            case .novelAI: return "NovelAI generation metadata"
            case .fooocus: return "Fooocus generation parameters"
            case .swarmUI: return "SwarmUI generation parameters"
            case .midjourney: return "Midjourney prompt and job ID"
            case .c2pa: return "Content Credentials (C2PA) manifest"
            }
        }
    }

    public struct Badge: Hashable, Sendable, Identifiable {
        public enum Tone: Hashable, Sendable { case neutral, warning, provenance }
        public let label: String
        public let detail: String
        public let tone: Tone
        public var id: String { label }
    }

    /// The badge row, in a stable order: structure, then blocks, then provenance.
    public var badges: [Badge] {
        var out: [Badge] = []
        // Only for a profile the file really embeds; an assumed sRGB is not something it carries.
        if iccIsEmbedded { out.append(Badge(label: "ICC", detail: "Colour profile: \(iccProfileName ?? "embedded")", tone: .neutral)) }
        if let model = colorModel, model != "RGB" { out.append(Badge(label: model, detail: "Colour model \(model)", tone: .neutral)) }
        if bitDepth > 8 { out.append(Badge(label: "\(bitDepth)-bit", detail: "\(bitDepth) bits per channel", tone: .neutral)) }
        if hasAlpha { out.append(Badge(label: "Alpha", detail: "Has an alpha channel", tone: .neutral)) }
        if hasHDR { out.append(Badge(label: "HDR", detail: "Carries an HDR gain map", tone: .neutral)) }
        if hasDepth { out.append(Badge(label: "Depth", detail: "Carries a depth map or portrait matte", tone: .neutral)) }
        if orientation != 1 { out.append(Badge(label: "Rotated", detail: "EXIF orientation \(orientation), normalised on load", tone: .neutral)) }
        if frameCount > 1 { out.append(Badge(label: "Animated ·\(frameCount)", detail: "\(frameCount) frames; only the first is used", tone: .warning)) }
        if hasEXIF { out.append(Badge(label: "EXIF", detail: "Camera and capture metadata", tone: .neutral)) }
        if hasGPS { out.append(Badge(label: "GPS", detail: "Location data", tone: .warning)) }
        if hasIPTC { out.append(Badge(label: "IPTC", detail: "Caption, keywords, credit", tone: .neutral)) }
        if hasXMP { out.append(Badge(label: "XMP", detail: "XMP packet (ratings, edits, rights, …)", tone: .neutral)) }
        for p in provenance { out.append(Badge(label: p.rawValue, detail: p.detail, tone: .provenance)) }
        return out
    }

    // MARK: - Detection

    public static func inspect(source: CGImageSource, data: Data?, type: UTType) -> ImageMetadata {
        var m = ImageMetadata()
        m.frameCount = CGImageSourceGetCount(source)
        var exif = MetadataSection(kind: .exif)
        var gps = MetadataSection(kind: .gps)
        var iptc = MetadataSection(kind: .iptc)
        var hasMirrorSources = false

        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            m.hasEXIF = hasRealEXIF(props)
            m.hasGPS = nonEmpty(props[kCGImagePropertyGPSDictionary])
            m.hasIPTC = nonEmpty(props[kCGImagePropertyIPTCDictionary])
            m.iccProfileName = props[kCGImagePropertyProfileName] as? String
            m.colorModel = props[kCGImagePropertyColorModel] as? String
            m.bitDepth = props[kCGImagePropertyDepth] as? Int ?? 8
            m.hasAlpha = props[kCGImagePropertyHasAlpha] as? Bool ?? false
            m.orientation = props[kCGImagePropertyOrientation] as? Int ?? 1

            let tiffDict = props[kCGImagePropertyTIFFDictionary] as? [String: Any] ?? [:]
            let exifDict = props[kCGImagePropertyExifDictionary] as? [String: Any] ?? [:]
            hasMirrorSources = m.hasIPTC || [kCGImagePropertyTIFFImageDescription, kCGImagePropertyTIFFArtist,
                                             kCGImagePropertyTIFFCopyright].contains { tiffDict[$0 as String] != nil }
            let pngDict = props[kCGImagePropertyPNGDictionary] as? [String: Any] ?? [:]
            let iptcDict = props[kCGImagePropertyIPTCDictionary] as? [String: Any] ?? [:]
            let tiffDescription = tiffDict[kCGImagePropertyTIFFImageDescription as String] as? String
            // ImageIO files a JPEG's ImageDescription under IPTC caption; check both.
            let description = tiffDescription
                ?? (iptcDict[kCGImagePropertyIPTCCaptionAbstract as String] as? String) ?? ""
            let userComment = (exifDict[kCGImagePropertyExifUserComment as String] as? String) ?? ""
            let software = (tiffDict[kCGImagePropertyTIFFSoftware as String] as? String)
                ?? (pngDict[kCGImagePropertyPNGSoftware as String] as? String) ?? ""

            if description.contains("Job ID:") {
                m.provenance.append(.midjourney)
                m.aiPayloads.append(AIPayload(source: .midjourney, name: "ImageDescription",
                                              location: tiffDescription != nil ? "TIFF ImageDescription" : "IPTC caption",
                                              text: description))
            }
            if looksLikeA1111(userComment) {
                m.provenance.append(.a1111)
                m.aiPayloads.append(AIPayload(source: .a1111, name: "UserComment", location: "EXIF UserComment",
                                              text: userComment))
            }
            if software.hasPrefix("NovelAI") { m.provenance.append(.novelAI) }

            if m.hasEXIF {
                // TIFF tags (IFD0) first, then the EXIF IFD and its lens extras.
                exif.fields = MetadataFormat.fields(tiffDict, first: tiffOrder)
                exif.addMissing(MetadataFormat.fields(exifDict, first: exifOrder, format: MetadataFormat.exif))
                let aux = props[kCGImagePropertyExifAuxDictionary] as? [String: Any] ?? [:]
                exif.addMissing(MetadataFormat.fields(aux))
                if let maker = props[kCGImagePropertyMakerAppleDictionary] as? [String: Any], !maker.isEmpty {
                    exif.add("Apple MakerNote", "‹\(maker.count) fields›")
                }
            }
            if m.hasGPS {
                gps.fields = MetadataFormat.fields(props[kCGImagePropertyGPSDictionary] as? [String: Any] ?? [:],
                                                   first: gpsOrder)
            }
            iptc.fields = MetadataFormat.fields(iptcDict, first: iptcOrder)
        }

        m.hasHDR = hasAuxiliary(source, [kCGImageAuxiliaryDataTypeHDRGainMap, kCGImageAuxiliaryDataTypeISOGainMap])
        m.hasDepth = hasAuxiliary(source, [kCGImageAuxiliaryDataTypeDepth, kCGImageAuxiliaryDataTypeDisparity,
                                           kCGImageAuxiliaryDataTypePortraitEffectsMatte])

        if let data {
            if type.conforms(to: .png) {
                let chunks = PNGScanner.textChunks(in: data)
                m.pngTextChunks = chunks
                m.pngTextKeywords = chunks.map(\.keyword)
                let found = provenance(fromPNGChunks: chunks)
                m.provenance.append(contentsOf: found)
                m.aiPayloads.append(contentsOf: payloads(fromPNGChunks: chunks, provenance: found))
                if PNGScanner.hasChunk("caBX", in: data) {
                    m.provenance.append(.c2pa)
                    m.c2paLocation = "PNG caBX chunk"
                }
            } else if type.conforms(to: .jpeg) {
                if JPEGScanner.hasC2PA(in: data) {
                    m.provenance.append(.c2pa)
                    m.c2paLocation = "JPEG APP11 segment (JUMBF)"
                }
            }
        }

        // XMP is what the file holds, not what ImageIO derives from EXIF / TIFF / IPTC.
        var xmp = MetadataSection(kind: .xmp)
        switch data.map({ XMPScanner.packet(in: $0, type: type, pngChunks: type.conforms(to: .png) ? m.pngTextChunks : nil) })
            ?? .notScanned {
        case .found(let packet, let extended):
            m.xmpPacket = packet
            m.xmpExtendedPacket = extended
            xmp.fields = XMPReader.fields(packet: packet) ?? []
            if let extended { xmp.addMissing(XMPReader.fields(packet: extended) ?? []) }
            // A packet that does not parse, or is empty, is still a packet.
            if xmp.fields.isEmpty { xmp.add("Packet", MetadataFormat.bytes(packet.utf8.count)) }
        case .absent:
            break
        case .notScanned:
            xmp.fields = XMPReader.fields(source, hasMirrorSources: hasMirrorSources)
        }
        m.hasXMP = !xmp.fields.isEmpty

        // Dedupe, keep first-seen order.
        var seen = Set<Provenance>()
        m.provenance = m.provenance.filter { seen.insert($0).inserted }
        // A PNG's Description can surface both through ImageIO and as a chunk.
        var seenPayloads = Set<[String]>()
        m.aiPayloads = m.aiPayloads.filter { seenPayloads.insert([$0.source.rawValue, $0.text]).inserted }

        // The colour space is read off a lazily decoded image; no pixels are touched.
        let profile = CGImageSourceCreateImageAtIndex(source, 0, nil)?.colorSpace?.copyICCData() as Data?
        var icc = MetadataSection(kind: .icc, fields: m.iccProfileName == nil && profile == nil ? []
            : ICCReader.fields(name: m.iccProfileName, colorModel: m.colorModel, profile: profile))
        // Embedded or assumed is read off the container; ImageIO answers for the ones not walked.
        m.iccOrigin = data.flatMap { ICCScanner.origin(in: $0, type: type) }
            ?? (m.iccProfileName != nil ? .embedded : .assumed)
        if !icc.fields.isEmpty {
            icc.fields.insert(MetadataField(key: "Embedded", value: m.iccEmbeddedValue), at: 0)
            icc.note = m.iccNote
        }

        m.sections = ([exif, gps, iptc, xmp, icc, m.aiWorkflowSection, m.c2paSection].filter { !$0.fields.isEmpty }
            + [m.structureSection]).map(MetadataLabels.decorated)
        return m
    }

    // Common tags lead; the rest follow alphabetically.
    static let tiffOrder = ["Make", "Model", "Software", "DateTime", "Artist", "Copyright", "ImageDescription"]
    static let exifOrder = ["DateTimeOriginal", "DateTimeDigitized", "LensMake", "LensModel", "ExposureTime", "FNumber",
                            "ISOSpeedRatings", "FocalLength", "FocalLenIn35mmFilm", "ExposureBiasValue", "Flash"]
    static let gpsOrder = ["Latitude", "LatitudeRef", "Longitude", "LongitudeRef", "Altitude", "AltitudeRef",
                           "DateStamp", "TimeStamp"]
    static let iptcOrder = ["ObjectName", "Headline", "Caption/Abstract", "Keywords", "Byline", "Credit", "Source",
                            "CopyrightNotice", "City", "Province/State", "Country/PrimaryLocationName"]

    /// Sources other than C2PA, then each payload in full.
    private var aiWorkflowSection: MetadataSection {
        var s = MetadataSection(kind: .aiWorkflow)
        let sources = provenance.filter { $0 != .c2pa }
        guard !sources.isEmpty else { return s }
        s.add("Source", sources.map(\.rawValue).joined(separator: ", "))
        for p in aiPayloads { s.add(sources.count > 1 ? "\(p.source.rawValue) \(p.name)" : p.name, p.text) }
        return s
    }

    private var c2paSection: MetadataSection {
        var s = MetadataSection(kind: .c2pa)
        guard provenance.contains(.c2pa) else { return s }
        s.add("Manifest", "Present")
        if let c2paLocation { s.add("Found in", c2paLocation) }
        return s
    }

    /// Shown with the Structure section when the source has an HDR gain map: the writer does not carry it.
    public static let hdrGainMapNote = "The HDR gain map is not carried into the saved file."

    /// `hdrGainMapNote` when the source has a gain map that Save will drop, else nil.
    public var hdrNote: String? { hasHDR ? Self.hdrGainMapNote : nil }

    /// Read-only facts about the pixels.
    var structureSection: MetadataSection {
        var s = MetadataSection(kind: .structure, note: hdrNote)
        s.add("Alpha", hasAlpha ? "Yes" : "No")
        s.add("Bit depth", "\(bitDepth) bits per channel")
        s.fields.append(MetadataField(key: "HDR gain map", value: hasHDR ? "Yes" : "No",
                                      readableValue: hasHDR ? "Yes, not carried into the saved file" : nil))
        s.add("Depth map", hasDepth ? "Yes" : "No")
        s.add("Frames", "\(frameCount)")
        s.add("Orientation", MetadataFormat.orientation(orientation))
        return s
    }

    /// ImageIO synthesises a small `{Exif}` block (pixel dimensions, colour
    /// space, version tags) for files that carry none. Only other keys count.
    static let synthesisedEXIFKeys: Set<String> = [
        kCGImagePropertyExifPixelXDimension, kCGImagePropertyExifPixelYDimension, kCGImagePropertyExifColorSpace,
        kCGImagePropertyExifVersion, kCGImagePropertyExifFlashPixVersion, kCGImagePropertyExifComponentsConfiguration,
        kCGImagePropertyExifGamma,
    ].map { $0 as String }.reduce(into: []) { $0.insert($1) }

    private static func hasRealEXIF(_ props: [CFString: Any]) -> Bool {
        if let exif = props[kCGImagePropertyExifDictionary] as? [String: Any],
           exif.keys.contains(where: { !synthesisedEXIFKeys.contains($0) }) {
            return true
        }
        // Camera make/model/date live in IFD0 and are EXIF to any user.
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            return tiff[kCGImagePropertyTIFFMake] != nil || tiff[kCGImagePropertyTIFFModel] != nil
                || tiff[kCGImagePropertyTIFFDateTime] != nil
        }
        return false
    }

    private static func nonEmpty(_ any: Any?) -> Bool {
        guard let dict = any as? [AnyHashable: Any] else { return false }
        return !dict.isEmpty
    }

    private static func hasAuxiliary(_ source: CGImageSource, _ types: [CFString]) -> Bool {
        types.contains { CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, $0) != nil }
    }

    static func looksLikeA1111(_ text: String) -> Bool {
        text.contains("Steps:") && (text.contains("Sampler:") || text.contains("CFG scale:"))
    }

    static func provenance(fromPNGChunks chunks: [PNGScanner.TextChunk]) -> [Provenance] {
        var out: [Provenance] = []
        let byKey = Dictionary(chunks.map { ($0.keyword, $0.text ?? "") }, uniquingKeysWith: { a, _ in a })
        if byKey["workflow"] != nil || (byKey["prompt"]?.contains("\"class_type\"") ?? false) { out.append(.comfyUI) }
        if byKey["fooocus_scheme"] != nil { out.append(.fooocus) }
        if let p = byKey["parameters"] {
            if p.contains("sui_image_params") { out.append(.swarmUI) }
            else if out.contains(.fooocus) { /* Fooocus also writes `parameters` */ }
            else if looksLikeA1111(p) { out.append(.a1111) }
        }
        if byKey["invokeai_metadata"] != nil || byKey["invokeai_graph"] != nil || byKey["sd-metadata"] != nil { out.append(.invokeAI) }
        if byKey["Software"]?.hasPrefix("NovelAI") ?? false { out.append(.novelAI) }
        if let d = byKey["Description"], d.contains("Job ID:") { out.append(.midjourney) }
        return out
    }

    /// The chunks that hold each detected source's payload, in file order.
    static func payloads(fromPNGChunks chunks: [PNGScanner.TextChunk], provenance found: [Provenance]) -> [AIPayload] {
        let has = Set(found)
        func source(for keyword: String) -> Provenance? {
            switch keyword {
            case "prompt", "workflow":
                return has.contains(.comfyUI) ? .comfyUI : nil
            case "parameters":
                return [.swarmUI, .fooocus, .a1111].first(where: has.contains)
            case "fooocus_scheme":
                return has.contains(.fooocus) ? .fooocus : nil
            case "invokeai_metadata", "invokeai_graph", "sd-metadata":
                return has.contains(.invokeAI) ? .invokeAI : nil
            case "Description":
                return [.novelAI, .midjourney].first(where: has.contains)
            case "Software", "Comment", "Title", "Source":
                return has.contains(.novelAI) ? .novelAI : nil
            default:
                return nil
            }
        }
        return chunks.compactMap { chunk in
            guard let text = chunk.text, let source = source(for: chunk.keyword) else { return nil }
            return AIPayload(source: source, name: chunk.keyword, location: "PNG \(chunk.type) chunk", text: text)
        }
    }
}

/// JPEG segment walker, used only to spot a C2PA / JUMBF APP11 segment.
public enum JPEGScanner {
    public static func hasC2PA(in data: Data) -> Bool {
        guard data.count > 4, data[data.startIndex] == 0xFF, data[data.startIndex + 1] == 0xD8 else { return false }
        var i = data.startIndex + 2
        while i + 4 <= data.endIndex {
            guard data[i] == 0xFF else { return false }
            let marker = data[i + 1]
            if marker == 0xD9 || marker == 0xDA { return false }          // EOI / SOS: no more headers
            let length = Int(data[i + 2]) << 8 | Int(data[i + 3])
            guard length >= 2, i + 2 + length <= data.endIndex else { return false }
            if marker == 0xEB {                                            // APP11
                let body = data[i + 4..<i + 2 + length]
                if body.prefix(2).elementsEqual([0x4A, 0x50]) || contains(body.prefix(64), ascii: "jumb") || contains(body.prefix(64), ascii: "c2pa") {
                    return true
                }
            }
            i += 2 + length
        }
        return false
    }

    private static func contains(_ bytes: Data, ascii: String) -> Bool {
        let pat = Array(ascii.utf8)
        guard bytes.count >= pat.count else { return false }
        let arr = Array(bytes)
        return (0...(arr.count - pat.count)).contains { Array(arr[$0..<$0 + pat.count]) == pat }
    }
}
