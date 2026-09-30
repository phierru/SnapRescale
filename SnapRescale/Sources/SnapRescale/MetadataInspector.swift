import SwiftUI
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
    private(set) var scrollRequest: ScrollRequest?

    func isExpanded(_ kind: MetadataSection.Kind) -> Bool { !collapsed.contains(kind) }

    // Everything below is called from a click or a menu command, so it writes a
    // run-loop turn later (GitHub #2, see Deferred.swift).

    func toggle() {
        deferred {
            self.scrollRequest = nil
            self.isPresented.toggle()
        }
    }

    func toggleSection(_ kind: MetadataSection.Kind) {
        deferred { self.collapsed.formSymmetricDifference([kind]) }
    }

    /// Opens the inspector with `kind` expanded and scrolled to the top.
    func reveal(_ kind: MetadataSection.Kind) {
        deferred {
            self.collapsed.remove(kind)
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
            ForEach([MetadataPolicy.Summary.default, .keepAll, .stripAll], id: \.self) { choice in
                Button {
                    // A run-loop turn later (GitHub #2, see Deferred.swift).
                    deferred { session.metadataPolicy = choice.policy ?? session.metadataPolicy }
                } label: {
                    if choice == current { Label(choice.label, systemImage: "checkmark") } else { Text(choice.label) }
                }
            }
            if current == .custom {
                Divider()
                Button {} label: { Label(current.label, systemImage: "checkmark") }.disabled(true)
            }
        } label: {
            Text(current.label).foregroundStyle(current == .custom ? .secondary : .primary)
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
        .help("\(session.metadataPolicy.summaryLine). Sets every section at once.")
        .accessibilityLabel("Metadata policy")
    }

    /// Trailing side of a section title, one fixed-size control after another:
    /// the keep / strip switch first; Copy and Export (#17) are appended here.
    private func sectionAccessory(_ section: MetadataSection, _ state: MetadataPolicy.SwitchState?) -> some View {
        HStack(spacing: 6) {
            if let policySection = section.kind.policySection {
                SectionSwitch(section: policySection, isEnabled: state?.isEnabled ?? true)
            }
        }
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
                        InspectorSection(section: section, isExpanded: state.isExpanded(section.kind),
                                         switchState: switchState,
                                         toggle: { state.toggleSection(section.kind) }) {
                            sectionAccessory(section, switchState)
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

/// The switch in a section title: keep · strip, or preserve · sRGB · strip for
/// the colour profile. The app's segmented control, one size down. It reads and
/// writes the session's policy, which a new image does not reset.
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
                    Text("Preserve").tag(MetadataPolicy.ICC.preserve)
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
        .controlSize(.mini)
        .fixedSize()
        .disabled(!isEnabled)
    }
}

/// A section: a title row that folds it, with the switch and the buttons of
/// later issues on its trailing side, a line for the switch's note, then its
/// key / value rows.
private struct InspectorSection<Accessory: View>: View {
    let section: MetadataSection
    let isExpanded: Bool
    /// `nil` for the sections without a switch.
    let switchState: MetadataPolicy.SwitchState?
    let toggle: () -> Void
    @ViewBuilder let accessory: Accessory

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
                accessory
            }
            .padding(.horizontal, 12)
            .frame(height: 30)

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
                    ForEach(section.fields) { InspectorRow(field: $0) }
                }
                .padding(.leading, 28).padding(.trailing, 12)
                .padding(.bottom, 10)
            }
        }
    }

    /// Under the title, folded or not: why the switch is disabled, or what the
    /// selected option costs. Every note the switch can show is laid out and
    /// only the current one drawn, so the room is the same whichever option is
    /// selected and a toggle moves nothing; the room changes with the format.
    @ViewBuilder private var switchNote: some View {
        if let switchState, !switchState.possibleNotes.isEmpty {
            ZStack(alignment: .topLeading) {
                ForEach(switchState.possibleNotes, id: \.self) { text in
                    Text(text)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .opacity(text == switchState.note ? 1 : 0)
                        .accessibilityHidden(text != switchState.note)
                }
            }
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

/// Key beside value; a long value (workflow JSON, a prompt) goes under its key,
/// cut to a few lines until expanded.
private struct InspectorRow: View {
    let field: MetadataField
    @State private var showsAll = false

    private static let foldedLines = 4
    /// Text handed to the folded view: enough for four lines, without laying out a whole workflow.
    private static let foldedCharacters = 600

    private var isLong: Bool {
        field.value.count > 90 || field.value.contains("\n")
    }

    var body: some View {
        if isLong {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    key
                    Spacer(minLength: 0)
                    Button(showsAll ? "Less" : "More") { deferred { showsAll.toggle() } }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                Text(showsAll ? field.value : String(field.value.prefix(Self.foldedCharacters)))
                    .font(.caption.monospaced())
                    .lineLimit(showsAll ? nil : Self.foldedLines)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                key.frame(width: 104, alignment: .leading)
                Text(field.value)
                    .font(.caption)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var key: some View {
        Text(field.key)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(field.key)
    }
}
