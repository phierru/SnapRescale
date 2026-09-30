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
/// `ICC_PROFILE`, TIFF tag 34675, WebP `ICCP`, HEIC / HEIF / AVIF `colr` box.
/// Nil for containers it does not walk, or cannot.
enum ICCScanner {
    typealias Bytes = XMPScanner.Bytes

    static let jpegSignature = Array("ICC_PROFILE".utf8) + [0]
    static let tiffTag = 34675

    static func origin(in data: Data, type: UTType) -> ICCOrigin? {
        let bytes = Bytes(data)
        if type.conforms(to: .png) { return png(data, bytes) }
        if type.conforms(to: .jpeg) { return jpeg(bytes) }
        if type.conforms(to: .tiff) { return tiff(bytes) }
        if type.conforms(to: .webP) { return webP(bytes) }
        if type.conforms(to: .heic) || type.conforms(to: .heif) || type.identifier == "public.avif" { return isoBMFF(bytes) }
        return nil
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

    /// Tag 34675 (ICCProfile) of the first IFD. BigTIFF is not walked.
    static func tiff(_ d: Bytes) -> ICCOrigin? {
        guard d.count >= 8 else { return nil }
        let little: Bool
        switch (d[0], d[1]) {
        case (0x49, 0x49): little = true
        case (0x4D, 0x4D): little = false
        default: return nil
        }
        guard d.u16(2, little: little) == 42 else { return nil }
        let ifd = d.u32(4, little: little)
        guard ifd >= 8, ifd + 2 <= d.count else { return nil }
        let entries = d.u16(ifd, little: little)
        guard ifd + 2 + entries * 12 <= d.count else { return nil }
        for k in 0..<entries where d.u16(ifd + 2 + k * 12, little: little) == tiffTag { return .embedded }
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
