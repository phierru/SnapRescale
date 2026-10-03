import Foundation
import zlib

/// One image's allowance for the metadata its scanners lift out of the file:
/// decoded bytes and element count, shared by everything read from that file,
/// so that many individually legal elements cannot add up past it, and the
/// inflate work spent getting there. Neither the pixel size nor the file size
/// bounds what a text chunk inflates to.
public struct MetadataBudget: Hashable, Sendable {
    /// What a scanner left out. The inspector shows `note`; none of it is written on save.
    public enum Skip: Hashable, Sendable {
        /// PNG text chunks past the budget.
        case pngText(count: Int)
        /// An XMP packet whose extents join to more than the budget (HEIC / HEIF / AVIF).
        case xmpPacket
        /// JPEG extended XMP the main packet does not name, or that does not assemble.
        case extendedXMP

        public var note: String {
            switch self {
            case .pngText(let count):
                return "\(count) PNG text \(count == 1 ? "chunk was" : "chunks were") over the metadata size limit and "
                    + "not read: not shown here and not carried into the saved file."
            case .xmpPacket:
                return "The XMP packet was over the metadata size limit and not read: not shown here and not "
                    + "carried into the saved file."
            case .extendedXMP:
                return "Extended XMP that does not belong to this packet, or is incomplete, was ignored: not shown "
                    + "here and not carried into the saved file."
            }
        }
    }

    /// 64 MiB: what a single inflated chunk was already allowed, now for the
    /// whole image. A ComfyUI graph runs from tens of kB to a few MB.
    public static let defaultBytes = 64 << 20
    /// Real files carry a handful of text chunks; this only stops a flood of tiny ones.
    public static let defaultElements = 4096
    /// 128 MiB of inflate output, kept or not: twice what can be kept, so that
    /// streams which are rejected (over the limit, damaged) cannot repeat the
    /// work. An attempt costs at least 64 KiB, so this bounds their number too.
    public static let defaultWork = 2 * defaultBytes

    /// What is left of each.
    public private(set) var bytes: Int
    public private(set) var elements: Int
    public private(set) var work: Int
    public internal(set) var skipped: [Skip] = []

    public init(bytes: Int = defaultBytes, elements: Int = defaultElements, work: Int = defaultWork) {
        self.bytes = max(0, bytes)
        self.elements = max(0, elements)
        self.work = max(0, work)
    }

    /// One more element of `count` decoded bytes; false, and nothing taken, when it does not fit.
    mutating func take(_ count: Int) -> Bool {
        guard elements > 0, count >= 0, count <= bytes else { return false }
        elements -= 1
        bytes -= count
        return true
    }

    /// Inflate work done, whether or not its output is kept.
    mutating func spend(_ count: Int) {
        work = max(0, work - count)
    }
}

/// Minimal PNG chunk walker: the `tEXt` / `iTXt` / `zTXt` chunks with their
/// text (inflated where compressed) and raw bytes, and presence of any named chunk.
public enum PNGScanner {
    public struct TextChunk: Hashable, Sendable {
        /// Chunk type: `tEXt`, `zTXt` or `iTXt`.
        public let type: String
        public let keyword: String
        /// The decoded text. Nil only when a compressed chunk is damaged and fails to inflate.
        public let text: String?
        /// True for `zTXt` and for `iTXt` with its compression flag set.
        public let isCompressed: Bool
        /// `iTXt` language tag and translated keyword; empty otherwise.
        public let languageTag: String
        public let translatedKeyword: String
        /// The chunk exactly as found: 4-byte type followed by the body, with
        /// neither the length prefix nor the CRC.
        public let raw: Data

        /// The complete chunk, ready to splice into a PNG: length, `raw`, and a fresh CRC.
        public var encoded: Data {
            var out = Data(capacity: raw.count + 8)
            withUnsafeBytes(of: UInt32(max(0, raw.count - 4)).bigEndian) { out.append(contentsOf: $0) }
            out.append(raw)
            withUnsafeBytes(of: PNGScanner.crc32(raw).bigEndian) { out.append(contentsOf: $0) }
            return out
        }
    }

    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    /// Ceiling on one inflated text chunk, against decompression bombs.
    static let inflateLimit = 64 << 20
    /// What one inflate pass writes into. An attempt costs at least this much
    /// work, however little it inflates, so that the allowance bounds how many
    /// attempts are made as well as their output.
    static let inflateBuffer = 64 << 10

    /// Text chunks in file order.
    public static func textChunks(in data: Data) -> [TextChunk] {
        var budget = MetadataBudget()
        return textChunks(in: data, budget: &budget)
    }

    /// As above, drawing on the image's `budget`. A chunk that does not fit is
    /// left out whole, text and raw bytes, and counted in `budget.skipped`; so
    /// is a compressed one, damaged or not, once the budget's work is spent.
    static func textChunks(in data: Data, budget: inout MetadataBudget) -> [TextChunk] {
        var out: [TextChunk] = []
        var skipped = 0
        forEachChunk(in: data) { type, body in
            guard type == "tEXt" || type == "zTXt" || type == "iTXt" else { return }
            guard let nul = body.firstIndex(of: 0) else { return }
            // Room is checked before anything is decoded or copied. The outer nil
            // is "does not fit"; the inner one a damaged stream, kept without text.
            func plain(_ bytes: Data, utf8Only: Bool) -> String?? {
                budget.take(bytes.count) ? .some(string(bytes, utf8Only: utf8Only)) : nil
            }
            func deflated(_ bytes: Data, utf8Only: Bool) -> String?? {
                // Nothing is inflated that could not be kept, nor once the work is spent.
                guard budget.elements > 0, budget.work > 0 else { return nil }
                var work = 0
                let result = inflated(bytes, limit: min(inflateLimit, budget.bytes, budget.work), work: &work)
                budget.spend(max(work, inflateBuffer))
                switch result {
                case .data(let d): return budget.take(d.count) ? .some(string(d, utf8Only: utf8Only)) : nil
                case .damaged: return budget.take(0) ? .some(nil) : nil
                case .overLimit: return nil
                }
            }
            let keyword = string(body[body.startIndex..<nul], utf8Only: false)
            var decoded: String??
            var compressed = false
            var language = "", translated = ""

            switch type {
            case "tEXt":
                // Latin-1 by the spec; most AI tools write UTF-8 anyway.
                decoded = plain(body[(nul + 1)...], utf8Only: false)
            case "zTXt":
                // keyword\0 method(1) deflate stream
                guard nul + 1 < body.endIndex else { return }
                compressed = true
                decoded = deflated(body[(nul + 2)...], utf8Only: false)
            default:
                // keyword\0 compressionFlag(1) method(1) language\0 translated\0 text
                guard nul + 2 < body.endIndex else { return }
                compressed = body[nul + 1] != 0
                var i = nul + 3
                guard let langEnd = body[i...].firstIndex(of: 0) else { return }
                language = string(body[i..<langEnd], utf8Only: true)
                i = langEnd + 1
                guard let transEnd = body[i...].firstIndex(of: 0) else { return }
                translated = string(body[i..<transEnd], utf8Only: true)
                i = transEnd + 1
                decoded = compressed ? deflated(body[i...], utf8Only: true) : plain(body[i...], utf8Only: true)
            }
            guard let text = decoded else { skipped += 1; return }

            // Copy out of the (possibly memory-mapped) file so the chunk owns its bytes.
            var raw = Data(capacity: body.count + 4)
            raw.append(contentsOf: Array(type.utf8))
            raw.append(contentsOf: body)
            out.append(TextChunk(type: type, keyword: keyword, text: text, isCompressed: compressed,
                                 languageTag: language, translatedKeyword: translated, raw: raw))
        }
        if skipped > 0 { budget.skipped.append(.pngText(count: skipped)) }
        return out
    }

    public static func hasChunk(_ name: String, in data: Data) -> Bool {
        var found = false
        forEachChunk(in: data) { type, _ in if type == name { found = true } }
        return found
    }

    /// PNG's CRC-32, over the chunk type and body.
    public static func crc32(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { raw in
            UInt32(zlib.crc32(0, raw.bindMemory(to: Bytef.self).baseAddress, uInt(raw.count)))
        }
    }

    enum Inflated: Hashable { case data(Data), damaged, overLimit }

    /// Inflates a zlib stream to at most `limit` bytes. A truncated stream is `.damaged`.
    static func inflated(_ data: Data, limit: Int = inflateLimit) -> Inflated {
        var work = 0
        return inflated(data, limit: limit, work: &work)
    }

    /// As above; `work` is what the attempt inflated, whatever the result: at
    /// most one byte past `limit`, which is enough to know a stream is over it.
    static func inflated(_ data: Data, limit: Int, work: inout Int) -> Inflated {
        guard !data.isEmpty else { return .damaged }
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return .damaged }
        defer { inflateEnd(&stream) }
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: inflateBuffer)
        return data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Inflated in
            stream.next_in = UnsafeMutablePointer(mutating: src.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(src.count)
            while true {
                var produced = 0
                let status = buffer.withUnsafeMutableBufferPointer { buf -> Int32 in
                    let room = min(buf.count - 1, max(0, limit - out.count)) + 1
                    stream.next_out = buf.baseAddress
                    stream.avail_out = uInt(room)
                    let s = zlib.inflate(&stream, Z_NO_FLUSH)
                    produced = room - Int(stream.avail_out)
                    return s
                }
                work += produced
                // Before the append, and before the end of the stream is accepted.
                guard produced <= limit - out.count else { return .overLimit }
                out.append(contentsOf: buffer[0..<produced])
                if status == Z_STREAM_END { return .data(out) }
                guard status == Z_OK else { return .damaged }
            }
        }
    }

    /// UTF-8 when valid; otherwise Latin-1 (the `tEXt` / `zTXt` encoding), or lossy UTF-8 for `iTXt`.
    private static func string(_ bytes: Data, utf8Only: Bool) -> String {
        if let s = String(data: bytes, encoding: .utf8) { return s }
        if !utf8Only, let s = String(data: bytes, encoding: .isoLatin1) { return s }
        return String(decoding: bytes, as: UTF8.self)
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
