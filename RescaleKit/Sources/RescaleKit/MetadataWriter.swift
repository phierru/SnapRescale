import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Turns a source's ImageIO properties into what the encoder is handed, for the
/// EXIF, GPS and IPTC switches of a `MetadataPolicy` (PRD §10.2–10.4). It keeps
/// or strips whole blocks and never edits a field, other than the three fixes
/// of §10.4. The exception is the AI payloads stored in EXIF / TIFF (A1111,
/// SwarmUI or Fooocus parameters in UserComment, a Midjourney ImageDescription):
/// the AI workflow switch owns those, and outside PNG it also puts the
/// `parameters` of a PNG text chunk into UserComment, where A1111 itself
/// stores them. The XMP packet is `XMPWriter`'s, ICC is `ColorPlan`'s and PNG
/// workflow chunks are `PNGSplicer`'s.
enum MetadataWriter {
    /// The property dictionary for `CGImageDestinationAddImage`: the kept blocks
    /// of `source`, fixed up for an output of `size`. A block the policy strips,
    /// the format cannot carry (`MetadataPolicy.capability`) or the source lacks
    /// is left out; nothing kept gives an empty dictionary. `metadata` is what
    /// was read off the source's container, for the AI payloads ImageIO's
    /// dictionaries do not hold.
    static func properties(from source: [CFString: Any], policy: MetadataPolicy, type: UTType,
                           size: PixelSize, carrying metadata: ImageMetadata? = nil) -> [CFString: Any] {
        var out: [CFString: Any] = [:]
        let keepIPTC = writes(.iptc, policy: policy, type: type)
        let keepAI = writes(.aiWorkflow, policy: policy, type: type)
        let userCommentKey = kCGImagePropertyExifUserComment as String
        let descriptionKey = kCGImagePropertyTIFFImageDescription as String
        let captionKey = kCGImagePropertyIPTCCaptionAbstract as String

        // AI payloads that live in EXIF / TIFF belong to the AI workflow switch,
        // whatever the EXIF and IPTC switches say (PRD §10.2, issue #18).
        let sourceTIFF = dictionary(source[kCGImagePropertyTIFFDictionary])
        let sourceEXIF = dictionary(source[kCGImagePropertyExifDictionary])
        let ownUserComment = (sourceEXIF[userCommentKey] as? String).flatMap { ImageMetadata.userCommentSource($0) != nil ? $0 : nil }
        // `parameters` from a PNG text chunk has no chunk to live in outside
        // PNG (review 2026-09-30, G2).
        let aiUserComment = ownUserComment
            ?? (type.conforms(to: .png) ? nil : metadata.flatMap(movedParameters)?.text)
        let aiDescription = (sourceTIFF[descriptionKey] as? String).flatMap { looksLikeMidjourney($0) ? $0 : nil }

        var tiff: [String: Any] = [:]
        var exif: [String: Any] = [:]
        var hasCameraData = false
        if writes(.exif, policy: policy, type: type) {
            tiff = sourceTIFF
            // The encoder's business, or describing the source's pixels.
            for key in structuralTIFFKeys { tiff[key] = nil }
            // Mirrored data follows its switch (PRD §10.3): these surface as the
            // IPTC caption, byline and copyright.
            if !keepIPTC { for key in iptcMirrorTIFFKeys { tiff[key] = nil } }
            if aiDescription != nil { tiff[descriptionKey] = nil }

            exif = sourceEXIF
            // ImageIO derives these from the pixels it is given.
            for key in ImageMetadata.synthesisedEXIFKeys { exif[key] = nil }
            if ownUserComment != nil { exif[userCommentKey] = nil }

            var extras: [CFString: Any] = [:]
            for (key, value) in source where isCameraExtra(key) && !dictionary(value).isEmpty { extras[key] = value }

            // A source without EXIF gets none: only its synthesised tags were
            // there. A bare resolution, which ImageIO also makes up, does not count.
            let hasTIFFTags = tiff.keys.contains { !resolutionTIFFKeys.contains($0) }
            if hasTIFFTags || !exif.isEmpty || !extras.isEmpty {
                out.merge(extras) { _, new in new }
                hasCameraData = true
            } else {
                tiff = [:]
            }
        }
        // Kept AI payloads go back in: next to the kept EXIF, or as a block
        // holding nothing else (bar the fixes below) when EXIF is stripped.
        if keepAI, MetadataPolicy.capability(of: .exif, in: type).canCarry {
            if let aiUserComment {
                // ImageIO writes the `ASCII` form, as in a file it read, and
                // turns anything else into question marks: see `PendingUserComment`.
                if aiUserComment.utf8.allSatisfy({ $0 < 0x80 }) {
                    exif[userCommentKey] = aiUserComment
                } else {
                    let pending = PendingUserComment(aiUserComment)
                    exif[userCommentKey] = pending.placeholder
                    out[pendingUserCommentKey] = pending
                }
            }
            if let aiDescription { tiff[descriptionKey] = aiDescription }
        }
        if hasCameraData || !tiff.isEmpty || !exif.isEmpty {
            // PRD §10.4: pixel dimensions are the output's, orientation is 1
            // wherever it appears. No thumbnail is ever asked for.
            exif[kCGImagePropertyExifPixelXDimension as String] = size.width
            exif[kCGImagePropertyExifPixelYDimension as String] = size.height
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            out[kCGImagePropertyOrientation] = 1
            out[kCGImagePropertyTIFFDictionary] = tiff
            out[kCGImagePropertyExifDictionary] = exif
        }

        // Its own switch although it is stored inside EXIF (PRD §10.2).
        if writes(.gps, policy: policy, type: type) {
            let gps = dictionary(source[kCGImagePropertyGPSDictionary])
            if !gps.isEmpty { out[kCGImagePropertyGPSDictionary] = gps }
        }

        if keepIPTC {
            var iptc = dictionary(source[kCGImagePropertyIPTCDictionary])
            // ImageIO's name for `xmp:Rating`: it exists only in the packet, so
            // it travels with the XMP switch (`XMPWriter`), not with IPTC.
            iptc[kCGImagePropertyIPTCStarRating as String] = nil
            // A Midjourney description surfaces as the caption too.
            if !keepAI, let caption = iptc[captionKey] as? String, looksLikeMidjourney(caption) { iptc[captionKey] = nil }
            if !iptc.isEmpty { out[kCGImagePropertyIPTCDictionary] = iptc }
        }
        return out
    }

    /// The `parameters` PNG chunk (A1111, Forge, Fooocus, SwarmUI) that moves
    /// into the EXIF user comment outside PNG. One comment holds one text: an
    /// AI comment the source's EXIF already has stays and nothing moves; else
    /// the first chunk in file order does. `MetadataPolicy.capability` reports
    /// the ones left out.
    static func movedParameters(in metadata: ImageMetadata) -> ImageMetadata.AIPayload? {
        guard !metadata.aiPayloads.contains(where: isUserComment) else { return nil }
        return metadata.aiPayloads.first(where: isPNGParameters)
    }

    static func isUserComment(_ payload: ImageMetadata.AIPayload) -> Bool { payload.location == "EXIF UserComment" }

    static func isPNGParameters(_ payload: ImageMetadata.AIPayload) -> Bool {
        payload.location.hasPrefix("PNG ") && payload.name == "parameters"
    }

    /// A comment in the source's EXIF that is not an AI payload: the user's own.
    static func ordinaryUserComment(in source: [CFString: Any]) -> String? {
        let comment = dictionary(source[kCGImagePropertyExifDictionary])[kCGImagePropertyExifUserComment as String] as? String
        return comment.flatMap { $0.isEmpty || ImageMetadata.userCommentSource($0) != nil ? nil : $0 }
    }

    // MARK: - User comment outside ASCII

    /// Where `properties` leaves a comment that `PendingUserComment.applied`
    /// still has to encode. The kit's own key: `encoderProperties` drops it.
    static var pendingUserCommentKey: CFString { "SnapRescalePendingUserComment" as CFString }

    /// An AI user comment ImageIO cannot write: its encoder knows the `ASCII`
    /// form only. A1111 (through piexif) writes `UNICODE` and UTF-16, big
    /// endian, which is also what ImageIO and A1111 read back. ImageIO is given
    /// an ASCII stand-in of the same byte length, swapped in the encoded file
    /// for the real comment, so no offset in the EXIF block moves.
    struct PendingUserComment {
        let text: String
        /// As many ASCII characters as the comment has UTF-16 bytes, unlikely to occur anywhere else.
        let placeholder: String

        init(_ text: String) {
            self.text = text
            let length = text.utf16.count * 2
            placeholder = String(String(repeating: UUID().uuidString, count: length / 36 + 1).prefix(length))
        }

        /// `data` with the stand-in replaced, or nil when it is not there exactly
        /// once as an EXIF comment and nowhere else (an XMP mirror, say). A PNG
        /// is taken chunk by chunk (issue #33).
        func applied(to data: Data) -> Data? {
            data.starts(with: PNGScanner.signature) ? applied(toPNG: data) : swapped(in: data)
        }

        /// In a PNG, ImageIO writes the comment into the `eXIf` chunk and mirrors
        /// it into the XMP packet it derives. The first takes the same swap, the
        /// second the text itself, escaped for XML; each changed chunk gets its
        /// length and CRC anew. Nil when the stand-in is in any other chunk,
        /// compressed text included.
        private func applied(toPNG png: Data) -> Data? {
            let standIn = Data(placeholder.utf8)
            let xmp = Data("XML:com.adobe.xmp\0\0".utf8)   // the keyword, then the flag: not compressed
            var swappedEXIF = false
            let out = PNGSplicer.rewritingChunks(in: png) { type, body in
                guard body.range(of: standIn) != nil else { return body }
                if type == "eXIf", !swappedEXIF, let swapped = swapped(in: body) {
                    swappedEXIF = true
                    return swapped
                }
                if type == "iTXt", body.starts(with: xmp) {
                    return body.replacing(standIn, with: Data(Self.xmlEscaped(text).utf8))
                }
                return nil
            }
            guard let out, swappedEXIF,
                  !PNGScanner.textChunks(in: out).contains(where: { $0.text?.contains(placeholder) == true })
            else { return nil }
            return out
        }

        /// The stand-in, stored as an `ASCII` comment, swapped for the `UNICODE` one.
        private func swapped(in data: Data) -> Data? {
            let standIn = Data(placeholder.utf8)
            let stored = Data("ASCII\0\0\0".utf8) + standIn
            guard let range = data.range(of: standIn), range.lowerBound - data.startIndex >= 8,
                  data[(range.lowerBound - 8)..<range.upperBound] == stored,
                  data.range(of: standIn, in: range.upperBound..<data.endIndex) == nil else { return nil }
            var comment = Data("UNICODE\0".utf8)
            for unit in text.utf16 { comment.append(contentsOf: [UInt8(unit >> 8), UInt8(unit & 0xFF)]) }
            var out = data
            out.replaceSubrange((range.lowerBound - 8)..<range.upperBound, with: comment)
            return out
        }

        /// `text` as XML character data: markup and quotes as entities, tab, line
        /// feed and carriage return as references, as ImageIO writes them, and a
        /// space for a character XML cannot hold.
        private static func xmlEscaped(_ text: String) -> String {
            var out = ""
            for scalar in text.unicodeScalars {
                switch scalar {
                case "&": out += "&amp;"
                case "<": out += "&lt;"
                case ">": out += "&gt;"
                case "\"": out += "&quot;"
                case "\t", "\n", "\r": out += "&#x\(String(scalar.value, radix: 16, uppercase: true));"
                case "\u{0}"..<"\u{20}", "\u{FFFE}", "\u{FFFF}": out += " "
                default: out.unicodeScalars.append(scalar)
                }
            }
            return out
        }
    }

    /// `written` as ImageIO takes it: without the kit's own key.
    static func encoderProperties(_ written: [CFString: Any]) -> [CFString: Any] {
        var out = written
        out[pendingUserCommentKey] = nil
        return out
    }

    /// `written` with the pending comment handed to ImageIO after all, which
    /// writes what of it is ASCII: the way out when the stand-in cannot be swapped.
    static func lettingImageIOEncodeUserComment(_ written: [CFString: Any]) -> [CFString: Any] {
        guard let pending = written[pendingUserCommentKey] as? PendingUserComment else { return written }
        var out = encoderProperties(written)
        var exif = dictionary(out[kCGImagePropertyExifDictionary])
        exif[kCGImagePropertyExifUserComment as String] = pending.text
        out[kCGImagePropertyExifDictionary] = exif
        return out
    }

    /// Midjourney writes its prompt and job ID into the description.
    static func looksLikeMidjourney(_ text: String) -> Bool { text.contains("Job ID:") }

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
