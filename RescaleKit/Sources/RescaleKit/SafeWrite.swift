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
    /// For a destination the user confirmed (Save As, Export); see `create`.
    public static func write(_ data: Data, to url: URL,
                             stage: Stage = { try $0.write(to: $1) }) throws {
        try staging(data, for: url, stage: stage) { staged in
            _ = try FileManager.default.replaceItemAt(url, withItemAt: staged)
        }
    }

    /// Writes `data` under the first of `candidates` that is free when the
    /// file lands, and returns that URL. For the saves nobody confirms (the
    /// silent save next to the original, the CLI): nothing is replaced
    /// (review 2026-10-03, G2). On failure nothing is left behind.
    ///
    /// The output is staged once, then takes a name by an exclusive rename,
    /// so a file that appeared after the name was chosen keeps its bytes and
    /// the same staged copy tries the next candidate. A volume without an
    /// exclusive rename (exFAT) gets the old check, then replace, which
    /// leaves that window open there. The candidates share one folder.
    @discardableResult
    public static func create(_ data: Data, firstFreeOf candidates: some Sequence<URL>,
                              stage: Stage = { try $0.write(to: $1) }) throws -> URL {
        let fm = FileManager.default
        var names = candidates.makeIterator()
        guard var url = names.next() else { throw CocoaError(.fileWriteUnknown) }
        return try staging(data, for: url, stage: stage) { staged in
            var exclusive = true
            while true {
                if exclusive {
                    switch renameExclusively(staged, to: url) {
                    case 0: return url
                    case EEXIST: break
                    // ENOTSUP: no exclusive rename on this volume (exFAT returns
                    // it for a free name); EINVAL: how a file system may refuse
                    // the flag; EXDEV: only `replaceItemAt` crosses volumes.
                    case ENOTSUP, EINVAL, EXDEV: exclusive = false; continue
                    case let code: throw error(code, at: url)
                    }
                } else if !fm.fileExists(atPath: url.path) {
                    _ = try fm.replaceItemAt(url, withItemAt: staged)
                    return url
                }
                guard let next = names.next() else {
                    throw CocoaError(.fileWriteFileExists, userInfo: [NSURLErrorKey: url, NSFilePathErrorKey: url.path])
                }
                url = next
            }
        }
    }

    /// `write`, run off the caller's actor, so a large file on a slow volume
    /// does not freeze the window (review 2026-10-03, #40).
    public static func writeDetached(_ data: Data, to url: URL,
                                     stage: @escaping @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1) }) async throws {
        try await Task.detached(priority: .userInitiated) {
            try write(data, to: url, stage: stage)
        }.value
    }

    /// `create`, run off the caller's actor.
    @discardableResult
    public static func createDetached(_ data: Data, firstFreeOf candidates: some Sequence<URL> & Sendable,
                                      stage: @escaping @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1) }) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try create(data, firstFreeOf: candidates, stage: stage)
        }.value
    }

    /// Stages `data` for `url` and hands the staged item to `commit`.
    ///
    /// The temporary item lives in the volume's item-replacement directory,
    /// which a sandboxed app can reach when it holds a grant for the file only
    /// (a save panel's URL); failing that, next to the destination, which a
    /// grant for the folder allows.
    private static func staging<T>(_ data: Data, for url: URL, stage: Stage,
                                   commit: (URL) throws -> T) throws -> T {
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
        do { try stage(data, staged) } catch { throw Self.error(error, at: url) }
        return try commit(staged)
    }

    /// `rename` that fails with EEXIST rather than replace. 0, or the errno.
    private static func renameExclusively(_ from: URL, to: URL) -> Int32 {
        from.withUnsafeFileSystemRepresentation { src in
            to.withUnsafeFileSystemRepresentation { dst in
                renamex_np(src, dst, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
            }
        }
    }

    /// The Cocoa error `replaceItemAt` would give, so the message reads the
    /// same, and a refusal is still recognised as one.
    private static func error(_ code: Int32, at url: URL) -> CocoaError {
        let kind: CocoaError.Code = switch code {
        case EACCES, EPERM: .fileWriteNoPermission
        case EROFS: .fileWriteVolumeReadOnly
        default: .fileWriteUnknown
        }
        return CocoaError(kind, userInfo: [NSURLErrorKey: url, NSFilePathErrorKey: url.path,
                                           NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(code))])
    }

    /// A staging error as it would read for `url`: a Cocoa error names the
    /// staged item, which the user never sees (#55). Its domain, code and
    /// underlying error stay, so a refusal is still recognised as one.
    private static func error(_ error: any Error, at url: URL) -> any Error {
        let ns = error as NSError
        guard ns.domain == NSCocoaErrorDomain else { return error }
        var info = ns.userInfo
        info[NSURLErrorKey] = url
        info[NSFilePathErrorKey] = url.path
        return CocoaError(CocoaError.Code(rawValue: ns.code), userInfo: info)
    }
}
