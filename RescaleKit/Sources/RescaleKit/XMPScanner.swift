import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Finds the XMP packet in the container itself, so presence does not depend on
/// the tags ImageIO derives from EXIF / TIFF / IPTC (issue #22).
///
/// Scanned: JPEG (APP1), PNG (`iTXt`), TIFF (tag 700 of the first IFD), WebP
/// (`XMP ` chunk), HEIC / HEIF / AVIF (`mime` item). Everything else, and any
/// file too damaged to walk, is `.notScanned` and left to the ImageIO fallback.
public enum XMPScanner {
    public enum Result: Hashable, Sendable {
        /// The packet as stored, and the reassembled extended packet of a JPEG if any.
        case found(packet: String, extended: String?)
        /// The container was walked and holds no packet.
        case absent
        /// The container is not one we walk, or could not be walked.
        case notScanned
    }

    static let jpegNamespace = Array("http://ns.adobe.com/xap/1.0/".utf8) + [0]
    static let jpegExtensionNamespace = Array("http://ns.adobe.com/xmp/extension/".utf8) + [0]
    static let pngKeyword = "XML:com.adobe.xmp"
    static let mimeType = "application/rdf+xml"
    /// Ceiling on one packet, against damaged length fields.
    static let sizeLimit = 64 << 20

    public static func packet(in data: Data, type: UTType) -> Result {
        var budget = MetadataBudget()
        return packet(in: data, type: type, pngChunks: nil, budget: &budget)
    }

    /// `pngChunks` spares a second walk when the caller has them already, and
    /// were charged to `budget` then. What is assembled here draws on it too;
    /// TIFF and WebP packets are single runs of the file's own bytes.
    static func packet(in data: Data, type: UTType, pngChunks: [PNGScanner.TextChunk]?,
                       budget: inout MetadataBudget) -> Result {
        let bytes = Bytes(data)
        if type.conforms(to: .png) { return png(pngChunks ?? PNGScanner.textChunks(in: data, budget: &budget), bytes) }
        if type.conforms(to: .jpeg) { return jpeg(bytes, &budget) }
        if type.conforms(to: .tiff) { return tiff(bytes) }
        if type.conforms(to: .webP) { return webP(bytes) }
        if type.conforms(to: .heic) || type.conforms(to: .heif) || type.identifier == "public.avif" {
            return isoBMFF(bytes, &budget)
        }
        return .notScanned
    }

    // MARK: JPEG

    /// The standard packet is one APP1 segment; anything over 64 KB continues in
    /// extended segments (namespace, 32-byte GUID, total length, offset, portion).
    ///
    /// Only the extension the standard packet names in `xmpNote:HasExtendedXMP`
    /// is its own, and only when the portions agree on the total length and
    /// cover it exactly once (XMP Part 3 §1.1.3.1). Anything else is left out
    /// and reported through `budget.skipped`.
    static func jpeg(_ d: Bytes, _ budget: inout MetadataBudget) -> Result {
        guard d.count > 4, d[0] == 0xFF, d[1] == 0xD8 else { return .notScanned }
        var main: Data?
        var portions: [Portion] = []
        var unusable = false
        var i = 2
        while i + 4 <= d.count, d[i] == 0xFF {
            let marker = d[i + 1]
            if marker == 0xFF { i += 1; continue }                       // fill byte
            if marker == 0xD9 || marker == 0xDA { break }                 // EOI / SOS: no more headers
            let length = d.u16(i + 2)
            guard length >= 2, i + 2 + length <= d.count else { break }
            let start = i + 4, end = i + 2 + length
            if marker == 0xE1 {
                if main == nil, d.starts(with: jpegNamespace, at: start, end: end) {
                    main = d.slice(start + jpegNamespace.count, end)
                } else if d.starts(with: jpegExtensionNamespace, at: start, end: end) {
                    let header = start + jpegExtensionNamespace.count + 32
                    if header + 8 < end {
                        portions.append(Portion(guid: d.slice(header - 32, header), total: d.u32(header),
                                                offset: d.u32(header + 4), data: d.slice(header + 8, end)))
                    } else {
                        unusable = true
                    }
                }
            }
            i = end
        }
        guard let main else { return .absent }
        guard !portions.isEmpty || unusable else { return .found(packet: string(main), extended: nil) }

        let packet = string(main)
        let own = extensionGUID(in: packet).map { guid in portions.filter { $0.guid.elementsEqual(guid) } } ?? []
        let extended = assembled(own, &budget)
        if extended == nil || own.count != portions.count || unusable { budget.skipped.append(.extendedXMP) }
        return .found(packet: packet, extended: extended.map(string))
    }

    /// One extension segment: the packet's GUID (32 ASCII hex digits), its
    /// total length, and this portion's place in it.
    struct Portion { let guid: Data; let total: Int; let offset: Int; let data: Data }

    /// The GUID a standard packet names as its extension, found by namespace, not prefix.
    static func extensionGUID(in packet: String) -> [UInt8]? {
        guard let meta = CGImageMetadataCreateFromXMPData(Data(packet.utf8) as CFData),
              let tags = CGImageMetadataCopyTags(meta) as? [CGImageMetadataTag] else { return nil }
        for tag in tags where CGImageMetadataTagCopyNamespace(tag) as String? == XMPWriter.note
            && CGImageMetadataTagCopyName(tag) as String? == "HasExtendedXMP" {
            return (CGImageMetadataTagCopyValue(tag) as? String).map { Array($0.utf8) }
        }
        return nil
    }

    /// One group's portions joined in offset order, whatever their order in the
    /// file. Nil unless they agree on a total within the budget and each starts
    /// where the last ended, from 0 to that total: no gap, no overlap, no excess.
    static func assembled(_ portions: [Portion], _ budget: inout MetadataBudget) -> Data? {
        guard let total = portions.first?.total, total > 0, total <= sizeLimit, total <= budget.bytes,
              portions.allSatisfy({ $0.total == total }) else { return nil }
        var out = Data(capacity: total)
        for portion in portions.sorted(by: { $0.offset < $1.offset }) {
            guard portion.offset == out.count, portion.data.count <= total - out.count else { return nil }
            out.append(portion.data)
        }
        return out.count == total && budget.take(total) ? out : nil
    }

    // MARK: PNG

    static func png(_ chunks: [PNGScanner.TextChunk], _ d: Bytes) -> Result {
        guard d.count > 8, d.starts(with: PNGScanner.signature, at: 0, end: d.count) else { return .notScanned }
        guard let chunk = chunks.first(where: { $0.keyword == pngKeyword }) else { return .absent }
        // A packet that fails to inflate is still there; ImageIO may read it.
        guard let text = chunk.text else { return .notScanned }
        return .found(packet: text, extended: nil)
    }

    // MARK: TIFF

    /// Tag 700 (XMLPacket) of the first IFD. BigTIFF is not walked.
    static func tiff(_ d: Bytes) -> Result {
        guard d.count >= 8 else { return .notScanned }
        let little: Bool
        switch (d[0], d[1]) {
        case (0x49, 0x49): little = true
        case (0x4D, 0x4D): little = false
        default: return .notScanned
        }
        guard d.u16(2, little: little) == 42 else { return .notScanned }
        let ifd = d.u32(4, little: little)
        guard ifd >= 8, ifd + 2 <= d.count else { return .notScanned }
        let entries = d.u16(ifd, little: little)
        guard ifd + 2 + entries * 12 <= d.count else { return .notScanned }
        for k in 0..<entries {
            let e = ifd + 2 + k * 12
            guard d.u16(e, little: little) == 700 else { continue }
            // BYTE or UNDEFINED, so the count is the size; four bytes or fewer sit inline.
            let size = d.u32(e + 4, little: little)
            let at = size <= 4 ? e + 8 : d.u32(e + 8, little: little)
            guard size > 0, size <= sizeLimit, at + size <= d.count else { return .notScanned }
            return .found(packet: string(d.slice(at, at + size)), extended: nil)
        }
        return .absent
    }

    // MARK: WebP

    static func webP(_ d: Bytes) -> Result {
        guard d.count >= 12, d.fourCC(0) == "RIFF", d.fourCC(8) == "WEBP" else { return .notScanned }
        var i = 12
        while i + 8 <= d.count {
            let size = d.u32(i + 4, little: true)
            guard i + 8 + size <= d.count else { break }
            if d.fourCC(i) == "XMP " { return .found(packet: string(d.slice(i + 8, i + 8 + size)), extended: nil) }
            i += 8 + size + (size & 1)
        }
        return .absent
    }

    // MARK: HEIC / HEIF / AVIF

    /// The `mime` item of content type `application/rdf+xml`, located through
    /// the `meta` box's `iinf` and `iloc`.
    static func isoBMFF(_ d: Bytes, _ budget: inout MetadataBudget) -> Result {
        guard d.count >= 12, d.fourCC(4) == "ftyp" else { return .notScanned }
        guard let meta = boxes(d, 0, d.count).first(where: { $0.type == "meta" }) else { return .absent }
        let children = boxes(d, meta.start + 4, meta.end)               // FullBox: version and flags first
        guard let iinf = children.first(where: { $0.type == "iinf" }), iinf.start + 4 <= iinf.end
        else { return .absent }

        let entriesAt = iinf.start + 4 + (d[iinf.start] == 0 ? 2 : 4)
        var itemID: Int?
        for infe in boxes(d, entriesAt, iinf.end) where infe.type == "infe" && infe.start + 12 <= infe.end {
            let version = d[infe.start]
            guard version >= 2 else { continue }
            var p = infe.start + 4
            let id = version == 2 ? d.u16(p) : d.u32(p)
            p += (version == 2 ? 2 : 4) + 2                              // item ID, protection index
            guard p + 4 <= infe.end, d.fourCC(p) == "mime" else { continue }
            p += 4
            guard let nameEnd = d.firstZero(p, infe.end) else { continue }
            let contentEnd = d.firstZero(nameEnd + 1, infe.end) ?? infe.end
            if string(d.slice(nameEnd + 1, contentEnd)) == mimeType { itemID = id; break }
        }
        guard let itemID else { return .absent }
        guard let iloc = children.first(where: { $0.type == "iloc" }) else { return .notScanned }
        let skips = budget.skipped.count
        guard let packet = item(itemID, d, iloc: iloc, idat: children.first { $0.type == "idat" }, &budget) else {
            // Over the budget is not handed to ImageIO to assemble instead.
            return budget.skipped.count > skips ? .absent : .notScanned
        }
        return .found(packet: string(packet), extended: nil)
    }

    struct Box { let type: String; let start: Int; let end: Int }

    /// Child boxes of a range; `start` / `end` bound each payload.
    static func boxes(_ d: Bytes, _ from: Int, _ to: Int) -> [Box] {
        var out: [Box] = []
        var i = from
        while i + 8 <= to {
            var size = d.u32(i), header = 8
            if size == 1 {
                guard i + 16 <= to else { break }
                size = d.u64(i + 8); header = 16
            } else if size == 0 {
                size = to - i
            }
            guard size >= header, i + size <= to else { break }
            out.append(Box(type: d.fourCC(i + 4), start: i + header, end: i + size))
            i += size
        }
        return out
    }

    /// An item's bytes, its extents joined. File offsets and `idat` offsets only.
    /// Extents may repeat a range, so the joined size is held to `budget`, not
    /// to the file's: past it the item is recorded as skipped and nil returned.
    private static func item(_ wanted: Int, _ d: Bytes, iloc: Box, idat: Box?, _ budget: inout MetadataBudget) -> Data? {
        var p = iloc.start
        guard p + 6 <= iloc.end else { return nil }
        let version = d[p]
        let offsetSize = Int(d[p + 4] >> 4), lengthSize = Int(d[p + 4] & 0x0F)
        let baseSize = Int(d[p + 5] >> 4), indexSize = version > 0 ? Int(d[p + 5] & 0x0F) : 0
        p += 6
        func read(_ size: Int) -> Int? {
            guard [0, 4, 8].contains(size), p + size <= iloc.end else { return nil }
            defer { p += size }
            return size == 0 ? 0 : size == 4 ? d.u32(p) : d.u64(p)
        }
        func over() -> Data? {
            budget.skipped.append(.xmpPacket)
            return nil
        }
        guard p + (version < 2 ? 2 : 4) <= iloc.end else { return nil }
        let items = version < 2 ? d.u16(p) : d.u32(p)
        p += version < 2 ? 2 : 4

        for _ in 0..<items {
            guard p + (version < 2 ? 2 : 4) <= iloc.end else { return nil }
            let id = version < 2 ? d.u16(p) : d.u32(p)
            p += version < 2 ? 2 : 4
            var method = 0
            if version > 0 {
                guard p + 2 <= iloc.end else { return nil }
                method = d.u16(p) & 0x0F
                p += 2
            }
            guard p + 2 <= iloc.end else { return nil }
            p += 2                                                       // data reference index
            guard let base = read(baseSize), p + 2 <= iloc.end else { return nil }
            let extents = d.u16(p)
            p += 2
            var out = Data()
            for _ in 0..<extents {
                guard read(indexSize) != nil, let offset = read(offsetSize), let length = read(lengthSize)
                else { return nil }
                guard id == wanted else { continue }
                let origin: Int, limit: Int
                switch method {
                case 0: origin = 0; limit = d.count
                case 1:
                    guard let idat else { return nil }
                    origin = idat.start; limit = idat.end
                default: return nil
                }
                let at = origin + base + offset
                // A zero length means "to the end" for a single extent.
                let size = length == 0 ? limit - at : length
                guard at >= 0, size > 0, size <= sizeLimit, at + size <= limit else { return nil }
                guard size <= budget.bytes - out.count else { return over() }
                out.append(d.slice(at, at + size))
            }
            if id == wanted { return out.isEmpty ? nil : budget.take(out.count) ? out : over() }
        }
        return nil
    }

    // MARK: Bytes

    /// UTF-8 (lossy when damaged), without the NUL padding some writers leave.
    private static func string(_ data: Data) -> String {
        var end = data.endIndex
        while end > data.startIndex, data[end - 1] == 0 { end -= 1 }
        return String(decoding: data[data.startIndex..<end], as: UTF8.self)
    }

    /// Zero-based, bounds-checked-by-the-caller reads over a (possibly sliced) `Data`.
    struct Bytes {
        let data: Data
        let base: Int
        let count: Int

        init(_ data: Data) {
            self.data = data
            base = data.startIndex
            count = data.count
        }

        subscript(i: Int) -> UInt8 { data[base + i] }

        func u16(_ i: Int, little: Bool = false) -> Int {
            little ? Int(self[i]) | Int(self[i + 1]) << 8 : Int(self[i]) << 8 | Int(self[i + 1])
        }

        func u32(_ i: Int, little: Bool = false) -> Int {
            little ? u16(i, little: true) | u16(i + 2, little: true) << 16 : u16(i) << 16 | u16(i + 2)
        }

        /// Saturates rather than overflow on a nonsense size.
        func u64(_ i: Int) -> Int {
            let high = u32(i)
            return high > 0xFFFF ? 1 << 48 : high << 32 | u32(i + 4)
        }

        func fourCC(_ i: Int) -> String {
            i + 4 <= count ? String(decoding: data[(base + i)..<(base + i + 4)], as: UTF8.self) : ""
        }

        func slice(_ from: Int, _ to: Int) -> Data { data[(base + from)..<(base + to)] }

        func starts(with prefix: [UInt8], at i: Int, end: Int) -> Bool {
            i + prefix.count <= end && data[(base + i)..<(base + i + prefix.count)].elementsEqual(prefix)
        }

        func firstZero(_ from: Int, _ to: Int) -> Int? {
            guard from < to else { return nil }
            return data[(base + from)..<(base + to)].firstIndex(of: 0).map { $0 - base }
        }
    }
}
