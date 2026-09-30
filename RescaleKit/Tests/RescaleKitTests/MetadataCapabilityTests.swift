import Foundation
import Testing
import UniformTypeIdentifiers
@testable import RescaleKit

/// The source-aware capability table and the switch notes (GitHub #19).
struct MetadataCapabilityTests {
    typealias Section = MetadataPolicy.Section

    private func state(_ fixture: Fixture, _ section: Section, _ format: OutputFormat,
                       _ edit: (inout MetadataPolicy) -> Void = { _ in }) throws -> MetadataPolicy.SwitchState {
        let source = try Fixture.load(fixture)
        var spec = RenderSpec(target: source.size, format: format, metadata: .keepMost)
        edit(&spec.metadata)
        return MetadataPolicy.switchState(of: section, for: source, spec: spec)
    }

    @Test func aGraphNeedsPNG() throws {
        for fixture in [Fixture.comfyUI, .compressedText] {
            let metadata = try Fixture.load(fixture).metadata
            for type in [UTType.jpeg, .heic, .tiff] {
                let cap = MetadataPolicy.capability(of: .aiWorkflow, in: type, carrying: metadata)
                #expect(!cap.canCarry && cap.note == "Requires PNG output", "\(fixture) \(type)")
                // The plain table cannot know: it says yes, with a note.
                #expect(MetadataPolicy.capability(of: .aiWorkflow, in: type).canCarry)
            }
            #expect(MetadataPolicy.capability(of: .aiWorkflow, in: .png, carrying: metadata) == .full)
            for format in [OutputFormat.jpeg, .heic, .tiff] {
                let s = try state(fixture, .aiWorkflow, format)
                #expect(!s.isEnabled && s.note == "Requires PNG output" && s.possibleNotes == ["Requires PNG output"])
            }
            for format in [OutputFormat.png, .keepOriginal] {
                let s = try state(fixture, .aiWorkflow, format)
                #expect(s.isEnabled && s.note == nil && s.possibleNotes.isEmpty)
            }
        }
    }

    @Test func a1111ParametersStayEnabledEverywhere() throws {
        for fixture in [Fixture.a1111PNG, .a1111JPEG] {
            let metadata = try Fixture.load(fixture).metadata
            #expect(metadata.provenance == [.a1111])
            for type in [UTType.jpeg, .heic, .tiff, .png] {
                #expect(MetadataPolicy.capability(of: .aiWorkflow, in: type, carrying: metadata).canCarry)
            }
            for format in [OutputFormat.jpeg, .heic, .tiff, .png] {
                #expect(try state(fixture, .aiWorkflow, format).isEnabled)
            }
        }
        // From a PNG chunk they move; say where to. Nothing to say when stripping.
        #expect(try state(.a1111PNG, .aiWorkflow, .jpeg).note == "Kept in the EXIF user comment.")
        #expect(try state(.a1111PNG, .aiWorkflow, .jpeg) { $0.aiWorkflow = .strip }.note == nil)
        #expect(try state(.a1111PNG, .aiWorkflow, .jpeg) { $0.aiWorkflow = .strip }.possibleNotes == ["Kept in the EXIF user comment."])
        #expect(try state(.a1111PNG, .aiWorkflow, .png).note == nil)
        #expect(try state(.a1111JPEG, .aiWorkflow, .heic).note == nil)
    }

    @Test func aGraphBesideParametersIsPartlyKept() throws {
        var metadata = try Fixture.load(.comfyUI).metadata
        metadata.aiPayloads.append(.init(source: .a1111, name: "parameters", location: "PNG tEXt chunk", text: "Steps: 20"))
        let cap = MetadataPolicy.capability(of: .aiWorkflow, in: .jpeg, carrying: metadata)
        #expect(cap.canCarry && cap.note?.contains("requires PNG output") == true)
        // InvokeAI: graph chunks only.
        var invoke = ImageMetadata()
        invoke.aiPayloads = [.init(source: .invokeAI, name: "invokeai_graph", location: "PNG iTXt chunk", text: "{}")]
        #expect(!MetadataPolicy.capability(of: .aiWorkflow, in: .tiff, carrying: invoke).canCarry)
    }

    /// Unrecognised text under a tool keyword stays a PNG chunk while the parameters beside it move.
    @Test func unrecognisedTextBesideParametersIsPartlyKept() throws {
        let parameters = try #require(try Fixture.load(.a1111PNG).metadata.pngTextChunks.first)
        let source = try PNGSplicerTests.source(holding: [parameters, PNGSplicerTests.text("prompt", PNGSplicerTests.privateNote)])
        let state = MetadataPolicy.switchState(of: .aiWorkflow, for: source, spec: RenderSpec(target: source.size, format: .jpeg))
        #expect(state.isEnabled && state.note == "Only the generation parameters are kept; the unrecognised text requires PNG output.")
        let out = try FixtureProbe.inspect(try Renderer.produce(source, spec: RenderSpec(target: source.size, format: .jpeg)))
        #expect(out.metadata.provenance == [.a1111] && !out.contains(PNGSplicerTests.privateNote))
    }

    /// A GIF's XMP is read through ImageIO's display fields, with no packet for
    /// the writer to copy: Keep is not offered (review 2026-09-30, G8).
    @Test(arguments: [OutputFormat.png, .jpeg, .heic, .tiff])
    func xmpShownWithoutAPacketCannotBeKept(_ format: OutputFormat) throws {
        let gif = try XMPDetectionTests.encode(.gif, packet: XMPDetectionTests.packet)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("xmp-\(UUID().uuidString).gif")
        try gif.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try SourceImage.load(url)
        #expect(source.metadata.hasXMP && source.metadata.xmpPacket == nil)
        #expect(source.metadata.section(.xmp)?["xmp:Rating"] == "4")

        var spec = RenderSpec(target: source.size, format: format, metadata: .keepAll)
        let xmp = MetadataPolicy.switchState(of: .xmp, for: source, spec: spec)
        #expect(!xmp.isEnabled && xmp.note == MetadataPolicy.xmpNotCarriedNote && xmp.possibleNotes == [MetadataPolicy.xmpNotCarriedNote])
        #expect(!MetadataPolicy.capability(of: .xmp, for: source, spec: spec).canCarry)
        // Nothing of it is written, so there are no copies for another switch to remove.
        spec.metadata.gps = .strip
        let gps = MetadataPolicy.switchState(of: .gps, for: source, spec: spec)
        #expect(gps.isEnabled && gps.note == nil && gps.possibleNotes.isEmpty)
        let out = try FixtureProbe.inspect(try Renderer.produce(source, spec: spec))
        #expect(out.metadata.section(.xmp)?["xmp:Rating"] == nil)

        // A source whose packet was read is unaffected.
        let packet = try Fixture.load(.iptcXMP)
        let kept = RenderSpec(target: packet.size, format: format, metadata: .keepAll)
        #expect(MetadataPolicy.switchState(of: .xmp, for: packet, spec: kept).isEnabled)
    }

    @Test func otherSectionsFollowTheTable() throws {
        let metadata = try Fixture.load(.comfyUI).metadata
        for section in Section.allCases where section != .aiWorkflow {
            for type in [UTType.jpeg, .png, .heic, .tiff, .gif, .bmp] {
                #expect(MetadataPolicy.capability(of: section, in: type, carrying: metadata)
                        == MetadataPolicy.capability(of: section, in: type))
            }
            #expect(!MetadataPolicy.capability(of: section, in: nil, carrying: metadata).canCarry)
        }
    }

    @Test func iccNotesFollowTheSelectedOption() throws {
        // PNG: only Strip has something to say.
        #expect(try state(.comfyUI, .icc, .png).note == nil)
        #expect(try state(.comfyUI, .icc, .png) { $0.icc = .convertToSRGB }.note == nil)
        #expect(try state(.comfyUI, .icc, .png) { $0.icc = .strip }.note?.contains("sRGB marker") == true)
        // HEIC: Strip and sRGB write the same file.
        #expect(try state(.displayP3, .icc, .heic).note == nil)
        #expect(try state(.displayP3, .icc, .heic) { $0.icc = .strip }.note?.contains("same file as sRGB") == true)
        #expect(try state(.displayP3, .icc, .heic) { $0.icc = .convertToSRGB }.note?.contains("same file as Strip") == true)
        #expect(try state(.displayP3, .icc, .heic).possibleNotes.count == 2)
        #expect(try state(.camera, .icc, .jpeg) { $0.icc = .strip }.possibleNotes.isEmpty)
        // A CMYK source: Preserve falls back, and says so only while selected.
        let cmyk = try state(.cmyk, .icc, .keepOriginal)
        #expect(cmyk.isEnabled && cmyk.note?.contains("CMYK") == true)
        #expect(try state(.cmyk, .icc, .keepOriginal) { $0.icc = .strip }.note == nil)
        let source = try Fixture.load(.cmyk)
        let spec = RenderSpec(target: source.size)
        #expect(MetadataPolicy.capability(of: .icc, for: source, spec: spec) == MetadataPolicy.iccCapability(for: source, spec: spec))
    }

    @Test func iptcNoteOnlyWhileKept() throws {
        #expect(try state(.iptcXMP, .iptc, .png).note == "PNG has no IPTC block; kept as the XMP copies.")
        #expect(try state(.iptcXMP, .iptc, .heic).note?.hasPrefix("HEIC has no IPTC block") == true)
        #expect(try state(.iptcXMP, .iptc, .jpeg).note == nil)
        // Stripped with XMP kept: the mirror hint takes its place.
        #expect(try state(.iptcXMP, .iptc, .png) { $0.iptc = .strip }.note == "Also removed from XMP")
    }

    @Test func strippingSaysWhenTheXMPCopiesGoToo() throws {
        // The default policy strips GPS; this file's XMP repeats it.
        #expect(try state(.iptcXMP, .gps, .jpeg).note == "Also removed from XMP")
        #expect(try state(.iptcXMP, .gps, .jpeg) { $0.gps = .keep }.note == nil)
        #expect(try state(.iptcXMP, .gps, .jpeg) { $0.gps = .keep }.possibleNotes == ["Also removed from XMP"])
        // XMP stripped as well: nothing left to mention, but the room stays reserved.
        let both = try state(.iptcXMP, .gps, .jpeg) { $0.xmp = .strip }
        #expect(both.note == nil && both.possibleNotes == ["Also removed from XMP"])
        #expect(try state(.iptcXMP, .iptc, .jpeg) { $0.iptc = .strip }.note == "Also removed from XMP")
        // No XMP packet, no hint; and XMP has no mirror of itself.
        let camera = try state(.camera, .gps, .jpeg)
        #expect(camera.isEnabled && camera.note == nil && camera.possibleNotes.isEmpty)
        #expect(try state(.iptcXMP, .xmp, .jpeg) { $0.xmp = .strip }.note == nil)
    }

    @Test func sectionSubscript() {
        var p = MetadataPolicy.default
        #expect(p[.gps] == .strip && p[.exif] == .strip && p[.icc] == .keep && p[.aiWorkflow] == .keep)
        for s in Section.allCases { p[s] = .keep }
        #expect(p == .keepAll)
        for s in Section.allCases { p[s] = .strip }
        #expect(p == .stripAll)
    }
}
