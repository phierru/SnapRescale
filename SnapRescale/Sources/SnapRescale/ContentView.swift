import SwiftUI
import RescaleKit
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(Session.self) private var session
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var session = session
        Group {
            if session.source == nil {
                EmptyStateView()
            } else {
                EditorView()
            }
        }
        .frame(minWidth: 960, minHeight: 640)
        .dropDestination(for: URL.self) { urls, _ in
            session.accept(urls)
            return true
        }
        .alert("SnapRescale", isPresented: Binding(
            get: { session.errorMessage != nil },
            set: { if !$0 { session.errorMessage = nil } }
        )) {
            Button("OK") { session.errorMessage = nil }
        } message: {
            Text(session.errorMessage ?? "")
        }
        .onChange(of: session.spec) { session.scheduleEncode() }
        // Launch arguments are parsed in applicationDidFinishLaunching, which can
        // run after this view appears, so watch the flag rather than read it once.
        .onChange(of: session.openWindowOnLaunch, initial: true) { _, id in
            guard let id else { return }
            session.openWindowOnLaunch = nil
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                openWindow(id: id)
            }
        }
        .onChange(of: session.openSettingsOnLaunch, initial: true) { _, wants in
            guard wants else { return }
            session.openSettingsOnLaunch = false
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                openSettings()
            }
        }
    }
}

struct EmptyStateView: View {
    @Environment(Session.self) private var session

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "photo.badge.arrow.down")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.secondary)
            Text("Drop an image here")
                .font(.title2.weight(.semibold))
            Text("Resize to any ratio, snapped to multiples of 8 and 16.")
                .foregroundStyle(.secondary)
            if session.isLoading {
                ProgressView().controlSize(.regular).padding(.top, 6)
            } else {
                Button("Choose Image…") { session.chooseImage() }
                    .keyboardShortcut("o")
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 6)
            }
            Text("Or right-click an image in Finder → Open With → SnapRescale")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [10, 8]))
                .foregroundStyle(.quaternary)
                .padding(28)
        }
    }
}

struct EditorView: View {
    @Environment(Session.self) private var session

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                SourceHeader()
                PreviewView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(16)
            Divider()
            ControlsPanel()
                .frame(width: 340)
        }
    }
}

struct SourceHeader: View {
    @Environment(Session.self) private var session

    private func summary(_ src: SourceImage) -> String {
        let mp = String(format: "%.1f MP", src.size.megapixels)
        let bytes = ByteCountFormatter.string(fromByteCount: Int64(src.fileSize), countStyle: .file)
        let ext = src.type.preferredFilenameExtension?.uppercased() ?? ""
        return "\(src.size.description) · \(mp) · \(bytes) · \(ext)"
    }

    var body: some View {
        if let src = session.source {
            HStack(spacing: 12) {
                Image(systemName: "photo")
                Text(src.url.lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle).layoutPriority(-1)
                Text(summary(src))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                MetadataBadges(badges: src.metadata.badges)
                Spacer()
                if session.isLoading { ProgressView().controlSize(.small) }
                Button("Open…") { session.chooseImage() }
            }
        }
    }
}

/// One capsule per metadata block the source carries (PRD §10). Hover for detail.
struct MetadataBadges: View {
    let badges: [ImageMetadata.Badge]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(badges) { b in
                Text(b.label)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(background(for: b.tone), in: Capsule())
                    .foregroundStyle(foreground(for: b.tone))
                    .help(b.detail)
            }
        }
    }

    private func background(for tone: ImageMetadata.Badge.Tone) -> Color {
        switch tone {
        case .neutral: return Color.secondary.opacity(0.18)
        case .warning: return Color.orange.opacity(0.22)
        case .provenance: return Color.accentColor.opacity(0.22)
        }
    }

    private func foreground(for tone: ImageMetadata.Badge.Tone) -> Color {
        switch tone {
        case .neutral: return .secondary
        case .warning: return .orange
        case .provenance: return .accentColor
        }
    }
}
