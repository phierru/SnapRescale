import Foundation
import Testing
@testable import RescaleKit

/// Replays every case in `Fixtures/solver-parity.json`, generated from the Python
/// prototype by `prototype/export_fixture.py`, and expects identical output.
/// This is the guarantee that the port is the same solver the PRD tables describe.
struct ParityTests {
    struct Fixture: Decodable {
        struct Case: Decodable {
            let source: [Int]
            let aspect: [Int]?
            let param: String
            let value: Double
            let multiple: Int
            let ideal: [Double]
            let result: [Int]

            var request: ResizeRequest {
                let aspect: AspectRatio = aspect.map { .fixed(width: $0[0], height: $0[1]) } ?? .original
                let size: SizeParameter
                switch param {
                case "width": size = .width(Int(value))
                case "height": size = .height(Int(value))
                case "megapixels": size = .megapixels(value)
                case "scale": size = .scale(value)
                default: fatalError("unknown param \(param)")
                }
                return ResizeRequest(aspect: aspect, size: size, multiple: Multiple(rawValue: multiple)!)
            }

            var label: String {
                "\(source[0])×\(source[1]) \(aspect.map { "\($0[0]):\($0[1])" } ?? "original") \(param)=\(value) ×\(multiple)"
            }
        }
        let cases: [Case]
    }

    static let fixture: Fixture = {
        let url = Bundle.module.url(forResource: "solver-parity", withExtension: "json", subdirectory: "Fixtures")!
        return try! JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }()

    @Test func fixtureIsSubstantial() {
        #expect(Self.fixture.cases.count > 5000)
    }

    @Test func everyCaseMatchesThePrototype() {
        var mismatches: [String] = []
        for c in Self.fixture.cases {
            let source = PixelSize(c.source[0], c.source[1])
            let s = c.request.solve(for: source)
            let expected = PixelSize(c.result[0], c.result[1])
            if s.size != expected {
                mismatches.append("\(c.label): got \(s.size), expected \(expected)")
            }
            #expect(abs(s.ideal.width - c.ideal[0]) < 1e-6, "\(c.label) ideal width")
            #expect(abs(s.ideal.height - c.ideal[1]) < 1e-6, "\(c.label) ideal height")
        }
        let report = "\(mismatches.count) mismatches:\n" + mismatches.prefix(20).joined(separator: "\n")
        #expect(mismatches.isEmpty, Comment(rawValue: report))
    }
}
