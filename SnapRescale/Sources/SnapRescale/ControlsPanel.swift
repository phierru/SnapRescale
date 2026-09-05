import SwiftUI
import AppKit
import RescaleKit

struct ControlsPanel: View {
    @Environment(Session.self) private var session

    var body: some View {
        @Bindable var session = session
        Form {
            Section("Aspect ratio") {
                Picker("Aspect", selection: $session.aspect) {
                    ForEach(AspectRatio.all, id: \.self) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            Section("Size") {
                Picker("View", selection: Binding(
                    get: { session.sizeKind },
                    set: { session.switchSizeKind(to: $0) }
                )) {
                    ForEach(Session.SizeKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)

                HStack(spacing: 6) {
                    stepButton("minus", -1)
                    TextField("", value: $session.sizeValue, format: .number.precision(.fractionLength(0...2)).grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(maxWidth: .infinity)
                    Text(unit).foregroundStyle(.secondary).frame(width: 28, alignment: .leading)
                    stepButton("plus", 1)
                }

                ladderRow

                readouts

                LabeledContent("Fit") {
                    HStack(spacing: 8) {
                        Picker("", selection: $session.fit) {
                            Text("Crop").tag(FitPolicy.crop)
                            Text("Pad").tag(FitPolicy.pad)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        PaddingWell()
                            .disabled(session.fit != .pad)
                            .opacity(session.fit == .pad ? 1 : 0.4)
                            .help("Padding colour; opacity 0 is transparent")
                    }
                }

                Picker("Multiple of", selection: $session.multiple) {
                    ForEach(Multiple.allCases, id: \.self) { Text("\($0.rawValue)").tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section("Format") {
                Picker("Format", selection: $session.format) {
                    ForEach(OutputFormat.allCases, id: \.self) { f in
                        Text(f == .keepOriginal ? "Keep original (\(keptExtension))" : f.label).tag(f)
                    }
                }
                if let src = session.source, session.format.isLossy(for: src.type) {
                    LabeledContent("Quality") {
                        HStack {
                            Slider(value: $session.quality, in: 0.1...1, step: 0.05)
                            Text("\(Int((session.quality * 100).rounded()))").monospacedDigit().frame(width: 28, alignment: .trailing)
                        }
                    }
                }
            }

            Section("Output") {
                if let solution = session.solution, let src = session.source {
                    LabeledContent("Size") {
                        Text("\(solution.size.description) · \(solution.megapixels, format: .number.precision(.fractionLength(2))) MP")
                            .monospacedDigit()
                    }
                    LabeledContent("File") {
                        HStack(spacing: 6) {
                            if let bytes = session.outputBytes {
                                Text(Int64(bytes), format: .byteCount(style: .file)).monospacedDigit()
                                    .opacity(session.isEncoding ? 0.5 : 1)
                            } else {
                                Text("—")
                            }
                            if session.isEncoding { ProgressView().controlSize(.mini) }
                            Text(keptExtension).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(notes(solution: solution, source: src), id: \.self) { note in
                        Label(note.text, systemImage: note.warning ? "exclamationmark.triangle" : "info.circle")
                            .foregroundStyle(note.warning ? .orange : .secondary)
                            .font(.callout)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 4) {
                HStack {
                    Button("Save As…") { session.saveAs() }
                    Spacer()
                    Button("Save") { session.save() }
                        .buttonStyle(.borderedProminent)
                }
                if let saved = session.lastSaved {
                    Text("Saved \(saved.lastPathComponent)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(.bar)
        }
    }

    // MARK: Pieces

    private var unit: String {
        switch session.sizeKind {
        case .width, .height: return "px"
        case .megapixels: return "MP"
        case .scale: return "%"
        }
    }

    private var keptExtension: String {
        guard let src = session.source else { return "" }
        return (session.format.resolvedType(for: src.type).preferredFilenameExtension ?? "").uppercased()
    }

    private func stepButton(_ icon: String, _ direction: Int) -> some View {
        Button {
            let big = NSEvent.modifierFlags.contains(.shift)
            session.step(direction, big: big)
        } label: {
            Image(systemName: icon)
                .font(.body.weight(.medium))
                .frame(width: 16, height: 16)
        }
        .help(session.sizeKind == .width || session.sizeKind == .height
              ? "Step by the multiple (\(session.multiple.rawValue)); ⇧ for ×10"
              : "Nudge; ⇧ for ×10")
    }

    /// The four views of the number on one line. The one being edited reads
    /// normally; the solver's three read dimmed (PRD §5).
    private var readouts: some View {
        Group {
            if let s = session.solution, let src = session.source {
                HStack(spacing: 0) {
                    readout("W", "\(s.width)", pinned: session.sizeKind == .width)
                    Spacer()
                    readout("H", "\(s.height)", pinned: session.sizeKind == .height)
                    Spacer()
                    readout("MP", String(format: "%.2f", s.megapixels), pinned: session.sizeKind == .megapixels)
                    Spacer()
                    readout("%", String(format: "%.1f", s.scale(relativeTo: src.size) * 100), pinned: session.sizeKind == .scale)
                }
                .font(.callout.monospacedDigit())
                .padding(.horizontal, 4)
            }
        }
    }

    private func readout(_ label: String, _ value: String, pinned: Bool) -> some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(.tertiary)
            Text(value).foregroundStyle(pinned ? .primary : .secondary).fontWeight(pinned ? .semibold : .regular)
        }
    }

    /// Quick picks under the field, as a segmented control like the view picker:
    /// 512 · 768 · 1024 · 1536 · 2048 for pixels, their own ladders for
    /// megapixels and scale. No segment is lit when the value is off the ladder.
    private var ladderRow: some View {
        Picker("", selection: Binding<Double>(
            get: { session.ladder.first { abs(session.sizeValue - $0) < 0.001 } ?? -1 },
            set: { if $0 > 0 { session.sizeValue = $0 } }
        )) {
            ForEach(session.ladder, id: \.self) { v in
                Text(session.ladderLabel(v)).tag(v)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
    }

    struct Note: Hashable { let text: String; let warning: Bool }

    private func notes(solution s: Solution, source src: SourceImage) -> [Note] {
        var out: [Note] = []
        for a in s.adjustments {
            switch a {
            case let .pinnedValueSnapped(axis, requested, actual):
                out.append(Note(text: "\(axis == .width ? "Width" : "Height") \(requested) is not a multiple of \(session.multiple.rawValue); using \(actual).", warning: false))
            case let .derivedAxisForced(axis, ideal, actual):
                out.append(Note(text: "\(session.aspect.label) wants \(axis == .width ? "width" : "height") \(ideal); the multiple of \(session.multiple.rawValue) forces \(actual).", warning: false))
            }
        }
        if session.reframes {
            switch session.fit {
            case .crop:
                let d = Geometry.discardedFraction(source: src.size, target: s.size, anchor: session.anchor)
                out.append(Note(text: String(format: "Crops %.0f%% of the image.", d * 100), warning: d > 0.4))
            case .pad:
                let p = Geometry.paddedFraction(source: src.size, target: s.size)
                out.append(Note(text: String(format: "%.0f%% of the canvas is padding.", p * 100), warning: false))
                if session.padColor.map(\.isTranslucent) ?? true, !session.format.supportsAlpha(for: src.type) {
                    out.append(Note(text: "\(keptExtension) has no alpha channel; transparent padding will be composited on white.", warning: true))
                }
            case .stretch:
                break
            }
        }
        if s.isUpscale(from: src.size, fit: session.fit) {
            out.append(Note(text: String(format: "Upscales the source by %.0f%%.", (s.resampleScale(from: src.size, fit: session.fit) - 1) * 100), warning: true))
        }
        return out
    }
}

/// The padding colour well. Opens the system colour panel (with eyedropper);
/// opacity is allowed, and 0 means transparent padding.
struct PaddingWell: View {
    @Environment(Session.self) private var session

    private var color: Binding<Color> {
        Binding(
            get: {
                let c = session.padColor ?? .transparent
                return Color(red: c.red, green: c.green, blue: c.blue, opacity: c.alpha)
            },
            set: { new in
                guard let ns = NSColor(new).usingColorSpace(.sRGB) else { return }
                session.padColor = PadColor(red: ns.redComponent, green: ns.greenComponent,
                                            blue: ns.blueComponent, alpha: ns.alphaComponent)
            }
        )
    }

    var body: some View {
        ColorPicker("", selection: color, supportsOpacity: true)
            .labelsHidden()
    }
}
