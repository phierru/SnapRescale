import Foundation

// The AI workflow summary (PRD §10.2, issue #25): a few readable fields above the
// raw payloads. Anything that cannot be read off unambiguously is left out.

extension ImageMetadata {
    /// The summary rows, in display order. The raw value is the row's title.
    public enum AISummaryKey: String, CaseIterable, Hashable, Sendable {
        case prompt = "Prompt"
        case negativePrompt = "Negative prompt"
        case model = "Model"
        case loras = "LoRAs"
        case seed = "Seed"
        case steps = "Steps"
        case cfg = "CFG"
        case sampler = "Sampler"
        case scheduler = "Scheduler"
        case size = "Size"
    }

    /// What the generation settings were, in reading order: prompt, negative prompt,
    /// model, LoRAs, seed, steps, CFG, sampler, scheduler, size. Read from ComfyUI API
    /// graphs and A1111-style parameters; other sources give the prompt only. A field
    /// is omitted when it cannot be determined, or when two samplers or two payloads
    /// disagree on it: never a guess. Empty when there is nothing to say.
    public var aiSummary: [MetadataField] {
        var found: [AISummaryKey: Set<String>] = [:]
        for payload in aiPayloads {
            for (key, value) in payload.summaryValues { found[key, default: []].insert(value) }
        }
        found[.prompt] = positivePrompt.map { [$0] }
        return AISummaryKey.allCases.compactMap { key in
            guard let values = found[key], values.count == 1, let value = values.first else { return nil }
            return MetadataField(key: key.rawValue, value: value, priority: .primary)
        }
    }

    /// One summary value, e.g. `aiSummaryValue(.seed)`.
    public func aiSummaryValue(_ key: AISummaryKey) -> String? {
        aiSummary.first { $0.key == key.rawValue }?.value
    }

    /// The summary as `Label: value` lines, for Copy.
    public var aiSummaryText: String {
        aiSummary.map { "\($0.label): \($0.readableValue)" }.joined(separator: "\n")
    }
}

extension ImageMetadata.AIPayload {
    /// The settings this payload states, the positive prompt aside (see `positivePrompt`).
    var summaryValues: [ImageMetadata.AISummaryKey: String] {
        switch (source, name) {
        case (.comfyUI, "prompt"): return WorkflowReader.comfyUI(text)
        case (.a1111, _): return WorkflowReader.a1111(text)
        default: return [:]
        }
    }
}

enum WorkflowReader {
    typealias Key = ImageMetadata.AISummaryKey

    static func size(_ width: String, _ height: String) -> String { "\(width) × \(height)" }

    private static func clean(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    // MARK: A1111 parameters

    /// `prompt`, then `Negative prompt: …` (possibly several lines), then the
    /// `Steps: 20, Sampler: Euler a, …` line.
    static func a1111(_ text: String) -> [Key: String] {
        let lines = text.components(separatedBy: .newlines)
        guard let settingsAt = lines.lastIndex(where: { $0.hasPrefix("Steps:") }) else { return [:] }
        var out: [Key: String] = [:]

        let marker = "Negative prompt:"
        if let negativeAt = lines.firstIndex(where: { $0.hasPrefix(marker) }), negativeAt < settingsAt {
            out[.negativePrompt] = clean(String(lines[negativeAt..<settingsAt].joined(separator: "\n").dropFirst(marker.count)))
        }

        let settings = self.settings(lines[settingsAt])
        let names: [(String, Key)] = [("Steps", .steps), ("Sampler", .sampler), ("Schedule type", .scheduler),
                                      ("CFG scale", .cfg), ("Seed", .seed), ("Model", .model)]
        for (name, key) in names { out[key] = settings[name] }
        if let s = settings["Size"] {
            let parts = s.split(separator: "x")
            out[.size] = parts.count == 2 && parts.allSatisfy({ Int($0) != nil }) ? size(String(parts[0]), String(parts[1])) : s
        }

        // `<lora:name:0.8>` tags in the prompt.
        if let prompt = PromptReader.a1111(text) {
            var loras: [String] = []
            for piece in prompt.components(separatedBy: "<lora:").dropFirst() {
                guard let end = piece.firstIndex(of: ">") else { continue }
                if let name = clean(String(piece[..<end].prefix { $0 != ":" })), !loras.contains(name) { loras.append(name) }
            }
            if !loras.isEmpty { out[.loras] = loras.joined(separator: ", ") }
        }
        return out
    }

    /// `Key: value, Key: "quoted, value", …` as a dictionary. A key stated twice
    /// with different values is dropped. A quoted value is a JSON string, as A1111
    /// writes it: `\"` does not close it, and its escapes are decoded (review 2026-09-30, G7).
    static func settings(_ line: String) -> [String: String] {
        var parts: [String] = []
        var current = ""
        var quoted = false
        var escaped = false
        for c in line {
            // Inside quotes a backslash takes the next character with it.
            if escaped { escaped = false }
            else if c == "\\", quoted { escaped = true }
            else if c == "\"" { quoted.toggle() }
            if c == ",", !quoted { parts.append(current); current = "" } else { current.append(c) }
        }
        parts.append(current)

        var out: [String: String] = [:]
        var clashing = Set<String>()
        for part in parts {
            guard let colon = part.firstIndex(of: ":") else { continue }
            let key = part[..<colon].trimmingCharacters(in: .whitespaces)
            var value = part[part.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = unquoted(value) }
            guard !key.isEmpty, !value.isEmpty else { continue }
            if let old = out[key], old != value { clashing.insert(key) }
            out[key] = value
        }
        for key in clashing { out[key] = nil }
        return out
    }

    /// A `"quoted"` value decoded as the JSON string it is; when it is not valid
    /// JSON, the quotes come off and the rest stays as written.
    private static func unquoted(_ value: String) -> String {
        let decoded = try? JSONSerialization.jsonObject(with: Data(value.utf8), options: .fragmentsAllowed)
        return decoded as? String ?? String(value.dropFirst().dropLast())
    }

    // MARK: ComfyUI API graph

    /// Walks from every sampler: a node with a linked `latent_image` (KSampler,
    /// KSamplerAdvanced, SamplerCustom, SamplerCustomAdvanced, …) or with its own
    /// `steps` and a linked `positive` (detailers). A field is kept only when every
    /// sampler resolves it, and to the same value.
    static func comfyUI(_ text: String) -> [Key: String] {
        guard let graph = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return [:] }
        var samplers: [[Key: String]] = []
        for id in graph.keys.sorted() {
            guard let inputs = inputs(id, graph) else { continue }
            let isSampler = PromptReader.link(inputs["latent_image"]) != nil
                || (inputs["steps"] != nil && PromptReader.link(inputs["positive"]) != nil)
            if isSampler { samplers.append(sampler(id, inputs, graph)) }
        }
        guard let first = samplers.first else { return [:] }
        return first.filter { key, value in samplers.allSatisfy { $0[key] == value } }
    }

    private static func inputs(_ id: String?, _ graph: [String: Any]) -> [String: Any]? {
        guard let id else { return nil }
        return (graph[id] as? [String: Any])?["inputs"] as? [String: Any]
    }

    private static func sampler(_ id: String, _ inputs: [String: Any], _ graph: [String: Any]) -> [Key: String] {
        // SamplerCustomAdvanced splits its settings over guider, noise, sampler and sigmas nodes.
        let guider = self.inputs(PromptReader.link(inputs["guider"]), graph)
        let noise = self.inputs(PromptReader.link(inputs["noise"]), graph)
        let select = self.inputs(PromptReader.link(inputs["sampler"]), graph)
        let sigmas = self.inputs(PromptReader.link(inputs["sigmas"]), graph)
        var out: [Key: String] = [:]

        out[.seed] = number(inputs["seed"], graph) ?? number(inputs["noise_seed"], graph) ?? number(noise?["noise_seed"], graph)
        out[.steps] = number(inputs["steps"], graph) ?? number(sigmas?["steps"], graph)
        out[.cfg] = number(inputs["cfg"], graph) ?? number(guider?["cfg"], graph)
        out[.sampler] = clean(inputs["sampler_name"] as? String) ?? clean(select?["sampler_name"] as? String)
        out[.scheduler] = clean(inputs["scheduler"] as? String) ?? clean(sigmas?["scheduler"] as? String)

        if let start = PromptReader.link(inputs["model"]) ?? PromptReader.link(guider?["model"]),
           let (name, loras) = model(start, graph) {
            out[.model] = name
            if !loras.isEmpty { out[.loras] = loras.joined(separator: ", ") }
        }
        if let negative = PromptReader.link(inputs["negative"]) ?? PromptReader.link(guider?["negative"]) {
            out[.negativePrompt] = clean(PromptReader.conditioningText(negative, in: graph, visited: [id], side: "negative"))
        }
        if let latent = self.inputs(PromptReader.link(inputs["latent_image"]), graph),
           let width = number(latent["width"], graph), let height = number(latent["height"], graph) {
            out[.size] = size(width, height)
        }
        return out
    }

    /// Upstream along `model` links to the loader: `ckpt_name` (checkpoint) or
    /// `unet_name` (UNET / diffusion model), collecting `lora_name`s on the way.
    private static func model(_ start: String, _ graph: [String: Any]) -> (name: String, loras: [String])? {
        var id: String? = start
        var visited = Set<String>()
        var loras: [String] = []
        while let current = id, visited.insert(current).inserted, visited.count < 64,
              let inputs = inputs(current, graph) {
            if let name = clean(inputs["ckpt_name"] as? String) ?? clean(inputs["unet_name"] as? String) {
                return (name, loras.reversed())
            }
            if let lora = clean(inputs["lora_name"] as? String) { loras.append(lora) }
            id = PromptReader.link(inputs["model"])
        }
        return nil
    }

    /// A number as written, or the single numeric value of the primitive node it links to.
    private static func number(_ value: Any?, _ graph: [String: Any]) -> String? {
        if let n = value as? NSNumber { return format(n) }
        guard let from = inputs(PromptReader.link(value), graph) else { return nil }
        let numbers = ["value", "seed", "noise_seed", "int", "float"].compactMap { (from[$0] as? NSNumber).flatMap(format) }
        return numbers.count == 1 ? numbers[0] : nil
    }

    /// Integers in full (seeds run to 64 bits), fractions trimmed.
    private static func format(_ n: NSNumber) -> String? {
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
        return CFNumberIsFloatType(n) ? MetadataFormat.number(n.doubleValue) : n.stringValue
    }
}
