import Foundation
import Synchronization
import Testing
@testable import RescaleKit

/// Review 2026-09-30, G1: a failed save must not cost the file it replaces.
/// Review 2026-10-03, G2: a save nobody confirmed must not replace anything.
@Suite struct SafeWriteTests {
    struct Injected: Error {}

    /// A disposable folder, removed when the test ends.
    private func withFolder(_ body: (URL) throws -> Void) throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    /// A disposable folder for an async test, which removes it.
    private func makeFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SafeWriteTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func names(in dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    @Test func createsANewFile() throws {
        try withFolder { dir in
            let url = dir.appendingPathComponent("new.jpg")
            try SafeWrite.write(Data("fresh".utf8), to: url)
            #expect(try Data(contentsOf: url) == Data("fresh".utf8))
            #expect(try names(in: dir) == ["new.jpg"])
        }
    }

    @Test func replacesAnExistingFile() throws {
        try withFolder { dir in
            let url = dir.appendingPathComponent("out.jpg")
            try Data("original, and longer than its replacement".utf8).write(to: url)
            try SafeWrite.write(Data("replacement".utf8), to: url)
            #expect(try Data(contentsOf: url) == Data("replacement".utf8))
            #expect(try names(in: dir) == ["out.jpg"])
        }
    }

    /// The write breaks off half way: the original bytes are all still there
    /// and nothing temporary is left behind.
    @Test func failedReplacementKeepsTheOriginal() throws {
        try withFolder { dir in
            let url = dir.appendingPathComponent("out.jpg")
            let original = Data("original".utf8)
            try original.write(to: url)
            var staged: URL?
            #expect(throws: Injected.self) {
                try SafeWrite.write(Data("replacement".utf8), to: url) { data, temp in
                    staged = temp
                    try data.prefix(data.count / 2).write(to: temp)
                    throw Injected()
                }
            }
            #expect(try Data(contentsOf: url) == original)
            #expect(try names(in: dir) == ["out.jpg"])
            let temp = try #require(staged)
            #expect(temp != url)
            #expect(!FileManager.default.fileExists(atPath: temp.path))
        }
    }

    @Test func failedCreationLeavesNothing() throws {
        try withFolder { dir in
            let url = dir.appendingPathComponent("new.jpg")
            #expect(throws: Injected.self) {
                try SafeWrite.write(Data("fresh".utf8), to: url) { data, temp in
                    try data.prefix(2).write(to: temp)
                    throw Injected()
                }
            }
            let left = try names(in: dir)
            #expect(left.isEmpty)
        }
    }

    /// A failure of the commit itself, not of the staging: the folder refuses
    /// the swap, and the file in it is as it was.
    @Test func failedCommitKeepsTheOriginal() throws {
        try withFolder { dir in
            let locked = dir.appendingPathComponent("locked")
            try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
            let url = locked.appendingPathComponent("out.jpg")
            let original = Data("original".utf8)
            try original.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
            #expect(throws: (any Error).self) {
                try SafeWrite.write(Data("replacement".utf8), to: url)
            }
            #expect(try Data(contentsOf: url) == original)
            #expect(try names(in: locked) == ["out.jpg"])
        }
    }

    // MARK: Create-only (review 2026-10-03, G2)

    /// What `OutputNaming.candidates` yields for an output called `out.jpg`.
    private func candidates(in dir: URL) -> [URL] {
        (["out.jpg"] + (2...20).map { "out_\($0).jpg" }).map { dir.appendingPathComponent($0) }
    }

    /// Another process takes the chosen name while the output is still being
    /// staged: its file keeps its bytes, and the output goes to the next name.
    @Test func createSkipsANameTakenAfterTheChoice() throws {
        try withFolder { dir in
            let urls = candidates(in: dir)
            let theirs = Data("theirs".utf8)
            let written = try SafeWrite.create(Data("ours".utf8), firstFreeOf: urls) { data, temp in
                try theirs.write(to: urls[0])
                try data.write(to: temp)
            }
            #expect(written == urls[1])
            #expect(try Data(contentsOf: urls[0]) == theirs)
            #expect(try Data(contentsOf: urls[1]) == Data("ours".utf8))
            #expect(try names(in: dir) == ["out.jpg", "out_2.jpg"])
        }
    }

    /// Writers that all chose the same name each keep their output, under a name of their own.
    @Test func concurrentCreatesKeepEveryOutput() throws {
        try withFolder { dir in
            let urls = candidates(in: dir)
            let results = Mutex<[Result<URL, any Error>]>([])
            DispatchQueue.concurrentPerform(iterations: 8) { i in
                let result = Result { try SafeWrite.create(Data("writer \(i)".utf8), firstFreeOf: urls) }
                results.withLock { $0.append(result) }
            }
            let written = try results.withLock { $0 }.map { try $0.get() }
            #expect(Set(written) == Set(urls.prefix(8)))
            let contents = try written.map { String(decoding: try Data(contentsOf: $0), as: UTF8.self) }
            #expect(Set(contents) == Set((0..<8).map { "writer \($0)" }))
            #expect(try names(in: dir) == urls.prefix(8).map(\.lastPathComponent).sorted())
        }
    }

    /// Nothing in the folder, and the staged copy, which lives elsewhere, is gone.
    @Test func failedCreateLeavesNothing() throws {
        try withFolder { dir in
            var staged: URL?
            #expect(throws: Injected.self) {
                try SafeWrite.create(Data("fresh".utf8), firstFreeOf: candidates(in: dir)) { data, temp in
                    staged = temp
                    try data.prefix(2).write(to: temp)
                    throw Injected()
                }
            }
            let left = try names(in: dir)
            #expect(left.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: try #require(staged).path))
        }
    }

    /// The folder refuses the new file: the error is the permission refusal
    /// `FolderAccess` asks for the folder on, and nothing is left behind.
    @Test func refusedCreateLeavesNothing() throws {
        try withFolder { dir in
            let locked = dir.appendingPathComponent("locked")
            try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
            let original = Data("original".utf8)
            try original.write(to: locked.appendingPathComponent("out.jpg"))
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
            var staged: URL?
            let error = #expect(throws: CocoaError.self) {
                try SafeWrite.create(Data("fresh".utf8), firstFreeOf: candidates(in: locked)) { data, temp in
                    staged = temp
                    try data.write(to: temp)
                }
            }
            #expect(error?.code == .fileWriteNoPermission)
            #expect(try Data(contentsOf: locked.appendingPathComponent("out.jpg")) == original)
            #expect(try names(in: locked) == ["out.jpg"])
            #expect(!FileManager.default.fileExists(atPath: try #require(staged).path))
        }
    }

    // MARK: Off the main actor (review 2026-10-03, #40)

    /// Queues a job on the main actor and waits for it. That fails when the
    /// caller is itself on the main actor, however its job was scheduled.
    private static func mainActorIsFree() -> Bool {
        let ran = DispatchSemaphore(value: 0)
        Task { @MainActor in ran.signal() }
        return ran.wait(timeout: .now() + 2) == .success
    }

    /// The test only awaits on the main actor, so the staging finds it free
    /// unless the write itself runs there.
    @MainActor @Test func detachedWriteLeavesTheMainActorFree() async throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("out.jpg")
        try await SafeWrite.writeDetached(Data("fresh".utf8), to: url) { data, temp in
            #expect(Self.mainActorIsFree())
            try data.write(to: temp)
        }
        #expect(try Data(contentsOf: url) == Data("fresh".utf8))
        #expect(try names(in: dir) == ["out.jpg"])
    }

    @MainActor @Test func detachedCreateLeavesTheMainActorFree() async throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try await SafeWrite.createDetached(Data("fresh".utf8), firstFreeOf: candidates(in: dir)) { data, temp in
            #expect(Self.mainActorIsFree())
            try data.write(to: temp)
        }
        #expect(url == dir.appendingPathComponent("out.jpg"))
        #expect(try Data(contentsOf: url) == Data("fresh".utf8))
        #expect(try names(in: dir) == ["out.jpg"])
    }

    /// A failure off the main actor still reaches the caller, which reports it.
    @Test func failedDetachedWriteKeepsTheOriginal() async throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("out.jpg")
        let original = Data("original".utf8)
        try original.write(to: url)
        await #expect(throws: Injected.self) {
            try await SafeWrite.writeDetached(Data("replacement".utf8), to: url) { data, temp in
                try data.prefix(data.count / 2).write(to: temp)
                throw Injected()
            }
        }
        #expect(try Data(contentsOf: url) == original)
        #expect(try names(in: dir) == ["out.jpg"])
    }

    @Test func failedDetachedCreateLeavesNothing() async throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let urls = candidates(in: dir)
        await #expect(throws: Injected.self) {
            try await SafeWrite.createDetached(Data("fresh".utf8), firstFreeOf: urls) { data, temp in
                try data.prefix(2).write(to: temp)
                throw Injected()
            }
        }
        #expect(try names(in: dir).isEmpty)
    }

    // MARK: Errors (#55)

    /// The folder is gone (renamed while its image was open), so the staging
    /// fails first: the error names the destination, not the staged file.
    @Test func failureNamesTheDestination() throws {
        try withFolder { dir in
            let url = dir.appendingPathComponent("gone/out.jpg")
            let errors = [
                #expect(throws: CocoaError.self) { try SafeWrite.write(Data("fresh".utf8), to: url) },
                #expect(throws: CocoaError.self) { try SafeWrite.create(Data("fresh".utf8), firstFreeOf: [url]) },
            ]
            for error in errors {
                #expect(error?.code == .fileNoSuchFile)
                #expect(error?.url == url)
                #expect(error?.filePath == url.path)
                #expect(error?.localizedDescription.contains("“out.jpg”") == true)
                #expect(error?.localizedDescription.contains(".tmp") == false)
            }
            let left = try names(in: dir)
            #expect(left.isEmpty)
        }
    }

    /// The staged copy is refused: the error keeps the code and the POSIX
    /// error under it, which `FolderAccess` asks for the folder on.
    @Test func refusedStagingKeepsTheCode() throws {
        try withFolder { dir in
            let url = dir.appendingPathComponent("out.jpg")
            let error = #expect(throws: CocoaError.self) {
                try SafeWrite.write(Data("fresh".utf8), to: url) { data, temp in
                    let folder = temp.deletingLastPathComponent()
                    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
                    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
                    try data.write(to: temp)
                }
            }
            #expect(error?.code == .fileWriteNoPermission)
            let underlying = error?.userInfo[NSUnderlyingErrorKey] as? NSError
            #expect(underlying?.domain == NSPOSIXErrorDomain)
            #expect(underlying?.code == Int(EACCES))
            #expect(error?.filePath == url.path)
            #expect(error?.localizedDescription.contains("“\(dir.lastPathComponent)”") == true)
            let left = try names(in: dir)
            #expect(left.isEmpty)
        }
    }
}
