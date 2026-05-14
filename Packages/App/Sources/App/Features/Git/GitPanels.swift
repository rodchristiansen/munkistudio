import SwiftUI
import AppKit
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
            // `.contextMenu(forSelectionType:)` is the macOS-correct
            // way to attach a right-click menu to a `List(selection:)`:
            // SwiftUI hands us the SHAs the user actually clicked
            // (which may or may not match the current selection) and
            // makes sure the menu actually appears. The per-row
            // `.contextMenu` modifier was being suppressed on macOS 26.
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
            .contextMenu(forSelectionType: String.self) { shas in
                let targets = shas.isEmpty ? [state.commitSelection].compactMap { $0 } : Array(shas)
                if let sha = targets.first {
                    Button("Copy SHA") { copyToPasteboard(sha) }
                    if let subject = state.commits.first(where: { $0.sha == sha })?.subject {
                        Button("Copy Subject") { copyToPasteboard(subject) }
                    }
                    Button("Copy .patch") { Task { await copyPatch(for: sha) } }
                }
            }
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Run `git format-patch -1 --stdout <sha>` and put the result on
    /// the clipboard. Matches the `.patch` output you'd get from a
    /// GitHub commit page so it can be applied with `git am`.
    private func copyPatch(for sha: String) async {
        guard let info = state.info else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["format-patch", "-1", "--stdout", sha]
        process.currentDirectoryURL = info.workTreeRoot
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
            let patch = String(decoding: data, as: UTF8.self)
            if !patch.isEmpty {
                copyToPasteboard(patch)
            }
        } catch {
            // Surfaced silently — the user will notice nothing on the
            // clipboard. Logging here would be useful when wiring up
            // os.Logger in a later pass.
        }
    }
}
