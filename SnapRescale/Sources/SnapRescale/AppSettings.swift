import Foundation
import RescaleKit

/// Everything in the Settings window (⌘,), persisted in UserDefaults.
/// Session reads the defaults when it starts; the ladder is read live.
@MainActor @Observable
final class AppSettings {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    // Saving (PRD §8, §11)
    var revealAfterSave: Bool { didSet { d.set(revealAfterSave, forKey: "revealSavedImageInFinder") } }
    var saveWithoutAsking: Bool { didSet { d.set(saveWithoutAsking, forKey: "saveNextToOriginalWithoutAsking") } }

    // Defaults for a new session (PRD §5, §9)
    var defaultMultiple: Multiple { didSet { d.set(defaultMultiple.rawValue, forKey: "defaultMultiple") } }
    var defaultQuality: Double { didSet { d.set(defaultQuality, forKey: "defaultQuality") } }

    // The size ladder (PRD §5). Pixel values only; MP and % ladders are fixed.
    static let defaultLadder = [512, 768, 1024, 1536, 2048]
    var ladder: [Int] { didSet { d.set(ladder, forKey: "ladderPixels") } }

    private init() {
        revealAfterSave = d.object(forKey: "revealSavedImageInFinder") as? Bool ?? true
        saveWithoutAsking = d.bool(forKey: "saveNextToOriginalWithoutAsking")
        defaultMultiple = Multiple(rawValue: d.integer(forKey: "defaultMultiple")) ?? .eight
        defaultQuality = d.object(forKey: "defaultQuality") as? Double ?? 0.95
        let stored = d.array(forKey: "ladderPixels") as? [Int] ?? []
        ladder = Self.validated(stored) ?? Self.defaultLadder
    }

    /// 2–6 distinct positive values, ascending. Nil when the list is unusable.
    static func validated(_ values: [Int]) -> [Int]? {
        let clean = Array(Set(values.filter { $0 > 0 && $0 <= Limits.maxDimension })).sorted()
        return (2...6).contains(clean.count) ? clean : nil
    }

    /// Values that snapping can displace (PRD §5: every detent should be divisible by 8 and 16).
    static func latticeUnsafe(_ values: [Int]) -> [Int] { values.filter { $0 % 16 != 0 } }
}
