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
                Button("Save") { Session.shared.save() }
                    .keyboardShortcut("s")
                    .disabled(Session.shared.source == nil)
                Button("Save As…") { Session.shared.saveAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(Session.shared.source == nil)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Session.shared.applyLaunchArguments(CommandLine.arguments)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Session.shared.accept(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
