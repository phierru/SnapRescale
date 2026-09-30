import Foundation
import UniformTypeIdentifiers

/// Something the inspector can save to disk (PRD §10.5): a suggested file name, its type and the bytes.
public struct MetadataExport: Hashable, Sendable, Identifiable {
    /// Suggested name, built on the source file's base name: `picture.workflow.json`.
    public let filename: String
    /// `.json` or `.plainText`.
    public let type: UTType
    public let data: Data
    /// The AI payload this came from; nil for Export All.
    public let payload: ImageMetadata.AIPayload?
    public var id: String { filename }

    /// `json` or `txt`.
    public var fileExtension: String { type == .json ? "json" : "txt" }
}

// MARK: - Copy and Export All

extension ImageMetadata {
    /// Every section as a title line and its `Label: value` lines, blank line between
    /// sections (Copy All, PRD §10.5). Readable: friendly labels, translated values.
    /// The AI workflow leads with its summary, as the section's own Copy does.
    public var copyAllText: String {
        let summary = aiSummaryText
        return sections.map { section in
            let lead = section.kind == .aiWorkflow && !summary.isEmpty ? summary + "\n" : ""
            return "\(section.title)\n\(lead)\(section.text)"
        }.joined(separator: "\n\n")
    }

    /// Every section as one pretty-printed UTF-8 JSON object (Export All…, PRD §10.5):
    /// section titles in inspector order, each an object of its fields in field order.
    /// Faithful: raw keys (`FocalLenIn35mmFilm`) and values as stored (`Flash: 16`), never
    /// the friendly labels or translations; derived fields (GPS `Position`, ICC `Embedded`)
    /// are extra keys. A payload that is itself JSON stays a string.
    public var exportAllJSON: Data {
        var out = "{\n"
        for (i, section) in sections.enumerated() {
            out += "  \(Self.jsonString(section.title)): {\n"
            for (j, field) in section.fields.enumerated() {
                out += "    \(Self.jsonString(field.key)): \(Self.jsonString(field.value))"
                out += j + 1 < section.fields.count ? ",\n" : "\n"
            }
            out += i + 1 < sections.count ? "  },\n" : "  }\n"
        }
        out += "}\n"
        return Data(out.utf8)
    }

    /// Export All… with its suggested name, `picture.metadata.json`.
    public func exportAll(baseName: String) -> MetadataExport {
        MetadataExport(filename: "\(baseName).metadata.json", type: .json, data: exportAllJSON, payload: nil)
    }

    /// A JSON string literal. JSONSerialization does the escaping; key order is ours.
    private static func jsonString(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
    }
}

// MARK: - AI workflow export

extension ImageMetadata.AIPayload {
    /// Worth a file of its own: graphs and parameters, not one-word companions
    /// (`fooocus_scheme`, NovelAI's `Software` / `Title` / `Source`).
    public var isExportable: Bool {
        switch source {
        case .comfyUI: return name == "workflow" || name == "prompt"
        case .a1111, .invokeAI, .midjourney: return true
        case .fooocus, .swarmUI: return name == "parameters"
        case .novelAI: return name == "Comment" || name == "Description"
        case .c2pa: return false
        }
    }

    /// The middle of the file name: `workflow`, `prompt`, `parameters`, `description`, …
    var exportLabel: String {
        switch name {
        case "UserComment": return "parameters"
        case "ImageDescription": return "description"
        default: return name.lowercased()
        }
    }

    /// Lower is better: the UI graph ComfyUI reloads in full beats the API graph, a graph beats its summary.
    var exportRank: Int {
        switch (source, name) {
        case (.comfyUI, "workflow"), (.invokeAI, "invokeai_graph"), (.novelAI, "Comment"): return 0
        case (.comfyUI, _), (.invokeAI, "invokeai_metadata"), (.novelAI, _): return 1
        case (.invokeAI, _): return 2
        default: return 0
        }
    }

    /// The payload as a file: `.json` when it parses as JSON, else `.txt`. The bytes are the
    /// payload text as UTF-8, untouched, so a ComfyUI graph drops straight back into ComfyUI.
    public func export(baseName: String) -> MetadataExport? {
        export(baseName: baseName, qualified: false)
    }

    func export(baseName: String, qualified: Bool) -> MetadataExport? {
        guard isExportable else { return nil }
        let type: UTType = isJSON ? .json : .plainText
        let label = qualified ? "\(source.rawValue.lowercased()).\(exportLabel)" : exportLabel
        return MetadataExport(filename: "\(baseName).\(label).\(isJSON ? "json" : "txt")", type: type,
                              data: Data(text.utf8), payload: self)
    }
}

extension ImageMetadata {
    /// Every exportable AI payload in file order (AI workflow ▸ Export…, PRD §10.5).
    /// `baseName` is the source file's name without extension. Names that would
    /// collide between two sources gain the source: `picture.a1111.parameters.txt`.
    public func aiExports(baseName: String) -> [MetadataExport] {
        let plain = aiPayloads.compactMap { $0.export(baseName: baseName) }
        var count: [String: Int] = [:]
        for e in plain { count[e.filename, default: 0] += 1 }
        return plain.compactMap { e in
            count[e.filename] == 1 ? e : e.payload?.export(baseName: baseName, qualified: true)
        }
    }

    /// The one to offer first: ComfyUI `workflow` over `prompt`, InvokeAI's graph over its
    /// metadata, otherwise the first in file order. Nil when nothing is exportable.
    public func primaryAIExport(baseName: String) -> MetadataExport? {
        aiExports(baseName: baseName).enumerated()
            .min { a, b in
                let (ra, rb) = (a.element.payload?.exportRank ?? 0, b.element.payload?.exportRank ?? 0)
                return ra != rb ? ra < rb : a.offset < b.offset
            }?.element
    }
}

extension SourceImage {
    /// The file name without its extension, the stem of every suggested export name.
    public var exportBaseName: String { url.deletingPathExtension().lastPathComponent }
    public var aiExports: [MetadataExport] { metadata.aiExports(baseName: exportBaseName) }
    public var primaryAIExport: MetadataExport? { metadata.primaryAIExport(baseName: exportBaseName) }
    public var exportAll: MetadataExport { metadata.exportAll(baseName: exportBaseName) }
}

// MARK: - Positive prompt

extension ImageMetadata {
    /// The positive prompt for Copy Prompt (PRD §10.5). Nil when no payload yields
    /// one or two payloads yield different ones: never a guess.
    public var positivePrompt: String? {
        var found: [String] = []
        for p in aiPayloads.compactMap(\.positivePrompt) where !found.contains(p) { found.append(p) }
        return found.count == 1 ? found[0] : nil
    }
}

extension ImageMetadata.AIPayload {
    /// The positive prompt in this payload, or nil when it cannot be read off unambiguously.
    public var positivePrompt: String? {
        let prompt: String?
        switch source {
        case .a1111:
            prompt = PromptReader.a1111(text)
        case .midjourney:
            prompt = PromptReader.midjourney(text)
        case .comfyUI:
            prompt = name == "prompt" ? PromptReader.comfyUI(text) : nil
        case .fooocus:
            prompt = name == "parameters" ? PromptReader.json(text, ["prompt"]) ?? PromptReader.a1111(text) : nil
        case .swarmUI:
            prompt = name == "parameters" ? PromptReader.json(text, ["sui_image_params", "prompt"]) : nil
        case .invokeAI:
            prompt = name == "invokeai_metadata" ? PromptReader.json(text, ["positive_prompt"]) : nil
        case .novelAI:
            // `Comment` is the generation JSON; `Description` is the bare prompt.
            prompt = name == "Comment" ? PromptReader.json(text, ["prompt"]) : name == "Description" ? text : nil
        case .c2pa:
            prompt = nil
        }
        guard let trimmed = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

enum PromptReader {
    /// Everything before the `Negative prompt:` line or, failing that, before the last `Steps:` line.
    static func a1111(_ text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
        guard let end = lines.firstIndex(where: { $0.hasPrefix("Negative prompt:") })
                ?? lines.lastIndex(where: { $0.hasPrefix("Steps:") }) else { return nil }
        return lines[..<end].joined(separator: "\n")
    }

    /// `a prompt --ar 16:9 --v 6 Job ID: …`: the part before the flags and the job ID.
    static func midjourney(_ text: String) -> String? {
        var s = Substring(text)
        if let job = s.range(of: "Job ID:") { s = s[..<job.lowerBound] }
        if s.hasPrefix("--") { return nil }
        if let flags = s.range(of: " --") { s = s[..<flags.lowerBound] }
        return String(s)
    }

    /// The string at a key path of a JSON object.
    static func json(_ text: String, _ path: [String]) -> String? {
        var node: Any? = try? JSONSerialization.jsonObject(with: Data(text.utf8))
        for key in path { node = (node as? [String: Any])?[key] }
        return node as? String
    }

    // MARK: ComfyUI API graph

    /// The text behind the `positive` input of the sampler(s). Every node with a linked
    /// `positive` input counts (KSampler, KSamplerAdvanced, SamplerCustom, CFGGuider, …), as
    /// does BasicGuider's `conditioning`; all of them must resolve, and to the same text.
    static func comfyUI(_ text: String) -> String? {
        guard let graph = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return nil }
        var prompts = Set<String>()
        var samplers = 0
        for id in graph.keys {
            guard let node = graph[id] as? [String: Any], let inputs = node["inputs"] as? [String: Any] else { continue }
            let input = node["class_type"] as? String == "BasicGuider" ? "conditioning" : "positive"
            guard let target = link(inputs[input]) else { continue }
            samplers += 1
            guard let prompt = conditioningText(target, in: graph, visited: [id]) else { return nil }
            prompts.insert(prompt)
        }
        return samplers > 0 && prompts.count == 1 ? prompts.first : nil
    }

    /// A graph link is `[node id, output index]`; the id may be a string or a number.
    static func link(_ value: Any?) -> String? {
        guard let pair = value as? [Any], pair.count == 2, pair[1] is NSNumber else { return nil }
        if let s = pair[0] as? String { return s }
        if let n = pair[0] as? NSNumber { return n.stringValue }
        return nil
    }

    /// Walks upstream from a conditioning link to the text encoder. Follows a node's own
    /// `positive` or `conditioning` input, or its only link (reroutes); stops at anything
    /// that mixes or blanks conditioning. `side` is `negative` for the negative prompt.
    static func conditioningText(_ id: String, in graph: [String: Any], visited: Set<String>,
                                 side: String = "positive") -> String? {
        guard !visited.contains(id), visited.count < 64,
              let node = graph[id] as? [String: Any], let inputs = node["inputs"] as? [String: Any] else { return nil }
        let seen = visited.union([id])
        if let text = inputs["text"] as? String { return text }
        // SDXL encoders carry two texts; only one prompt when they agree.
        if let g = inputs["text_g"] as? String, let l = inputs["text_l"] as? String { return g == l ? g : nil }
        if let from = link(inputs["text"]) { return stringValue(from, in: graph) }
        if node["class_type"] as? String == "ConditioningZeroOut" { return nil }
        for name in [side, "conditioning"] {
            if let next = link(inputs[name]) { return conditioningText(next, in: graph, visited: seen, side: side) }
        }
        let links = inputs.values.compactMap(link)
        return links.count == 1 ? conditioningText(links[0], in: graph, visited: seen, side: side) : nil
    }

    /// A primitive string node feeding an encoder's `text`: exactly one of `text` / `value` / `string`.
    private static func stringValue(_ id: String, in graph: [String: Any]) -> String? {
        guard let inputs = (graph[id] as? [String: Any])?["inputs"] as? [String: Any] else { return nil }
        let strings = ["text", "value", "string"].compactMap { inputs[$0] as? String }
        return strings.count == 1 ? strings[0] : nil
    }
}
