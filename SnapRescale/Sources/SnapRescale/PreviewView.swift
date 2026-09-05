import SwiftUI
import RescaleKit

/// The window's main content (PRD §7): the source with the surviving region
/// drawn over it, or the padded canvas with the source inset. Drag to reframe.
struct PreviewView: View {
    @Environment(Session.self) private var session
    @State private var dragStart: CropAnchor?

    var body: some View {
        GeometryReader { geo in
            if let source = session.source, let preview = session.previewImage, let solution = session.solution {
                let avail = geo.size
                ZStack(alignment: .topLeading) {
                    switch session.fit {
                    case .crop:
                        cropLayer(source: source.size, preview: preview, target: solution.size, avail: avail)
                    case .pad:
                        padLayer(source: source.size, preview: preview, target: solution.size, avail: avail)
                    case .stretch:
                        stretchLayer(preview: preview, target: solution.size, avail: avail)
                    }
                }
                .frame(width: avail.width, height: avail.height, alignment: .topLeading)
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .safeAreaInset(edge: .bottom, spacing: 8) { footer }
    }

    /// Under the image: what the frame keeps, and the composition-grid picker.
    private var footer: some View {
        @Bindable var session = session
        return HStack {
            caption
            Spacer()
            Picker("Grid", selection: $session.grid) {
                ForEach(CompositionGrid.allCases) { g in
                    g.icon.tag(g).help(g.label)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
            .help("Composition grid (display only)")
        }
    }

    // MARK: Layers

    private func cropLayer(source: PixelSize, preview: CGImage, target: PixelSize, avail: CGSize) -> some View {
        let frame = fitRect(aspect: source.aspectRatio, in: avail)
        let scale = frame.width / Double(source.width)
        let crop = Geometry.cropRect(source: source, target: target, anchor: session.anchor)
        let shown = CGRect(x: frame.minX + crop.minX * scale, y: frame.minY + crop.minY * scale,
                           width: crop.width * scale, height: crop.height * scale)
        let slackX = Double(source.width) - crop.width
        let slackY = Double(source.height) - crop.height

        return ZStack(alignment: .topLeading) {
            image(preview, in: frame)
            // Dim everything outside the surviving region.
            Path { p in
                p.addRect(frame)
                p.addRect(shown)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)
            Rectangle()
                .strokeBorder(.white, lineWidth: 1.5)
                .frame(width: shown.width, height: shown.height)
                .offset(x: shown.minX, y: shown.minY)
                .shadow(radius: 2)
                .allowsHitTesting(false)
            gridLines(in: shown)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { session.anchor = .center }
        .gesture(dragGesture(scale: scale, slackX: slackX, slackY: slackY, invert: false))
    }

    private func padLayer(source: PixelSize, preview: CGImage, target: PixelSize, avail: CGSize) -> some View {
        let canvas = fitRect(aspect: target.aspectRatio, in: avail)
        let scale = canvas.width / Double(target.width)
        let inset = Geometry.padRect(source: source, target: target, anchor: session.anchor)
        let shown = CGRect(x: canvas.minX + inset.minX * scale, y: canvas.minY + inset.minY * scale,
                           width: inset.width * scale, height: inset.height * scale)
        let slackX = Double(target.width) - inset.width
        let slackY = Double(target.height) - inset.height

        return ZStack(alignment: .topLeading) {
            ZStack {
                let c = session.padColor ?? .transparent
                if c.isTranslucent { Checkerboard() }
                Color(red: c.red, green: c.green, blue: c.blue, opacity: c.alpha)
            }
            .frame(width: canvas.width, height: canvas.height)
            .offset(x: canvas.minX, y: canvas.minY)
            image(preview, in: shown)
            Rectangle()
                .strokeBorder(.secondary, lineWidth: 1)
                .frame(width: canvas.width, height: canvas.height)
                .offset(x: canvas.minX, y: canvas.minY)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { session.anchor = .center }
        .gesture(dragGesture(scale: scale, slackX: slackX, slackY: slackY, invert: true))
    }

    private func stretchLayer(preview: CGImage, target: PixelSize, avail: CGSize) -> some View {
        let canvas = fitRect(aspect: target.aspectRatio, in: avail)
        return image(preview, in: canvas)
    }

    // MARK: Pieces

    private func image(_ cg: CGImage, in rect: CGRect) -> some View {
        Image(decorative: cg, scale: 1)
            .resizable()
            .interpolation(.high)
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
    }

    private func gridLines(in r: CGRect) -> some View {
        Path { p in
            for f in session.grid.fractions {
                let x = r.minX + r.width * f
                let y = r.minY + r.height * f
                p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY))
                p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y))
            }
        }
        .stroke(.white.opacity(0.4), lineWidth: 0.5)
        .allowsHitTesting(false)
    }

    /// Dragging moves the anchor. In crop mode the *window* moves with the
    /// pointer; in pad mode the *image* does, so the sign flips.
    private func dragGesture(scale: Double, slackX: Double, slackY: Double, invert: Bool) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                let start = dragStart ?? session.anchor
                dragStart = start
                let sign = invert ? 1.0 : 1.0
                let dx = v.translation.width / scale
                let dy = v.translation.height / scale
                let nx = slackX > 0 ? start.x + sign * dx / slackX : start.x
                let ny = slackY > 0 ? start.y + sign * dy / slackY : start.y
                session.anchor = CropAnchor(x: nx, y: ny)
            }
            .onEnded { _ in dragStart = nil }
    }

    private func fitRect(aspect: Double, in avail: CGSize) -> CGRect {
        let pad = 12.0
        let w = avail.width - 2 * pad, h = avail.height - 2 * pad
        var dw = w, dh = w / aspect
        if dh > h { dh = h; dw = h * aspect }
        return CGRect(x: (avail.width - dw) / 2, y: (avail.height - dh) / 2, width: dw, height: dh)
    }

    private var caption: some View {
        Group {
            if let source = session.source, let solution = session.solution {
                switch session.fit {
                case .crop where session.reframes || solution.isUpscale(from: source.size):
                    let crop = Geometry.cropRect(source: source.size, target: solution.size, anchor: session.anchor)
                    Text("Keeps \(PixelSize(Int(crop.width), Int(crop.height)).description) of \(source.size.description) · drag to reframe, double-click to centre")
                case .pad:
                    Text("Padded canvas \(solution.size.description) · drag to place, double-click to centre")
                case .stretch:
                    Text("Stretched to \(solution.size.description)")
                default:
                    Text("Whole image → \(solution.size.description)")
                }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let s = 10.0
            for y in stride(from: 0.0, to: size.height, by: s) {
                for x in stride(from: 0.0, to: size.width, by: s) {
                    let dark = (Int(x / s) + Int(y / s)) % 2 == 0
                    ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)),
                             with: .color(dark ? .gray.opacity(0.35) : .gray.opacity(0.15)))
                }
            }
        }
    }
}
