import Foundation
import Testing
import UniformTypeIdentifiers
@testable import RescaleKit

/// Copy, Export All, AI workflow export and Copy Prompt (PRD §10.5, issue #12).
struct MetadataExportTests {
    typealias Payload = ImageMetadata.AIPayload

    static let lighthouse = "a lighthouse on a cliff, synthetic test fixture"

    static func payload(_ source: ImageMetadata.Provenance, _ name: String, _ text: String) -> Payload {
        Payload(source: source, name: name, location: "PNG tEXt chunk", text: text)
    }

    static func metadata(_ payloads: Payload...) -> ImageMetadata {
        var m = ImageMetadata()
        m.aiPayloads = payloads
        return m
    }

    static func string(_ export: MetadataExport?) -> String? {
        export.map { String(decoding: $0.data, as: UTF8.self) }
    }

    // MARK: Copy

    @Test func sectionTextIsKeyValueLines() {
        let s = MetadataSection(kind: .exif, fields: [.init(key: "Make", value: "Acme"), .init(key: "Model", value: "X1")])
        #expect(s.text == "Make: Acme\nModel: X1")
    }

    @Test func copyAllTitlesEverySectionInOrder() {
        var m = ImageMetadata()
        m.sections = [
            MetadataSection(kind: .exif, fields: [.init(key: "Make", value: "Acme")]),
            MetadataSection(kind: .structure, fields: [.init(key: "Alpha", value: "No"), .init(key: "Frames", value: "1")]),
        ]
        #expect(m.copyAllText == "EXIF\nMake: Acme\n\nStructure\nAlpha: No\nFrames: 1")
    }

    @Test func copyAllOnFixtureCoversEverySection() throws {
        let m = try Fixture.load(.camera).metadata
        let text = m.copyAllText
        var cursor = text.startIndex
        for section in m.sections {
            let found = try #require(text.range(of: "\(section.title)\n\(section.text)", range: cursor..<text.endIndex))
            cursor = found.upperBound
        }
    }

    // MARK: Export All

    @Test func exportAllKeepsSectionAndFieldOrder() throws {
        var m = ImageMetadata()
        m.sections = [
            MetadataSection(kind: .exif, fields: [.init(key: "Zeta", value: "1"), .init(key: "Alpha", value: "say \"hi\"\n/ok")]),
            MetadataSection(kind: .aiWorkflow, fields: [.init(key: "prompt", value: #"{"a":1}"#)]),
            MetadataSection(kind: .structure, fields: [.init(key: "Città", value: "è")]),
        ]
        let expected = """
        {
          "EXIF": {
            "Zeta": "1",
            "Alpha": "say \\"hi\\"\\n/ok"
          },
          "AI workflow": {
            "prompt": "{\\"a\\":1}"
          },
          "Structure": {
            "Città": "è"
          }
        }

        """
        #expect(String(decoding: m.exportAllJSON, as: UTF8.self) == expected)
        #expect(m.exportAllJSON == m.exportAllJSON)
        let parsed = try #require(try JSONSerialization.jsonObject(with: m.exportAllJSON) as? [String: [String: String]])
        #expect(parsed["EXIF"]?["Alpha"] == "say \"hi\"\n/ok")
        #expect(parsed["Structure"]?["Città"] == "è")
    }

    @Test(arguments: Fixture.allCases) func exportAllRoundTripsEveryFixture(_ fixture: Fixture) throws {
        let source = try Fixture.load(fixture)
        let export = source.exportAll
        #expect(export.type == .json)
        #expect(export.filename == (fixture.rawValue as NSString).deletingPathExtension + ".metadata.json")
        let parsed = try #require(try JSONSerialization.jsonObject(with: export.data) as? [String: [String: String]])
        #expect(parsed.count == source.metadata.sections.count)
        for section in source.metadata.sections {
            #expect(parsed[section.title] == Dictionary(uniqueKeysWithValues: section.fields.map { ($0.key, $0.value) }))
        }
        // Inspector order survives in the bytes.
        let text = String(decoding: export.data, as: UTF8.self)
        let offsets = try source.metadata.sections.map { try #require(text.range(of: "\n  \"\($0.title)\": {")).lowerBound }
        #expect(offsets == offsets.sorted())
    }

    @Test func exportAllWithNoSectionsIsAnEmptyObject() throws {
        let parsed = try JSONSerialization.jsonObject(with: ImageMetadata().exportAllJSON) as? [String: Any]
        #expect(parsed?.isEmpty == true)
    }

    // MARK: AI workflow export

    @Test(arguments: [Fixture.comfyUI, .compressedText])
    func comfyUIExportsWorkflowFirstByteForByte(_ fixture: Fixture) throws {
        let source = try Fixture.load(fixture)
        let base = (fixture.rawValue as NSString).deletingPathExtension
        let chunks = Dictionary(uniqueKeysWithValues: source.metadata.pngTextChunks.map { ($0.keyword, $0.text ?? "") })

        let primary = try #require(source.primaryAIExport)
        #expect(primary.filename == "\(base).workflow.json")
        #expect(primary.type == .json)
        #expect(primary.fileExtension == "json")
        #expect(primary.data == Data(try #require(chunks["workflow"]).utf8))
        #expect(primary.data.starts(with: Data(#"{"last_node_id":9,"last_link_id":9,"nodes":[{"id":4,"#.utf8)))

        let all = source.aiExports
        #expect(all.map(\.filename) == ["\(base).prompt.json", "\(base).workflow.json"])
        #expect(all[0].data == Data(try #require(chunks["prompt"]).utf8))
        #expect(all[0].data.starts(with: Data(#"{"3":{"class_type":"KSampler","inputs":{"seed":42,"#.utf8)))
    }

    @Test func uncompressedComfyUIExportIsASliceOfTheFile() throws {
        let export = try #require(try Fixture.load(.comfyUI).primaryAIExport)
        #expect(Fixture.comfyUI.data.range(of: export.data) != nil)
    }

    @Test func comfyUIFallsBackToTheAPIGraph() {
        let m = Self.metadata(Self.payload(.comfyUI, "prompt", #"{"3":{"class_type":"KSampler","inputs":{}}}"#))
        let primary = m.primaryAIExport(baseName: "picture")
        #expect(primary?.filename == "picture.prompt.json")
        #expect(Self.string(primary) == #"{"3":{"class_type":"KSampler","inputs":{}}}"#)
    }

    @Test func a1111PNGExportsParametersAsText() throws {
        let source = try Fixture.load(.a1111PNG)
        let export = try #require(source.primaryAIExport)
        #expect(export.filename == "a1111.parameters.txt")
        #expect(export.type == .plainText)
        #expect(export.fileExtension == "txt")
        #expect(export.data == Data(try #require(source.metadata.pngTextChunks.first?.text).utf8))
        #expect(source.aiExports == [export])
    }

    @Test func a1111JPEGExportsUserCommentAsParameters() throws {
        let export = try #require(try Fixture.load(.a1111JPEG).primaryAIExport)
        #expect(export.filename == "a1111-usercomment.parameters.txt")
        #expect(Self.string(export) == Self.string(try Fixture.load(.a1111PNG).primaryAIExport))
    }

    @Test func invokeAIPrefersTheGraph() {
        let m = Self.metadata(Self.payload(.invokeAI, "invokeai_metadata", #"{"positive_prompt":"a fox"}"#),
                              Self.payload(.invokeAI, "invokeai_graph", #"{"nodes":{},"edges":[]}"#))
        #expect(m.primaryAIExport(baseName: "fox")?.filename == "fox.invokeai_graph.json")
        #expect(Self.string(m.primaryAIExport(baseName: "fox")) == #"{"nodes":{},"edges":[]}"#)
        #expect(m.aiExports(baseName: "fox").map(\.filename) == ["fox.invokeai_metadata.json", "fox.invokeai_graph.json"])
    }

    @Test func parametersAreTextUnlessJSON() {
        let swarm = Self.metadata(Self.payload(.swarmUI, "parameters", #"{"sui_image_params":{"prompt":"a cat"}}"#))
        #expect(swarm.primaryAIExport(baseName: "p")?.filename == "p.parameters.json")
        #expect(swarm.primaryAIExport(baseName: "p")?.type == .json)

        let fooocus = Self.metadata(Self.payload(.fooocus, "parameters", "a cat\nSteps: 30, Sampler: dpmpp, CFG scale: 4"),
                                    Self.payload(.fooocus, "fooocus_scheme", "a1111"))
        #expect(fooocus.aiExports(baseName: "p").map(\.filename) == ["p.parameters.txt"])

        let novel = Self.metadata(Self.payload(.novelAI, "Title", "AI generated image"),
                                  Self.payload(.novelAI, "Description", "a cat"),
                                  Self.payload(.novelAI, "Software", "NovelAI"),
                                  Self.payload(.novelAI, "Comment", #"{"prompt":"a cat","steps":28}"#))
        #expect(novel.aiExports(baseName: "p").map(\.filename) == ["p.description.txt", "p.comment.json"])
        #expect(novel.primaryAIExport(baseName: "p")?.filename == "p.comment.json")

        let mj = Self.metadata(Payload(source: .midjourney, name: "ImageDescription", location: "TIFF ImageDescription",
                                       text: "a cat --ar 16:9 Job ID: 1234"))
        #expect(mj.primaryAIExport(baseName: "p")?.filename == "p.description.txt")
        #expect(Self.string(mj.primaryAIExport(baseName: "p")) == "a cat --ar 16:9 Job ID: 1234")
    }

    @Test func collidingNamesGainTheSource() {
        let m = Self.metadata(Self.payload(.comfyUI, "prompt", "{}"),
                              Self.payload(.a1111, "parameters", "x\nSteps: 1, Sampler: e"),
                              Self.payload(.swarmUI, "parameters", "y"))
        #expect(m.aiExports(baseName: "p").map(\.filename)
                == ["p.prompt.json", "p.a1111.parameters.txt", "p.swarmui.parameters.txt"])
    }

    @Test func nothingToExportWithoutPayloads() throws {
        #expect(try Fixture.load(.camera).aiExports.isEmpty)
        #expect(try Fixture.load(.camera).primaryAIExport == nil)
        #expect(Self.payload(.c2pa, "manifest", "x").export(baseName: "p") == nil)
    }

    // MARK: Copy Prompt

    @Test(arguments: [Fixture.comfyUI, .compressedText, .a1111PNG, .a1111JPEG])
    func fixturePromptIsExtracted(_ fixture: Fixture) throws {
        #expect(try Fixture.load(fixture).metadata.positivePrompt == Self.lighthouse)
    }

    @Test func fixturesWithoutAIHaveNoPrompt() throws {
        #expect(try Fixture.load(.camera).metadata.positivePrompt == nil)
    }

    @Test func a1111Prompt() {
        #expect(PromptReader.a1111("a cat, 8k\nsecond line\nNegative prompt: dog\nSteps: 20, Sampler: Euler a") == "a cat, 8k\nsecond line")
        #expect(PromptReader.a1111("a cat\nSteps: 20, Sampler: Euler a, CFG scale: 7") == "a cat")
        #expect(PromptReader.a1111("just some text") == nil)
        // Nothing before the settings line: no prompt, not a guess.
        #expect(Self.payload(.a1111, "parameters", "Steps: 20, Sampler: Euler a").positivePrompt == nil)
        #expect(Self.payload(.a1111, "parameters", "  a cat \nNegative prompt: dog\nSteps: 2, Sampler: e").positivePrompt == "a cat")
    }

    @Test func midjourneyPrompt() {
        #expect(Self.payload(.midjourney, "Description", "a cat in a hat --ar 16:9 --v 6 Job ID: abcd-1234").positivePrompt == "a cat in a hat")
        #expect(Self.payload(.midjourney, "Description", "a well-lit cat Job ID: abcd").positivePrompt == "a well-lit cat")
        #expect(Self.payload(.midjourney, "Description", "--ar 16:9 Job ID: abcd").positivePrompt == nil)
        #expect(Self.payload(.midjourney, "Description", "Job ID: abcd").positivePrompt == nil)
    }

    @Test func otherSourcesBestEffort() {
        #expect(Self.payload(.swarmUI, "parameters", #"{"sui_image_params":{"prompt":"a cat","steps":20}}"#).positivePrompt == "a cat")
        #expect(Self.payload(.invokeAI, "invokeai_metadata", #"{"positive_prompt":"a fox","negative_prompt":"dog"}"#).positivePrompt == "a fox")
        #expect(Self.payload(.invokeAI, "invokeai_graph", #"{"nodes":{}}"#).positivePrompt == nil)
        #expect(Self.payload(.fooocus, "parameters", #"{"prompt":"an owl","negative_prompt":""}"#).positivePrompt == "an owl")
        #expect(Self.payload(.fooocus, "parameters", "an owl\nNegative prompt: x\nSteps: 30, Sampler: s").positivePrompt == "an owl")
        #expect(Self.payload(.fooocus, "fooocus_scheme", "fooocus").positivePrompt == nil)
        #expect(Self.payload(.novelAI, "Comment", #"{"prompt":"a cat","uc":"bad"}"#).positivePrompt == "a cat")
        #expect(Self.payload(.novelAI, "Description", "a cat").positivePrompt == "a cat")
        #expect(Self.payload(.novelAI, "Software", "NovelAI").positivePrompt == nil)
        #expect(Self.payload(.comfyUI, "workflow", #"{"nodes":[],"links":[]}"#).positivePrompt == nil)
    }

    @Test func payloadsThatDisagreeGiveNoPrompt() {
        let agree = Self.metadata(Self.payload(.novelAI, "Description", "a cat"),
                                  Self.payload(.novelAI, "Comment", #"{"prompt":"a cat"}"#))
        #expect(agree.positivePrompt == "a cat")
        let differ = Self.metadata(Self.payload(.novelAI, "Description", "a cat"),
                                   Self.payload(.novelAI, "Comment", #"{"prompt":"a dog"}"#))
        #expect(differ.positivePrompt == nil)
    }

    // MARK: ComfyUI graphs

    static func encoder(_ text: String) -> String {
        #"{"class_type":"CLIPTextEncode","inputs":{"text":"\#(text)","clip":["4",1]}}"#
    }

    static func sampler(_ type: String = "KSampler", positive: String, negative: String = "7") -> String {
        #"{"class_type":"\#(type)","inputs":{"seed":1,"model":["4",0],"positive":["\#(positive)",0],"negative":["\#(negative)",0]}}"#
    }

    @Test(arguments: ["KSampler", "KSamplerAdvanced", "SamplerCustom", "SomeCustomSampler"])
    func comfyUISamplerKinds(_ type: String) {
        let graph = #"{"3":\#(Self.sampler(type, positive: "6")),"6":\#(Self.encoder("a cat")),"7":\#(Self.encoder("bad"))}"#
        #expect(PromptReader.comfyUI(graph) == "a cat")
    }

    @Test func comfyUIFollowsPassThroughNodes() {
        // Sampler ← ControlNetApplyAdvanced (positive) ← ConditioningSetArea (conditioning) ← Reroute ← encoder.
        let graph = #"""
        {"3":\#(Self.sampler(positive: "10", negative: "10")),
         "10":{"class_type":"ControlNetApplyAdvanced","inputs":{"strength":1.0,"positive":["11",0],"negative":["7",0],"control_net":["12",0],"image":["13",0]}},
         "11":{"class_type":"ConditioningSetArea","inputs":{"width":64,"conditioning":["14",0]}},
         "14":{"class_type":"Reroute","inputs":{"":["6",0]}},
         "6":\#(Self.encoder("a cat")),"7":\#(Self.encoder("bad"))}
        """#
        #expect(PromptReader.comfyUI(graph) == "a cat")
    }

    @Test func comfyUIGuiders() {
        let flux = #"""
        {"1":{"class_type":"SamplerCustomAdvanced","inputs":{"guider":["2",0],"noise":["9",0]}},
         "2":{"class_type":"BasicGuider","inputs":{"model":["4",0],"conditioning":["5",0]}},
         "5":{"class_type":"FluxGuidance","inputs":{"guidance":3.5,"conditioning":["6",0]}},
         "6":\#(Self.encoder("a cat"))}
        """#
        #expect(PromptReader.comfyUI(flux) == "a cat")
    }

    @Test func comfyUITextVariants() {
        let sdxl = #"{"3":\#(Self.sampler(positive: "6")),"6":{"class_type":"CLIPTextEncodeSDXL","inputs":{"text_g":"a cat","text_l":"a cat","clip":["4",1]}}}"#
        #expect(PromptReader.comfyUI(sdxl) == "a cat")
        let split = #"{"3":\#(Self.sampler(positive: "6")),"6":{"class_type":"CLIPTextEncodeSDXL","inputs":{"text_g":"a cat","text_l":"a dog","clip":["4",1]}}}"#
        #expect(PromptReader.comfyUI(split) == nil)
        let primitive = #"{"3":\#(Self.sampler(positive: "6")),"6":{"class_type":"CLIPTextEncode","inputs":{"text":["20",0],"clip":["4",1]}},"20":{"class_type":"PrimitiveString","inputs":{"value":"a cat"}}}"#
        #expect(PromptReader.comfyUI(primitive) == "a cat")
    }

    @Test func comfyUISamplersThatAgree() {
        let graph = #"{"3":\#(Self.sampler(positive: "6")),"30":\#(Self.sampler("KSamplerAdvanced", positive: "6")),"6":\#(Self.encoder("a cat")),"7":\#(Self.encoder("bad"))}"#
        #expect(PromptReader.comfyUI(graph) == "a cat")
    }

    @Test func comfyUIAmbiguousGraphsGiveNil() {
        // Two samplers, two prompts.
        let two = #"{"3":\#(Self.sampler(positive: "6")),"30":\#(Self.sampler(positive: "60")),"6":\#(Self.encoder("a cat")),"60":\#(Self.encoder("a dog"))}"#
        #expect(PromptReader.comfyUI(two) == nil)
        // Mixed conditioning.
        let combine = #"{"3":\#(Self.sampler(positive: "8")),"8":{"class_type":"ConditioningCombine","inputs":{"conditioning_1":["6",0],"conditioning_2":["60",0]}},"6":\#(Self.encoder("a cat")),"60":\#(Self.encoder("a dog"))}"#
        #expect(PromptReader.comfyUI(combine) == nil)
        // Blanked conditioning.
        let zero = #"{"3":\#(Self.sampler(positive: "8")),"8":{"class_type":"ConditioningZeroOut","inputs":{"conditioning":["6",0]}},"6":\#(Self.encoder("a cat"))}"#
        #expect(PromptReader.comfyUI(zero) == nil)
        // One sampler resolves, the other does not.
        let half = #"{"3":\#(Self.sampler(positive: "6")),"30":\#(Self.sampler(positive: "99")),"6":\#(Self.encoder("a cat"))}"#
        #expect(PromptReader.comfyUI(half) == nil)
        // A cycle, no sampler, not a graph.
        let cycle = #"{"3":\#(Self.sampler(positive: "8")),"8":{"class_type":"Reroute","inputs":{"":["9",0]}},"9":{"class_type":"Reroute","inputs":{"":["8",0]}}}"#
        #expect(PromptReader.comfyUI(cycle) == nil)
        #expect(PromptReader.comfyUI(#"{"6":\#(Self.encoder("a cat"))}"#) == nil)
        #expect(PromptReader.comfyUI("[1,2]") == nil)
        #expect(PromptReader.comfyUI("not json") == nil)
    }
}
