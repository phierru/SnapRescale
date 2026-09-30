import Foundation

/// Friendly labels, translated coded values and field priority for the inspector
/// (PRD §10.2, issue #25). Works on the raw key and the stored display value, so
/// `MetadataField.key` / `.value` stay what the file holds.
enum MetadataLabels {
    typealias Kind = MetadataSection.Kind

    // MARK: Priority

    /// The primary fields of each section, in reading order. Everything else is secondary.
    static let primaryKeys: [Kind: [String]] = [
        .exif: ["Make", "Model", "LensModel", "DateTimeOriginal", "ExposureTime", "FNumber", "ISOSpeedRatings",
                "FocalLength", "FocalLenIn35mmFilm", "Flash"],
        .gps: ["Position", "Altitude"],
        .iptc: ["Caption/Abstract", "Keywords", "Byline", "Credit", "CopyrightNotice", "City"],
        .xmp: ["xmp:Rating", "xmp:Label", "dc:title", "dc:description", "dc:creator", "dc:rights"],
        // The summary (`ImageMetadata.aiSummary`) goes above; the raw payloads fold away.
        .aiWorkflow: ["Source"],
    ]

    /// Short read-only sections with nothing to fold.
    static let allPrimary: Set<Kind> = [.icc, .c2pa, .structure]

    // MARK: Decoration

    /// The section with labels, readable values and priorities filled in, and for
    /// GPS one derived `Position` line after the raw fields.
    static func decorated(_ section: MetadataSection) -> MetadataSection {
        var out = section
        if section.kind == .gps, section["Position"] == nil,
           let position = position(latitude: section["Latitude"], latitudeRef: section["LatitudeRef"],
                                   longitude: section["Longitude"], longitudeRef: section["LongitudeRef"]) {
            out.fields.append(MetadataField(key: "Position", value: position))
        }
        let primary = Set(primaryKeys[section.kind] ?? [])
        out.fields = out.fields.map { f in
            MetadataField(key: f.key, value: f.value,
                          label: f.label != f.key ? f.label : label(section.kind, f.key),
                          readableValue: f.isTranslated ? f.readableValue
                              : readable(section.kind, f.key, f.value, in: section),
                          priority: allPrimary.contains(section.kind) || primary.contains(f.key) ? .primary : .secondary)
        }
        return out
    }

    // MARK: Labels

    static func label(_ kind: Kind, _ key: String) -> String {
        switch kind {
        case .exif: return exifLabels[key] ?? humanised(key)
        case .gps: return gpsLabels[key] ?? humanised(key)
        case .iptc: return iptcLabels[key] ?? humanised(key)
        case .xmp: return xmpLabels[key] ?? key
        default: return key
        }
    }

    static let exifLabels: [String: String] = [
        "Make": "Camera make", "Model": "Camera model", "Software": "Software", "DateTime": "Date modified",
        "Artist": "Artist", "Copyright": "Copyright", "ImageDescription": "Description",
        "HostComputer": "Host computer", "Orientation": "Orientation",
        "XResolution": "Resolution (X)", "YResolution": "Resolution (Y)", "ResolutionUnit": "Resolution unit",
        "DateTimeOriginal": "Date taken", "DateTimeDigitized": "Date digitised",
        "OffsetTime": "Time zone (modified)", "OffsetTimeOriginal": "Time zone (taken)",
        "OffsetTimeDigitized": "Time zone (digitised)",
        "SubsecTime": "Sub-second time (modified)", "SubsecTimeOriginal": "Sub-second time (taken)",
        "SubsecTimeDigitized": "Sub-second time (digitised)",
        "LensMake": "Lens make", "LensModel": "Lens", "LensSpecification": "Lens specification",
        "LensSerialNumber": "Lens serial number", "BodySerialNumber": "Camera serial number",
        "ExposureTime": "Exposure time", "FNumber": "Aperture", "ISOSpeedRatings": "ISO",
        "FocalLength": "Focal length", "FocalLenIn35mmFilm": "Focal length (35 mm)",
        "ExposureBiasValue": "Exposure compensation", "Flash": "Flash",
        "MeteringMode": "Metering mode", "ExposureProgram": "Exposure programme", "ExposureMode": "Exposure mode",
        "WhiteBalance": "White balance", "ColorSpace": "Colour space", "SceneCaptureType": "Scene capture type",
        "SensingMethod": "Sensing method", "SceneType": "Scene type", "CompositeImage": "Composite image",
        "LightSource": "Light source", "CustomRendered": "Custom rendered", "FileSource": "File source",
        "Contrast": "Contrast", "Saturation": "Saturation", "Sharpness": "Sharpness",
        "ShutterSpeedValue": "Shutter speed (APEX)", "ApertureValue": "Aperture (APEX)",
        "BrightnessValue": "Brightness (APEX)", "MaxApertureValue": "Maximum aperture (APEX)",
        "PixelXDimension": "Pixel width", "PixelYDimension": "Pixel height",
        "ExifVersion": "EXIF version", "FlashPixVersion": "FlashPix version",
        "ComponentsConfiguration": "Components configuration", "SubjectArea": "Subject area",
        "DigitalZoomRatio": "Digital zoom ratio", "UserComment": "User comment",
        "LensInfo": "Lens specification", "SerialNumber": "Serial number",
    ]

    static let gpsLabels: [String: String] = [
        "Position": "Position", "Latitude": "Latitude", "LatitudeRef": "Latitude hemisphere",
        "Longitude": "Longitude", "LongitudeRef": "Longitude hemisphere",
        "Altitude": "Altitude", "AltitudeRef": "Altitude reference",
        "DateStamp": "Date (UTC)", "TimeStamp": "Time (UTC)",
        "Speed": "Speed", "SpeedRef": "Speed unit",
        "ImgDirection": "Image direction", "ImgDirectionRef": "Image direction reference",
        "DestBearing": "Destination bearing", "DestBearingRef": "Destination bearing reference",
        "Track": "Direction of travel", "TrackRef": "Direction of travel reference",
        "HPositioningError": "Horizontal accuracy",
    ]

    static let iptcLabels: [String: String] = [
        "ObjectName": "Title", "Headline": "Headline", "Caption/Abstract": "Caption", "Keywords": "Keywords",
        "Byline": "Byline", "BylineTitle": "Byline title", "Credit": "Credit", "Source": "Source",
        "CopyrightNotice": "Copyright", "City": "City", "SubLocation": "Sublocation",
        "Province/State": "Province / state", "Country/PrimaryLocationName": "Country",
        "Country/PrimaryLocationCode": "Country code", "Writer/Editor": "Caption writer",
        "DateCreated": "Date created", "TimeCreated": "Time created",
        "DigitalCreationDate": "Date digitised", "DigitalCreationTime": "Time digitised",
    ]

    static let xmpLabels: [String: String] = [
        "xmp:Rating": "Rating", "xmp:Label": "Label", "dc:title": "Title", "dc:description": "Description",
        "dc:creator": "Creator", "dc:rights": "Rights",
    ]

    /// `SubjectDistRange` → "Subject dist range", `ISOSpeed` → "ISO speed". Keys that are
    /// not plain CamelCase identifiers (`Caption/Abstract`, `dc:title`) come back unchanged.
    static func humanised(_ key: String) -> String {
        guard !key.isEmpty, key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return key }
        let chars = Array(key)
        var words: [String] = []
        var current = ""
        for (i, c) in chars.enumerated() {
            let previous = i > 0 ? chars[i - 1] : nil
            let next = i + 1 < chars.count ? chars[i + 1] : nil
            var breaks = false
            if let previous {
                if c.isUppercase {
                    // aB, 1B, or the last capital of an acronym: ISOSpeed → ISO | Speed.
                    breaks = !previous.isUppercase || (next?.isLowercase ?? false)
                } else if c.isNumber {
                    breaks = !previous.isNumber
                }
            }
            if breaks, !current.isEmpty { words.append(current); current = "" }
            current.append(c)
        }
        if !current.isEmpty { words.append(current) }
        return words.enumerated().map { i, w in
            i == 0 || (w.count > 1 && w.allSatisfy { $0.isUppercase || $0.isNumber }) ? w : w.lowercased()
        }.joined(separator: " ")
    }

    // MARK: Values

    /// The value a person reads. Unknown codes and anything unparseable come back unchanged.
    static func readable(_ kind: Kind, _ key: String, _ value: String, in section: MetadataSection? = nil) -> String {
        switch kind {
        case .exif:
            if key == "Flash" { return flash(value) }
            if ["DateTime", "DateTimeOriginal", "DateTimeDigitized"].contains(key) { return date(value) }
            if let table = exifCodes[key], let code = Int(value), let name = table[code] { return name }
            return value
        case .gps:
            switch key {
            case "Altitude":
                guard Double(value) != nil else { return value }
                return section?["AltitudeRef"] == "1" ? "\(value) m below sea level" : "\(value) m"
            case "HPositioningError":
                return Double(value) != nil ? "\(value) m" : value
            case "DateStamp":
                return date(value)
            default:
                return gpsCodes[key]?[value] ?? value
            }
        default:
            return value
        }
    }

    /// EXIF writes dates as `2026:09:30 10:11:12`; shown as `2026-09-30 10:11:12`.
    static func date(_ value: String) -> String {
        let c = Array(value)
        guard c.count == 10 || c.count == 19, c[4] == ":", c[7] == ":",
              c.prefix(4).allSatisfy(\.isNumber) else { return value }
        return String(c[0..<4]) + "-" + String(c[5..<7]) + "-" + String(c[8...])
    }

    /// The EXIF Flash bit field: bit 0 fired, bits 1–2 return light, bits 3–4 mode,
    /// bit 5 no flash function, bit 6 red-eye reduction. 16 → "Off, did not fire".
    static func flash(_ value: String) -> String {
        guard let bits = Int(value), (0...0x7F).contains(bits) else { return value }
        if bits & 0x20 != 0 { return bits == 0x20 ? "No flash function" : value }
        var parts: [String] = []
        switch (bits >> 3) & 0b11 {
        case 1: parts.append("on")
        case 2: parts.append("off")
        case 3: parts.append("auto")
        default: break
        }
        parts.append(bits & 1 != 0 ? "fired" : "did not fire")
        switch (bits >> 1) & 0b11 {
        case 2: parts.append("return light not detected")
        case 3: parts.append("return light detected")
        case 1: return value                                              // reserved
        default: break
        }
        if bits & 0x40 != 0 { parts.append("red-eye reduction") }
        let text = parts.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    static let orientations = [1: "Upright", 2: "Mirrored horizontally", 3: "Rotated 180°", 4: "Mirrored vertically",
                               5: "Mirrored, rotated 90° CCW", 6: "Rotated 90° CW", 7: "Mirrored, rotated 90° CW",
                               8: "Rotated 90° CCW"]

    /// EXIF 2.32 / TIFF 6.0 enumerations, keyed by ImageIO's tag names.
    static let exifCodes: [String: [Int: String]] = [
        "MeteringMode": [0: "Unknown", 1: "Average", 2: "Centre-weighted average", 3: "Spot", 4: "Multi-spot",
                         5: "Pattern", 6: "Partial", 255: "Other"],
        "ExposureProgram": [0: "Not defined", 1: "Manual", 2: "Normal programme", 3: "Aperture priority",
                            4: "Shutter priority", 5: "Creative programme", 6: "Action programme",
                            7: "Portrait mode", 8: "Landscape mode"],
        "ExposureMode": [0: "Auto", 1: "Manual", 2: "Auto bracket"],
        "WhiteBalance": [0: "Auto", 1: "Manual"],
        "ColorSpace": [1: "sRGB", 65535: "Uncalibrated"],
        "SceneCaptureType": [0: "Standard", 1: "Landscape", 2: "Portrait", 3: "Night scene"],
        "SensingMethod": [1: "Not defined", 2: "One-chip colour area sensor", 3: "Two-chip colour area sensor",
                          4: "Three-chip colour area sensor", 5: "Colour sequential area sensor",
                          7: "Trilinear sensor", 8: "Colour sequential linear sensor"],
        "SceneType": [1: "Directly photographed"],
        "FileSource": [1: "Film scanner", 2: "Reflection print scanner", 3: "Digital camera"],
        "ResolutionUnit": [1: "None", 2: "Inches", 3: "Centimetres"],
        "Orientation": orientations,
        "CompositeImage": [0: "Unknown", 1: "Not a composite image", 2: "General composite image",
                           3: "Composite image captured while shooting"],
        "LightSource": [0: "Unknown", 1: "Daylight", 2: "Fluorescent", 3: "Tungsten", 4: "Flash", 9: "Fine weather",
                        10: "Cloudy", 11: "Shade", 12: "Daylight fluorescent", 13: "Day white fluorescent",
                        14: "Cool white fluorescent", 15: "White fluorescent", 16: "Warm white fluorescent",
                        17: "Standard light A", 18: "Standard light B", 19: "Standard light C", 20: "D55", 21: "D65",
                        22: "D75", 23: "D50", 24: "ISO studio tungsten", 255: "Other"],
        "CustomRendered": [0: "Normal", 1: "Custom"],
        "Contrast": [0: "Normal", 1: "Soft", 2: "Hard"],
        "Saturation": [0: "Normal", 1: "Low", 2: "High"],
        "Sharpness": [0: "Normal", 1: "Soft", 2: "Hard"],
    ]

    static let gpsCodes: [String: [String: String]] = [
        "LatitudeRef": ["N": "North", "S": "South"],
        "LongitudeRef": ["E": "East", "W": "West"],
        "AltitudeRef": ["0": "Above sea level", "1": "Below sea level"],
        "SpeedRef": ["K": "km/h", "M": "mph", "N": "knots"],
        "ImgDirectionRef": ["T": "True north", "M": "Magnetic north"],
        "DestBearingRef": ["T": "True north", "M": "Magnetic north"],
        "TrackRef": ["T": "True north", "M": "Magnetic north"],
    ]

    // MARK: GPS position

    /// `46.1553° N, 8.7716° E`. Nil without both coordinates and both hemispheres:
    /// the sign alone is not trusted.
    static func position(latitude: String?, latitudeRef: String?, longitude: String?, longitudeRef: String?) -> String? {
        guard let lat = latitude.flatMap(Double.init), let lon = longitude.flatMap(Double.init) else { return nil }
        return position(latitude: lat, latitudeRef: latitudeRef, longitude: lon, longitudeRef: longitudeRef)
    }

    static func position(latitude: Double, latitudeRef: String?, longitude: Double, longitudeRef: String?) -> String? {
        guard let ns = latitudeRef?.uppercased(), ns == "N" || ns == "S",
              let ew = longitudeRef?.uppercased(), ew == "E" || ew == "W",
              abs(latitude) <= 90, abs(longitude) <= 180 else { return nil }
        return String(format: "%.4f° %@, %.4f° %@", abs(latitude), ns, abs(longitude), ew)
    }
}
