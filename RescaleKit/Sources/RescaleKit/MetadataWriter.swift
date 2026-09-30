import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Turns a source's ImageIO properties into what the encoder is handed, for the
/// EXIF, GPS and IPTC switches of a `MetadataPolicy` (PRD §10.2–10.4). It keeps
/// or strips whole blocks and never edits a field, other than the three fixes
/// of §10.4. XMP, ICC and the AI workflow are decided elsewhere.
enum MetadataWriter {
    /// The property dictionary for `CGImageDestinationAddImage`: the kept blocks
    /// of `source`, fixed up for an output of `size`. A block the policy strips,
    /// the format cannot carry (`MetadataPolicy.capability`) or the source lacks
    /// is left out; nothing kept gives an empty dictionary.
    static func properties(from source: [CFString: Any], policy: MetadataPolicy, type: UTType,
                           size: PixelSize) -> [CFString: Any] {
        var out: [CFString: Any] = [:]
        let keepIPTC = writes(.iptc, policy: policy, type: type)

        if writes(.exif, policy: policy, type: type) {
            var tiff = dictionary(source[kCGImagePropertyTIFFDictionary])
            // The encoder's business, or describing the source's pixels.
            for key in structuralTIFFKeys { tiff[key] = nil }
            // Mirrored data follows its switch (PRD §10.3): these surface as the
            // IPTC caption, byline and copyright notice.
            if !keepIPTC { for key in iptcMirrorTIFFKeys { tiff[key] = nil } }

            var exif = dictionary(source[kCGImagePropertyExifDictionary])
            // ImageIO derives these from the pixels it is given.
            for key in ImageMetadata.synthesisedEXIFKeys { exif[key] = nil }

            var extras: [CFString: Any] = [:]
            for (key, value) in source where isCameraExtra(key) && !dictionary(value).isEmpty { extras[key] = value }

            // A source without EXIF gets none: only its synthesised tags were
            // there. A bare resolution, which ImageIO also makes up, does not count.
            let hasTIFFTags = tiff.keys.contains { !resolutionTIFFKeys.contains($0) }
            if hasTIFFTags || !exif.isEmpty || !extras.isEmpty {
                // PRD §10.4: pixel dimensions are the output's, orientation is 1
                // wherever it appears. No thumbnail is ever asked for.
                exif[kCGImagePropertyExifPixelXDimension as String] = size.width
                exif[kCGImagePropertyExifPixelYDimension as String] = size.height
                tiff[kCGImagePropertyTIFFOrientation as String] = 1
                out[kCGImagePropertyOrientation] = 1
                out[kCGImagePropertyTIFFDictionary] = tiff
                out[kCGImagePropertyExifDictionary] = exif
                out.merge(extras) { _, new in new }
            }
        }

        // Its own switch although it is stored inside EXIF (PRD §10.2).
        if writes(.gps, policy: policy, type: type) {
            let gps = dictionary(source[kCGImagePropertyGPSDictionary])
            if !gps.isEmpty { out[kCGImagePropertyGPSDictionary] = gps }
        }

        if keepIPTC {
            let iptc = dictionary(source[kCGImagePropertyIPTCDictionary])
            if !iptc.isEmpty { out[kCGImagePropertyIPTCDictionary] = iptc }
        }
        return out
    }

    /// Removes what ImageIO adds unasked. Given EXIF dates, its JPEG encoder
    /// writes an IPTC block (APP13) mirroring them and the TIFF caption, artist
    /// and copyright, and at times an empty one; that block goes unless IPTC is
    /// being written.
    static func finish(_ data: Data, type: UTType, written: [CFString: Any]) -> Data {
        guard type.conforms(to: .jpeg), written[kCGImagePropertyIPTCDictionary] == nil else { return data }
        return removingPhotoshopSegments(fromJPEG: data)
    }

    private static func writes(_ section: MetadataPolicy.Section, policy: MetadataPolicy, type: UTType) -> Bool {
        policy.keeps(section) && MetadataPolicy.capability(of: section, in: type).canCarry
    }

    private static func dictionary(_ any: Any?) -> [String: Any] { any as? [String: Any] ?? [:] }

    /// Lens extras and the maker notes ImageIO can parse travel with EXIF.
    private static func isCameraExtra(_ key: CFString) -> Bool {
        let name = key as String
        return name == kCGImagePropertyExifAuxDictionary as String || name.hasPrefix("{Maker")
    }

    static let structuralTIFFKeys: [String] = [
        kCGImagePropertyTIFFCompression, kCGImagePropertyTIFFPhotometricInterpretation,
        kCGImagePropertyTIFFTileWidth, kCGImagePropertyTIFFTileLength, kCGImagePropertyTIFFOrientation,
        kCGImagePropertyTIFFTransferFunction, kCGImagePropertyTIFFWhitePoint,
        kCGImagePropertyTIFFPrimaryChromaticities,
    ].map { $0 as String }

    static let resolutionTIFFKeys: [String] = [
        kCGImagePropertyTIFFXResolution, kCGImagePropertyTIFFYResolution, kCGImagePropertyTIFFResolutionUnit,
    ].map { $0 as String }

    static let iptcMirrorTIFFKeys: [String] = [
        kCGImagePropertyTIFFImageDescription, kCGImagePropertyTIFFArtist, kCGImagePropertyTIFFCopyright,
    ].map { $0 as String }

    /// Drops every APP13 "Photoshop 3.0" segment (the IPTC IIM block) from a JPEG's header.
    static func removingPhotoshopSegments(fromJPEG data: Data) -> Data {
        let d = [UInt8](data)
        guard d.count > 4, d[0] == 0xFF, d[1] == 0xD8 else { return data }
        let signature = Array("Photoshop 3.0".utf8)
        var out = Data(d[0..<2])
        var i = 2
        while i + 4 <= d.count, d[i] == 0xFF, d[i + 1] != 0xDA, d[i + 1] != 0xD9 {
            let end = i + 2 + (Int(d[i + 2]) << 8 | Int(d[i + 3]))
            guard end > i + 3, end <= d.count else { return data }
            if !(d[i + 1] == 0xED && d[(i + 4)..<end].starts(with: signature)) { out.append(contentsOf: d[i..<end]) }
            i = end
        }
        out.append(contentsOf: d[i...])
        return out
    }
}
