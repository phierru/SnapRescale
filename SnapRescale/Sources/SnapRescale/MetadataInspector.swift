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

/// The trailing panel: one collapsible section per block the source carries,
/// in the kit's order. Read-only. Deliberately not a grouped Form (GitHub #2).
struct MetadataInspector: View {
    @Environment(Session.self) private var session
    @State private var state = InspectorState.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let src = session.source {
                sections(src.metadata.sections)
                    .id(src.url)   // a replaced image starts scrolled to the top, long values folded
            } else {
                emptyState
            }
        }
    }

    // MARK: Slots for later issues

    /// Trailing side of the panel header: the master Default · Keep all · Strip all control (#19).
    @ViewBuilder private var panelAccessory: some View {
        EmptyView()
    }

    /// Trailing side of a section title: keep/strip switch (#19), Copy and Export (#17).
    @ViewBuilder private func sectionAccessory(_ section: MetadataSection) -> some View {
        EmptyView()
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 8) {
            Text("Metadata").font(.headline)
            Spacer()
            panelAccessory
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

    private func sections(_ sections: [MetadataSection]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(sections) { section in
                        InspectorSection(section: section, isExpanded: state.isExpanded(section.kind),
                                         toggle: { state.toggleSection(section.kind) }) {
                            sectionAccessory(section)
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

/// A section: a title row that folds it, with room on the trailing side for
/// the controls of later issues, then its key / value rows.
private struct InspectorSection<Accessory: View>: View {
    let section: MetadataSection
    let isExpanded: Bool
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
                        Text(section.title).font(.subheadline.weight(.semibold))
                        Text("\(section.fields.count)").font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                accessory
            }
            .padding(.horizontal, 12)
            .frame(height: 30)

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
