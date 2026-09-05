import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What a source file carries besides pixels (PRD §10, `docs/reference/image-metadata.md`).
/// Detection only; nothing here is written back yet.
public struct ImageMetadata: Hashable, Sendable {
    public var hasEXIF = false
    public var hasGPS = false
    public var hasIPTC = false
    public var hasXMP = false
    public var iccProfileName: String?
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
        if let icc = iccProfileName { out.append(Badge(label: "ICC", detail: "Colour profile: \(icc)", tone: .neutral)) }
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

        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            m.hasEXIF = hasRealEXIF(props)
            m.hasGPS = nonEmpty(props[kCGImagePropertyGPSDictionary])
            m.hasIPTC = nonEmpty(props[kCGImagePropertyIPTCDictionary])
            m.iccProfileName = props[kCGImagePropertyProfileName] as? String
            m.colorModel = props[kCGImagePropertyColorModel] as? String
            m.bitDepth = props[kCGImagePropertyDepth] as? Int ?? 8
            m.hasAlpha = props[kCGImagePropertyHasAlpha] as? Bool ?? false
            m.orientation = props[kCGImagePropertyOrientation] as? Int ?? 1

            let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
            let png = props[kCGImagePropertyPNGDictionary] as? [CFString: Any]
            let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
            // ImageIO files a JPEG's ImageDescription under IPTC caption; check both.
            let description = (tiff?[kCGImagePropertyTIFFImageDescription] as? String)
                ?? (iptc?[kCGImagePropertyIPTCCaptionAbstract] as? String) ?? ""
            let userComment = (exif?[kCGImagePropertyExifUserComment] as? String) ?? ""
            let software = (tiff?[kCGImagePropertyTIFFSoftware] as? String)
                ?? (png?[kCGImagePropertyPNGSoftware] as? String) ?? ""

            if description.contains("Job ID:") { m.provenance.append(.midjourney) }
            if looksLikeA1111(userComment) { m.provenance.append(.a1111) }
            if software.hasPrefix("NovelAI") { m.provenance.append(.novelAI) }
        }

        m.hasXMP = hasXMPTags(source)
        m.hasHDR = hasAuxiliary(source, [kCGImageAuxiliaryDataTypeHDRGainMap, kCGImageAuxiliaryDataTypeISOGainMap])
        m.hasDepth = hasAuxiliary(source, [kCGImageAuxiliaryDataTypeDepth, kCGImageAuxiliaryDataTypeDisparity,
                                           kCGImageAuxiliaryDataTypePortraitEffectsMatte])

        if let data {
            if type.conforms(to: .png) {
                let chunks = PNGScanner.textChunks(in: data)
                m.pngTextKeywords = chunks.map(\.keyword)
                m.provenance.append(contentsOf: provenance(fromPNGChunks: chunks))
                if PNGScanner.hasChunk("caBX", in: data) { m.provenance.append(.c2pa) }
            } else if type.conforms(to: .jpeg) {
                if JPEGScanner.hasC2PA(in: data) { m.provenance.append(.c2pa) }
            }
        }

        // Dedupe, keep first-seen order.
        var seen = Set<Provenance>()
        m.provenance = m.provenance.filter { seen.insert($0).inserted }
        return m
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

    /// ImageIO folds EXIF/TIFF into the metadata tree; only other namespaces prove a real XMP packet.
    private static func hasXMPTags(_ source: CGImageSource) -> Bool {
        guard let meta = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
              let tags = CGImageMetadataCopyTags(meta) as? [CGImageMetadataTag] else { return false }
        let synthesised: Set<String> = ["exif", "exifEX", "exifAux", "tiff", "GPS", "gps"]
        return tags.contains { tag in
            guard let prefix = CGImageMetadataTagCopyPrefix(tag) as String? else { return false }
            return !synthesised.contains(prefix)
        }
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
}

/// Minimal PNG chunk walker: keywords (and text for uncompressed chunks) of
/// `tEXt` / `iTXt` / `zTXt`, and presence of any named chunk.
public enum PNGScanner {
    public struct TextChunk: Hashable, Sendable {
        public let keyword: String
        /// Nil for zTXt and compressed iTXt (we don't inflate; the keyword is enough).
        public let text: String?
    }

    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    public static func textChunks(in data: Data) -> [TextChunk] {
        var out: [TextChunk] = []
        forEachChunk(in: data) { type, body in
            switch type {
            case "tEXt":
                if let nul = body.firstIndex(of: 0) {
                    let keyword = String(decoding: body[body.startIndex..<nul], as: UTF8.self)
                    let text = String(decoding: body[(nul + 1)...], as: UTF8.self)
                    out.append(TextChunk(keyword: keyword, text: text))
                }
            case "zTXt":
                if let nul = body.firstIndex(of: 0) {
                    out.append(TextChunk(keyword: String(decoding: body[body.startIndex..<nul], as: UTF8.self), text: nil))
                }
            case "iTXt":
                // keyword\0 compressionFlag(1) method(1) language\0 translated\0 text
                guard let nul = body.firstIndex(of: 0), nul + 2 < body.endIndex else { return }
                let keyword = String(decoding: body[body.startIndex..<nul], as: UTF8.self)
                let compressed = body[nul + 1] != 0
                var i = nul + 3
                guard let langEnd = body[i...].firstIndex(of: 0) else { return }
                i = langEnd + 1
                guard let transEnd = body[i...].firstIndex(of: 0) else { return }
                i = transEnd + 1
                out.append(TextChunk(keyword: keyword, text: compressed ? nil : String(decoding: body[i...], as: UTF8.self)))
            default:
                break
            }
        }
        return out
    }

    public static func hasChunk(_ name: String, in data: Data) -> Bool {
        var found = false
        forEachChunk(in: data) { type, _ in if type == name { found = true } }
        return found
    }

    private static func forEachChunk(in data: Data, _ body: (String, Data) -> Void) {
        guard data.count > 8, Array(data.prefix(8)) == signature else { return }
        var i = data.startIndex + 8
        while i + 8 <= data.endIndex {
            let length = Int(UInt32(bigEndian: data[i..<i + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
            let type = String(decoding: data[i + 4..<i + 8], as: UTF8.self)
            let start = i + 8
            guard length >= 0, start + length + 4 <= data.endIndex else { return }
            body(type, data[start..<start + length])
            if type == "IEND" { return }
            i = start + length + 4
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
