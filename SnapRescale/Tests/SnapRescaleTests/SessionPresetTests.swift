import Foundation
import Testing
import RescaleKit
@testable import SnapRescale

/// #60: `apply` rounds quality to a whole percent and takes a scale through
/// the field's percent; a preset that does not survive that unchanged still
/// stays selected until a setting is edited.
@MainActor @Suite struct SessionPresetTests {
    @Test(arguments: [
        Preset(name: "Quality 95.5", size: .width(1024), format: .jpeg, quality: 0.955),
        Preset(name: "Scale 12.3", size: .scale(0.123)),
        Preset(name: "Scale 0.7", size: .scale(0.007)),
        Preset(name: "Scale 1.3", size: .scale(0.013)),
    ])
    func appliedPresetStaysSelected(_ preset: Preset) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionPresetTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = Session(presets: PresetStore(directory: dir))
        let saved = try #require(try session.presets.save(preset))
        session.apply(saved)
        session.noteSettingsChanged()
        #expect(session.activePreset == preset.name)
        session.quality = 0.5
        session.noteSettingsChanged()
        #expect(session.activePreset == nil)
    }
}
