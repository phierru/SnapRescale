import Foundation
import Testing
@testable import RescaleKit

struct PresetTests {
    @Test func roundTripsThroughJSON() throws {
        for p in Preset.shipped {
            let data = try p.jsonData()
            let back = try Preset.from(json: data)
            #expect(back == p, Comment(rawValue: p.name))
        }
        let custom = Preset(name: "Pad test", aspect: .fixed(width: 4, height: 5), size: .scale(0.5),
                            multiple: .sixteen, fit: .pad, padColor: PadColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 0.8),   // 8-bit exact: hex round-trips
                            format: .heic, quality: 0.7)
        #expect(try Preset.from(json: try custom.jsonData()) == custom)
    }

    @Test func shippedPresetsSolveSensibly() {
        let src = PixelSize(6000, 4000)
        let byName = Dictionary(uniqueKeysWithValues: Preset.shipped.map { ($0.name, $0) })
        #expect(byName["Thumbnail"]!.request.solve(for: src).size == PixelSize(320, 320))
        #expect(byName["Social 16:9"]!.request.solve(for: src).size == PixelSize(1920, 1080))
        #expect(byName["SDXL 1024"]!.request.solve(for: src).size == PixelSize(1024, 1024))
        let web = byName["Web"]!.request.solve(for: src)
        #expect(abs(web.megapixels - 1.5) < 0.01)
        #expect(web.size.aspectRatio == 1.5)
    }

    @Test func jsonIsReadable() throws {
        let json = String(decoding: try Preset.shipped[2].jsonData(), as: UTF8.self)
        #expect(json.contains(#""aspect" : "16:9""#))
        #expect(json.contains(#""size" : {"#) && json.contains(#""width" : 1920"#))
        #expect(json.contains(#""format" : "keep""#))
        #expect(json.contains("\"padColor\" : \"#ffffff\""))
        #expect(!json.contains("_0"))
        // Hand-written variants decode too.
        let hand = """
        { "name": "Hand", "aspect": "4:3", "size": { "megapixels": 2 }, "multiple": 16,
          "fit": "pad", "padColor": "#00000080", "format": "png", "quality": 1 }
        """
        let p = try Preset.from(json: Data(hand.utf8))
        #expect(p.aspect == .fixed(width: 4, height: 3))
        #expect(p.size == .megapixels(2))
        #expect(p.padColor?.alpha ?? 0 > 0.49 && p.padColor?.alpha ?? 0 < 0.51)
        #expect(p.format == .png)
    }

    @Test func fileNamesAreSafe() {
        #expect(Preset.shipped.first { $0.name == "Social 16:9" }!.fileName == "Social 16-9.json")
        #expect(Preset(name: "a/b", size: .width(1)).fileName == "a-b.json")
    }

    @Test func summaryReadsWell() {
        #expect(Preset.shipped[0].summary == "Original · 1.5 MP · JPEG 80")
        #expect(Preset.shipped[2].summary == "16:9 · 1920 px wide · ×8 · keep format")
    }
}
