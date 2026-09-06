import SwiftUI
import RescaleKit

@main
struct SnapRescaleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("SnapRescale", id: "main") {
            ContentView()
                .environment(Session.shared)
        }
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { Session.shared.chooseImage() }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                let s = Session.shared
                Button(s.saveWithoutAsking ? (s.quitsAfterSave ? "Save & Quit" : "Save")
                                           : (s.quitsAfterSave ? "Save & Quit…" : "Save…")) { s.save() }
                    .keyboardShortcut("s")
                    .disabled(s.source == nil)
                if s.saveWithoutAsking {
                    Button(s.quitsAfterSave ? "Save As & Quit…" : "Save As…") { s.saveAs() }
                        .keyboardShortcut("s", modifiers: [.command, .shift])
                        .disabled(s.source == nil)
                }
            }
        }

        Settings {
            SettingsView().environment(Session.shared)
        }
    }
}

/// M5 preferences. Only the saving policy for now; grid, ladder, defaults follow.
struct SettingsView: View {
    @Environment(Session.self) private var session
    @State private var grantedFolders = FolderAccess.grantedFolderCount

    var body: some View {
        @Bindable var session = session
        Form {
            Section("Saving") {
                Toggle("Show the saved image in Finder", isOn: $session.revealAfterSave)
                Toggle("Save next to the original without asking", isOn: $session.saveWithoutAsking)
                Text(session.saveWithoutAsking
                     ? "⌘S writes {name}_{w}x{h} beside the original. ⇧⌘S opens the save panel. The first save into a folder asks for permission once."
                     : "⌘S opens the save panel in the original's folder, pre-filled with {name}_{w}x{h}, so the name can be tweaked.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if session.saveWithoutAsking {
                    LabeledContent("Folders allowed") {
                        HStack {
                            Text("\(grantedFolders)")
                            Button("Forget All") { FolderAccess.forgetAll(); grantedFolders = 0 }
                                .disabled(grantedFolders == 0)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
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
