import SwiftUI
import RescaleKit

@main
struct SnapRescaleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("SnapRescale", id: "main") {
            ContentView()
                .environment(Session.shared)
        }
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About SnapRescale") { openWindow(id: "about") }
            }
            CommandGroup(replacing: .help) {
                Button("SnapRescale Help") { openWindow(id: "help") }
                    .keyboardShortcut("?", modifiers: .command)
                Button("Report an Issue…") { NSWorkspace.shared.open(Links.issues) }
            }
            CommandGroup(replacing: .newItem) {
                Button("Open…") { Session.shared.chooseImage() }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                let s = Session.shared
                Button(s.saveWithoutAsking ? (s.quitsAfterSave ? "Save & Quit" : "Save")
                                           : (s.quitsAfterSave ? "Save & Quit…" : "Save…")) { s.save() }
                    .keyboardShortcut("s")
                    .disabled(!s.canSave)
                if s.saveWithoutAsking {
                    Button(s.quitsAfterSave ? "Save As & Quit…" : "Save As…") { s.saveAs() }
                        .keyboardShortcut("s", modifiers: [.command, .shift])
                        .disabled(!s.canSave)
                }
            }
        }

        Settings {
            SettingsView().environment(Session.shared)
        }

        Window("About SnapRescale", id: "about") { AboutView() }
            .windowResizability(.contentSize)
            .windowStyle(.hiddenTitleBar)
        Window("SnapRescale Help", id: "help") { HelpView() }
            .windowResizability(.contentSize)
    }
}

/// The Settings window (⌘,), PRD §5, §7, §8, §11.
struct SettingsView: View {
    @Environment(Session.self) private var session
    @State private var settings = AppSettings.shared
    @State private var grantedFolders = FolderAccess.grantedFolderCount
    @State private var ladderText = AppSettings.shared.ladder.map(String.init).joined(separator: ", ")
    @State private var ladderError: String?

    var body: some View {
        @Bindable var session = session
        @Bindable var settings = settings
        Form {
            Section("Saving") {
                Toggle("Show the saved image in Finder", isOn: $settings.revealAfterSave)
                Toggle("Save next to the original without asking", isOn: $settings.saveWithoutAsking)
                Text(settings.saveWithoutAsking
                     ? "⌘S writes {name}_{w}x{h} beside the original. ⇧⌘S opens the save panel. The first save into a folder asks for permission once."
                     : "⌘S opens the save panel in the original's folder, pre-filled with {name}_{w}x{h}, so the name can be tweaked.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if settings.saveWithoutAsking {
                    LabeledContent("Folders allowed") {
                        HStack {
                            Text("\(grantedFolders)")
                            Button("Forget All") { FolderAccess.forgetAll(); grantedFolders = 0 }
                                .disabled(grantedFolders == 0)
                        }
                    }
                }
            }

            Section("Defaults for a new image") {
                Picker("Multiple of", selection: $settings.defaultMultiple) {
                    ForEach(Multiple.allCases, id: \.self) { Text("\($0.rawValue)").tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent("Quality") {
                    HStack {
                        Slider(value: $settings.defaultQuality, in: 0.1...1, step: 0.05)
                        Text("\(Preset.percent(settings.defaultQuality))").monospacedDigit().frame(width: 28, alignment: .trailing)
                    }
                }
                Picker("Composition grid", selection: $session.grid) {
                    ForEach(CompositionGrid.allCases) { g in g.icon.tag(g).help(g.label) }
                }
                .pickerStyle(.segmented)
                Text("The grid is remembered whenever you change it under the image; this is the same setting.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section("Size ladder") {
                TextField("Pixel values", text: $ladderText)
                    .textFieldStyle(.roundedBorder)
                    .monospacedDigit()
                    .onSubmit(commitLadder)
                HStack {
                    Text(ladderNote).font(.callout).foregroundStyle(ladderError == nil ? Color.secondary : Color.orange)
                    Spacer()
                    Button("Apply", action: commitLadder)
                    Button("Reset") {
                        settings.ladder = AppSettings.defaultLadder
                        ladderText = settings.ladder.map(String.init).joined(separator: ", ")
                        ladderError = nil
                    }
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("Everything stays on this Mac: no network, no analytics.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Link("Privacy Policy", destination: Links.privacy).font(.caption)
            }
            .padding(.horizontal, 20).padding(.vertical, 8)
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var ladderNote: String {
        if let e = ladderError { return e }
        let unsafe = AppSettings.latticeUnsafe(settings.ladder)
        if unsafe.isEmpty { return "2–6 values, comma-separated. All are multiples of 16, so snapping never moves them." }
        return "Not multiples of 16, so a multiple of 8 or 16 will move them: \(unsafe.map(String.init).joined(separator: ", "))."
    }

    private func commitLadder() {
        let values = ladderText.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Int($0) }
        if let ok = AppSettings.validated(values) {
            settings.ladder = ok
            ladderText = ok.map(String.init).joined(separator: ", ")
            ladderError = nil
        } else {
            ladderError = "Enter 2 to 6 positive whole numbers."
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let services = ServicesProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = services
        Session.shared.applyLaunchArguments(CommandLine.arguments)
    }

    /// Open With, Dock-icon drop, or a file passed to `open -a`.
    func application(_ application: NSApplication, open urls: [URL]) {
        Session.shared.accept(urls, origin: .external)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Target of the "Resize with SnapRescale" entry in Finder's Services menu.
final class ServicesProvider: NSObject {
    @objc func resizeImage(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else {
            error.pointee = "No image file on the pasteboard."
            return
        }
        Task { @MainActor in
            NSApp.activate()
            Session.shared.accept(urls, origin: .external)
        }
    }
}
