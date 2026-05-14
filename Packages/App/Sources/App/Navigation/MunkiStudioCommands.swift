import SwiftUI
import AppKit

/// Menu-bar commands. Currently just the standard "Open…" and "Reload"
/// entries; more land as features come online.
struct MunkiStudioCommands: Commands {
    let store: RepositoryStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Repository…") {
                openRepository()
            }
            .keyboardShortcut("o", modifiers: .command)
        }
        CommandMenu("Repository") {
            Button("Reload") {
                Task { await store.reload() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(store.repository == nil)
        }
    }

    @MainActor
    private func openRepository() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            Task { await store.open(rootURL: url) }
        }
    }
}
