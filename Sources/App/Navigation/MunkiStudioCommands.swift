import SwiftUI

/// Menu-bar commands. Currently just the standard "Open…" and "Reload"
/// entries; more land as features come online.
struct MunkiStudioCommands: Commands {
    let store: RepositoryStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Repository…") {
                // `Commands` aren't `View`s — no `.fileImporter` here.
                // Bounce through `RepositoryStore` so `ContentView` (a
                // real view) can present the picker.
                store.openRepositoryPickerRequested = true
            }
            .keyboardShortcut("o", modifiers: .command)
        }
        CommandMenu("Repository") {
            Button("Reload") {
                Task { await store.reload() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(store.repository == nil)
            Divider()
            Button("Close Repository") {
                store.repository = nil
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
            .disabled(store.repository == nil)
        }
        #if DEBUG
        CommandMenu("Developer") {
            Button("Show Splash Screen") {
                store.repository = nil
            }
            .keyboardShortcut("0", modifiers: [.command, .shift])
        }
        #endif
    }

}
