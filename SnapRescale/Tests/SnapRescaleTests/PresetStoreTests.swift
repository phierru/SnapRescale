import Foundation
import Testing
import RescaleKit
@testable import SnapRescale

/// Review 2026-10-03, P3: a folder that cannot be read, created or changed is
/// reported, never mistaken for an empty folder or a done delete.
@MainActor @Suite struct PresetStoreTests {
    /// A disposable folder, removed when the test ends.
    private func withFolder(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PresetStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    private func setPermissions(_ mode: Int, of url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    /// Runs `/bin/chmod`, for the ACLs FileManager cannot set.
    private func chmod(_ arguments: String...) throws {
        let process = try Process.run(URL(fileURLWithPath: "/bin/chmod"), arguments: arguments)
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
    }

    @Test func seedsTheShippedPresetsIntoAMissingFolder() throws {
        try withFolder { dir in
            let store = PresetStore(directory: dir.appendingPathComponent("presets"))
            #expect(store.presets.map(\.name) == Preset.shipped.map(\.name))
            #expect(store.problems.isEmpty)
        }
    }

    @Test func unreadableFolderKeepsTheLastPresets() throws {
        try withFolder { dir in
            let store = PresetStore(directory: dir.appendingPathComponent("presets"))
            let names = store.presets.map(\.name)
            try setPermissions(0o000, of: store.directory)
            defer { try? setPermissions(0o755, of: store.directory) }
            store.load()
            #expect(store.presets.map(\.name) == names)
            #expect(store.problems.count == 1)
            #expect(store.problems.first?.hasPrefix("Could not read the presets folder") == true)
        }
    }

    @Test func failedDeleteThrowsAndKeepsThePreset() throws {
        try withFolder { dir in
            let store = PresetStore(directory: dir.appendingPathComponent("presets"))
            try setPermissions(0o555, of: store.directory)
            defer { try? setPermissions(0o755, of: store.directory) }
            #expect(throws: (any Error).self) {
                try store.delete(named: "Web")
            }
            #expect(store.presets.contains { $0.name == "Web" })
            #expect(FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("Web.json").path))
        }
    }

    @Test func deletingAFileAlreadyGoneDropsThePreset() throws {
        try withFolder { dir in
            let store = PresetStore(directory: dir.appendingPathComponent("presets"))
            try FileManager.default.removeItem(at: store.directory.appendingPathComponent("Web.json"))
            try store.delete(named: "Web")
            #expect(!store.presets.contains { $0.name == "Web" })
            #expect(store.problems.isEmpty)
        }
    }

    /// Removed, but the folder cannot be read again: the other presets stay.
    @Test func deleteInAnUnreadableFolderStillDropsThePreset() throws {
        try withFolder { dir in
            let store = PresetStore(directory: dir.appendingPathComponent("presets"))
            try setPermissions(0o333, of: store.directory)
            defer { try? setPermissions(0o755, of: store.directory) }
            try store.delete(named: "Web")
            #expect(store.presets.map(\.name) == Preset.shipped.map(\.name).filter { $0 != "Web" })
            #expect(store.problems.first?.hasPrefix("Could not read the presets folder") == true)
        }
    }

    /// Save Preset applies what was read back: the file keeps the colour in 8 bits.
    @Test func saveReturnsThePresetAsReadBack() throws {
        try withFolder { dir in
            let store = PresetStore(directory: dir.appendingPathComponent("presets"))
            let mine = Preset(name: "Mine", size: .width(777), padColor: PadColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
            let saved = try store.save(mine)
            #expect(saved == (try Preset.from(json: mine.jsonData())))
            #expect(saved != mine)
        }
    }

    /// Written but not read back: the list still holds the old "Web", which is
    /// not what was saved.
    @Test func saveIntoAnUnreadableFolderReturnsNoStaleCopy() throws {
        try withFolder { dir in
            let store = PresetStore(directory: dir.appendingPathComponent("presets"))
            var web = try #require(store.presets.first { $0.name == "Web" })
            web.size = .width(777)
            try setPermissions(0o333, of: store.directory)
            defer { try? setPermissions(0o755, of: store.directory) }
            #expect(try store.save(web) == nil)
            #expect(store.problems.first?.hasPrefix("Could not read the presets folder") == true)
        }
    }

    @Test func unwritableParentReportsTheSeeding() throws {
        try withFolder { dir in
            try setPermissions(0o555, of: dir)
            defer { try? setPermissions(0o755, of: dir) }
            let store = PresetStore(directory: dir.appendingPathComponent("presets"))
            #expect(store.presets.isEmpty)
            #expect(store.problems.count == 1)
            #expect(store.problems.first?.hasPrefix("Could not open or create the presets folder") == true)
        }
    }

    /// The folder is created but takes no files: each shipped preset is reported.
    @Test func seedingFailureReportsEachShippedPreset() throws {
        try withFolder { dir in
            // Inherited by the presets folder, not applied to `dir` itself.
            try chmod("+a", "everyone deny add_file,only_inherit,directory_inherit", dir.path)
            defer { try? chmod("-R", "-N", dir.path) }
            let store = PresetStore(directory: dir.appendingPathComponent("presets"))
            #expect(store.presets.isEmpty)
            #expect(store.problems.count == Preset.shipped.count)
            #expect(zip(store.problems, Preset.shipped).allSatisfy { $0.hasPrefix("Could not add “\($1.name)”") })
        }
    }
}
