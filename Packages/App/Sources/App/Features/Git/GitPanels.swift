import SwiftUI
import AppKit
import Core

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
                    ? [state.fileSelection].compactMap { $0 }
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
        try? await store.services.git.stage(in: info, relativePaths: [relativePath])
        await refresh()
    }

    private func unstage(relativePath: String) async {
        guard let info = state.info else { return }
        try? await store.services.git.unstage(in: info, relativePaths: [relativePath])
        await refresh()
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["checkout", "--", relativePath]
        process.currentDirectoryURL = info.workTreeRoot
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
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
