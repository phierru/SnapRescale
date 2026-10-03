import Foundation
import Testing
@testable import RescaleKit

/// `{name}_{w}x{h}.{ext}` next to the original, then a counter (PRD §11).
/// Review 2026-10-03, G2: the silent save and the CLI take the first of the
/// candidates that is free when the file lands; Save As suggests the first
/// one free now.
@Suite struct OutputNamingTests {
    let spec = RenderSpec(target: PixelSize(32, 24), format: .png)

    @Test func candidatesCountUpFromTheBareName() throws {
        let source = try Fixture.load(.camera)
        let dir = URL(fileURLWithPath: "/tmp/out", isDirectory: true)
        let names = OutputNaming.candidates(for: source, spec: spec, in: dir).prefix(3).map(\.lastPathComponent)
        #expect(names == ["camera-exif-gps-thumbnail_32x24.png",
                          "camera-exif-gps-thumbnail_32x24_2.png",
                          "camera-exif-gps-thumbnail_32x24_3.png"])
        // Without a directory, next to the original.
        let first = try #require(OutputNaming.candidates(for: source, spec: spec).first { _ in true })
        #expect(first.deletingLastPathComponent() == source.url.deletingLastPathComponent())
    }

    /// The Save As suggestion skips names already taken.
    @Test func suggestionIsTheFirstFreeCandidate() throws {
        let source = try Fixture.load(.camera)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OutputNamingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(OutputNaming.url(for: source, spec: spec, in: dir).lastPathComponent
                == "camera-exif-gps-thumbnail_32x24.png")
        for name in ["camera-exif-gps-thumbnail_32x24.png", "camera-exif-gps-thumbnail_32x24_2.png"] {
            try Data().write(to: dir.appendingPathComponent(name))
        }
        #expect(OutputNaming.url(for: source, spec: spec, in: dir).lastPathComponent
                == "camera-exif-gps-thumbnail_32x24_3.png")
    }
}
