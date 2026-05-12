import SwiftUI
import Observation
import Core

/// All the live state the Git pane needs — files, branches, commits,
/// selection within each, focused panel, commit composer fields. Pulled
/// out of the views so the lazygit-style key handlers can mutate it
/// without weaving bindings through every subview.
@Observable
@MainActor
final class GitPaneState {
    enum Panel: Hashable, CaseIterable {
        case files, history
    }

    var info: GitRepositoryInfo?

    var files: [GitStatusEntry] = []
    var branches: [GitBranch] = []
    var commits: [GitCommit] = []

    var fileSelection: String?
    var branchSelection: String?
    var commitSelection: String?

    var focusedPanel: Panel = .files

    var diffText: String = ""

    var commitSubject: String = ""
    var commitBody: String = ""
    var runHooks: Bool = true

    var statusMessage: String?
    var statusKind: StatusKind = .info
    var processOutput: String = ""

    var helpVisible: Bool = false
    var filterVisible: Bool = false
    var filter: String = ""

    enum StatusKind { case info, success, error }

    // MARK: Filtered views (used by the lists)

    var filteredFiles: [GitStatusEntry] {
        guard !filter.isEmpty else { return files }
        let q = filter.lowercased()
        return files.filter { $0.relativePath.lowercased().contains(q) }
    }

    var filteredBranches: [GitBranch] {
        guard !filter.isEmpty else { return branches }
        let q = filter.lowercased()
        return branches.filter { $0.name.lowercased().contains(q) }
    }

    var filteredCommits: [GitCommit] {
        guard !filter.isEmpty else { return commits }
        let q = filter.lowercased()
        return commits.filter { $0.subject.lowercased().contains(q) || $0.sha.lowercased().contains(q) }
    }

    // MARK: Nav helpers (used by `j`/`k`)

    func moveSelectionDown() {
        switch focusedPanel {
        case .files:
            fileSelection = nextID(in: filteredFiles.map(\.relativePath), after: fileSelection)
        case .history:
            commitSelection = nextID(in: filteredCommits.map(\.sha), after: commitSelection)
        }
    }

    func moveSelectionUp() {
        switch focusedPanel {
        case .files:
            fileSelection = previousID(in: filteredFiles.map(\.relativePath), before: fileSelection)
        case .history:
            commitSelection = previousID(in: filteredCommits.map(\.sha), before: commitSelection)
        }
    }

    private func nextID(in ids: [String], after current: String?) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else { return ids.first }
        return ids[min(index + 1, ids.count - 1)]
    }

    private func previousID(in ids: [String], before current: String?) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else { return ids.first }
        return ids[max(index - 1, 0)]
    }

    func focusNextPanel() {
        let all = Panel.allCases
        guard let index = all.firstIndex(of: focusedPanel) else { return }
        focusedPanel = all[(index + 1) % all.count]
    }

    func focusPreviousPanel() {
        let all = Panel.allCases
        guard let index = all.firstIndex(of: focusedPanel) else { return }
        focusedPanel = all[(index - 1 + all.count) % all.count]
    }
}
