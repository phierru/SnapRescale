import SwiftUI
import RescaleKit
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(Session.self) private var session

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
                Text(src.url.lastPathComponent).font(.headline).lineLimit(1)
                Text(summary(src))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                if session.isLoading { ProgressView().controlSize(.small) }
                Button("Open…") { session.chooseImage() }
            }
        }
    }
}
