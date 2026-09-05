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

    @Test func c2paSegmentInJPEG() {
        var jpeg = Self.encode(.jpeg)
        // Insert an APP11 segment right after SOI: FF EB, length, "JP", then a jumb box name.
        let payload: [UInt8] = [0x4A, 0x50] + [0, 0, 0, 0] + Array("jumb".utf8) + Array("c2pa".utf8)
        let length = UInt16(payload.count + 2)
        var seg: [UInt8] = [0xFF, 0xEB, UInt8(length >> 8), UInt8(length & 0xFF)]
        seg += payload
        jpeg.insert(contentsOf: seg, at: 2)
        #expect(JPEGScanner.hasC2PA(in: jpeg))
        #expect(!JPEGScanner.hasC2PA(in: Self.encode(.jpeg)))
    }

    @Test func badgesOrderAndTooltip() {
        var m = ImageMetadata()
        m.iccProfileName = "Display P3"; m.hasEXIF = true; m.hasGPS = true; m.orientation = 6; m.provenance = [.comfyUI]
        let labels = m.badges.map(\.label)
        #expect(labels == ["ICC", "Rotated", "EXIF", "GPS", "ComfyUI"])
        #expect(m.badges[0].detail.contains("Display P3"))
    }
}
