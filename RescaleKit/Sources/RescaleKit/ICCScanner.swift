import Foundation
import UniformTypeIdentifiers

/// Where a source's colour profile comes from (PRD §10.1, issue #25). ImageIO names
/// a profile for every image, sRGB when the file has none; only an embedded one
/// earns the ICC badge.
public enum ICCOrigin: Hashable, Sendable {
    /// ICC profile bytes are in the file.
    case embedded
    /// No profile, but the file states its colour space; the associated value says
    /// how, e.g. "PNG sRGB chunk".
    case tagged(String)
    /// Nothing in the file: the profile is the macOS default.
    case assumed
}

/// Looks for the profile in the container itself: PNG `iCCP`, JPEG APP2
/// `ICC_PROFILE`, TIFF tag 34675, WebP `ICCP`, HEIC / HEIF / AVIF `colr` box,
/// GIF `ICCRGBG1` extension, BMP V5 header. Nil for containers it does not
/// walk, or cannot.
enum ICCScanner {
    typealias Bytes = XMPScanner.Bytes

    static let jpegSignature = Array("ICC_PROFILE".utf8) + [0]
    static let tiffTag = 34675
    /// Block size, application identifier and authentication code.
    static let gifApplication = [11] + Array("ICCRGBG1012".utf8)
    /// `PROFILE_EMBEDDED`, "MBED", the V5 header's colour space type.
    static let bmpEmbedded = 0x4D42_4544

    static func origin(in data: Data, type: UTType) -> ICCOrigin? {
        guard walks(type) else { return nil }
        let bytes = Bytes(data)
        if type.conforms(to: .png) { return png(data, bytes) }
        if type.conforms(to: .jpeg) { return jpeg(bytes) }
        if type.conforms(to: .tiff) { return tiff(bytes) }
        if type.conforms(to: .webP) { return webP(bytes) }
        if type.conforms(to: .gif) { return gif(bytes) }
        if type.conforms(to: .bmp) { return bmp(bytes) }
        return isoBMFF(bytes)
    }

    /// Whether `origin` walks this kind of container. One it walks but cannot
    /// parse has no profile it could find: the caller counts it as assumed.
    static func walks(_ type: UTType) -> Bool {
        [.png, .jpeg, .tiff, .webP, .gif, .bmp, .heic, .heif].contains { type.conforms(to: $0) }
            || type.identifier == "public.avif"
    }

    /// `iCCP` is a profile; `sRGB`, `cICP` and `gAMA` + `cHRM` only name a colour space.
    static func png(_ data: Data, _ d: Bytes) -> ICCOrigin? {
        guard d.count > 8, d.starts(with: PNGScanner.signature, at: 0, end: d.count) else { return nil }
        if PNGScanner.hasChunk("iCCP", in: data) { return .embedded }
        if PNGScanner.hasChunk("cICP", in: data) { return .tagged("PNG cICP chunk") }
        if PNGScanner.hasChunk("sRGB", in: data) { return .tagged("PNG sRGB chunk") }
        if PNGScanner.hasChunk("gAMA", in: data), PNGScanner.hasChunk("cHRM", in: data) {
            return .tagged("PNG gAMA and cHRM chunks")
        }
        return .assumed
    }

    static func jpeg(_ d: Bytes) -> ICCOrigin? {
        guard d.count > 4, d[0] == 0xFF, d[1] == 0xD8 else { return nil }
        var i = 2
        while i + 4 <= d.count, d[i] == 0xFF {
            let marker = d[i + 1]
            if marker == 0xFF { i += 1; continue }                       // fill byte
            if marker == 0xD9 || marker == 0xDA { break }                 // EOI / SOS: no more headers
            let length = d.u16(i + 2)
            guard length >= 2, i + 2 + length <= d.count else { return nil }
            if marker == 0xE2, d.starts(with: jpegSignature, at: i + 4, end: i + 2 + length) { return .embedded }
            i += 2 + length
        }
        return .assumed
    }

    /// Tag 34675 (ICCProfile) of the first IFD, in a TIFF or a BigTIFF.
    static func tiff(_ d: Bytes) -> ICCOrigin? {
        guard d.count >= 8 else { return nil }
        let little: Bool
        switch (d[0], d[1]) {
        case (0x49, 0x49): little = true
        case (0x4D, 0x4D): little = false
        default: return nil
        }
        // BigTIFF (43) has 64-bit offsets and entry counts, and 20-byte entries.
        let version = d.u16(2, little: little), big = version == 43
        guard version == 42 || (big && d.count >= 16) else { return nil }
        func u64(_ i: Int) -> Int {
            let (low, high) = little ? (d.u32(i, little: true), d.u32(i + 4, little: true)) : (d.u32(i + 4), d.u32(i))
            return high > 0xFFFF ? 1 << 48 : high << 32 | low
        }
        let (countSize, entrySize) = big ? (8, 20) : (2, 12)
        let ifd = big ? u64(8) : d.u32(4, little: little)
        guard ifd >= 8, ifd + countSize <= d.count else { return nil }
        let entries = big ? u64(ifd) : d.u16(ifd, little: little)
        guard ifd + countSize + entries * entrySize <= d.count else { return nil }
        for k in 0..<entries where d.u16(ifd + countSize + k * entrySize, little: little) == tiffTag { return .embedded }
        return .assumed
    }

    static func webP(_ d: Bytes) -> ICCOrigin? {
        guard d.count >= 12, d.fourCC(0) == "RIFF", d.fourCC(8) == "WEBP" else { return nil }
        var i = 12
        while i + 8 <= d.count {
            let size = d.u32(i + 4, little: true)
            guard i + 8 + size <= d.count else { break }
            if d.fourCC(i) == "ICCP" { return .embedded }
            i += 8 + size + (size & 1)
        }
        return .assumed
    }

    /// The `colr` boxes among the item properties (`meta` ▸ `iprp` ▸ `ipco`): `prof` /
    /// `rICC` carry a profile, `nclx` only code points. The properties are not matched
    /// to the primary item; a profile on any item counts.
    static func isoBMFF(_ d: Bytes) -> ICCOrigin? {
        guard d.count >= 12, d.fourCC(4) == "ftyp" else { return nil }
        guard let meta = XMPScanner.boxes(d, 0, d.count).first(where: { $0.type == "meta" }),
              let iprp = XMPScanner.boxes(d, meta.start + 4, meta.end).first(where: { $0.type == "iprp" }),
              let ipco = XMPScanner.boxes(d, iprp.start, iprp.end).first(where: { $0.type == "ipco" })
        else { return nil }
        let kinds = XMPScanner.boxes(d, ipco.start, ipco.end)
            .filter { $0.type == "colr" && $0.start + 4 <= $0.end }.map { d.fourCC($0.start) }
        if kinds.contains("prof") || kinds.contains("rICC") { return .embedded }
        if kinds.contains("nclx") { return .tagged("nclx colour box") }
        return .assumed
    }

    /// An `ICCRGBG1` application extension, before or between the images.
    static func gif(_ d: Bytes) -> ICCOrigin? {
        guard d.count >= 13, d.starts(with: Array("GIF8".utf8), at: 0, end: d.count) else { return nil }
        func colourTable(_ flags: UInt8) -> Int { flags & 0x80 == 0 ? 0 : 3 << (Int(flags & 7) + 1) }
        var i = 13 + colourTable(d[10])
        while i < d.count {
            if d[i] == 0x21, i + 2 < d.count {                            // extension: label, then sub-blocks
                if d[i + 1] == 0xFF, d.starts(with: gifApplication, at: i + 2, end: d.count) { return .embedded }
                i += 2
            } else if d[i] == 0x2C, i + 10 <= d.count {                   // image: descriptor, colour table, LZW size
                i += 10 + colourTable(d[i + 9]) + 1
            } else {
                break                                                     // trailer, or not a block
            }
            while i < d.count, d[i] != 0 { i += 1 + Int(d[i]) }           // sub-blocks up to the terminator
            i += 1
        }
        return .assumed
    }

    /// A V5 header whose colour space is an embedded profile, and the profile
    /// it points to. Older headers cannot carry one.
    static func bmp(_ d: Bytes) -> ICCOrigin? {
        guard d.count >= 18, d[0] == 0x42, d[1] == 0x4D else { return nil }          // "BM"
        guard d.u32(14, little: true) >= 124, d.count >= 14 + 124 else { return .assumed }
        let profile = 14 + d.u32(14 + 112, little: true), size = d.u32(14 + 116, little: true)
        guard d.u32(14 + 56, little: true) == bmpEmbedded, size > 0, profile + size <= d.count else { return .assumed }
        return .embedded
    }
}

extension ImageMetadata {
    /// True when the file itself carries an ICC profile. The ICC badge follows this.
    public var iccIsEmbedded: Bool { iccOrigin == .embedded }

    /// What to say beside an ICC section whose profile is not in the file, e.g.
    /// "macOS default (sRGB assumed)". Nil for an embedded profile.
    public var iccNote: String? {
        let name = iccProfileName.map { $0.contains("sRGB") ? "sRGB" : $0 } ?? "sRGB"
        switch iccOrigin {
        case .embedded: return nil
        case .tagged(let how): return "No embedded profile (\(how)); macOS default (\(name) assumed)"
        case .assumed: return "macOS default (\(name) assumed)"
        }
    }

    /// The value of the ICC section's `Embedded` field.
    var iccEmbeddedValue: String {
        switch iccOrigin {
        case .embedded: return "Yes"
        case .tagged(let how): return "No (\(how))"
        case .assumed: return "No (macOS default)"
        }
    }
}
