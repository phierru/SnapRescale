import Foundation
import zlib

/// Minimal PNG chunk walker: the `tEXt` / `iTXt` / `zTXt` chunks with their
/// text (inflated where compressed) and raw bytes, and presence of any named chunk.
public enum PNGScanner {
    public struct TextChunk: Hashable, Sendable {
        /// Chunk type: `tEXt`, `zTXt` or `iTXt`.
        public let type: String
        public let keyword: String
        /// The decoded text. Nil only when a compressed chunk fails to inflate.
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

    /// Text chunks in file order.
    public static func textChunks(in data: Data) -> [TextChunk] {
        var out: [TextChunk] = []
        forEachChunk(in: data) { type, body in
            guard type == "tEXt" || type == "zTXt" || type == "iTXt" else { return }
            guard let nul = body.firstIndex(of: 0) else { return }
            let keyword = string(body[body.startIndex..<nul], utf8Only: false)
            var text: String?
            var compressed = false
            var language = "", translated = ""

            switch type {
            case "tEXt":
                // Latin-1 by the spec; most AI tools write UTF-8 anyway.
                text = string(body[(nul + 1)...], utf8Only: false)
            case "zTXt":
                // keyword\0 method(1) deflate stream
                guard nul + 1 < body.endIndex else { return }
                compressed = true
                text = inflated(body[(nul + 2)...]).map { string($0, utf8Only: false) }
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
                text = compressed ? inflated(body[i...]).map { string($0, utf8Only: true) }
                                  : string(body[i...], utf8Only: true)
            }

            // Copy out of the (possibly memory-mapped) file so the chunk owns its bytes.
            var raw = Data(capacity: body.count + 4)
            raw.append(contentsOf: Array(type.utf8))
            raw.append(contentsOf: body)
            out.append(TextChunk(type: type, keyword: keyword, text: text, isCompressed: compressed,
                                 languageTag: language, translatedKeyword: translated, raw: raw))
        }
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

    /// Inflates a zlib stream. Nil when it is damaged, truncated or over the limit.
    static func inflated(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        return data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Data? in
            stream.next_in = UnsafeMutablePointer(mutating: src.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(src.count)
            while true {
                var produced = 0
                let status = buffer.withUnsafeMutableBufferPointer { buf -> Int32 in
                    stream.next_out = buf.baseAddress
                    stream.avail_out = uInt(buf.count)
                    let s = zlib.inflate(&stream, Z_NO_FLUSH)
                    produced = buf.count - Int(stream.avail_out)
                    return s
                }
                out.append(contentsOf: buffer[0..<produced])
                if status == Z_STREAM_END { return out }
                guard status == Z_OK, out.count <= inflateLimit else { return nil }
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
