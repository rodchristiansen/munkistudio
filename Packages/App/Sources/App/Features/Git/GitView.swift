import SwiftUI
import Core

/// Git status pane (middle column). Lists changed files with stage
/// toggles; selecting one drives the diff viewer in the detail column.
/// Mirrors Cimian's GitPage layout in spirit.
struct GitView: View {
    @Environment(RepositoryStore.self) private var store
    @State private var statusEntries: [GitStatusEntry] = []
    @State private var loading: Bool = false
    @State private var loadError: String?
    @State private var stagedPaths: Set<String> = []

    var body: some View {
        @Bindable var bindableStore = store
        VStack(alignment: .leading, spacing: 0) {
            if let info = store.gitInfo {
                statusList(info: info)
            } else {
                ContentUnavailableView(
                    "No git repository",
                    systemImage: "arrow.triangle.branch",
                    description: Text("This repo doesn't live inside a git working tree.")
                )
            }
        }
        .task(id: store.gitInfo?.workTreeRoot) { await refresh() }
        .navigationTitle("Git")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }

    private func statusList(info: GitRepositoryInfo) -> some View {
        @Bindable var bindableStore = store
        return List(selection: $bindableStore.selectedItemID) {
            if loading { ProgressView() }
            if let loadError {
                Text(loadError).foregroundStyle(.red)
            }
            Section("Working tree") {
                if statusEntries.isEmpty {
                    Text("No changes").foregroundStyle(.secondary)
                }
                ForEach(statusEntries, id: \.relativePath) { entry in
                    GitStatusRow(
                        entry: entry,
                        isStaged: stagedPaths.contains(entry.relativePath),
                        toggle: { Task { await toggleStage(entry: entry, info: info) } }
                    )
                    .tag(AnyHashable(entry.relativePath))
                }
            }
        }
    }

    @MainActor
    private func refresh() async {
        guard let info = store.gitInfo else {
            statusEntries = []
            return
        }
        loading = true
        defer { loading = false }
        do {
            let entries = try await store.services.git.status(in: info)
            statusEntries = entries
            stagedPaths = Set(entries.filter(\.staged).map(\.relativePath))
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func toggleStage(entry: GitStatusEntry, info: GitRepositoryInfo) async {
        do {
            if stagedPaths.contains(entry.relativePath) {
                try await store.services.git.unstage(in: info, relativePaths: [entry.relativePath])
            } else {
                try await store.services.git.stage(in: info, relativePaths: [entry.relativePath])
            }
            await refresh()
        } catch {
            loadError = error.localizedDescription
        }
    }
}

struct GitStatusRow: View {
    let entry: GitStatusEntry
    let isStaged: Bool
    let toggle: () -> Void

    var body: some View {
        HStack {
            Button(action: toggle) {
                Image(systemName: isStaged ? "checkmark.square.fill" : "square")
            }
            .buttonStyle(.plain)
            Text(letter(for: entry.kind))
                .font(.caption.monospaced())
                .frame(width: 18, alignment: .center)
                .foregroundStyle(color(for: entry.kind))
            Text(entry.relativePath)
        }
    }

    private func letter(for kind: GitStatusEntry.Kind) -> String {
        switch kind {
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .copied: "C"
        case .untracked: "?"
        case .ignored: "!"
        case .conflicted: "U"
        }
    }

    private func color(for kind: GitStatusEntry.Kind) -> Color {
        switch kind {
        case .modified: .yellow
        case .added, .untracked: .green
        case .deleted: .red
        case .renamed, .copied: .blue
        case .conflicted: .orange
        case .ignored: .secondary
        }
    }
}
