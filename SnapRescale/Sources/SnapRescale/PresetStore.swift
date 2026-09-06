import Foundation
import RescaleKit

/// Presets on disk: `~/Library/Application Support/SnapRescale/presets/*.json`
/// (inside the container when sandboxed). Shipped presets are written there on
/// first run so they are editable like any other; deleting one just removes it.
@MainActor @Observable
final class PresetStore {
    private(set) var presets: [Preset] = []
    let directory: URL

    init(directory: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.directory = directory ?? base.appendingPathComponent("SnapRescale/presets", isDirectory: true)
        load()
    }

    func load() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            for p in Preset.shipped { try? write(p) }
        }
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        presets = files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? Preset.from(json: Data(contentsOf: $0)) }
            .sorted { a, b in
                // Shipped order first, then the user's alphabetically.
                let ia = Preset.shipped.firstIndex { $0.name == a.name } ?? Int.max
                let ib = Preset.shipped.firstIndex { $0.name == b.name } ?? Int.max
                return ia != ib ? ia < ib : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
    }

    func save(_ preset: Preset) throws {
        if let old = presets.first(where: { $0.name == preset.name }), old.fileName != preset.fileName {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(old.fileName))
        }
        try write(preset)
        load()
    }

    func delete(named name: String) {
        guard let p = presets.first(where: { $0.name == name }) else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(p.fileName))
        load()
    }

    private func write(_ preset: Preset) throws {
        try preset.jsonData().write(to: directory.appendingPathComponent(preset.fileName), options: .atomic)
    }
}
