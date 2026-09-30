import Foundation
import Testing
@testable import RescaleKit

/// Review 2026-09-30, G1: a failed save must not cost the file it replaces.
@Suite struct SafeWriteTests {
    struct Injected: Error {}

    /// A disposable folder, removed when the test ends.
    private func withFolder(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SafeWriteTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
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
}
