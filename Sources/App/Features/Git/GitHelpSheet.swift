import SwiftUI

/// Help overlay showing every lazygit-style keybinding the Git pane
/// supports. Triggered by `?` and dismissed by `?` again or Esc.
///
/// Layout is dense by design: small footprint, three scannable columns
/// of `chip + description` rows, plus a footer hint so the global keys
/// (`?` to toggle, `Esc` to dismiss) don't have to crowd the columns.
struct GitHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 620, height: 380)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "keyboard")
                .foregroundStyle(.tint)
                .imageScale(.medium)
            Text("Git Pane Shortcuts")
                .font(.headline)
            Spacer()
            Button("Close") { dismiss() }
                .controlSize(.small)
                .keyboardShortcut(.escape)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Content

    private var content: some View {
        HStack(alignment: .top, spacing: 20) {
            column("Navigation", entries: [
                ("1 / 2", "Files / History"),
                ("Tab", "Next panel"),
                ("⇧ Tab", "Previous panel"),
                ("j / ↓", "Down"),
                ("k / ↑", "Up"),
                ("/", "Filter items"),
                ("Esc", "Clear filter"),
            ])
            column("Files", entries: [
                ("Space", "Stage / unstage"),
                ("a", "Stage / unstage all"),
                ("⌥ click", "Unstage All button"),
                ("⏎", "Show diff"),
                ("o", "Open in editor"),
                ("d", "Discard (confirm)"),
                ("r", "Refresh"),
            ])
            column("Commit", entries: [
                ("c", "Focus subject"),
                ("⌘⏎", "Commit"),
                ("⇧C", "Commit + Push"),
                ("P", "Push"),
                ("p", "Pull"),
                ("f", "Fetch"),
            ])
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func column(_ title: String, entries: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.7)
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            ForEach(entries, id: \.0) { key, description in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    KeyChip(key)
                    Text(description)
                        .font(.footnote)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                KeyChip("?")
                Text("Toggle this help")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                KeyChip("Esc")
                Text("Close")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

/// Small capsule rendering of a key or chord. Sized to its content so
/// "Space" and "⌘⏎" sit equally well, but the typography stays
/// monospaced + light so the row's description carries the meaning.
private struct KeyChip: View {
    let label: String

    init(_ label: String) {
        self.label = label
    }

    var body: some View {
        Text(label)
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .foregroundStyle(.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.secondary.opacity(0.28), lineWidth: 0.5)
            )
            .fixedSize()
    }
}
