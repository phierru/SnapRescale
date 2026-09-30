import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import RescaleKit

/// Readable labels and values, field priority, the AI workflow summary,
/// embedded-vs-assumed ICC and the HDR note (issue #25).
struct MetadataReadableTests {
    typealias Payload = ImageMetadata.AIPayload
    typealias Key = ImageMetadata.AISummaryKey

    // MARK: Labels

    @Test func friendlyLabels() {
        #expect(MetadataLabels.label(.exif, "FocalLenIn35mmFilm") == "Focal length (35 mm)")
        #expect(MetadataLabels.label(.exif, "ISOSpeedRatings") == "ISO")
        #expect(MetadataLabels.label(.exif, "ExposureTime") == "Exposure time")
        #expect(MetadataLabels.label(.exif, "LensModel") == "Lens")
        #expect(MetadataLabels.label(.exif, "ColorSpace") == "Colour space")
        #expect(MetadataLabels.label(.iptc, "Caption/Abstract") == "Caption")
        #expect(MetadataLabels.label(.xmp, "dc:rights") == "Rights")
        #expect(MetadataLabels.label(.gps, "LatitudeRef") == "Latitude hemisphere")
        // No entry: CamelCase is spelled out; anything else is left alone.
        #expect(MetadataLabels.label(.exif, "SubjectDistRange") == "Subject dist range")
        #expect(MetadataLabels.label(.exif, "ISOSpeed") == "ISO speed")
        #expect(MetadataLabels.label(.exif, "Apple MakerNote") == "Apple MakerNote")
        #expect(MetadataLabels.label(.xmp, "photoshop:City") == "photoshop:City")
        #expect(MetadataLabels.label(.structure, "Bit depth") == "Bit depth")
    }

    @Test func fieldsDefaultToTheRawPair() {
        let f = MetadataField(key: "Make", value: "Acme")
        #expect(f.label == "Make" && f.readableValue == "Acme" && f.priority == .secondary && !f.isTranslated)
    }

    // MARK: Values

    @Test(arguments: [("0", "Did not fire"), ("1", "Fired"), ("16", "Off, did not fire"), ("9", "On, fired"),
                      ("24", "Auto, did not fire"), ("25", "Auto, fired"), ("32", "No flash function"),
                      ("5", "Fired, return light not detected"), ("7", "Fired, return light detected"),
                      ("65", "Fired, red-eye reduction"), ("95", "Auto, fired, return light detected, red-eye reduction"),
                      // Reserved bits and nonsense stay as they are.
                      ("3", "3"), ("33", "33"), ("128", "128"), ("-1", "-1"), ("n/a", "n/a")])
    func flashBitField(_ raw: String, _ expected: String) {
        #expect(MetadataLabels.readable(.exif, "Flash", raw) == expected)
    }

    @Test(arguments: [("MeteringMode", "5", "Pattern"), ("MeteringMode", "2", "Centre-weighted average"),
                      ("ExposureProgram", "2", "Normal programme"), ("ExposureMode", "0", "Auto"),
                      ("WhiteBalance", "1", "Manual"), ("ColorSpace", "1", "sRGB"), ("ColorSpace", "65535", "Uncalibrated"),
                      ("SceneCaptureType", "3", "Night scene"), ("SensingMethod", "2", "One-chip colour area sensor"),
                      ("SceneType", "1", "Directly photographed"), ("ResolutionUnit", "2", "Inches"),
                      ("Orientation", "6", "Rotated 90° CW"), ("CompositeImage", "2", "General composite image"),
                      ("LightSource", "21", "D65"), ("DateTimeOriginal", "2026:09:30 10:11:12", "2026-09-30 10:11:12")])
    func codedValues(_ key: String, _ raw: String, _ expected: String) {
        #expect(MetadataLabels.readable(.exif, key, raw) == expected)
    }

    @Test func unknownCodesStayNumbers() {
        #expect(MetadataLabels.readable(.exif, "MeteringMode", "42") == "42")
        #expect(MetadataLabels.readable(.exif, "ColorSpace", "2") == "2")
        #expect(MetadataLabels.readable(.exif, "SceneType", "9") == "9")
        #expect(MetadataLabels.readable(.exif, "ExposureProgram", "auto") == "auto")
        // Not a coded field: untouched.
        #expect(MetadataLabels.readable(.exif, "ISOSpeedRatings", "2") == "2")
        #expect(MetadataLabels.readable(.exif, "DateTimeOriginal", "yesterday") == "yesterday")
        #expect(MetadataLabels.readable(.gps, "LatitudeRef", "X") == "X")
        // The same key in another section is not an EXIF code.
        #expect(MetadataLabels.readable(.iptc, "Flash", "16") == "16")
    }

    @Test func gpsRefsAndAltitude() {
        #expect(MetadataLabels.readable(.gps, "LatitudeRef", "S") == "South")
        #expect(MetadataLabels.readable(.gps, "LongitudeRef", "W") == "West")
        #expect(MetadataLabels.readable(.gps, "AltitudeRef", "0") == "Above sea level")
        #expect(MetadataLabels.readable(.gps, "SpeedRef", "K") == "km/h")
        #expect(MetadataLabels.readable(.gps, "ImgDirectionRef", "T") == "True north")
        #expect(MetadataLabels.readable(.gps, "DateStamp", "2026:09:30") == "2026-09-30")

        let below = MetadataSection(kind: .gps, fields: [.init(key: "Altitude", value: "12.5"), .init(key: "AltitudeRef", value: "1")])
        #expect(MetadataLabels.decorated(below).fields[0].readableValue == "12.5 m below sea level")
        let above = MetadataSection(kind: .gps, fields: [.init(key: "Altitude", value: "372.4")])
        let altitude = MetadataLabels.decorated(above).fields[0]
        #expect(altitude.readableValue == "372.4 m" && altitude.value == "372.4" && altitude.priority == .primary)
    }

    @Test(arguments: [("N", "E", "46.1553° N, 8.7716° E"), ("N", "W", "46.1553° N, 8.7716° W"),
                      ("S", "E", "46.1553° S, 8.7716° E"), ("S", "W", "46.1553° S, 8.7716° W")])
    func gpsPositionInEveryHemisphere(_ ns: String, _ ew: String, _ expected: String) throws {
        #expect(MetadataLabels.position(latitude: 46.15531, latitudeRef: ns, longitude: 8.77164, longitudeRef: ew) == expected)

        // Through the file: one derived line after the raw fields, which stay.
        let props: [CFString: Any] = [kCGImagePropertyGPSDictionary: [
            kCGImagePropertyGPSLatitude: 46.15531, kCGImagePropertyGPSLatitudeRef: ns,
            kCGImagePropertyGPSLongitude: 8.77164, kCGImagePropertyGPSLongitudeRef: ew,
            kCGImagePropertyGPSAltitude: 210, kCGImagePropertyGPSAltitudeRef: 0,
        ]]
        let gps = try #require(MetadataTests.inspect(MetadataTests.encode(.jpeg, properties: props), .jpeg).section(.gps))
        #expect(gps["Position"] == expected)
        #expect(gps["LatitudeRef"] == ns && gps["LongitudeRef"] == ew && gps["Latitude"] != nil)
        #expect(gps.fields.last?.key == "Position")
        #expect(gps.primaryFields.map(\.key) == ["Position", "Altitude"])
        #expect(gps.primaryFields.map(\.readableValue) == [expected, "210 m"])
    }

    @Test func gpsPositionNeedsBothHemispheres() {
        #expect(MetadataLabels.position(latitude: 46.1, latitudeRef: nil, longitude: 8.7, longitudeRef: "E") == nil)
        #expect(MetadataLabels.position(latitude: 46.1, latitudeRef: "N", longitude: 8.7, longitudeRef: "?") == nil)
        #expect(MetadataLabels.position(latitude: "x", latitudeRef: "N", longitude: "8.7", longitudeRef: "E") == nil)
        #expect(MetadataLabels.position(latitude: 96, latitudeRef: "N", longitude: 8.7, longitudeRef: "E") == nil)
        let half = MetadataSection(kind: .gps, fields: [.init(key: "Latitude", value: "46.1"), .init(key: "LatitudeRef", value: "N")])
        #expect(MetadataLabels.decorated(half)["Position"] == nil)
    }

    @Test func codedValuesInAFile() throws {
        let props: [CFString: Any] = [kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifFlash: 16, kCGImagePropertyExifMeteringMode: 5, kCGImagePropertyExifExposureProgram: 2,
            kCGImagePropertyExifFocalLenIn35mmFilm: 26,
            kCGImagePropertyExifLightSource: 99,
        ]]
        let exif = try #require(MetadataTests.inspect(MetadataTests.encode(.jpeg, properties: props), .jpeg).section(.exif))
        func field(_ key: String) throws -> MetadataField { try #require(exif.fields.first { $0.key == key }) }
        // The raw pair is what the file holds; the readable pair is for people.
        #expect(try field("Flash").value == "16")
        #expect(try field("Flash").readableValue == "Off, did not fire")
        #expect(try field("Flash").isTranslated)
        #expect(try field("MeteringMode").readableValue == "Pattern")
        #expect(try field("ExposureProgram").readableValue == "Normal programme")
        #expect(try field("FocalLenIn35mmFilm").label == "Focal length (35 mm)")
        #expect(try field("FocalLenIn35mmFilm").readableValue == "26 mm")
        #expect(try field("LightSource").readableValue == "99")
        #expect(exif["Flash"] == "16")
    }

    // MARK: Priority

    @Test func cameraFixtureSplitsIntoPrimaryAndSecondary() throws {
        let m = try Fixture.load(.camera).metadata
        let exif = try #require(m.section(.exif))
        #expect(exif.primaryFields.map(\.key) == ["Make", "Model", "LensModel", "DateTimeOriginal", "ExposureTime",
                                                  "FNumber", "ISOSpeedRatings", "FocalLength"])
        #expect(exif.primaryFields.map(\.label) == ["Camera make", "Camera model", "Lens", "Date taken", "Exposure time",
                                                    "Aperture", "ISO", "Focal length"])
        let secondary = exif.secondaryFields.map(\.key)
        #expect(secondary.contains("Software") && secondary.contains("LensMake") && secondary.contains("ColorSpace"))
        #expect(secondary.contains("DateTime") && secondary.contains("PixelXDimension"))
        #expect(exif.primaryFields.count + exif.secondaryFields.count == exif.fields.count)
        // Secondary fields keep field order.
        #expect(secondary == exif.fields.map(\.key).filter(secondary.contains))

        let gps = try #require(m.section(.gps))
        #expect(gps.primaryFields.map(\.key) == ["Position", "Altitude"])
        #expect(gps["Position"] == "0.0000° N, 0.0000° E")
        #expect(gps.secondaryFields.map(\.key).contains("LatitudeRef"))

        // Short read-only sections have nothing to fold.
        #expect(try #require(m.section(.structure)).secondaryFields.isEmpty)
        #expect(try #require(m.section(.icc)).secondaryFields.isEmpty)
    }

    @Test func iptcXMPAndAIPriorities() throws {
        let m = try Fixture.load(.iptcXMP).metadata
        #expect(try #require(m.section(.iptc)).primaryFields.map(\.key)
                == ["Caption/Abstract", "Keywords", "Byline", "Credit", "CopyrightNotice", "City"])
        let xmp = try #require(m.section(.xmp))
        #expect(xmp.primaryFields.map(\.key) == ["xmp:Rating", "xmp:Label", "dc:description", "dc:creator", "dc:rights"])
        #expect(xmp.primaryFields.map(\.label) == ["Rating", "Label", "Description", "Creator", "Rights"])
        #expect(xmp.secondaryFields.map(\.key).contains("xmp:CreatorTool"))

        // The raw payloads fold away under the summary.
        let ai = try #require(try Fixture.load(.comfyUI).metadata.section(.aiWorkflow))
        #expect(ai.primaryFields.map(\.key) == ["Source"])
        #expect(ai.secondaryFields.map(\.key) == ["prompt", "workflow"])
    }

    @Test func primaryOrderIsReadingOrderNotFieldOrder() {
        let s = MetadataLabels.decorated(MetadataSection(kind: .exif, fields: [
            .init(key: "Flash", value: "16"), .init(key: "Zed", value: "1"), .init(key: "ISOSpeedRatings", value: "100"),
            .init(key: "Make", value: "Acme"),
        ]))
        #expect(s.primaryFields.map(\.key) == ["Make", "ISOSpeedRatings", "Flash"])
        #expect(s.secondaryFields.map(\.key) == ["Zed"])
        #expect(s.fields.map(\.key) == ["Flash", "Zed", "ISOSpeedRatings", "Make"])
    }

    // MARK: Copy and Export All

    @Test func copyIsReadableExportAllIsRaw() throws {
        let m = try Fixture.load(.camera).metadata
        let copy = m.copyAllText
        #expect(copy.contains("Camera make: Synthetic Camera Co"))
        #expect(copy.contains("Colour space: sRGB"))
        #expect(copy.contains("Date taken: 2020-01-01 12:00:00"))
        #expect(copy.contains("Position: 0.0000° N, 0.0000° E"))
        #expect(!copy.contains("ColorSpace"))

        let json = try #require(try JSONSerialization.jsonObject(with: m.exportAllJSON) as? [String: [String: String]])
        #expect(json["EXIF"]?["ColorSpace"] == "1")
        #expect(json["EXIF"]?["Make"] == "Synthetic Camera Co")
        #expect(json["EXIF"]?["DateTimeOriginal"] == "2020:01:01 12:00:00")
        #expect(json["EXIF"]?["Colour space"] == nil && json["EXIF"]?["Camera make"] == nil)
        #expect(json["GPS"]?["LatitudeRef"] == "N")
        #expect(json["GPS"]?["Altitude"] == "0")
        // Derived fields are extra keys beside the raw ones.
        #expect(json["GPS"]?["Position"] == "0.0000° N, 0.0000° E")
        #expect(json["ICC profile"]?["Embedded"] == "No (macOS default)")
    }

    // MARK: AI workflow summary

    static func metadata(_ payloads: Payload...) -> ImageMetadata {
        var m = ImageMetadata()
        m.aiPayloads = payloads
        return m
    }

    static func comfy(_ graph: String) -> ImageMetadata {
        metadata(Payload(source: .comfyUI, name: "prompt", location: "PNG tEXt chunk", text: graph))
    }

    static func a1111(_ text: String) -> ImageMetadata {
        metadata(Payload(source: .a1111, name: "parameters", location: "PNG tEXt chunk", text: text))
    }

    static func pairs(_ m: ImageMetadata) -> [String] { m.aiSummary.map { "\($0.key)=\($0.value)" } }

    @Test(arguments: [Fixture.comfyUI, .compressedText])
    func comfyUIFixtureSummary(_ fixture: Fixture) throws {
        let m = try Fixture.load(fixture).metadata
        #expect(Self.pairs(m) == [
            "Prompt=a lighthouse on a cliff, synthetic test fixture", "Negative prompt=blurry, watermark",
            "Model=placeholder-model.safetensors", "Seed=42", "Steps=20", "CFG=7", "Sampler=euler", "Scheduler=normal",
            "Size=64 × 48",
        ])
        #expect(m.aiSummary.allSatisfy { $0.priority == .primary })
        #expect(m.aiSummaryValue(.seed) == "42" && m.aiSummaryValue(.loras) == nil)
        #expect(m.aiSummaryText.hasPrefix("Prompt: a lighthouse on a cliff") && m.aiSummaryText.hasSuffix("Size: 64 × 48"))
    }

    @Test(arguments: [Fixture.a1111PNG, .a1111JPEG])
    func a1111FixtureSummary(_ fixture: Fixture) throws {
        #expect(Self.pairs(try Fixture.load(fixture).metadata) == [
            "Prompt=a lighthouse on a cliff, synthetic test fixture", "Negative prompt=blurry, watermark",
            "Model=placeholder-model", "Seed=42", "Steps=20", "CFG=7", "Sampler=Euler a", "Size=64 × 48",
        ])
    }

    @Test func sourcesWithoutAIHaveNoSummary() throws {
        #expect(try Fixture.load(.camera).metadata.aiSummary.isEmpty)
        #expect(ImageMetadata().aiSummary.isEmpty && ImageMetadata().aiSummaryText.isEmpty)
        // The UI graph alone says nothing we read.
        #expect(Self.metadata(Payload(source: .comfyUI, name: "workflow", location: "", text: #"{"nodes":[]}"#)).aiSummary.isEmpty)
        #expect(Self.comfy("not json").aiSummary.isEmpty && Self.comfy("[1]").aiSummary.isEmpty)
    }

    @Test func a1111Details() {
        let m = Self.a1111("""
        a cat <lora:fluffy:0.8>, 8k <lora:style_v2:1>
        Negative prompt: dog,
        blurry
        Steps: 30, Sampler: DPM++ 2M, Schedule type: Karras, CFG scale: 6.5, Seed: 18446744073709551615, Size: 832x1216, Model hash: abc, Model: sdxl_base, Lora hashes: "fluffy: 11, style_v2: 22", Version: v1.9
        """)
        #expect(Self.pairs(m) == [
            "Prompt=a cat <lora:fluffy:0.8>, 8k <lora:style_v2:1>", "Negative prompt=dog,\nblurry", "Model=sdxl_base",
            "LoRAs=fluffy, style_v2", "Seed=18446744073709551615", "Steps=30", "CFG=6.5", "Sampler=DPM++ 2M",
            "Scheduler=Karras", "Size=832 × 1216",
        ])
        // Quoted values keep their commas and colons.
        #expect(WorkflowReader.settings(#"Steps: 2, Lora hashes: "a: 1, b: 2", Seed: 3"#)
                == ["Steps": "2", "Lora hashes": "a: 1, b: 2", "Seed": "3"])
    }

    @Test func a1111MissingNegativeAndOddLines() {
        #expect(Self.pairs(Self.a1111("a cat\nSteps: 20, Sampler: Euler a, CFG scale: 7"))
                == ["Prompt=a cat", "Steps=20", "CFG=7", "Sampler=Euler a"])
        // An empty negative prompt is no negative prompt.
        #expect(Self.a1111("a cat\nNegative prompt: \nSteps: 20, Sampler: Euler a").aiSummaryValue(.negativePrompt) == nil)
        // A key stated twice with two values is not reported.
        let twice = Self.a1111("a cat\nSteps: 20, Sampler: Euler a, Seed: 1, Seed: 2")
        #expect(twice.aiSummaryValue(.seed) == nil && twice.aiSummaryValue(.steps) == "20")
        #expect(Self.a1111("Steps: 20, Sampler: Euler a, Size: big").aiSummaryValue(.size) == "big")
        #expect(WorkflowReader.a1111("no settings line").isEmpty)
    }

    static func encoder(_ text: String) -> String {
        #"{"class_type":"CLIPTextEncode","inputs":{"text":"\#(text)","clip":["4",1]}}"#
    }

    static func sampler(seed: Int = 1, steps: Int = 20, cfg: String = "7.5", name: String = "euler", model: String = "4",
                        negative: String? = "7", latent: String = "5") -> String {
        let neg = negative.map { #","negative":["\#($0)",0]"# } ?? ""
        return #"{"class_type":"KSampler","inputs":{"seed":\#(seed),"steps":\#(steps),"cfg":\#(cfg),"sampler_name":"\#(name)","scheduler":"karras","model":["\#(model)",0],"positive":["6",0]\#(neg),"latent_image":["\#(latent)",0]}}"#
    }

    static let loader = #"{"class_type":"CheckpointLoaderSimple","inputs":{"ckpt_name":"base.safetensors"}}"#
    static let latent = #"{"class_type":"EmptyLatentImage","inputs":{"width":1024,"height":768,"batch_size":1}}"#

    @Test func comfyUITwoSamplersThatDisagree() {
        // Same model, prompt, steps and scheduler; different seed, CFG, sampler; the second works on an upscaled latent.
        let graph = #"""
        {"3":\#(Self.sampler(seed: 1, cfg: "7.5", name: "euler")),
         "30":\#(Self.sampler(seed: 2, cfg: "4", name: "dpmpp_2m", latent: "31")),
         "31":{"class_type":"LatentUpscale","inputs":{"samples":["3",0],"width":2048,"height":1536}},
         "4":\#(Self.loader),"5":\#(Self.latent),"6":\#(Self.encoder("a cat")),"7":\#(Self.encoder("bad"))}
        """#
        #expect(Self.pairs(Self.comfy(graph)) == ["Prompt=a cat", "Negative prompt=bad", "Model=base.safetensors",
                                                  "Steps=20", "Scheduler=karras"])
    }

    @Test func comfyUITwoSamplersThatAgree() {
        let graph = #"""
        {"3":\#(Self.sampler()),"30":\#(Self.sampler()),
         "4":\#(Self.loader),"5":\#(Self.latent),"6":\#(Self.encoder("a cat")),"7":\#(Self.encoder("bad"))}
        """#
        #expect(Self.pairs(Self.comfy(graph)) == ["Prompt=a cat", "Negative prompt=bad", "Model=base.safetensors", "Seed=1",
                                                  "Steps=20", "CFG=7.5", "Sampler=euler", "Scheduler=karras", "Size=1024 × 768"])
    }

    @Test func comfyUIMissingNegative() {
        // No negative input at all.
        let none = #"{"3":\#(Self.sampler(negative: nil)),"4":\#(Self.loader),"5":\#(Self.latent),"6":\#(Self.encoder("a cat"))}"#
        #expect(Self.comfy(none).aiSummaryValue(.negativePrompt) == nil)
        #expect(Self.comfy(none).aiSummaryValue(.seed) == "1")
        // Linked to a node that is not there, to an empty text, to blanked conditioning.
        let dangling = #"{"3":\#(Self.sampler(negative: "99")),"4":\#(Self.loader),"5":\#(Self.latent),"6":\#(Self.encoder("a cat"))}"#
        #expect(Self.comfy(dangling).aiSummaryValue(.negativePrompt) == nil)
        let empty = #"{"3":\#(Self.sampler()),"4":\#(Self.loader),"5":\#(Self.latent),"6":\#(Self.encoder("a cat")),"7":\#(Self.encoder(""))}"#
        #expect(Self.comfy(empty).aiSummaryValue(.negativePrompt) == nil)
        let zeroed = #"{"3":\#(Self.sampler()),"4":\#(Self.loader),"5":\#(Self.latent),"6":\#(Self.encoder("a cat")),"7":{"class_type":"ConditioningZeroOut","inputs":{"conditioning":["6",0]}}}"#
        #expect(Self.comfy(zeroed).aiSummaryValue(.negativePrompt) == nil)
        #expect(Self.comfy(zeroed).aiSummaryValue(.prompt) == "a cat")
    }

    @Test func comfyUINegativeFollowsItsOwnSideOfPassThroughNodes() {
        let graph = #"""
        {"3":\#(Self.sampler(negative: "10")),"4":\#(Self.loader),"5":\#(Self.latent),
         "10":{"class_type":"ControlNetApplyAdvanced","inputs":{"strength":1.0,"positive":["6",0],"negative":["7",0],"control_net":["12",0],"image":["13",0]}},
         "6":\#(Self.encoder("a cat")),"7":\#(Self.encoder("bad"))}
        """#
        #expect(Self.comfy(graph).aiSummaryValue(.negativePrompt) == "bad")
    }

    @Test func comfyUIModelChainAndUnresolvedParts() {
        // Sampler ← ModelSampling ← LoRA ← LoRA ← UNET loader; size wired to a node we do not know.
        let graph = #"""
        {"3":\#(Self.sampler(model: "20")),
         "20":{"class_type":"ModelSamplingAuraFlow","inputs":{"shift":3,"model":["21",0]}},
         "21":{"class_type":"LoraLoaderModelOnly","inputs":{"lora_name":"second.safetensors","strength_model":1,"model":["22",0]}},
         "22":{"class_type":"LoraLoader","inputs":{"lora_name":"first.safetensors","model":["23",0],"clip":["24",0]}},
         "23":{"class_type":"UNETLoader","inputs":{"unet_name":"unet.safetensors","weight_dtype":"default"}},
         "5":{"class_type":"EmptySD3LatentImage","inputs":{"width":["79",0],"height":["79",1],"batch_size":1}},
         "79":{"class_type":"ResolutionSelector","inputs":{"megapixels":1}},
         "6":\#(Self.encoder("a cat")),"7":\#(Self.encoder("bad"))}
        """#
        let m = Self.comfy(graph)
        #expect(m.aiSummaryValue(.model) == "unet.safetensors")
        #expect(m.aiSummaryValue(.loras) == "first.safetensors, second.safetensors")
        #expect(m.aiSummaryValue(.size) == nil)

        // A model chain that ends nowhere gives no model and no LoRAs.
        let lost = #"""
        {"3":\#(Self.sampler(model: "21")),"5":\#(Self.latent),"6":\#(Self.encoder("a cat")),
         "21":{"class_type":"LoraLoaderModelOnly","inputs":{"lora_name":"x.safetensors","model":["99",0]}}}
        """#
        #expect(Self.comfy(lost).aiSummaryValue(.model) == nil && Self.comfy(lost).aiSummaryValue(.loras) == nil)
        #expect(Self.comfy(lost).aiSummaryValue(.size) == "1024 × 768")
    }

    @Test func comfyUICustomSamplerWithGuider() {
        let graph = #"""
        {"1":{"class_type":"SamplerCustomAdvanced","inputs":{"noise":["9",0],"guider":["2",0],"sampler":["8",0],"sigmas":["10",0],"latent_image":["5",0]}},
         "2":{"class_type":"CFGGuider","inputs":{"cfg":3.5,"model":["4",0],"positive":["6",0],"negative":["7",0]}},
         "8":{"class_type":"KSamplerSelect","inputs":{"sampler_name":"dpmpp_2m"}},
         "9":{"class_type":"RandomNoise","inputs":{"noise_seed":18446744073709551615}},
         "10":{"class_type":"BasicScheduler","inputs":{"scheduler":"simple","steps":28,"denoise":1.0,"model":["4",0]}},
         "4":\#(Self.loader),"5":\#(Self.latent),"6":\#(Self.encoder("a cat")),"7":\#(Self.encoder("bad"))}
        """#
        #expect(Self.pairs(Self.comfy(graph)) == [
            "Prompt=a cat", "Negative prompt=bad", "Model=base.safetensors", "Seed=18446744073709551615", "Steps=28",
            "CFG=3.5", "Sampler=dpmpp_2m", "Scheduler=simple", "Size=1024 × 768",
        ])
    }

    @Test func payloadsThatDisagreeDropTheField() {
        let graph = #"{"3":\#(Self.sampler(seed: 42)),"4":\#(Self.loader),"5":\#(Self.latent),"6":\#(Self.encoder("a cat")),"7":\#(Self.encoder("bad"))}"#
        let m = Self.metadata(Payload(source: .comfyUI, name: "prompt", location: "", text: graph),
                              Payload(source: .a1111, name: "parameters", location: "",
                                      text: "a cat\nNegative prompt: bad\nSteps: 20, Sampler: Euler, CFG scale: 7.5, Seed: 42, Size: 1024x768"))
        #expect(Self.pairs(m) == ["Prompt=a cat", "Negative prompt=bad", "Model=base.safetensors", "Seed=42", "Steps=20",
                                  "CFG=7.5", "Scheduler=karras", "Size=1024 × 768"])
    }

    // MARK: ICC: embedded or assumed

    @Test(arguments: [Fixture.displayP3, .cmyk, .sixteenBit])
    func fixturesWithAProfileEmbedIt(_ fixture: Fixture) throws {
        let m = try Fixture.load(fixture).metadata
        #expect(m.iccOrigin == .embedded && m.iccIsEmbedded && m.iccNote == nil)
        #expect(m.badges.first?.label == "ICC")
        #expect(m.badges.first?.detail == "Colour profile: \(try #require(m.iccProfileName))")
        let icc = try #require(m.section(.icc))
        #expect(icc.note == nil && icc.fields.first?.key == "Embedded" && icc["Embedded"] == "Yes")
    }

    @Test(arguments: [Fixture.comfyUI, .a1111PNG, .compressedText])
    func taggedPNGsHaveNoBadgeAndAFlaggedSection(_ fixture: Fixture) throws {
        let m = try Fixture.load(fixture).metadata
        #expect(m.iccOrigin == .tagged("PNG sRGB chunk") && !m.iccIsEmbedded)
        #expect(!m.badges.contains { $0.label == "ICC" })
        // The section stays, flagged, with the profile macOS supplies.
        let icc = try #require(m.section(.icc))
        #expect(icc.note == "No embedded profile (PNG sRGB chunk); macOS default (sRGB assumed)")
        #expect(icc.note == m.iccNote)
        #expect(icc["Embedded"] == "No (PNG sRGB chunk)")
        #expect(icc["Name"] == "sRGB IEC61966-2.1")
    }

    @Test(arguments: [Fixture.camera, .iptcXMP, .rotated, .a1111JPEG])
    func jpegsWithoutAProfileAreAssumed(_ fixture: Fixture) throws {
        let m = try Fixture.load(fixture).metadata
        #expect(m.iccOrigin == .assumed && !m.iccIsEmbedded)
        #expect(!m.badges.contains { $0.label == "ICC" })
        let icc = try #require(m.section(.icc))
        #expect(icc.note == "macOS default (sRGB assumed)")
        #expect(icc["Embedded"] == "No (macOS default)")
    }

    static func be32(_ n: Int) -> [UInt8] { [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)] }

    /// A bare PNG: signature, IHDR, the named (empty) chunks, IEND.
    static func png(chunks: [String]) -> Data {
        var out = PNGScanner.signature + be32(13) + Array("IHDR".utf8) + [UInt8](repeating: 0, count: 13 + 4)
        for c in chunks { out += be32(1) + Array(c.utf8) + [0] + be32(0) }
        return Data(out + be32(0) + Array("IEND".utf8) + be32(0))
    }

    static func box(_ type: String, _ body: [UInt8]) -> [UInt8] { be32(body.count + 8) + Array(type.utf8) + body }

    static func heif(colr kinds: [String]) -> Data {
        let ipco = box("ipco", kinds.flatMap { box("colr", Array($0.utf8) + [0, 1, 0, 13, 0, 6, 0x80]) } + box("ispe", [0, 0, 0, 0, 0, 0, 0, 8, 0, 0, 0, 8]))
        return Data(box("ftyp", Array("heic".utf8) + [0, 0, 0, 0]) + box("meta", [0, 0, 0, 0] + box("hdlr", [0, 0, 0, 0]) + box("iprp", ipco)))
    }

    @Test func pngColourChunks() {
        #expect(ICCScanner.origin(in: Self.png(chunks: ["iCCP"]), type: .png) == .embedded)
        #expect(ICCScanner.origin(in: Self.png(chunks: ["sRGB", "iCCP"]), type: .png) == .embedded)
        #expect(ICCScanner.origin(in: Self.png(chunks: ["sRGB", "gAMA"]), type: .png) == .tagged("PNG sRGB chunk"))
        #expect(ICCScanner.origin(in: Self.png(chunks: ["cICP"]), type: .png) == .tagged("PNG cICP chunk"))
        #expect(ICCScanner.origin(in: Self.png(chunks: ["gAMA", "cHRM"]), type: .png) == .tagged("PNG gAMA and cHRM chunks"))
        // Gamma alone does not name a colour space.
        #expect(ICCScanner.origin(in: Self.png(chunks: ["gAMA"]), type: .png) == .assumed)
        #expect(ICCScanner.origin(in: Self.png(chunks: []), type: .png) == .assumed)
        #expect(ICCScanner.origin(in: Data([1, 2, 3]), type: .png) == nil)
    }

    @Test func otherContainers() {
        #expect(ICCScanner.origin(in: Fixture.cmyk.data, type: .jpeg) == .embedded)
        #expect(ICCScanner.origin(in: Fixture.camera.data, type: .jpeg) == .assumed)
        #expect(ICCScanner.origin(in: Fixture.sixteenBit.data, type: .tiff) == .embedded)
        #expect(ICCScanner.origin(in: Fixture.displayP3.data, type: .heic) == .embedded)

        #expect(ICCScanner.origin(in: Self.heif(colr: ["nclx"]), type: .heic) == .tagged("nclx colour box"))
        #expect(ICCScanner.origin(in: Self.heif(colr: ["nclx", "prof"]), type: .heic) == .embedded)
        #expect(ICCScanner.origin(in: Self.heif(colr: ["rICC"]), type: .heif) == .embedded)
        #expect(ICCScanner.origin(in: Self.heif(colr: []), type: .heic) == .assumed)

        let riff = Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WEBP".utf8) + Array("VP8X".utf8) + [2, 0, 0, 0, 0x20, 0]
        #expect(ICCScanner.origin(in: Data(riff + Array("ICCP".utf8) + [2, 0, 0, 0, 1, 2]), type: .webP) == .embedded)
        #expect(ICCScanner.origin(in: Data(riff), type: .webP) == .assumed)

        // Not walked: left to ImageIO.
        #expect(ICCScanner.origin(in: MetadataTests.encode(.gif), type: .gif) == nil)
        #expect(ICCScanner.origin(in: Data([0xFF, 0xD8, 0xFF]), type: .tiff) == nil)
    }

    @Test func tiffWithoutAProfileIsAssumed() throws {
        // A TIFF written without its profile tag.
        var tiff = [UInt8](Fixture.sixteenBit.data)
        let little = tiff[0] == 0x49
        func u16(_ i: Int) -> Int { little ? Int(tiff[i]) | Int(tiff[i + 1]) << 8 : Int(tiff[i]) << 8 | Int(tiff[i + 1]) }
        func u32(_ i: Int) -> Int { little ? u16(i) | u16(i + 2) << 16 : u16(i) << 16 | u16(i + 2) }
        let ifd = u32(4)
        let entry = try #require((0..<u16(ifd)).map { ifd + 2 + $0 * 12 }.first { u16($0) == 34675 })
        // Retag the entry as something unknown.
        tiff[entry] = 0xFF; tiff[entry + 1] = 0xFF
        #expect(ICCScanner.origin(in: Data(tiff), type: .tiff) == .assumed)
    }

    @Test func badgeFollowsTheOrigin() {
        var m = ImageMetadata()
        m.iccProfileName = "sRGB IEC61966-2.1"
        #expect(m.iccOrigin == .assumed && m.badges.isEmpty && m.iccNote == "macOS default (sRGB assumed)")
        m.iccOrigin = .tagged("PNG sRGB chunk")
        #expect(m.badges.isEmpty)
        m.iccOrigin = .embedded
        #expect(m.badges.map(\.label) == ["ICC"] && m.iccNote == nil)
        // An assumed profile that is not sRGB is named.
        m.iccOrigin = .assumed
        m.iccProfileName = "Generic CMYK Profile"
        #expect(m.iccNote == "macOS default (Generic CMYK Profile assumed)")
    }

    // MARK: HDR

    @Test func hdrGainMapIsFlaggedAsNotSaved() throws {
        var m = ImageMetadata()
        #expect(m.hdrNote == nil && m.structureSection.note == nil)
        #expect(m.structureSection.fields.first { $0.key == "HDR gain map" }?.readableValue == "No")

        m.hasHDR = true
        #expect(m.hdrNote == ImageMetadata.hdrGainMapNote)
        let structure = MetadataLabels.decorated(m.structureSection)
        #expect(structure.note == "The HDR gain map is not carried into the saved file.")
        let field = try #require(structure.fields.first { $0.key == "HDR gain map" })
        #expect(field.value == "Yes" && field.readableValue == "Yes, not carried into the saved file")
        #expect(structure.text.contains("HDR gain map: Yes, not carried into the saved file"))

        // No fixture has a gain map.
        for fixture in Fixture.allCases {
            #expect(try Fixture.load(fixture).metadata.section(.structure)?.note == nil)
        }
    }
}
