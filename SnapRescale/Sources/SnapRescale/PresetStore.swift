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
    /// Lines for the preset menu, each with its reason: files in the folder that
    /// could not be used (review C3), and a folder that could not be created,
    /// seeded or read (review 2026-10-03, P3).
    private(set) var problems: [String] = []
    let directory: URL
    private var fileByName: [String: URL] = [:]

    init(directory: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.directory = directory ?? base.appendingPathComponent("SnapRescale/presets", isDirectory: true)
        load()
    }

    /// Reads the folder, first creating it with the shipped presets if it is
    /// missing. A folder that cannot be created or read is not an empty one:
    /// the last presets read stay, `problems` says why, and this returns false.
    @discardableResult
    func load() -> Bool {
        let fm = FileManager.default
        var problems: [String] = []
        if !fm.fileExists(atPath: directory.path) {
            do {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                for p in Preset.shipped {
                    do {
                        try write(p, to: freshURL(for: p))
                    } catch {
                        problems.append("Could not add “\(p.name)”: \(error.localizedDescription)")
                    }
                }
            } catch {
                self.problems = ["Could not open or create the presets folder: \(error.localizedDescription)"]
                return false
            }
        }
        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch {
            self.problems = problems + ["Could not read the presets folder: \(error.localizedDescription)"]
            return false
        }
        let files = contents
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var byName: [String: URL] = [:]
        var loaded: [Preset] = []
        for url in files {
            do {
                let p = try Preset.from(json: Data(contentsOf: url))
                try p.validate()
                if byName[p.name] != nil {
                    problems.append("Skipped: \(url.lastPathComponent): another file already defines “\(p.name)”")
                    continue
                }
                byName[p.name] = url
                loaded.append(p)
            } catch {
                problems.append("Skipped: \(url.lastPathComponent): \(error.localizedDescription)")
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
        return true
    }

    /// Saves under `preset.name`: replaces the preset of that name if there is
    /// one, otherwise creates a new file that cannot collide with an existing one.
    /// Returns the preset as read back, or nil if the folder could not be read
    /// again: the list then still holds the old preset of that name, or none.
    func save(_ preset: Preset) throws -> Preset? {
        try preset.validate()
        let url = fileByName[preset.name] ?? freshURL(for: preset)
        try write(preset, to: url)
        guard load() else { return nil }
        return presets.first { $0.name == preset.name }
    }

    /// Removes the preset's file. Throws if it cannot be removed; the preset stays.
    /// A file that is already gone (removed in Finder) counts as deleted. Once
    /// the file is gone the preset leaves the list, even if the folder cannot
    /// be read again.
    func delete(named name: String) throws {
        guard let url = fileByName[name] else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            // Nothing to report: the file is gone either way.
        }
        if !load() {
            presets.removeAll { $0.name == name }
            fileByName[name] = nil
        }
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
