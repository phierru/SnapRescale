import AppKit
import SwiftUI

/// The overlay drawn inside the crop frame. Display only; never written to the file.
enum CompositionGrid: String, CaseIterable, Identifiable {
    case none, centre, thirds, golden, fifths

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "Frame only"
        case .centre: return "Centre lines"
        case .thirds: return "Rule of thirds"
        case .golden: return "Golden ratio"
        case .fifths: return "Rule of fifths"
        }
    }

    /// Line positions as fractions of the frame, used on both axes.
    var fractions: [Double] {
        switch self {
        case .none: return []
        case .centre: return [0.5]
        case .thirds: return [1.0 / 3, 2.0 / 3]
        case .golden: return [0.381_966, 0.618_034]     // 1/φ² and 1/φ
        case .fifths: return [0.2, 0.4, 0.6, 0.8]
        }
    }

    static let defaultsKey = "compositionGrid"

    static func loadPreference() -> CompositionGrid {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(CompositionGrid.init(rawValue:)) ?? .thirds
    }

    func savePreference() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
    }

    /// A template icon: the frame with this grid's lines, drawn at control size.
    var icon: Image {
        let size = NSSize(width: 22, height: 15)
        let image = NSImage(size: size, flipped: false) { rect in
            let inset = rect.insetBy(dx: 1, dy: 1)
            NSColor.black.setStroke()
            let frame = NSBezierPath(roundedRect: inset, xRadius: 1.5, yRadius: 1.5)
            frame.lineWidth = 1.2
            frame.stroke()
            let lines = NSBezierPath()
            lines.lineWidth = 0.8
            for f in self.fractions {
                let x = inset.minX + inset.width * f
                let y = inset.minY + inset.height * f
                lines.move(to: NSPoint(x: x, y: inset.minY)); lines.line(to: NSPoint(x: x, y: inset.maxY))
                lines.move(to: NSPoint(x: inset.minX, y: y)); lines.line(to: NSPoint(x: inset.maxX, y: y))
            }
            lines.stroke()
            return true
        }
        image.isTemplate = true
        return Image(nsImage: image)
    }
}
