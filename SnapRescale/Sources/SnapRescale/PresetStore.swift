import Foundation
import RescaleKit

/// Presets on disk: `~/Library/Application Support/SnapRescale/presets/*.json`
/// (inside the container when sandboxed). Shipped presets are written there on
/// first run so they are editable like any other; deleting one just removes it.
///
/// Names are the identity the user sees; files are tracked by their real URL,
/// so two names that sanitise to the same file name cannot overwrite each other
/// (review 2026-09-06, C4). Saving under an existing name replaces that preset.
@MainActor @Observable
final class PresetStore {
    private(set) var presets: [Preset] = []
    /// Files in the folder that could not be used, with the reason (review C3).
    private(set) var problems: [String] = []
    let directory: URL
    private var fileByName: [String: URL] = [:]

    init(directory: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.directory = directory ?? base.appendingPathComponent("SnapRescale/presets", isDirectory: true)
        load()
    }

    func load() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            for p in Preset.shipped { try? write(p, to: freshURL(for: p)) }
        }
        let files = ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var problems: [String] = []
        var byName: [String: URL] = [:]
        var loaded: [Preset] = []
        for url in files {
            do {
                let p = try Preset.from(json: Data(contentsOf: url))
                try p.validate()
                if byName[p.name] != nil {
                    problems.append("\(url.lastPathComponent): another file already defines “\(p.name)”")
                    continue
                }
                byName[p.name] = url
                loaded.append(p)
            } catch {
                problems.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        presets = loaded.sorted { a, b in
            // Shipped order first, then the user's alphabetically.
            let ia = Preset.shipped.firstIndex { $0.name == a.name } ?? Int.max
            let ib = Preset.shipped.firstIndex { $0.name == b.name } ?? Int.max
            return ia != ib ? ia < ib : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        fileByName = byName
        self.problems = problems
    }

    /// Saves under `preset.name`: replaces the preset of that name if there is
    /// one, otherwise creates a new file that cannot collide with an existing one.
    func save(_ preset: Preset) throws {
        try preset.validate()
        let url = fileByName[preset.name] ?? freshURL(for: preset)
        try write(preset, to: url)
        load()
    }

    func delete(named name: String) {
        guard let url = fileByName[name] else { return }
        try? FileManager.default.removeItem(at: url)
        load()
    }

    /// `Name.json`, or `Name 2.json`, … until no file of that name exists.
    private func freshURL(for preset: Preset) -> URL {
        let base = String(preset.fileName.dropLast(5))
        var candidate = directory.appendingPathComponent(preset.fileName)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) \(n).json")
            n += 1
        }
        return candidate
    }

    private func write(_ preset: Preset, to url: URL) throws {
        try preset.jsonData().write(to: url, options: .atomic)
    }
}
