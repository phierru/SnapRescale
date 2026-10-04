import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import RescaleKit

/// Synthesises files with ImageIO, splices in the chunks ImageIO cannot write,
/// and checks the detector reads them back.
struct MetadataTests {
    static func tinyImage() -> CGImage {
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return ctx.makeImage()!
    }

    static func encode(_ type: UTType, properties: [CFString: Any] = [:]) -> Data {
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, tinyImage(), properties as CFDictionary)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    /// Insert a PNG chunk right after IHDR.
    static func withChunk(_ png: Data, type: String, body: [UInt8]) -> Data {
        var out = Data(png.prefix(8 + 25))   // signature + IHDR (4+4+13+4)
        var length = UInt32(body.count).bigEndian
        out.append(Data(bytes: &length, count: 4))
        out.append(contentsOf: Array(type.utf8))
        out.append(contentsOf: body)
        out.append(contentsOf: [0, 0, 0, 0])  // CRC not checked by the scanner
        out.append(png.suffix(from: 8 + 25))
        return out
    }

    static func tEXt(_ keyword: String, _ text: String) -> [UInt8] {
        Array(keyword.utf8) + [0] + Array(text.utf8)
    }

    static func inspect(_ data: Data, _ type: UTType) -> ImageMetadata {
        let src = CGImageSourceCreateWithData(data as CFData, nil)!
        return ImageMetadata.inspect(source: src, data: data, type: type)
    }

    @Test func plainPNGHasNothingButProfile() {
        let m = Self.inspect(Self.encode(.png), .png)
        #expect(m.provenance.isEmpty)
        #expect(!m.hasEXIF && !m.hasGPS && !m.hasIPTC)
        #expect(m.frameCount == 1)
        #expect(m.hasAlpha)
    }

    @Test func comfyUIWorkflowIsDetected() {
        let png = Self.withChunk(Self.encode(.png), type: "tEXt",
                                 body: Self.tEXt("workflow", #"{"nodes":[{"id":1}]}"#))
        let m = Self.inspect(png, .png)
        #expect(m.provenance == [.comfyUI])
        #expect(m.pngTextKeywords.contains("workflow"))
        #expect(m.badges.contains { $0.label == "ComfyUI" && $0.tone == .provenance })
    }

    @Test func comfyUIPromptOnlyIsDetected() {
        let png = Self.withChunk(Self.encode(.png), type: "tEXt",
                                 body: Self.tEXt("prompt", #"{"3":{"class_type":"KSampler","inputs":{}}}"#))
        #expect(Self.inspect(png, .png).provenance == [.comfyUI])
    }

    @Test func a1111ParametersAreDetected() {
        let text = "a cat\nNegative prompt: dog\nSteps: 20, Sampler: Euler a, CFG scale: 7, Seed: 1"
        let png = Self.withChunk(Self.encode(.png), type: "tEXt", body: Self.tEXt("parameters", text))
        #expect(Self.inspect(png, .png).provenance == [.a1111])
    }

    @Test func fooocusAndSwarmAreNotMistakenForA1111() {
        let f = Self.withChunk(Self.withChunk(Self.encode(.png), type: "tEXt", body: Self.tEXt("fooocus_scheme", "fooocus")),
                               type: "tEXt", body: Self.tEXt("parameters", "Steps: 30, Sampler: dpmpp"))
        #expect(Self.inspect(f, .png).provenance == [.fooocus])
        let s = Self.withChunk(Self.encode(.png), type: "tEXt",
                               body: Self.tEXt("parameters", #"{"sui_image_params":{"prompt":"x"}}"#))
        #expect(Self.inspect(s, .png).provenance == [.swarmUI])
    }

    @Test func invokeAIAndNovelAIAreDetected() {
        let i = Self.withChunk(Self.encode(.png), type: "tEXt", body: Self.tEXt("invokeai_metadata", "{}"))
        #expect(Self.inspect(i, .png).provenance == [.invokeAI])
        let n = Self.withChunk(Self.encode(.png), type: "tEXt", body: Self.tEXt("Software", "NovelAI"))
        #expect(Self.inspect(n, .png).provenance == [.novelAI])
    }

    @Test func iTXtIsParsed() {
        // keyword\0 compressed(0) method(0) lang\0 translated\0 text
        let body: [UInt8] = Array("workflow".utf8) + [0, 0, 0] + Array("en".utf8) + [0] + [0] + Array("{}".utf8)
        let png = Self.withChunk(Self.encode(.png), type: "iTXt", body: body)
        let m = Self.inspect(png, .png)
        #expect(m.provenance == [.comfyUI])
    }

    @Test func c2paChunkInPNG() {
        let png = Self.withChunk(Self.encode(.png), type: "caBX", body: [0, 0, 0, 0])
        #expect(Self.inspect(png, .png).provenance == [.c2pa])
    }

    @Test func exifAndGPSInJPEG() {
        let props: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: "Test 50mm", kCGImagePropertyExifISOSpeedRatings: [100]],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 47.37, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 8.54, kCGImagePropertyGPSLongitudeRef: "E"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFImageDescription: "a castle --v 6 Job ID: 1234-abcd"],
        ]
        let m = Self.inspect(Self.encode(.jpeg, properties: props), .jpeg)
        #expect(m.hasEXIF)
        #expect(m.hasGPS)
        #expect(m.provenance == [.midjourney])
        #expect(m.badges.contains { $0.label == "GPS" && $0.tone == .warning })
        #expect(!m.hasAlpha)
    }

    static func box(_ type: String, _ body: [UInt8]) -> [UInt8] { MetadataReadableTests.box(type, body) }

    /// A JPEG with an APP11 segment right after SOI: FF EB, length, then the JPEG XT
    /// header (`JP`, box instance 1, packet sequence 1) and `box`.
    static func withAPP11(_ jpeg: Data, box: [UInt8]) -> Data {
        let payload: [UInt8] = Array("JP".utf8) + [0, 1] + MetadataReadableTests.be32(1) + box
        var out = jpeg
        out.insert(contentsOf: [0xFF, 0xEB, UInt8((payload.count + 2) >> 8), UInt8((payload.count + 2) & 0xFF)] + payload, at: 2)
        return out
    }

    /// A JUMBF superbox whose description box (type UUID, toggles: label present
    /// and requestable) carries `label`, then a content box.
    static func jumbf(type uuid: [UInt8], label: String) -> [UInt8] {
        box("jumb", box("jumd", uuid + [0x03] + Array(label.utf8) + [0]) + box("json", Array("{}".utf8)))
    }

    /// The UUID of a C2PA manifest store: "c2pa", then 0011-0010-8000-00AA00389B71.
    static let c2paUUID = Array("c2pa".utf8) + [0x00, 0x11, 0x00, 0x10, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71]

    /// The header segments' markers, up to SOS.
    static func markers(_ jpeg: Data) -> [UInt8] {
        let d = [UInt8](jpeg)
        var out: [UInt8] = [], i = 2
        while i + 4 <= d.count, d[i] == 0xFF, d[i + 1] != 0xDA {
            out.append(d[i + 1])
            i += 2 + (Int(d[i + 2]) << 8 | Int(d[i + 3]))
        }
        return out
    }

    @Test func c2paSegmentInJPEG() throws {
        let jpeg = Self.withAPP11(Self.encode(.jpeg), box: Self.jumbf(type: Self.c2paUUID, label: "c2pa"))
        #expect(JPEGScanner.hasC2PA(in: jpeg))
        #expect(!JPEGScanner.hasC2PA(in: Self.encode(.jpeg)))
        let m = Self.inspect(jpeg, .jpeg)
        #expect(m.provenance == [.c2pa] && m.c2paLocation == "JPEG APP11 segment (JUMBF)")

        // The output carries no APP11, so no manifest that no longer matches the pixels.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("c2pa-\(UUID().uuidString).jpg")
        try jpeg.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try SourceImage.load(url)
        let out = try Renderer.produce(source, spec: RenderSpec(target: source.size, metadata: .keepMost))
        #expect(!Self.markers(out).contains(0xEB) && Self.inspect(out, .jpeg).provenance.isEmpty)
    }

    /// JPEG XT and JUMBF content other than a C2PA manifest store share APP11 (issue #58).
    @Test func otherAPP11ContentIsNotC2PA() {
        let jpeg = Self.encode(.jpeg)
        // A JPEG XT box, no JUMBF.
        #expect(!JPEGScanner.hasC2PA(in: Self.withAPP11(jpeg, box: Self.box("LCHK", [0, 0, 0, 0]))))
        // JUMBF under another label, or with the C2PA UUID and no label.
        #expect(!JPEGScanner.hasC2PA(in: Self.withAPP11(jpeg, box: Self.jumbf(type: Self.c2paUUID, label: "jpxt"))))
        let unlabelled = Self.box("jumb", Self.box("jumd", Self.c2paUUID + [0x00]) + Self.box("json", Array("{}".utf8)))
        #expect(!JPEGScanner.hasC2PA(in: Self.withAPP11(jpeg, box: unlabelled)))
        #expect(Self.inspect(Self.withAPP11(jpeg, box: Self.box("LCHK", [0, 0, 0, 0])), .jpeg).provenance.isEmpty)
    }

    @Test func badgesOrderAndTooltip() {
        var m = ImageMetadata()
        // The ICC badge is for an embedded profile only (issue #25).
        m.iccProfileName = "Display P3"; m.iccOrigin = .embedded; m.hasEXIF = true; m.hasGPS = true; m.orientation = 6; m.provenance = [.comfyUI]
        let labels = m.badges.map(\.label)
        #expect(labels == ["ICC", "Rotated", "EXIF", "GPS", "ComfyUI"])
        #expect(m.badges[0].detail.contains("Display P3"))
    }
}
