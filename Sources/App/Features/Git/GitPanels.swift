import SwiftUI
import AppKit
import Core
import Infra

/// Three focused-panel views for the Git pane. Each renders a list whose
/// selection lives on the shared ``GitPaneState`` so the parent view's
/// key handler can drive nav without forwarding bindings.
struct GitFilesPanel: View {
    @Bindable var state: GitPaneState
    @Environment(RepositoryStore.self) private var store

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
                let isStaged = state.files.first { $0.relativePath == entry.relativePath }?.staged == true
                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(
                        get: { isStaged },
                        set: { newValue in
                            Task {
                                if newValue {
                                    await stage(relativePath: entry.relativePath)
                                } else {
                                    await unstage(relativePath: entry.relativePath)
                                }
                            }
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .help(isStaged ? "Unstage \(entry.relativePath)" : "Stage \(entry.relativePath)")
                    Text(letter(for: entry.kind))
                        .font(.caption.monospaced())
                        .frame(width: 22)
                        .foregroundStyle(color(for: entry.kind))
                    Text(entry.relativePath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .contentShape(.rect)
                // Single click still falls through to the List's
                // selection binding; the double-click handler only
                // fires when the user really double-clicks. If the
                // file is a known pkginfo or manifest in the loaded
                // snapshot, route to its editor — otherwise the click
                // is a no-op (deleted files, ignored files, anything
                // outside pkgsinfo/ or manifests/).
                .onTapGesture(count: 2) {
                    openInEditor(relativePath: entry.relativePath)
                }
                .tag(entry.relativePath)
            }
            // `.contextMenu(forSelectionType:)` is the macOS-correct
            // way to attach a right-click menu to `List(selection:)`:
            // SwiftUI hands us the path(s) the user clicked even if the
            // selection binding hasn't caught up yet, so the actions
            // always operate on the visually-targeted row.
            .contextMenu(forSelectionType: String.self) { selections in
                let targets = selections.isEmpty
                    ? Array(state.fileSelection)
                    : Array(selections)
                if let path = targets.first {
                    fileContextMenu(relativePath: path)
                }
            }
        }
    }

    // MARK: Context menu

    @ViewBuilder
    private func fileContextMenu(relativePath: String) -> some View {
        let fileURL = state.info?.workTreeRoot.appending(path: relativePath)
        let isPkginfo = fileURL.flatMap { url in
            store.snapshot.pkginfos.first { $0.fileURL == url }
        } != nil
        let isManifest = fileURL.flatMap { url in
            store.snapshot.manifests.first { $0.fileURL == url }
        } != nil
        let isKnown = isPkginfo || isManifest
        let entry = state.files.first { $0.relativePath == relativePath }

        Button("Open") { openInEditor(relativePath: relativePath) }
            .disabled(!isKnown)
        Button("Open in External Editor") { openExternally(relativePath: relativePath) }
        if let url = fileURL {
            let apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
            if !apps.isEmpty {
                Menu("Open With") {
                    ForEach(apps, id: \.self) { appURL in
                        Button(displayName(for: appURL)) {
                            open(relativePath: relativePath, withApp: appURL)
                        }
                    }
                }
            }
        }
        Button("Show in Finder") { revealInFinder(relativePath: relativePath) }

        Divider()

        Button("Copy Path") { copyAbsolutePath(relativePath: relativePath) }
        Button("Copy Relative Path") { copyToPasteboard(relativePath) }
        Button("Copy Filename") {
            copyToPasteboard((relativePath as NSString).lastPathComponent)
        }

        Divider()

        if let entry {
            if entry.staged {
                Button("Unstage") { Task { await unstage(relativePath: relativePath) } }
            } else {
                Button("Stage") { Task { await stage(relativePath: relativePath) } }
            }
        }
        Button("Discard Changes…", role: .destructive) {
            Task { await discard(relativePath: relativePath) }
        }
        .disabled(entry?.kind == .untracked)
    }

    // MARK: Actions

    /// Open the working-copy file at `relativePath` in the matching
    /// detail editor. Routes to Packages or Manifests based on whichever
    /// snapshot list contains a record at that absolute URL.
    private func openInEditor(relativePath: String) {
        guard let info = state.info else { return }
        let fileURL = info.workTreeRoot.appending(path: relativePath)
        if let record = store.snapshot.pkginfos.first(where: { $0.fileURL == fileURL }) {
            store.selectedSection = .packages
            store.selectedItemID = AnyHashable(record.id)
            let category = record.pkginfo.category?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? "Uncategorized"
            store.expandedCategories.insert(category)
        } else if let record = store.snapshot.manifests.first(where: { $0.fileURL == fileURL }) {
            store.selectedSection = .manifests
            store.selectedItemID = AnyHashable(record.id)
        }
    }

    private func openExternally(relativePath: String) {
        guard let url = state.info?.workTreeRoot.appending(path: relativePath) else { return }
        NSWorkspace.shared.open(url)
    }

    private func open(relativePath: String, withApp appURL: URL) {
        guard let url = state.info?.workTreeRoot.appending(path: relativePath) else { return }
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
    }

    private func revealInFinder(relativePath: String) {
        guard let url = state.info?.workTreeRoot.appending(path: relativePath) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func copyAbsolutePath(relativePath: String) {
        guard let url = state.info?.workTreeRoot.appending(path: relativePath) else { return }
        copyToPasteboard(url.path(percentEncoded: false))
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func stage(relativePath: String) async {
        guard let info = state.info else { return }
        do {
            try await store.services.git.stage(in: info, relativePaths: [relativePath])
            await refresh()
        } catch {
            handle(error: error, action: "Stage", info: info, retry: { await stage(relativePath: relativePath) })
        }
    }

    private func unstage(relativePath: String) async {
        guard let info = state.info else { return }
        do {
            try await store.services.git.unstage(in: info, relativePaths: [relativePath])
            await refresh()
        } catch {
            handle(error: error, action: "Unstage", info: info, retry: { await unstage(relativePath: relativePath) })
        }
    }

    /// Common error path: if git failed because of an index.lock,
    /// offer the recovery flow and retry the action on success.
    /// Otherwise surface the error in the status bar so the user
    /// sees something happened.
    @MainActor
    private func handle(
        error: Error,
        action: String,
        info: GitRepositoryInfo,
        retry: @escaping () async -> Void
    ) {
        let message = error.localizedDescription
        guard IndexLockRecovery.matches(message: message) else {
            state.statusMessage = "\(action) failed: \(message)"
            state.statusKind = .error
            return
        }
        switch IndexLockRecovery.present(workTreeRoot: info.workTreeRoot, message: message) {
        case .deleted:
            state.statusMessage = "Removed .git/index.lock — retrying \(action.lowercased())…"
            state.statusKind = .info
            Task { await retry() }
        case .cancelled:
            state.statusMessage = "\(action) failed: \(message)"
            state.statusKind = .error
        case .failed(let why):
            state.statusMessage = why
            state.statusKind = .error
        }
    }

    private func discard(relativePath: String) async {
        let alert = NSAlert()
        alert.messageText = "Discard changes to \(relativePath)?"
        alert.informativeText = "This is irreversible."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let info = state.info else { return }
        _ = try? await ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["checkout", "--", relativePath],
            in: info.workTreeRoot
        )
        await refresh()
    }

    /// Refresh the panel's view of the working copy after a mutation.
    /// Mirrors the partial-refresh `GitView.refresh()` does: pull the
    /// status list, recompute selection, and re-publish the dirty count
    /// so the toolbar's badge stays consistent.
    private func refresh() async {
        guard let info = state.info else { return }
        if let files = try? await store.services.git.status(in: info) {
            state.files = files
            store.gitDirtyCount = files.count
        }
    }

    /// `urlsForApplications(toOpen:)` returns `.app` bundle URLs. The
    /// display name is the bundle's name (CFBundleName / localized) when
    /// available, falling back to the filename without extension.
    private func displayName(for appURL: URL) -> String {
        if let bundle = Bundle(url: appURL),
           let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String {
            return name
        }
        return appURL.deletingPathExtension().lastPathComponent
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
    @Environment(RepositoryStore.self) private var store
    @State private var pendingAction: CommitAction?

    private static let rowHeight: CGFloat = 46

    var body: some View {
        let commits = state.filteredCommits
        let graph = CommitGraphBuilder.build(commits)
        Group {
            if commits.isEmpty {
                ContentUnavailableView("No commits", systemImage: "clock").padding()
            } else {
                List(selection: $state.commitSelection) {
                    ForEach(Array(commits.enumerated()), id: \.element.sha) { index, commit in
                        commitRow(
                            commit,
                            graphRow: index < graph.rows.count ? graph.rows[index] : nil,
                            laneCount: graph.laneCount
                        )
                        .tag(commit.sha)
                        .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 8))
                        .listRowSeparator(.hidden)
                    }
                }
                .contextMenu(forSelectionType: String.self) { shas in
                    let targets = shas.isEmpty ? [state.commitSelection].compactMap { $0 } : Array(shas)
                    if let sha = targets.first,
                       let commit = state.commits.first(where: { $0.sha == sha }) {
                        commitContextMenu(commit)
                    }
                }
            }
        }
        .popover(item: $pendingAction, arrowEdge: .trailing) { action in
            GitCommitActionSheet(
                action: action,
                currentBranch: state.info?.currentBranch,
                perform: { request in await run(request) }
            )
        }
    }

    private func commitRow(_ commit: GitCommit, graphRow: GraphRow?, laneCount: Int) -> some View {
        HStack(spacing: 8) {
            if let graphRow {
                GraphCell(row: graphRow, laneCount: laneCount, rowHeight: Self.rowHeight)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    ForEach(commit.refs, id: \.self) { ref in
                        refBadge(ref)
                    }
                    Text(commit.subject).lineLimit(1)
                }
                HStack(spacing: 6) {
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
        }
        .frame(height: Self.rowHeight)
        .contentShape(.rect)
    }

    private func refBadge(_ ref: GitRef) -> some View {
        let tint = badgeColor(ref)
        return HStack(spacing: 3) {
            Image(systemName: icon(for: ref.kind)).imageScale(.small)
            Text(ref.name).lineLimit(1)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(tint.opacity(0.18), in: .capsule)
        .foregroundStyle(tint)
        .overlay(
            Capsule().strokeBorder(ref.isHead ? tint : Color.clear, lineWidth: 1)
        )
    }

    private func icon(for kind: GitRef.Kind) -> String {
        switch kind {
        case .head: "circle.fill"
        case .localBranch: "arrow.triangle.branch"
        case .remoteBranch: "cloud"
        case .tag: "tag"
        }
    }

    private func badgeColor(_ ref: GitRef) -> Color {
        switch ref.kind {
        case .head, .localBranch: .blue
        case .remoteBranch: .purple
        case .tag: .orange
        }
    }

    @ViewBuilder
    private func commitContextMenu(_ commit: GitCommit) -> some View {
        let branch = state.info?.currentBranch ?? "current branch"
        Button("Edit Commit Message…") {
            Task { pendingAction = .editMessage(commit, current: await loadCommitMessage(commit)) }
        }
        Divider()
        Button("Add Tag…") { pendingAction = .addTag(commit) }
        Button("Create Branch…") { pendingAction = .createBranch(commit) }
        Divider()
        Button("Checkout…") { pendingAction = .checkout(commit) }
        Button("Cherry-Pick…") { pendingAction = .cherryPick(commit) }
        Button("Revert…") { pendingAction = .revert(commit) }
        Divider()
        Button("Merge into \(branch)…") { pendingAction = .merge(commit) }
        Button("Rebase \(branch) on this Commit…") { pendingAction = .rebase(commit) }
        Button("Reset \(branch) to this Commit…") { pendingAction = .reset(commit) }
        Divider()
        Button("Copy Commit Hash") { copyToPasteboard(commit.sha) }
        Button("Copy Commit Subject") { copyToPasteboard(commit.subject) }
        Button("Copy .patch") { Task { await copyPatch(for: commit.sha) } }
    }

    /// Fetch a commit's full message to pre-fill the edit sheet; falls
    /// back to the subject line if the lookup fails.
    private func loadCommitMessage(_ commit: GitCommit) async -> String {
        guard let info = state.info else { return commit.subject }
        return (try? await store.services.git.commitMessage(in: info, sha: commit.sha)) ?? commit.subject
    }

    private func run(_ request: CommitActionRequest) async {
        guard let info = state.info else { return }
        let git = store.services.git
        do {
            switch request {
            case .addTag(let c, let name, let message):
                try await git.tag(in: info, name: name, at: c.sha, message: message.isEmpty ? nil : message)
            case .createBranch(let c, let name):
                try await git.createBranch(in: info, name: name, at: c.sha)
            case .checkout(let c):
                try await git.checkoutCommit(in: info, sha: c.sha)
            case .cherryPick(let c):
                try await git.cherryPick(in: info, sha: c.sha)
            case .revert(let c):
                try await git.revert(in: info, sha: c.sha)
            case .merge(let c):
                try await git.merge(in: info, ref: c.sha)
            case .rebase(let c):
                try await git.rebase(in: info, onto: c.sha)
            case .reset(let c, let mode):
                try await git.reset(in: info, to: c.sha, mode: mode)
            case .editMessage(let c, let message):
                try await git.editCommitMessage(in: info, sha: c.sha, message: message)
            }
            state.statusMessage = nil
            await refreshAll()
        } catch {
            state.statusMessage = error.localizedDescription
            state.statusKind = .error
        }
    }

    /// Re-pull the working tree, branches, and log after a mutation so
    /// the History panel and toolbar reflect the new state.
    private func refreshAll() async {
        guard let info = state.info else { return }
        if let updated = await store.services.git.discover(at: info.workTreeRoot) {
            state.info = updated
        }
        if let files = try? await store.services.git.status(in: info) {
            state.files = files
            store.gitDirtyCount = files.count
        }
        if let branches = try? await store.services.git.branches(in: info) {
            state.branches = branches
        }
        if let commits = try? await store.services.git.log(in: info, max: 200) {
            state.commits = commits
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Run `git format-patch -1 --stdout <sha>` and put the result on the
    /// clipboard — the `.patch` form that can be applied with `git am`.
    private func copyPatch(for sha: String) async {
        guard let info = state.info else { return }
        let result = try? await ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["format-patch", "-1", "--stdout", sha],
            in: info.workTreeRoot
        )
        if let patch = result?.stdout, !patch.isEmpty {
            copyToPasteboard(patch)
        }
    }
}
