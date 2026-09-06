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
                Button(Session.shared.quitsAfterSave ? "Save & Quit" : "Save") { Session.shared.save() }
                    .keyboardShortcut("s")
                    .disabled(Session.shared.source == nil)
                Button(Session.shared.quitsAfterSave ? "Save As & Quit…" : "Save As…") { Session.shared.saveAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(Session.shared.source == nil)
            }
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
