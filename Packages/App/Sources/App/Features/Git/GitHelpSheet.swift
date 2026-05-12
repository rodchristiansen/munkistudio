import SwiftUI

/// Help overlay showing every lazygit-style keybinding the Git pane
/// supports. Triggered by `?` and dismissed by `?` again or Esc.
struct GitHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Git pane shortcuts").font(.title2.bold())
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.escape)
            }

            HStack(alignment: .top, spacing: 32) {
                column("Navigation", entries: [
                    ("1 / 2 / 3", "Files / Branches / Commits panel"),
                    ("Tab", "Next panel"),
                    ("Shift+Tab", "Previous panel"),
                    ("j / ↓", "Move selection down"),
                    ("k / ↑", "Move selection up"),
                    ("g g", "Top"),
                    ("G", "Bottom"),
                    ("/", "Filter visible items"),
                    ("Esc", "Clear filter / close help"),
                ])
                column("Files panel", entries: [
                    ("Space", "Stage / unstage selected"),
                    ("a", "Stage / unstage all"),
                    ("Enter", "Show diff"),
                    ("o", "Open file in editor"),
                    ("d", "Discard changes (with confirm)"),
                    ("r", "Refresh"),
                ])
                column("Commits & actions", entries: [
                    ("c", "Focus commit subject"),
                    ("Cmd+Return", "Commit"),
                    ("C", "Commit + Push"),
                    ("P", "Push"),
                    ("p", "Pull"),
                    ("f", "Fetch"),
                    ("?", "Toggle this help"),
                ])
            }
            Spacer()
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 420)
    }

    private func column(_ title: String, entries: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            ForEach(entries, id: \.0) { key, description in
                HStack(alignment: .firstTextBaseline) {
                    Text(key)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.tint)
                        .frame(width: 100, alignment: .leading)
                    Text(description)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
