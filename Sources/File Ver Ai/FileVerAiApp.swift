import SwiftUI
import AppKit

@main
struct FileVerAiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage(SettingsKeys.listFontSize) private var listFontSize: Int = 12

    var body: some Scene {
        Window("File Ver Ai", id: "main") {
            ContentView()
        }
        .defaultSize(width: 800, height: 500)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(String(localized: "menu.open")) { openFiles() }
                    .keyboardShortcut("o")
                Divider()
                Button(String(localized: "menu.exportCSV")) {
                    ExportHub.shared.export()
                }
                .keyboardShortcut("e")
            }
            CommandGroup(replacing: .help) {}
            CommandGroup(after: .toolbar) {
                Picker(String(localized: "menu.textSize"), selection: $listFontSize) {
                    Text("11").tag(11)
                    Text("12").tag(12)
                    Text("13").tag(13)
                    Text("14").tag(14)
                }
            }
        }
    }

    private func openFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = []
        guard panel.runModal() == .OK else { return }
        FileOpenHub.shared.dispatch(panel.urls)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    /// Dock アイコン / Finder からのドロップ・ダブルクリックで複数ファイルが渡される経路。
    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter { !$0.hasDirectoryPath }
        guard !files.isEmpty else { return }
        Task { @MainActor in
            FileOpenHub.shared.dispatch(files)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
