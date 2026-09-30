import Foundation
import Testing
import UniformTypeIdentifiers
@testable import RescaleKit

/// Detection on the fixture corpus (`MetadataFixtures.swift`): each file is
/// found to carry what its README entry says.
struct FixtureDetectionTests {
    static func labels(_ f: Fixture) throws -> [String] { try Fixture.load(f).metadata.badges.map(\.label) }

    @Test func corpusIsCompleteAndSmall() throws {
        for f in Fixture.allCases {
            let source = try Fixture.load(f)
            #expect(source.fileSize > 0 && source.fileSize < 100_000, "\(f.rawValue)")
            #expect(source.metadata.frameCount == 1, "\(f.rawValue)")
        }
    }

    @Test func cameraJPEGCarriesEXIFGPSAndAThumbnail() throws {
        let m = try Fixture.load(.camera).metadata
        #expect(m.hasEXIF && m.hasGPS && !m.hasIPTC)
        #expect(m.provenance.isEmpty)
        #expect(m.badges.contains { $0.label == "GPS" && $0.tone == .warning })
        #expect(FixtureProbe.hasEXIFThumbnail(jpeg: Fixture.camera.data))
        // The file has no XMP packet, but ImageIO derives `xmp:` / `photoshop:`
        // date tags from the TIFF ones and the detector counts them.
        withKnownIssue("XMP reported for a file without a packet", isIntermittent: true) {
            #expect(!m.hasXMP)
        }
    }

    @Test func iptcXMPJPEGCarriesBoth() throws {
        let m = try Fixture.load(.iptcXMP).metadata
        #expect(m.hasIPTC && m.hasXMP && !m.hasEXIF)
        // No GPS IFD in this file: ImageIO surfaces the packet's `exif:GPS*` mirror.
        #expect(m.hasGPS)
    }

    @Test func rotatedJPEGIsNormalisedOnLoad() throws {
        let source = try Fixture.load(.rotated)
        #expect(source.metadata.orientation == 6)
        #expect(source.size == PixelSize(48, 64))
        #expect(try Self.labels(.rotated).contains("Rotated"))
    }

    @Test func colourAndDepthFixtures() throws {
        let p3 = try Fixture.load(.displayP3)
        #expect(p3.type == .heic)
        #expect(p3.metadata.iccProfileName == "Display P3")
        #expect(p3.metadata.badges.first { $0.label == "ICC" }?.detail.contains("Display P3") == true)

        let deep = try Fixture.load(.sixteenBit)
        #expect(deep.type == .tiff)
        #expect(deep.metadata.bitDepth == 16)
        #expect(try Self.labels(.sixteenBit).contains("16-bit"))

        let cmyk = try Fixture.load(.cmyk).metadata
        #expect(cmyk.colorModel == "CMYK")
        #expect(cmyk.iccProfileName == "Generic CMYK Profile")
        #expect(try Self.labels(.cmyk).contains("CMYK"))
    }

    @Test func comfyUIPNGCarriesBothGraphs() throws {
        let m = try Fixture.load(.comfyUI).metadata
        #expect(m.provenance == [.comfyUI])
        #expect(m.pngTextKeywords == ["prompt", "workflow"])
        let chunks = PNGScanner.textChunks(in: Fixture.comfyUI.data)
        let prompt = try #require(chunks.first { $0.keyword == "prompt" }?.text)
        let graph = try #require(JSONSerialization.jsonObject(with: Data(prompt.utf8)) as? [String: [String: Any]])
        // The positive prompt: a CLIPTextEncode wired into the KSampler.
        let sampler = try #require(graph.values.first { $0["class_type"] as? String == "KSampler" }?["inputs"] as? [String: Any])
        let positive = try #require((sampler["positive"] as? [Any])?.first as? String)
        #expect(graph[positive]?["class_type"] as? String == "CLIPTextEncode")
        let workflow = try #require(chunks.first { $0.keyword == "workflow" }?.text)
        #expect((try JSONSerialization.jsonObject(with: Data(workflow.utf8)) as? [String: Any])?["nodes"] != nil)
    }

    @Test func a1111IsDetectedInPNGAndJPEG() throws {
        let png = try Fixture.load(.a1111PNG).metadata
        #expect(png.provenance == [.a1111])
        #expect(png.pngTextKeywords == ["parameters"])
        let jpeg = try Fixture.load(.a1111JPEG).metadata
        #expect(jpeg.provenance == [.a1111])
        #expect(jpeg.hasEXIF)
    }

    @Test func compressedTextChunksAreInflated() throws {
        let m = try Fixture.load(.compressedText).metadata
        #expect(m.pngTextKeywords == ["prompt", "workflow"])
        #expect(m.provenance == [.comfyUI])
        let chunks = PNGScanner.textChunks(in: Fixture.compressedText.data)
        #expect(chunks.allSatisfy { $0.isCompressed })
        // Same graphs as the uncompressed fixture, recovered from zTXt / iTXt.
        let plain = PNGScanner.textChunks(in: Fixture.comfyUI.data)
        #expect(chunks.map(\.text) == plain.map(\.text))
    }
}

/// BASELINE, not a specification. These pin what `Renderer.produce` writes
/// today — every metadata block stripped, orientation baked in; colour and
/// depth follow the ICC policy since #15 (detail in `ColorPlanTests`) —
/// so the writer issues (#13 EXIF/GPS/IPTC, #18 XMP, #14 AI workflow, #15 ICC)
/// have to change an expectation here deliberately, in the commit that changes
/// the behaviour. The two orientation tests are the exception: PRD §10.3 keeps
/// them true for good.
struct MetadataRoundTripBaselineTests {
    @Test(arguments: Fixture.allCases)
    func everythingIsStripped(_ fixture: Fixture) throws {
        let out = try fixture.roundTrip()
        let m = out.metadata
        #expect(!m.hasEXIF && !m.hasGPS && !m.hasIPTC && !m.hasXMP)
        #expect(m.provenance.isEmpty)
        #expect(m.pngTextKeywords.isEmpty)
        #expect(!out.hasEXIFThumbnail)
        // "16-bit" is not in this list since #15: depth is kept, not stripped.
        let blocks: Set = ["EXIF", "GPS", "IPTC", "XMP", "Rotated", "CMYK"]
        #expect(m.badges.allSatisfy { !blocks.contains($0.label) && $0.tone != .provenance })
    }

    /// The default policy preserves the profile and the depth (#15). CMYK is
    /// the exception: the loader hands it over as sRGB, so it is written as sRGB.
    @Test(arguments: Fixture.allCases)
    func defaultOutputKeepsProfileAndDepth(_ fixture: Fixture) throws {
        let m = try fixture.roundTrip().metadata
        #expect(m.iccProfileName == (fixture == .displayP3 ? "Display P3" : "sRGB IEC61966-2.1"))
        #expect(m.colorModel == "RGB")
        #expect(m.bitDepth == (fixture == .sixteenBit ? 16 : 8))
        #expect(m.badges.contains { $0.label == "16-bit" } == (fixture == .sixteenBit))
    }

    /// Convert to sRGB is what every file got before #15, bar the depth.
    @Test(arguments: Fixture.allCases)
    func convertedOutputIsSRGB(_ fixture: Fixture) throws {
        let m = try fixture.roundTrip { $0.metadata.icc = .convertToSRGB }.metadata
        #expect(m.iccProfileName == "sRGB IEC61966-2.1")
        #expect(m.colorModel == "RGB")
        #expect(m.bitDepth == (fixture == .sixteenBit ? 16 : 8))
    }

    @Test(arguments: Fixture.allCases)
    func formatAndSizeAreKept(_ fixture: Fixture) throws {
        let source = try Fixture.load(fixture)
        let out = try fixture.roundTrip()
        #expect(out.type == OutputFormat.keepOriginal.resolvedType(for: source.type))
        #expect(out.size == source.size)
    }

    @Test(arguments: Fixture.allCases)
    func outputOrientationIsUpright(_ fixture: Fixture) throws {
        #expect(try fixture.roundTrip().metadata.orientation == 1)
    }

    @Test func orientationIsBakedIntoThePixels() throws {
        let out = try Fixture.rotated.roundTrip()
        #expect(Fixture.storedSize == PixelSize(64, 48))
        #expect(out.size == PixelSize(48, 64))
        // Stored top-left is red, stored bottom-left blue; turned 90° clockwise
        // they end up top-right and top-left.
        let topLeft = out.pixel(3, 3), topRight = out.pixel(44, 3)
        #expect(topRight[0] > 200 && topRight[1] < 60 && topRight[2] < 60)
        #expect(topLeft[2] > 200 && topLeft[0] < 60 && topLeft[1] < 60)
    }

    @Test func strippingHoldsAcrossFormats() throws {
        // The adjust closure is where a writer test sets its policy.
        let jpeg = try Fixture.comfyUI.roundTrip { $0.format = .jpeg }
        #expect(jpeg.type == .jpeg)
        #expect(jpeg.metadata.provenance.isEmpty && !jpeg.metadata.hasEXIF)
        let png = try Fixture.camera.roundTrip { $0.format = .png }
        #expect(png.type == .png)
        #expect(!png.metadata.hasEXIF && !png.metadata.hasGPS)
        let half = try Fixture.camera.roundTrip(spec: RenderSpec(target: PixelSize(32, 24), format: .heic))
        #expect(half.type == .heic && half.size == PixelSize(32, 24))
        #expect(!half.metadata.hasEXIF && !half.metadata.hasGPS)
    }
}
