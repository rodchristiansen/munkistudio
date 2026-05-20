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
        case files, history, hooks
    }

    var info: GitRepositoryInfo?

    var files: [GitStatusEntry] = []
    var branches: [GitBranch] = []
    var commits: [GitCommit] = []

    /// Files panel uses a Set so SwiftUI's List gives us native macOS
    /// multi-select: Cmd-click toggles individual files, Shift-click
    /// extends a contiguous range. The diff pane and other "operate
    /// on the focused file" flows use `primaryFileSelection`.
    var fileSelection: Set<String> = []
    var branchSelection: String?
    var commitSelection: String?

    /// The "focused" file for diff sync and single-target actions —
    /// just the first element of the multi-select set.
    var primaryFileSelection: String? { fileSelection.first }

    var focusedPanel: Panel = .files

    var diffText: String = ""

    // MARK: Hooks

    var hooksInfo: GitHooksInfo?
    /// `GitHook.id` (its file path) of the selected hook.
    var hookSelection: String?
    /// Editor buffer for the selected hook and its on-disk baseline.
    var hookDraft: String = ""
    var hookOriginal: String = ""

    var hookDraftDirty: Bool { hookDraft != hookOriginal }

    var selectedHook: GitHook? {
        guard let id = hookSelection else { return nil }
        return hooksInfo?.hooks.first { $0.id == id }
    }

    var commitSubject: String = ""
    var commitBody: String = ""
    var runHooks: Bool = true
    var amend: Bool = false
    var skipHooks: Bool = false

    var statusMessage: String?
    var statusKind: StatusKind = .info
    var processOutput: String = ""

    /// Set whenever a remote-touching action (refresh, fetch, pull,
    /// push) completes successfully. Used by the composer to render a
    /// "Last refreshed Xm ago" indicator.
    var lastRefreshedAt: Date?

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

    var filteredHooks: [GitHook] {
        let all = hooksInfo?.hooks ?? []
        guard !filter.isEmpty else { return all }
        let q = filter.lowercased()
        return all.filter { $0.name.lowercased().contains(q) }
    }

    // MARK: Nav helpers (used by `j`/`k`)

    func moveSelectionDown() {
        switch focusedPanel {
        case .files:
            let next = nextID(in: filteredFiles.map(\.relativePath), after: primaryFileSelection)
            fileSelection = next.map { [$0] } ?? []
        case .history:
            commitSelection = nextID(in: filteredCommits.map(\.sha), after: commitSelection)
        case .hooks:
            hookSelection = nextID(in: filteredHooks.map(\.id), after: hookSelection)
        }
    }

    func moveSelectionUp() {
        switch focusedPanel {
        case .files:
            let prev = previousID(in: filteredFiles.map(\.relativePath), before: primaryFileSelection)
            fileSelection = prev.map { [$0] } ?? []
        case .history:
            commitSelection = previousID(in: filteredCommits.map(\.sha), before: commitSelection)
        case .hooks:
            hookSelection = previousID(in: filteredHooks.map(\.id), before: hookSelection)
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
