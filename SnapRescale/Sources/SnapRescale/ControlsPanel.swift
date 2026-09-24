import SwiftUI
import AppKit
import RescaleKit

/// macOS 27 lays a grouped Form (any SwiftUI scroll container) out 430 pt wide
/// for one pass when its state changes *inside* a mouse event on one of its
/// controls, overflowing the 340 pt sidebar until the next update (GitHub #2).
/// The same change made a run-loop turn later is laid out correctly, so every
/// control in the panel writes through here.
@MainActor func deferred(_ work: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async { work() }
}

/// Carries a non-Sendable value across `DispatchQueue.main.async`; both ends run on the main thread.
private final class MainThreadBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

extension Binding {
    /// Writes on the next run-loop turn; see `deferred(_:)`.
    var deferred: Binding<Value> {
        Binding(get: { wrappedValue }, set: { new in
            let box = MainThreadBox((self, new))
            DispatchQueue.main.async { box.value.0.wrappedValue = box.value.1 }
        })
    }
}

struct ControlsPanel: View {
    @Environment(Session.self) private var session

    var body: some View {
        @Bindable var session = session
        Form {
            Section {
                PresetRow()
                LabeledContent("Aspect ratio") { aspectMenu }
            }

            Section("Size") {
                Picker("View", selection: Binding(
                    get: { session.sizeKind },
                    set: { kind in deferred { session.switchSizeKind(to: kind) } }
                )) {
                    ForEach(Session.SizeKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)

                HStack(spacing: 6) {
                    stepButton("minus", -1)
                    Spacer()
                    TextField("", value: $session.sizeValue.deferred, format: .number.precision(.fractionLength(0...2)).grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 110)
                    Text(unit).foregroundStyle(.secondary).frame(width: 28, alignment: .leading)
                    Spacer()
                    stepButton("plus", 1)
                }

                ladderRow

                LabeledContent("Fit") {
                    HStack(spacing: 8) {
                        Picker("", selection: $session.fit.deferred) {
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

                LabeledContent("Multiple of") {
                    HStack(spacing: 6) {
                        Picker("", selection: $session.multiple.deferred) {
                            ForEach(Multiple.allCases, id: \.self) { Text("\($0.rawValue)").tag($0) }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        Text("px").foregroundStyle(.secondary).padding(.trailing, 4)   // optical: the well above has no cap
                    }
                }

                readouts
            }

            Section("Format") {
                Picker("Format", selection: $session.format.deferred) {
                    ForEach(OutputFormat.allCases, id: \.self) { f in
                        if f == .keepOriginal {
                            let ok = session.source.map { f.isAvailable(for: $0.type) } ?? true
                            Text(ok ? "Keep original (\(sourceExtension))" : "Keep original (\(sourceExtension) not writable)")
                                .tag(f)
                                .selectionDisabled(!ok)
                        } else {
                            Text(f.label).tag(f)
                        }
                    }
                }
                if let src = session.source, session.format.isLossy(for: src.type) {
                    LabeledContent("Quality") {
                        HStack {
                            Slider(value: $session.quality.deferred, in: 0.1...1, step: 0.05)
                            Text("\(Preset.percent(session.quality))").monospacedDigit().frame(width: 28, alignment: .trailing)
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
                            ProgressView()
                                .controlSize(.mini)
                                .opacity(session.isEncoding ? 1 : 0)
                            if let bytes = session.outputBytes {
                                Text(Int64(bytes), format: .byteCount(style: .file)).monospacedDigit()
                                    .opacity(session.isEncoding ? 0.5 : 1)
                            } else {
                                Text("—")
                            }
                            Text(keptExtension).foregroundStyle(.secondary)
                        }
                        .frame(height: 20)
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
        // Pins the Preset row's height whether or not the panel scrolls (the
        // grouped style otherwise moves it), and pulls it up over the style's
        // built-in top spacing so it centres on the header row (GitHub #3).
        .contentMargins(.top, -15, for: .scrollContent)
        .onChange(of: session.spec) { session.noteSettingsChanged() }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 4) {
                HStack {
                    if session.saveWithoutAsking {
                        Button(session.quitsAfterSave ? "Save As & Quit…" : "Save As…") { deferred { session.saveAs() } }
                            .disabled(!session.canSave)
                    }
                    Spacer()
                    if session.isSaving { ProgressView().controlSize(.small) }
                    Button(saveTitle) { deferred { session.save() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!session.canSave)
                        .help(session.saveWithoutAsking
                              ? "Writes next to the original without asking (Settings)"
                              : "Opens the save panel, pre-filled with the suggested name")
                }
            }
            .padding(12)
            .background(.bar)
        }
    }

    // MARK: Pieces

    /// Same borderless drop-down as the preset row above it (GitHub #4).
    private var aspectMenu: some View {
        Menu {
            ForEach(AspectRatio.all, id: \.self) { a in
                Button {
                    deferred { session.aspect = a }
                } label: {
                    if a == session.aspect {
                        Label(a.displayName, systemImage: "checkmark")
                    } else {
                        Text(a.displayName)
                    }
                }
            }
        } label: {
            Text(session.aspect.displayName)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var saveTitle: String {
        switch (session.saveWithoutAsking, session.quitsAfterSave) {
        case (true, true): return "Save & Quit"
        case (true, false): return "Save"
        case (false, true): return "Save & Quit…"
        case (false, false): return "Save…"
        }
    }

    private var unit: String {
        switch session.sizeKind {
        case .width, .height: return "px"
        case .megapixels: return "MP"
        case .scale: return "%"
        }
    }

    private var keptExtension: String {
        guard let src = session.source else { return "" }
        return (session.format.resolvedType(for: src.type)?.preferredFilenameExtension ?? "").uppercased()
    }

    private var sourceExtension: String {
        (session.source?.type.preferredFilenameExtension ?? "").uppercased()
    }

    private func stepButton(_ icon: String, _ direction: Int) -> some View {
        Button {
            let big = NSEvent.modifierFlags.contains(.shift)
            deferred { session.step(direction, big: big) }
        } label: {
            Image(systemName: icon)
                .font(.body.weight(.medium))
                .frame(width: 16, height: 16)
        }
        .help(session.sizeKind == .width || session.sizeKind == .height
              ? "Step by the multiple (\(session.multiple.rawValue)); ⇧ for ×10"
              : "Nudge; ⇧ for ×10")
    }

    /// The solved size, last in the Size card (GitHub #6): the four views of the
    /// number on one line. The one being edited reads normally; the solver's
    /// three read dimmed (PRD §5).
    private var readouts: some View {
        Group {
            if let s = session.solution, let src = session.source {
                // A plain HStack, not LabeledContent: that would stack the
                // values under the label when the row gets tight.
                HStack(spacing: 8) {
                    Text("Result")
                    Spacer(minLength: 6)
                    readout("W", "\(s.width)", pinned: session.sizeKind == .width)
                    readout("H", "\(s.height)", pinned: session.sizeKind == .height)
                    readout("MP", String(format: "%.2f", s.megapixels), pinned: session.sizeKind == .megapixels)
                    readout("%", String(format: "%.1f", s.scale(relativeTo: src.size) * 100), pinned: session.sizeKind == .scale)
                        .padding(.trailing, 4)
                }
                .font(.callout.monospacedDigit())
            }
        }
    }

    private func readout(_ label: String, _ value: String, pinned: Bool) -> some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(.tertiary)
            Text(value).foregroundStyle(pinned ? .primary : .secondary).fontWeight(pinned ? .semibold : .regular)
        }
        .lineLimit(1)
        .fixedSize()
    }

    /// Quick picks under the field, as a segmented control like the view picker:
    /// 512 · 768 · 1024 · 1536 · 2048 for pixels, their own ladders for
    /// megapixels and scale. No segment is lit when the value is off the ladder.
    private var ladderRow: some View {
        Picker("", selection: Binding<Double>(
            get: { session.ladder.first { abs(session.sizeValue - $0) < 0.001 } ?? -1 },
            set: { v in if v > 0 { deferred { session.sizeValue = v } } }
        )) {
            ForEach(session.ladder, id: \.self) { v in
                Text(session.ladderLabel(v)).tag(v)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(maxWidth: .infinity)
    }

    struct Note: Hashable { let text: String; let warning: Bool }

    private func notes(solution s: Solution, source src: SourceImage) -> [Note] {
        var out: [Note] = []
        if let problem = session.sizeProblem {
            out.append(Note(text: problem + " Using the nearest legal value.", warning: true))
        }
        if let f = session.formatNote {
            out.append(Note(text: f, warning: true))
        }
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
                if let spec = session.spec, session.padColor.map(\.isTranslucent) ?? true, !spec.padNeedsAlpha(sourceType: src.type) {
                    out.append(Note(text: "\(keptExtension) has no alpha channel; translucent padding is composited on white, as previewed.", warning: true))
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
                let color = PadColor(red: ns.redComponent, green: ns.greenComponent,
                                     blue: ns.blueComponent, alpha: ns.alphaComponent)
                deferred { session.padColor = color }
            }
        )
    }

    var body: some View {
        ColorPicker("", selection: color, supportsOpacity: true)
            .labelsHidden()
    }
}

/// Preset menu at the top of the panel: pick one, save the current settings as
/// one, or delete the active one. Any edit afterwards shows "Custom".
struct PresetRow: View {
    @Environment(Session.self) private var session
    @State private var namingSheet = false
    @State private var newName = ""

    var body: some View {
        LabeledContent("Preset") {
            menu
        }
        .sheet(isPresented: $namingSheet) { namingView }
    }

    private var menu: some View {
        Menu {
            ForEach(session.presets.presets) { p in
                Button {
                    deferred { session.apply(p) }
                } label: {
                    if session.activePreset == p.name {
                        Label(p.name, systemImage: "checkmark")
                    } else {
                        Text(p.name)
                    }
                }
                .help(p.summary)
            }
            Divider()
            Button("Save Current as Preset…") { newName = session.activePreset ?? ""; namingSheet = true }
                .disabled(session.source == nil)
            if let name = session.activePreset {
                Button("Delete “\(name)”") { deferred { session.presets.delete(named: name); session.noteSettingsChanged() } }
            }
            if !session.presets.problems.isEmpty {
                Divider()
                ForEach(session.presets.problems, id: \.self) { problem in
                    Button("Skipped: \(problem)") {}.disabled(true)
                }
            }
            Button("Show Presets Folder in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([session.presets.directory])
            }
        } label: {
            Text(session.activePreset ?? "Custom")
                .foregroundStyle(session.activePreset == nil ? .secondary : .primary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var namingView: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text("Save Preset").font(.headline)
                TextField("Name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                    .onSubmit(saveNamed)
                Text(session.currentPreset(named: newName.isEmpty ? "Preset" : newName).summary)
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel") { namingSheet = false }.keyboardShortcut(.cancelAction)
                    Button("Save", action: saveNamed).keyboardShortcut(.defaultAction)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(20)
    }

    private func saveNamed() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        do {
            try session.presets.save(session.currentPreset(named: name))
            session.apply(session.presets.presets.first { $0.name == name }!)
            namingSheet = false
        } catch {
            session.errorMessage = error.localizedDescription
        }
    }
}
