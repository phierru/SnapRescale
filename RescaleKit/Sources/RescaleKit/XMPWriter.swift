import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The XMP switch of a `MetadataPolicy` (PRD §10.2–10.4, issue #18): what of the
/// source's own packet the encoder is handed, as a `CGImageMetadata` tree for
/// `CGImageDestinationAddImageAndMetadata`.
///
/// The switch governs only what the source's packet adds. A packet ImageIO
/// derives by itself from kept EXIF / TIFF / IPTC — it always does on PNG and
/// HEIC, where IPTC can live only as XMP — belongs to those sections, so an
/// output with XMP stripped may still hold a packet.
///
/// Mirrored data follows its switch (PRD §10.3), here in both directions: a
/// kept packet loses the properties that repeat a stripped section, and a
/// property ImageIO surfaces from the packet as EXIF, GPS or IPTC follows that
/// section's switch even with XMP stripped. The tree is filtered tag by tag;
/// the packet text is never rewritten by hand, ImageIO serialises it afresh.
enum XMPWriter {
    static let exif = "http://ns.adobe.com/exif/1.0/"
    static let tiff = "http://ns.adobe.com/tiff/1.0/"
    static let xmp = "http://ns.adobe.com/xap/1.0/"
    static let dublinCore = "http://purl.org/dc/elements/1.1/"
    static let photoshop = "http://ns.adobe.com/photoshop/1.0/"
    static let note = "http://ns.adobe.com/xmp/note/"
    /// `xmpGImg`, the image inside `xmp:Thumbnails`.
    static let thumbnailImage = "http://ns.adobe.com/xap/1.0/g/img/"

    /// Namespaces that only repeat EXIF / TIFF: `exif`, `tiff`, `exifEX`, `aux`.
    static let exifNamespaces: Set<String> = [exif, tiff, "http://cipa.jp/exif/1.0/", "http://ns.adobe.com/exif/1.0/aux/"]
    /// `Iptc4xmpCore` and `Iptc4xmpExt`.
    static let iptcNamespaces: Set<String> = ["http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/",
                                              "http://iptc.org/std/Iptc4xmpExt/2008-02-29/"]
    /// The `xmp:` properties that repeat the TIFF dates and Software.
    static let exifMirrorsInXMP: Set<String> = ["CreateDate", "ModifyDate", "CreatorTool"]
    /// The `tiff:` properties that surface as IPTC caption, byline and copyright.
    static let iptcMirrorsInTIFF: Set<String> = ["ImageDescription", "Artist", "Copyright"]
    static let iptcMirrorsInDublinCore: Set<String> = ["description", "subject", "rights", "creator", "title"]
    /// The `photoshop:` properties that are IPTC fields; the rest (colour mode,
    /// history, …) are Photoshop's own.
    static let iptcMirrorsInPhotoshop: Set<String> = [
        "AuthorsPosition", "CaptionWriter", "Category", "City", "Country", "Credit", "Headline", "Instructions",
        "Source", "State", "SupplementalCategories", "TransmissionReference", "Urgency", "LegacyIPTCDigest",
    ]

    /// What is written of the sections a property may mirror.
    struct Kept: Hashable {
        var exif = true, gps = true, iptc = true, aiWorkflow = true
    }

    /// The tree to write, or nil when XMP is stripped, the format cannot carry
    /// it, the source has no packet, or nothing of it is left after filtering.
    /// A JPEG's extended packet is folded into the same tree.
    static func metadata(from source: ImageMetadata, policy: MetadataPolicy, type: UTType,
                         size: PixelSize) -> CGImageMetadata? {
        func writes(_ section: MetadataPolicy.Section) -> Bool {
            policy.keeps(section) && MetadataPolicy.capability(of: section, in: type).canCarry
        }
        guard writes(.xmp), let packet = source.xmpPacket else { return nil }
        let kept = Kept(exif: writes(.exif), gps: writes(.gps), iptc: writes(.iptc), aiWorkflow: writes(.aiWorkflow))
        return metadata(packet: packet, extended: source.xmpExtendedPacket, kept: kept, size: size)
    }

    static func metadata(packet: String, extended: String?, kept: Kept, size: PixelSize) -> CGImageMetadata? {
        guard let parsed = CGImageMetadataCreateFromXMPData(Data(packet.utf8) as CFData),
              let tree = CGImageMetadataCreateMutableCopy(parsed) else { return nil }

        // The extended packet is a second RDF document; the main one wins a clash.
        if let extended, let more = CGImageMetadataCreateFromXMPData(Data(extended.utf8) as CFData) {
            for tag in tags(more) {
                guard let path = path(tag), CGImageMetadataCopyTagWithPath(tree, nil, path as CFString) == nil,
                      let namespace = CGImageMetadataTagCopyNamespace(tag),
                      let prefix = CGImageMetadataTagCopyPrefix(tag) else { continue }
                CGImageMetadataRegisterNamespaceForPrefix(tree, namespace, prefix, nil)
                CGImageMetadataSetTagWithPath(tree, nil, path as CFString, tag)
            }
        }

        // Top-level properties are swapped whole: ImageIO's path calls are not
        // safe on the inside of a structure or an array.
        for tag in tags(tree) {
            guard let path = path(tag) else { continue }
            let result = filtered(tag, kept: kept, size: size)
            if result === tag { continue }
            CGImageMetadataRemoveTagWithPath(tree, nil, path as CFString)
            if let result { CGImageMetadataSetTagWithPath(tree, nil, path as CFString, result) }
        }
        // ImageIO's own marker (`iio:hasXMP`) is not content.
        let left = tags(tree).filter { CGImageMetadataTagCopyPrefix($0) as String? != XMPReader.internalPrefix }
        return left.isEmpty ? nil : tree
    }

    /// `tag` as it is written: itself when nothing in it changes, a rebuilt copy
    /// when a descendant is dropped or fixed, nil when it goes altogether. The
    /// rules apply by namespace and name at any depth, inside structures and
    /// array items alike (review 2026-09-30, S2), and a container left empty
    /// goes with its contents. An array item has no name of its own and follows
    /// its array. A rebuilt container loses its own qualifiers, which ImageIO
    /// cannot set; an untouched one keeps them.
    static func filtered(_ tag: CGImageMetadataTag, isItem: Bool = false, kept: Kept, size: PixelSize) -> CGImageMetadataTag? {
        guard let namespace = CGImageMetadataTagCopyNamespace(tag), let name = CGImageMetadataTagCopyName(tag) else { return tag }
        func rebuilt(_ type: CGImageMetadataType, _ value: CFTypeRef) -> CGImageMetadataTag? {
            guard let prefix = CGImageMetadataTagCopyPrefix(tag) else { return nil }
            return CGImageMetadataTagCreate(namespace, prefix, name, type, value)
        }
        func isKept(_ tag: CGImageMetadataTag) -> Bool {
            keeps(namespace: CGImageMetadataTagCopyNamespace(tag) as String? ?? "",
                  name: CGImageMetadataTagCopyName(tag) as String? ?? "", value: XMPReader.value(tag), kept: kept)
        }
        if !isItem {
            guard isKept(tag) else { return nil }
            if let fixed = fixedValue(namespace: namespace as String, name: name as String, size: size) {
                return rebuilt(.string, fixed as CFString)
            }
        }
        // A qualifier that may not be written takes its property with it.
        let qualifiers = CGImageMetadataTagCopyQualifiers(tag) as? [CGImageMetadataTag] ?? []
        guard qualifiers.allSatisfy(isKept) else { return nil }

        let value = CGImageMetadataTagCopyValue(tag)
        if let children = value as? [String: CGImageMetadataTag] {
            var left: [String: CGImageMetadataTag] = [:]
            var changed = false
            for (key, child) in children {
                let result = filtered(child, kept: kept, size: size)
                left[key] = result
                changed = changed || result !== child
            }
            if !changed { return tag }
            return left.isEmpty ? nil : rebuilt(.structure, left as CFDictionary)
        }
        if let items = value as? [CGImageMetadataTag] {
            let left = items.compactMap { filtered($0, isItem: true, kept: kept, size: size) }
            if left.count == items.count, zip(left, items).allSatisfy({ $0 === $1 }) { return tag }
            return left.isEmpty ? nil : rebuilt(CGImageMetadataTagGetType(tag), left as CFArray)
        }
        return tag
    }

    /// Whether a property of the source's packet is written, at any depth.
    static func keeps(namespace: String, name: String, value: @autoclosure () -> String, kept: Kept) -> Bool {
        // Never written (PRD §10.4): a thumbnail would still show the original.
        // The extended-packet pointer goes because the two packets are merged.
        if namespace == thumbnailImage || (namespace == xmp && name == "Thumbnails") { return false }
        if namespace == note && name == "HasExtendedXMP" { return false }

        // AI payloads belong to the AI workflow switch wherever they sit.
        if namespace == exif && name == "UserComment" && ImageMetadata.looksLikeA1111(value()) { return kept.aiWorkflow }
        let isDescription = (namespace == tiff && name == "ImageDescription") || (namespace == dublinCore && name == "description")
        if isDescription && MetadataWriter.looksLikeMidjourney(value()) { return kept.aiWorkflow }

        // GPS is stored inside EXIF but switched on its own (PRD §10.2).
        if namespace == exif && name.hasPrefix("GPS") { return kept.gps }
        if namespace == tiff && iptcMirrorsInTIFF.contains(name) { return kept.exif && kept.iptc }
        if exifNamespaces.contains(namespace) { return kept.exif }
        if namespace == xmp && exifMirrorsInXMP.contains(name) { return kept.exif }

        if iptcNamespaces.contains(namespace) { return kept.iptc }
        if namespace == dublinCore && iptcMirrorsInDublinCore.contains(name) { return kept.iptc }
        if namespace == photoshop {
            // The creation date repeats both the EXIF and the IPTC one.
            if name == "DateCreated" { return kept.exif && kept.iptc }
            if iptcMirrorsInPhotoshop.contains(name) { return kept.iptc }
        }
        return true
    }

    /// PRD §10.4 in the packet too: orientation 1, the output's pixel dimensions.
    static func fixedValue(namespace: String, name: String, size: PixelSize) -> String? {
        switch (namespace, name) {
        case (tiff, "Orientation"): return "1"
        case (tiff, "ImageWidth"), (exif, "PixelXDimension"): return "\(size.width)"
        case (tiff, "ImageLength"), (exif, "PixelYDimension"): return "\(size.height)"
        default: return nil
        }
    }

    private static func tags(_ metadata: CGImageMetadata) -> [CGImageMetadataTag] {
        CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] ?? []
    }

    private static func path(_ tag: CGImageMetadataTag) -> String? {
        guard let prefix = CGImageMetadataTagCopyPrefix(tag) as String?,
              let name = CGImageMetadataTagCopyName(tag) as String? else { return nil }
        return "\(prefix):\(name)"
    }
}
