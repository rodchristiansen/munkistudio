import SwiftUI
import Core

/// Three focused-panel views for the Git pane. Each renders a list whose
/// selection lives on the shared ``GitPaneState`` so the parent view's
/// key handler can drive nav without forwarding bindings.
struct GitFilesPanel: View {
    @Bindable var state: GitPaneState

    var body: some View {
        if state.files.isEmpty {
            ContentUnavailableView(
                "Working tree clean",
                systemImage: "checkmark.circle",
                description: Text("No uncommitted changes.")
            )
            .padding()
        } else {
            List(state.filteredFiles, id: \.relativePath, selection: $state.fileSelection) { entry in
                HStack(spacing: 8) {
                    Text(state.files.first { $0.relativePath == entry.relativePath }?.staged == true ? "●" : "○")
                        .font(.callout.monospaced())
                        .foregroundStyle(state.files.first { $0.relativePath == entry.relativePath }?.staged == true ? Color.green : .secondary)
                        .frame(width: 12)
                    Text(letter(for: entry.kind))
                        .font(.caption.monospaced())
                        .frame(width: 22)
                        .foregroundStyle(color(for: entry.kind))
                    Text(entry.relativePath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .tag(entry.relativePath)
            }
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

struct GitBranchesPanel: View {
    @Bindable var state: GitPaneState

    var body: some View {
        if state.branches.isEmpty {
            ContentUnavailableView("No branches", systemImage: "arrow.triangle.branch")
                .padding()
        } else {
            List(state.filteredBranches, id: \.name, selection: $state.branchSelection) { branch in
                HStack {
                    Image(systemName: branch.isCurrent ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(branch.isCurrent ? Color.green : .secondary)
                    Text(branch.name)
                    Spacer()
                    if let upstream = branch.upstreamName {
                        Text(upstream)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                .tag(branch.name)
            }
        }
    }
}

struct GitCommitsPanel: View {
    @Bindable var state: GitPaneState

    var body: some View {
        if state.commits.isEmpty {
            ContentUnavailableView("No commits", systemImage: "clock")
                .padding()
        } else {
            List(state.filteredCommits, id: \.sha, selection: $state.commitSelection) { commit in
                VStack(alignment: .leading, spacing: 2) {
                    Text(commit.subject).lineLimit(1)
                    HStack {
                        Text(commit.sha.prefix(8))
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                        Text(commit.author).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(commit.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .tag(commit.sha)
            }
        }
    }
}
