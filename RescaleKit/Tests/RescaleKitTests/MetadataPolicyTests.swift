import Foundation
import Testing
import UniformTypeIdentifiers
@testable import RescaleKit

struct MetadataPolicyTests {
    typealias Section = MetadataPolicy.Section

    /// PRD §10.2: strip EXIF, GPS, IPTC and XMP; keep the colour profile and the AI workflow.
    @Test func defaultKeepsOnlyTheProfileAndTheWorkflow() {
        let p = MetadataPolicy.default
        #expect(p == MetadataPolicy())
        #expect(p.exif == .strip && p.gps == .strip && p.iptc == .strip && p.xmp == .strip)
        #expect(p.aiWorkflow == .keep)
        #expect(p.icc == .preserve)
        #expect(Section.allCases.filter(p.keeps) == [.icc, .aiWorkflow])
    }

    @Test func summaryDrivesTheMasterControl() {
        #expect(MetadataPolicy.keepAll.summary == .keepAll)
        #expect(MetadataPolicy.stripAll.summary == .stripAll)
        #expect(MetadataPolicy.default.summary == .default)
        #expect(MetadataPolicy().summary == .default)
        #expect(Section.allCases.allSatisfy { MetadataPolicy.keepAll.keeps($0) })
        #expect(Section.allCases.allSatisfy { !MetadataPolicy.stripAll.keeps($0) })

        var p = MetadataPolicy.keepMost
        #expect(p.summary == .custom)
        p.gps = .keep
        #expect(p.summary == .keepAll)
        p.icc = .convertToSRGB   // neither kept nor stripped
        #expect(p.summary == .custom && p.keeps(.icc))
        p = .default
        p.iptc = .keep
        #expect(p.summary == .custom)
        p.iptc = .strip
        #expect(p.summary == .default)
        p = .stripAll
        p.xmp = .keep
        #expect(p.summary == .custom)
    }

    @Test func summaryLabels() {
        typealias Summary = MetadataPolicy.Summary
        #expect(Summary.allCases == [.default, .keepAll, .stripAll, .custom])
        #expect(Summary.allCases.map(\.label) == ["Default", "Keep all", "Strip all", "Custom"])
    }

    /// The sidebar row (GitHub #16): the label, and for anything that is not
    /// all-or-nothing, what is stripped or what is left.
    @Test func summaryLineReadsWellForEveryCombination() {
        typealias P = MetadataPolicy
        #expect(P.default.summaryLine == "Default · only ICC, AI kept")
        #expect(P.keepAll.summaryLine == "Keep all")
        #expect(P.stripAll.summaryLine == "Strip all")
        #expect(Preset.shipped[0].metadata.summaryLine == "Default · only ICC, AI kept")

        func keeping(_ change: (inout P) -> Void) -> String {
            var p = P.keepAll
            change(&p)
            return p.summaryLine
        }
        #expect(keeping { $0.icc = .convertToSRGB } == "Custom · converted to sRGB")
        #expect(P.keepMost.summaryLine == "Custom · GPS stripped")
        #expect(P.keepMost(icc: .convertToSRGB).summaryLine == "Custom · GPS stripped, sRGB")
        #expect(keeping { $0.exif = .strip; $0.gps = .strip } == "Custom · EXIF, GPS stripped")
        #expect(keeping { $0.icc = .strip } == "Custom · ICC stripped")
        #expect(keeping { $0.aiWorkflow = .strip } == "Custom · AI stripped")
        #expect(keeping { $0.exif = .strip; $0.gps = .strip; $0.iptc = .strip } == "Custom · EXIF, GPS, IPTC stripped")
        // Past three, what is left is the shorter list.
        #expect(P(aiWorkflow: .strip).summaryLine == "Custom · only ICC kept")
        #expect(P(icc: .convertToSRGB).summaryLine == "Custom · only sRGB, AI kept")
        #expect(P(icc: .convertToSRGB, aiWorkflow: .strip).summaryLine == "Custom · only sRGB kept")
        #expect(P(gps: .keep, icc: .strip, aiWorkflow: .strip).summaryLine == "Custom · only GPS kept")

        // Every one of the 96 policies gets a short single line that starts with its label.
        let actions = P.Action.allCases
        for exif in actions { for gps in actions { for iptc in actions { for xmp in actions {
            for icc in P.ICC.allCases { for ai in actions {
                let p = P(exif: exif, gps: gps, iptc: iptc, xmp: xmp, icc: icc, aiWorkflow: ai)
                let line = p.summaryLine
                #expect(line.hasPrefix(p.summary.label), Comment(rawValue: line))
                #expect(line.count <= 40 && !line.contains("\n"), Comment(rawValue: line))
                #expect((p.summary == .custom) == line.hasPrefix("Custom · "), Comment(rawValue: line))
            } }
        } } } }
    }

    @Test func sectionsAreTheSixWithASwitch() {
        #expect(Section.allCases == [.exif, .gps, .iptc, .xmp, .icc, .aiWorkflow])
        #expect(Section.allCases.map(\.label) == ["EXIF", "GPS", "IPTC", "XMP", "ICC profile", "AI workflow"])
    }

    @Test func roundTripsThroughJSON() throws {
        var policies: [MetadataPolicy] = [.default, .keepAll, .stripAll]
        for icc in MetadataPolicy.ICC.allCases {
            policies.append(MetadataPolicy(exif: .strip, gps: .keep, iptc: .strip, xmp: .keep, icc: icc, aiWorkflow: .strip))
        }
        for p in policies {
            let data = try JSONEncoder().encode(p)
            #expect(try JSONDecoder().decode(MetadataPolicy.self, from: data) == p)
            let preset = Preset(name: "P", size: .width(100), metadata: p)
            #expect(try Preset.from(json: try preset.jsonData()) == preset)
        }
    }

    @Test func jsonIsReadable() throws {
        let preset = Preset(name: "P", size: .width(100), metadata: MetadataPolicy(icc: .convertToSRGB))
        let json = String(decoding: try preset.jsonData(), as: UTF8.self)
        #expect(json.contains(#""metadata" : {"#))
        #expect(json.contains(#""exif" : "strip""#) && json.contains(#""gps" : "strip""#))
        #expect(json.contains(#""iptc" : "strip""#) && json.contains(#""xmp" : "strip""#))
        #expect(json.contains(#""icc" : "srgb""#) && json.contains(#""aiWorkflow" : "keep""#))
        #expect(!json.contains("_0"))

        // Hand-written: a section left out takes its default.
        let hand = #"{ "gps": "keep", "icc": "strip" }"#
        let p = try JSONDecoder().decode(MetadataPolicy.self, from: Data(hand.utf8))
        #expect(p == MetadataPolicy(gps: .keep, icc: .strip))
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(MetadataPolicy.self, from: Data(#"{ "gps": "maybe" }"#.utf8))
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(MetadataPolicy.self, from: Data(#"{ "icc": "cmyk" }"#.utf8))
        }
    }

    /// A preset saved before the field existed: the PRD §12 example, verbatim.
    @Test func oldPresetDecodesWithTheDefaultPolicy() throws {
        let old = """
        { "name": "Social 16:9", "aspect": "16:9", "size": { "width": 1920 },
          "multiple": 8, "fit": "crop", "padColor": "#ffffff",
          "format": "keep", "quality": 0.95 }
        """
        let p = try Preset.from(json: Data(old.utf8))
        #expect(p.metadata == .default)
        #expect(p == Preset.shipped[2])
        #expect(throws: Never.self) { try p.validate() }
    }

    @Test func specAndPresetCarryThePolicy() {
        #expect(RenderSpec(target: PixelSize(10, 10)).metadata == .default)
        #expect(RenderSpec(target: PixelSize(10, 10), metadata: .stripAll).metadata == .stripAll)
        #expect(Preset.shipped.allSatisfy { $0.metadata == .default })
        #expect(Preset.shipped[0].name == "Web" && Preset.shipped[0].metadata.gps == .strip)
        #expect(RenderSpec(target: PixelSize(10, 10)) != RenderSpec(target: PixelSize(10, 10), metadata: .keepAll))
    }

    // MARK: - Capability table (PRD §10.3)

    private func cap(_ s: Section, _ t: UTType) -> MetadataPolicy.Capability { MetadataPolicy.capability(of: s, in: t) }

    @Test func pngCarriesEverything() {
        for s in Section.allCases { #expect(cap(s, .png).canCarry, Comment(rawValue: s.rawValue)) }
        #expect(cap(.aiWorkflow, .png) == .full)   // the only home of a ComfyUI graph
        #expect(cap(.iptc, .png).note?.contains("XMP") == true)
        for s in [Section.exif, .gps, .xmp] { #expect(cap(s, .png) == .full) }
        // Strip cannot remove ImageIO's `sRGB` chunk (issue #15).
        #expect(cap(.icc, .png).note?.contains("sRGB marker") == true)
    }

    @Test func jpegCarriesPhotoMetadataButNoGraph() {
        for s in [Section.exif, .gps, .iptc, .xmp, .icc] { #expect(cap(s, .jpeg) == .full) }
        let ai = cap(.aiWorkflow, .jpeg)
        #expect(ai.canCarry)
        #expect(ai.note?.contains("A1111") == true && ai.note?.contains("ComfyUI") == true && ai.note?.contains("PNG") == true)
    }

    @Test func heicCarriesPhotoMetadataButNoGraph() {
        for s in [Section.exif, .gps, .xmp] { #expect(cap(s, .heic) == .full) }
        // An sRGB HEIC has no profile to strip (issue #15).
        #expect(cap(.icc, .heic).note?.contains("Strip and Convert") == true)
        #expect(cap(.iptc, .heic).canCarry && cap(.iptc, .heic).note?.contains("XMP") == true)
        #expect(cap(.aiWorkflow, .heic).canCarry && cap(.aiWorkflow, .heic).note?.hasPrefix("HEIC") == true)
    }

    @Test func tiffCarriesPhotoMetadataButNoGraph() {
        for s in [Section.exif, .gps, .iptc, .xmp, .icc] { #expect(cap(s, .tiff) == .full) }
        #expect(cap(.aiWorkflow, .tiff).canCarry && cap(.aiWorkflow, .tiff).note?.hasPrefix("TIFF") == true)
    }

    @Test func gifAndBMPCarryNothingAndSayWhy() {
        for t in [UTType.gif, .bmp, .webP] {
            for s in Section.allCases {
                let c = cap(s, t)
                #expect(!c.canCarry, Comment(rawValue: "\(t.identifier) \(s.rawValue)"))
                #expect(c.note?.isEmpty == false)
            }
        }
        #expect(cap(.gps, .gif).note == "GIF cannot carry a GPS location.")
        #expect(cap(.aiWorkflow, .bmp).note == "BMP cannot carry an AI workflow. Save as PNG to keep it.")
    }

    /// Every type `OutputFormat` can resolve to has a row, and `keepOriginal`
    /// follows the source.
    @Test func everyOutputTypeIsCovered() {
        for t in OutputFormat.writable {
            for s in Section.allCases {
                #expect(cap(s, t).canCarry, Comment(rawValue: "\(t.identifier) \(s.rawValue)"))
            }
        }
        let sources: [UTType] = [.jpeg, .png, .heic, .tiff, .gif, .bmp, .webP]
        for f in OutputFormat.allCases {
            for src in sources {
                for s in Section.allCases {
                    let c = MetadataPolicy.capability(of: s, format: f, source: src)
                    if let t = f.resolvedType(for: src) {
                        #expect(c == cap(s, t))
                    } else {
                        #expect(!c.canCarry && c.note?.isEmpty == false)
                    }
                }
            }
        }
        #expect(MetadataPolicy.capability(of: .aiWorkflow, format: .keepOriginal, source: .png) == .full)
        #expect(MetadataPolicy.capability(of: .aiWorkflow, format: .jpeg, source: .png).note != nil)
    }
}
