import AppKit
import Foundation

/// Sandbox-aware write access to a folder (PRD §8, §11).
///
/// Under App Sandbox an opened file grants access to that file only, not its
/// folder, so "save next to the original without asking" needs the user to
/// point at the folder once. The grant is kept as a security-scoped bookmark,
/// so later saves into the same folder are silent. Outside the sandbox the
/// direct write simply succeeds and none of this runs.
@MainActor
enum FolderAccess {
    private static let defaultsKey = "folderBookmarks"

    enum Outcome {
        /// Where the file went, which `commit` decides.
        case written(URL)
        case cancelled
        case failed(Error)
    }

    /// Runs `commit`, which writes into `folder` and returns the URL it wrote,
    /// asking for the folder once if the sandbox refuses. `commit` may run
    /// again after a failure, so a failed attempt must leave nothing behind
    /// and any existing file as it was (`SafeWrite`).
    static func write(in folder: URL, _ commit: () throws -> URL) -> Outcome {
        // 1. A stored grant for this folder.
        if let granted = resolveBookmark(for: folder) {
            defer { granted.stopAccessingSecurityScopedResource() }
            do { return .written(try commit()) } catch { /* fall through to re-ask */ }
        }

        // 2. Plain write: works unsandboxed, or when the folder is already reachable.
        do {
            return .written(try commit())
        } catch let error as NSError where isPermissionDenied(error) {
            // 3. Ask once for the folder.
            guard let granted = askForFolder(folder) else { return .cancelled }
            defer { granted.stopAccessingSecurityScopedResource() }
            do { return .written(try commit()) } catch { return .failed(error) }
        } catch {
            return .failed(error)
        }
    }

    // MARK: - Bookmarks

    private static var bookmarks: [String: Data] {
        get { UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Data] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    /// Resolves and starts accessing a stored bookmark; caller must stop accessing.
    private static func resolveBookmark(for folder: URL) -> URL? {
        guard let data = bookmarks[folder.path] else { return nil }
        var stale = false
        guard let resolved = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                                      relativeTo: nil, bookmarkDataIsStale: &stale),
              resolved.startAccessingSecurityScopedResource()
        else {
            bookmarks[folder.path] = nil
            return nil
        }
        if stale, let fresh = try? resolved.bookmarkData(options: [.withSecurityScope]) {
            bookmarks[folder.path] = fresh
        }
        return resolved
    }

    private static func askForFolder(_ folder: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.prompt = "Allow"
        panel.message = "SnapRescale needs permission to save next to the original in “\(folder.lastPathComponent)”. This is asked once per folder."
        guard panel.runModal() == .OK, let chosen = panel.url else { return nil }
        guard chosen.startAccessingSecurityScopedResource() else { return nil }
        if let data = try? chosen.bookmarkData(options: [.withSecurityScope]) {
            bookmarks[chosen.path] = data
        }
        return chosen
    }

    private static func isPermissionDenied(_ error: NSError) -> Bool {
        (error.domain == NSCocoaErrorDomain && [NSFileWriteNoPermissionError, NSFileReadNoPermissionError, NSFileWriteVolumeReadOnlyError].contains(error.code))
            || (error.domain == NSPOSIXErrorDomain && (error.code == Int(EPERM) || error.code == Int(EACCES)))
            || ((error.userInfo[NSUnderlyingErrorKey] as? NSError).map(isPermissionDenied) ?? false)
    }

    /// For the preferences window: forget every folder grant.
    static func forgetAll() { bookmarks = [:] }
    static var grantedFolderCount: Int { bookmarks.count }
}
