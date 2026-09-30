import Foundation

/// Writes a file so that a failure never costs the one already there.
///
/// `Data.write(to:)` truncates the destination before the new bytes are on
/// disk, so a failed replacement leaves a partial file where the original was
/// (review 2026-09-30, G1). Here the bytes go to a temporary item first and
/// take the destination's place in one step, only once they are complete.
public enum SafeWrite {
    /// Writes the staged copy. Replaceable so a test can make it fail.
    public typealias Stage = (Data, URL) throws -> Void

    /// Writes `data` to `url`, creating the file or replacing it as a whole.
    /// On failure the destination is untouched and the temporary item is removed.
    ///
    /// The temporary item lives in the volume's item-replacement directory,
    /// which a sandboxed app can reach when it holds a grant for the file only
    /// (a save panel's URL); failing that, next to the destination, which a
    /// grant for the folder allows.
    public static func write(_ data: Data, to url: URL,
                             stage: Stage = { try $0.write(to: $1) }) throws {
        let fm = FileManager.default
        let name = url.lastPathComponent
        let staged: URL
        let cleanup: URL
        if let dir = try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                 appropriateFor: url, create: true) {
            staged = dir.appendingPathComponent(name)
            cleanup = dir
        } else {
            staged = url.deletingLastPathComponent()
                .appendingPathComponent(".\(name).\(UUID().uuidString).tmp")
            cleanup = staged
        }
        // After a successful commit the staged item has moved; this removes
        // what is left of it, which after a failure is everything.
        defer { try? fm.removeItem(at: cleanup) }
        try stage(data, staged)
        _ = try fm.replaceItemAt(url, withItemAt: staged)
    }
}
