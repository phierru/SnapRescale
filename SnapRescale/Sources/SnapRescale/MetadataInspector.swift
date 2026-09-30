import SwiftUI
import AppKit
import RescaleKit

/// UI state of the metadata inspector (PRD §10.2): open or closed, which
/// sections are collapsed, and where a badge click wants it scrolled. Kept out
/// of `Session` because none of it changes what Save writes.
@MainActor @Observable
final class InspectorState {
    static let shared = InspectorState()

    /// A badge click: scroll to `kind`. The serial makes a repeated click on the same badge count.
    struct ScrollRequest: Equatable {
        let kind: MetadataSection.Kind
        let serial: Int
    }

    /// `--inspector` opens it at launch, for screenshots and tests.
    var isPresented = CommandLine.arguments.contains("--inspector")
    /// Sections start expanded; the set holds the ones the user closed.
    private(set) var collapsed: Set<MetadataSection.Kind> = []
    /// A section that starts folded (a colour profile that is not in the file) is
    /// held here once the user opens it.
    private(set) var opened: Set<MetadataSection.Kind> = []
    /// Sections whose secondary fields are shown; they start behind the More row.
    private(set) var showsMore: Set<MetadataSection.Kind> = []
    private(set) var scrollRequest: ScrollRequest?

    func isExpanded(_ kind: MetadataSection.Kind, startsCollapsed: Bool = false) -> Bool {
        startsCollapsed ? opened.contains(kind) : !collapsed.contains(kind)
    }

    // Everything below is called from a click or a menu command, so it writes a
    // run-loop turn later (GitHub #2, see Deferred.swift).

    func toggle() {
        deferred {
            self.scrollRequest = nil
            self.isPresented.toggle()
        }
    }

    func toggleSection(_ kind: MetadataSection.Kind, startsCollapsed: Bool = false) {
        deferred {
            if startsCollapsed {
                self.opened.formSymmetricDifference([kind])
            } else {
                self.collapsed.formSymmetricDifference([kind])
            }
        }
    }

    func toggleMore(_ kind: MetadataSection.Kind) {
        deferred { self.showsMore.formSymmetricDifference([kind]) }
    }

    /// Opens the inspector with `kind` expanded and scrolled to the top.
    func reveal(_ kind: MetadataSection.Kind) {
        deferred {
            self.collapsed.remove(kind)
            self.opened.insert(kind)
            self.scrollRequest = ScrollRequest(kind: kind, serial: (self.scrollRequest?.serial ?? 0) + 1)
            self.isPresented = true
        }
    }
}

extension ImageMetadata.Badge {
    /// The inspector section a badge opens (PRD §10.1).
    var section: MetadataSection.Kind {
        switch label {
        case "ICC": return .icc
        case "EXIF": return .exif
        case "GPS": return .gps
        case "IPTC": return .iptc
        case "XMP": return .xmp
        case "C2PA": return .c2pa
        // The other provenance badges are AI sources; what is left describes the pixels.
        default: return tone == .provenance ? .aiWorkflow : .structure
        }
    }
}

extension MetadataSection.Kind {
    /// The switch of a section; C2PA and Structure have none (PRD §10.2).
    var policySection: MetadataPolicy.Section? {
        switch self {
        case .exif: return .exif
        case .gps: return .gps
        case .iptc: return .iptc
        case .xmp: return .xmp
        case .icc: return .icc
        case .aiWorkflow: return .aiWorkflow
        case .c2pa, .structure: return nil
        }
    }
}

/// The trailing panel: one collapsible section per block the source carries,
/// in the kit's order, each with its keep / strip switch (PRD §10.2). Nothing
/// is edited. Deliberately not a grouped Form (GitHub #2).
struct MetadataInspector: View {
    @Environment(Session.self) private var session
    @State private var state = InspectorState.shared
    @State private var details = AIDetails()
    /// Copy All has just run: its menu shows a tick for a moment.
    @State private var copiedAll = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let src = session.source {
                sections(src.metadata.sections, of: src)
                    .id(src.url)   // a replaced image starts scrolled to the top, long values folded
            } else {
                emptyState
            }
        }
    }

    // MARK: Header slots

    /// Trailing side of the panel header: the master control. It shows the
    /// state of the policy — Default · Keep all · Strip all · Custom — and sets
    /// every switch at once; Custom is only ever a result, so it cannot be chosen.
    private var panelAccessory: some View {
        let current = session.metadataPolicy.summary
        return Menu {
            // A picker, so the menu ticks the current item itself. The write goes
            // a run-loop turn later (GitHub #2, see Deferred.swift).
            Picker("Metadata policy", selection: Binding(
                get: { session.metadataPolicy.summary },
                set: { choice in deferred { session.metadataPolicy = choice.policy ?? session.metadataPolicy } }
            )) {
                ForEach([MetadataPolicy.Summary.default, .keepAll, .stripAll], id: \.self) { choice in
                    Text(choice.label).tag(choice)
                }
                if current == .custom {
                    Divider()
                    Text(current.label).tag(current).selectionDisabled()
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(current.label).foregroundStyle(current == .custom ? .secondary : .primary)
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
        .help("\(session.metadataPolicy.summaryLine). Sets every section at once.")
        .accessibilityLabel("Metadata policy")
    }

    /// Before the master control: Copy All and Export All… (PRD §10.5). Read-only,
    /// so they work whatever the switches say.
    private var panelActions: some View {
        Menu {
            Button("Copy All") {
                guard let source = session.source else { return }
                Pasteboard.copy(source.metadata.copyAllText)
                // A run-loop turn later (GitHub #2, see Deferred.swift).
                deferred { copiedAll = true }
                Task { @MainActor in
                    try? await Task.sleep(for: CopyButton.feedback)
                    copiedAll = false
                }
            }
            Button("Export All…") {
                if let source = session.source { save(source.exportAll) }
            }
        } label: {
            // A menu label takes one image, so the symbol is swapped; both are
            // the same circle, and the frame below keeps the room fixed anyway.
            Image(systemName: copiedAll ? "checkmark.circle" : "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 22, height: 22)
        .disabled(session.source == nil)
        .help("Copy every section as text, or export them all as one JSON file")
        .accessibilityLabel("Copy or export all metadata")
    }

    /// Trailing side of a section title, one fixed-size control after another:
    /// the keep / strip switch, the AI workflow's Copy Prompt and Export…, then
    /// Copy, which every section has. Icons, so that all of it fits on the
    /// title's row at the panel's width.
    private func sectionControls(_ section: MetadataSection, _ state: MetadataPolicy.SwitchState?,
                                 _ source: SourceImage) -> some View {
        HStack(spacing: 6) {
            if let policySection = section.kind.policySection {
                SectionSwitch(section: policySection, isEnabled: state?.isEnabled ?? true)
            }
            if section.kind == .aiWorkflow {
                let ai = details.of(source)
                if let prompt = ai.prompt {
                    CopyButton(symbol: "text.quote", help: "Copy the positive prompt") { prompt }
                }
                exportControl(ai.exports, primary: ai.primaryExport)
            }
            CopyButton(help: "Copy \(section.title) as text") { copyText(section, source) }
        }
    }

    /// Export…: a button for one file, a menu when the source holds several
    /// (a ComfyUI `workflow` and its `prompt`), the one to prefer first.
    @ViewBuilder private func exportControl(_ exports: [MetadataExport], primary: MetadataExport?) -> some View {
        if let primary {
            Group {
                if exports.count > 1 {
                    Menu {
                        ForEach([primary] + exports.filter { $0 != primary }) { export in
                            Button(export.filename) { save(export) }
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                } else {
                    Button { save(primary) } label: {
                        Image(systemName: "square.and.arrow.up")
                            .frame(minWidth: 18, minHeight: 18)
                            .contentShape(Rectangle())
                    }
                }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .fixedSize()
            .help(exports.count > 1 ? "Export… — save a workflow payload as a file" : "Export… — save \(primary.filename)")
            .accessibilityLabel("Export…")
        }
    }

    /// What Copy puts on the pasteboard for a section: its `Label: value` lines,
    /// under the summary for the AI workflow.
    private func copyText(_ section: MetadataSection, _ source: SourceImage) -> String {
        let summary = section.kind == .aiWorkflow ? source.metadata.aiSummaryText : ""
        return summary.isEmpty ? section.text : summary + "\n" + section.text
    }

    /// Asks where, then writes there and nowhere else: under the sandbox the
    /// panel's URL is the only place the app may write to. The panel opens a
    /// run-loop turn after the click (GitHub #2, see Deferred.swift).
    private func save(_ export: MetadataExport) {
        let folder = session.source?.url.deletingLastPathComponent()
        deferred {
            let panel = NSSavePanel()
            panel.directoryURL = folder
            panel.nameFieldStringValue = export.filename
            panel.allowedContentTypes = [export.type]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try export.data.write(to: url)
            } catch {
                session.errorMessage = error.localizedDescription
            }
        }
    }

    /// A colour profile that is not in the file has nothing to read: its section
    /// starts folded, under the note that says so.
    private func startsCollapsed(_ section: MetadataSection, _ source: SourceImage) -> Bool {
        section.kind == .icc && !source.metadata.iccIsEmbedded
    }

    /// Whether the chosen output format can carry a section of this source, and
    /// the note to show under its title. Recomputed with the spec, so a change
    /// of format updates the switches at once.
    private func switchState(_ kind: MetadataSection.Kind, _ source: SourceImage) -> MetadataPolicy.SwitchState? {
        guard let section = kind.policySection else { return nil }
        // No solution yet: the size does not matter here, the format and policy do.
        let spec = session.spec ?? RenderSpec(target: source.size, format: session.format, metadata: session.metadataPolicy)
        return MetadataPolicy.switchState(of: section, for: source, spec: spec)
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 8) {
            Text("Metadata").font(.headline)
            Spacer()
            panelActions
            panelAccessory
            // `toggle()` writes a run-loop turn later (GitHub #2).
            Button { state.toggle() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close the metadata inspector (⌥⌘I)")
            .accessibilityLabel("Close metadata inspector")
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No image").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
            Text("Open an image to see what it carries.").font(.caption).foregroundStyle(.tertiary)
        }
        .multilineTextAlignment(.center)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sections(_ sections: [MetadataSection], of source: SourceImage) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(sections) { section in
                        let switchState = switchState(section.kind, source)
                        let startsCollapsed = startsCollapsed(section, source)
                        InspectorSection(section: section,
                                         summary: section.kind == .aiWorkflow ? details.of(source).summary : [],
                                         isExpanded: state.isExpanded(section.kind, startsCollapsed: startsCollapsed),
                                         showsMore: state.showsMore.contains(section.kind),
                                         switchState: switchState,
                                         toggle: { state.toggleSection(section.kind, startsCollapsed: startsCollapsed) },
                                         toggleMore: { state.toggleMore(section.kind) }) {
                            sectionControls(section, switchState, source)
                        }
                        .id(section.kind)
                        Divider()
                    }
                }
            }
            // `initial` covers the click that opens the panel: the request is already set when this appears.
            .onChange(of: state.scrollRequest, initial: true) { _, request in
                guard let request else { return }
                Task { @MainActor in
                    // Let the section expand and lay out first, or the target offset is stale.
                    try? await Task.sleep(for: .milliseconds(50))
                    proxy.scrollTo(request.kind, anchor: .top)
                }
            }
        }
    }
}

/// What the AI workflow section reads off the payloads. Parsing a graph is not
/// free, so it is done once per image and not on every redraw.
@MainActor private final class AIDetails {
    struct Value {
        var summary: [MetadataField] = []
        var prompt: String?
        var exports: [MetadataExport] = []
        var primaryExport: MetadataExport?
    }

    private var metadata: ImageMetadata?
    private var value = Value()

    func of(_ source: SourceImage) -> Value {
        if metadata != source.metadata {
            metadata = source.metadata
            value = Value(summary: source.metadata.aiSummary, prompt: source.metadata.positivePrompt,
                          exports: source.aiExports, primaryExport: source.primaryAIExport)
        }
        return value
    }
}

enum Pasteboard {
    /// Plain text, replacing what was there.
    @MainActor static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Copies text and says so: the icon turns into a tick for a moment. Both states are laid out, so nothing moves.
private struct CopyButton: View {
    static let feedback = Duration.milliseconds(1200)

    var symbol = "doc.on.doc"
    let help: String
    /// Built on the click, not on every redraw: a section's text can be a whole workflow.
    let text: () -> String
    @State private var copied = false

    var body: some View {
        Button {
            Pasteboard.copy(text())
            // A run-loop turn later (GitHub #2, see Deferred.swift).
            deferred { copied = true }
            Task { @MainActor in
                try? await Task.sleep(for: Self.feedback)
                copied = false
            }
        } label: {
            ZStack {
                Image(systemName: symbol).opacity(copied ? 0 : 1)
                Image(systemName: "checkmark").opacity(copied ? 1 : 0)
            }
            .frame(minWidth: 18, minHeight: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .fixedSize()
        .help(help)
        .accessibilityLabel(help)
    }
}

extension MetadataPolicy.Summary {
    /// The policy a master-control choice sets; `custom` sets nothing.
    var policy: MetadataPolicy? {
        switch self {
        case .default: return .default
        case .keepAll: return .keepAll
        case .stripAll: return .stripAll
        case .custom: return nil
        }
    }
}

/// The switch in a section title: keep · strip, or keep · sRGB · strip for
/// the colour profile. The app's segmented control, one size down. It reads and
/// writes the session's policy, which a new image resets to the default.
private struct SectionSwitch: View {
    @Environment(Session.self) private var session
    let section: MetadataPolicy.Section
    let isEnabled: Bool

    var body: some View {
        // Every write goes a run-loop turn later (GitHub #2, see Deferred.swift).
        Group {
            if section == .icc {
                Picker(section.label, selection: Binding(
                    get: { session.metadataPolicy.icc },
                    set: { new in deferred { session.metadataPolicy.icc = new } }
                )) {
                    Text("Keep").tag(MetadataPolicy.ICC.preserve)
                    Text("sRGB").tag(MetadataPolicy.ICC.convertToSRGB)
                    Text("Strip").tag(MetadataPolicy.ICC.strip)
                }
                .help("Preserve the source's colour profile, convert the pixels to sRGB, or write no profile")
            } else {
                Picker(section.label, selection: Binding(
                    get: { session.metadataPolicy[section] },
                    set: { new in deferred { session.metadataPolicy[section] = new } }
                )) {
                    Text("Keep").tag(MetadataPolicy.Action.keep)
                    Text("Strip").tag(MetadataPolicy.Action.strip)
                }
                .help("Keep or strip \(section.label) when saving")
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(.small)
        .fixedSize()
        .disabled(!isEnabled)
    }
}

/// A section: a title row that folds it, with its switch and buttons trailing, the
/// lines for the section's own note and the switch's, then its rows: the AI
/// summary, the primary fields, and the rest behind a More row.
private struct InspectorSection<Controls: View>: View {
    let section: MetadataSection
    /// The AI workflow summary, shown above the fields; empty for the other sections.
    let summary: [MetadataField]
    let isExpanded: Bool
    let showsMore: Bool
    /// `nil` for the sections without a switch.
    let switchState: MetadataPolicy.SwitchState?
    let toggle: () -> Void
    let toggleMore: () -> Void
    @ViewBuilder let controls: Controls

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button(action: toggle) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 10)
                        // One line always: the row is 30 pt whatever sits beside the title.
                        Text(section.title).font(.subheadline.weight(.semibold))
                            .lineLimit(1).fixedSize().layoutPriority(1)
                        Text("\(section.fields.count)").font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                controls
            }
            .padding(.horizontal, 12)
            .frame(height: 30)

            sectionNote
            switchNote

            if isExpanded {
                VStack(alignment: .leading, spacing: 5) {
                    if let note {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 2)
                    }
                    ForEach(summary) { InspectorRow(field: $0, isProse: true) }
                    ForEach(section.primaryFields) { InspectorRow(field: $0) }
                    if !secondary.isEmpty {
                        moreRow
                        if showsMore {
                            ForEach(secondary) { InspectorRow(field: $0) }
                        }
                    }
                }
                .padding(.leading, 28).padding(.trailing, 12)
                .padding(.bottom, 10)
            }
        }
    }

    private var secondary: [MetadataField] { section.secondaryFields }

    /// Last of the primary rows: unfolds the secondary fields below it.
    private var moreRow: some View {
        Button(action: toggleMore) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(showsMore ? 90 : 0))
                    .frame(width: 8)
                Text("More (\(secondary.count))")
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(height: 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(showsMore ? "Hide the other fields" : "Show the other \(secondary.count) fields")
    }

    /// The kit's remark on the section, folded or not: an assumed colour
    /// profile, a gain map that is not saved. It depends on the image alone, so
    /// it sits above the switch's note and never moves with a toggle.
    @ViewBuilder private var sectionNote: some View {
        if let text = section.note {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 28).padding(.trailing, 12)
                .padding(.bottom, 6)
        }
    }

    /// Under the title, folded or not: why the switch is disabled, or what the
    /// selected option costs. Shown only while it applies: room reserved for a
    /// note that is not there reads as a stray blank line.
    @ViewBuilder private var switchNote: some View {
        if let switchState, let text = switchState.note {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .font(.caption)
                .foregroundStyle(switchState.isEnabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                .padding(.leading, 28).padding(.trailing, 12)
                .padding(.bottom, 6)
        }
    }

    private var note: String? {
        switch section.kind {
        case .c2pa:
            return "Always stripped on save. The signature binds the original pixels, so a resized copy that kept it would show as tampered."
        default:
            return nil
        }
    }
}

/// Label beside value, as a person reads them; the raw key and the stored value
/// are in the tooltips. A long value (workflow JSON, a prompt) goes under its
/// label, cut to a few lines until expanded.
private struct InspectorRow: View {
    let field: MetadataField
    /// Prose (a prompt) is set like the other values; a raw payload in monospace.
    var isProse = false
    @State private var showsAll = false

    private static let foldedLines = 4
    /// Text handed to the folded view: enough for four lines, without laying out a whole workflow.
    private static let foldedCharacters = 600
    private static let labelWidth: CGFloat = 104

    private var value: String { field.readableValue }

    private var isLong: Bool {
        value.count > 90 || value.contains("\n")
    }

    var body: some View {
        if isLong {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    label
                    Spacer(minLength: 0)
                    Button(showsAll ? "Less" : "More") { deferred { showsAll.toggle() } }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                Text(showsAll ? value : String(value.prefix(Self.foldedCharacters)))
                    .font(isProse ? .caption : .caption.monospaced())
                    .lineLimit(showsAll ? nil : Self.foldedLines)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                label.frame(width: Self.labelWidth, alignment: .leading)
                Text(value)
                    .font(.caption)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(field.isTranslated ? "Stored as \(field.value)" : "")
            }
        }
    }

    /// A long label wraps to a second line rather than losing its middle; past
    /// that its tail goes, and the tooltip has it in full with the raw key.
    private var label: some View {
        Text(field.label)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .truncationMode(.tail)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .help(field.label == field.key ? field.key : "\(field.label) (\(field.key))")
    }
}
