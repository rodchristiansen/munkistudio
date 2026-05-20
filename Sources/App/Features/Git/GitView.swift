import SwiftUI
import AppKit
import Core

/// Lazygit-style Git pane (revised).
///
/// Layout:
/// ```
/// ┌──────────────────────────────────────────────────────────────┐
/// │ Branch: [main ▾]                  [↺] [⬆] [⬇] [⤓]      [?] │
/// ├───────────────────────────┬──────────────────────────────────┤
/// │ ▸ 1 Files                 │  Diff / details                  │
/// │   2 History               │                                  │
/// ├───────────────────────────┴──────────────────────────────────┤
/// │ Commit subject:                                              │
/// │ [____________________________________________________]       │
/// │ ☑ Run hooks                       [Commit]  [Commit & Push]  │
/// └──────────────────────────────────────────────────────────────┘
/// ```
///
/// Branches moved to a dropdown picker so the panel strip stays tight
/// (Files + History only). The in-pane branch chip is gone — the toolbar
/// already shows branch + ahead/behind.
struct GitView: View {
    @Environment(RepositoryStore.self) private var store
    @Environment(AppSettings.self) private var settings
    /// Owned by the store so the panel + selection survive leaving the
    /// Git tab and coming back.
    private var state: GitPaneState { store.gitPaneState }
    @FocusState private var paneFocused: Bool
    @FocusState private var commitSubjectFocused: Bool
    /// Tracks whether Option is currently held. Drives the Stage All ↔
    /// Unstage All label/action flip so the user can deliberately
    /// unstage everything without first hunting for the "all staged"
    /// state that the plain Stage All button toggles around.
    @State private var optionHeld: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            mainBody
        }
        .task(id: store.gitInfo?.workTreeRoot) { await loadAll() }
        .sheet(isPresented: Bindable(state).helpVisible) { GitHelpSheet() }
        .focusable()
        .focused($paneFocused)
        .focusEffectDisabled()
        .onKeyPress { press in handleKey(press) }
        .onModifierKeysChanged(mask: .option) { _, new in
            optionHeld = new.contains(.option)
        }
        .onAppear { paneFocused = true }
        // SwiftUI's List(selection:) binding fires when the user clicks
        // a row, but the GitView only re-syncs the diff from key
        // handlers. Watch the selection bindings explicitly so mouse
        // clicks also refresh the diff pane.
        .onChange(of: state.fileSelection) { _, _ in
            Task { await syncDiff() }
        }
        .onChange(of: state.commitSelection) { _, _ in
            Task { await syncDiff() }
        }
        .onChange(of: state.hookSelection) { _, _ in
            Task { await syncDiff() }
        }
        .onChange(of: state.focusedPanel) { _, _ in
            Task { await syncDiff() }
        }
    }

    // MARK: Header

    private var header: some View {
        // Branch picker on the leading edge with the git-action cluster
        // (Fetch / Pull / Push / Refresh / Help) immediately to its
        // right. Grouping branch + actions together keeps the eye on a
        // single control band; the trailing space is intentionally
        // empty so status text from the commit composer reads cleanly.
        HStack(spacing: 8) {
            if store.gitInfo != nil {
                branchPicker
                Button { Task { await runFetch() } } label: {
                    Label("Fetch", systemImage: "arrow.down.to.line")
                }
                .help("git fetch (f)")
                Button { Task { await runPull() } } label: {
                    Label("Pull", systemImage: "arrow.down")
                }
                .help("git pull --rebase --autostash (p)")
                Button { Task { await runPush() } } label: {
                    Label("Push", systemImage: "arrow.up")
                }
                .help("git push (P)")
                Divider().frame(height: 16)
                Button { Task { await refresh() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh (r)")
                Button { state.helpVisible.toggle() } label: {
                    Label("Help", systemImage: "questionmark.circle")
                }
                .help("Show shortcuts (?)")
            } else {
                Text("Not a git repository").foregroundStyle(.secondary)
            }
            Spacer()
        }
        .labelStyle(.titleAndIcon)
        .fontWeight(.semibold)
        .buttonStyle(.bordered)
        .controlSize(.large)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var branchPicker: some View {
        Menu {
            ForEach(state.branches, id: \.name) { branch in
                Button {
                    Task { await switchBranch(branch.name) }
                } label: {
                    HStack {
                        Image(systemName: branch.isCurrent ? "checkmark" : "")
                        Text(branch.name)
                        if let upstream = branch.upstreamName {
                            Spacer()
                            Text(upstream).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.secondary)
                    .imageScale(.small)
                Text(state.info?.currentBranch ?? "(none)")
                    .font(.callout.monospaced())
                    .fontWeight(.semibold)
                if store.gitDirtyCount > 0 {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                        .help("\(store.gitDirtyCount) uncommitted change\(store.gitDirtyCount == 1 ? "" : "s")")
                }
                if let info = state.info {
                    if info.aheadCount > 0 {
                        Image(systemName: "arrow.up")
                            .imageScale(.small)
                            .foregroundStyle(.secondary)
                        Text("\(info.aheadCount)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if info.behindCount > 0 {
                        Image(systemName: "arrow.down")
                            .imageScale(.small)
                            .foregroundStyle(.secondary)
                        Text("\(info.behindCount)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Image(systemName: "chevron.down")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: Body

    private var mainBody: some View {
        // Aim for a 1:2 split — left column (composer + file list) gets
        // a third, diff gets two-thirds. HSplitView still lets the user
        // drag from there.
        GeometryReader { geometry in
            let leftWidth = max(320, geometry.size.width / 3)
            HSplitView {
                VStack(spacing: 0) {
                    panelTabs
                    Divider()
                    // Tower-style: commit composer lives ABOVE the
                    // file/history list so the subject field is always
                    // in view as you scan changes.
                    if state.focusedPanel == .files {
                        commitComposer
                        Divider()
                    }
                    if state.filterVisible {
                        HStack {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField("Filter", text: Bindable(state).filter)
                                .textFieldStyle(.plain)
                            Button {
                                state.filter = ""
                                state.filterVisible = false
                            } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.regularMaterial)
                    }
                    focusedPanelContents
                }
                .frame(minWidth: 320, idealWidth: leftWidth, maxWidth: 640)

                Group {
                    if state.focusedPanel == .hooks {
                        GitHookDetailPane(state: state)
                    } else {
                        DiffPane(text: state.diffText)
                    }
                }
                .frame(minWidth: 320)
            }
        }
    }

    private var panelTabs: some View {
        HStack(spacing: 0) {
            ForEach(GitPaneState.Panel.allCases, id: \.self) { panel in
                Button {
                    state.focusedPanel = panel
                    paneFocused = true
                } label: {
                    Text(label(for: panel))
                        .font(.callout)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            state.focusedPanel == panel ? Color.accentColor.opacity(0.15) : Color.clear,
                            in: .rect(cornerRadius: 5)
                        )
                }
                .buttonStyle(.plain)
                .help("\(label(for: panel)) (press \(keyHint(for: panel)))")
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func keyHint(for panel: GitPaneState.Panel) -> String {
        switch panel {
        case .files: "1"
        case .history: "2"
        case .hooks: "3"
        }
    }

    private func label(for panel: GitPaneState.Panel) -> String {
        switch panel {
        case .files: "Files"
        case .history: "History"
        case .hooks: "Hooks"
        }
    }

    @ViewBuilder
    private var focusedPanelContents: some View {
        switch state.focusedPanel {
        case .files: GitFilesPanel(state: state)
        case .history: GitCommitsPanel(state: state)
        case .hooks: GitHooksPanel(state: state)
        }
    }

    // MARK: Commit composer
    //
    // Tower-app-inspired layout: subject + body at the top, three
    // checkboxes (Amend / Sign Off / Skip Hooks) in the middle row,
    // then a "Stage All" button paired with the primary Commit
    // action. The composer renders ABOVE the file list (see
    // `mainBody`) so the subject field stays visible while scanning
    // changes.

    private var commitComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            commitFieldsHeader
            TextField("Subject", text: Bindable(state).commitSubject)
                .textFieldStyle(.roundedBorder)
                .focused($commitSubjectFocused)
            TextEditor(text: Bindable(state).commitBody)
                .frame(minHeight: 50, maxHeight: 80)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                )
            commitOptionsRow
            commitActionRow
            if !state.processOutput.isEmpty {
                ScrollView {
                    Text(state.processOutput)
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 100)
                .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                )
            }
        }
        .padding(12)
    }

    private var commitFieldsHeader: some View {
        HStack {
            Text("Commit").font(.headline)
            Spacer()
            statusTrailing
        }
    }

    @ViewBuilder
    private var statusTrailing: some View {
        // Prefer the transient status message (commit failed / pushed)
        // when one is set; otherwise fall back to the "Last refreshed
        // Xm ago" stamp so the user always knows how stale the state is.
        if let message = state.statusMessage {
            Label(message, systemImage: statusIcon(for: state.statusKind))
                .foregroundStyle(statusColor(for: state.statusKind))
                .font(.callout)
        } else if let stamp = state.lastRefreshedAt {
            TimelineView(.periodic(from: stamp, by: 30)) { _ in
                Text("Last refreshed \(Self.relative(from: stamp))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Compact relative duration with single-character units, matching
    /// the `m`/`h`/`d` shorthand the user asked for. Uses absolute
    /// elapsed seconds rather than a calendar-aware DateFormatter — the
    /// indicator is meant to read like a stopwatch, not a calendar.
    private static func relative(from date: Date) -> String {
        let seconds = max(0, Int(Date.now.timeIntervalSince(date)))
        if seconds < 60 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        return "\(days)d ago"
    }

    private var commitOptionsRow: some View {
        HStack(spacing: 16) {
            Toggle("Amend", isOn: Bindable(state).amend)
                .help("Amend the last commit instead of creating a new one")
            Toggle("Skip Hooks", isOn: Bindable(state).skipHooks)
                .help("Pass --no-verify to bypass pre-commit and commit-msg hooks")
            Spacer()
        }
        .toggleStyle(.checkbox)
        .controlSize(.small)
    }

    private var commitActionRow: some View {
        HStack {
            Button(optionHeld ? "Unstage All" : "Stage All") {
                Task {
                    if optionHeld {
                        await unstageAll()
                    } else {
                        await toggleStageAll()
                    }
                }
            }
            .buttonStyle(.bordered)
            .disabled(optionHeld ? !state.files.contains(where: \.staged) : state.files.isEmpty)
            .help(optionHeld
                  ? "Unstage every staged file (hold Option)"
                  : "Stage every change in the working tree — hold Option to Unstage All")
            Spacer()
            Button("Commit") { Task { await runCommit() } }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(state.commitSubject.isEmpty)
            Button("Commit & Push") { Task { await runCommitAndPush() } }
                .buttonStyle(.bordered)
                .disabled(state.commitSubject.isEmpty)
        }
        .controlSize(.large)
    }

    private func statusIcon(for kind: GitPaneState.StatusKind) -> String {
        switch kind {
        case .info: "info.circle"
        case .success: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    private func statusColor(for kind: GitPaneState.StatusKind) -> Color {
        switch kind {
        case .info: .secondary
        case .success: .green
        case .error: .red
        }
    }
}

// MARK: Key handling

private extension GitView {
    func handleKey(_ press: KeyPress) -> KeyPress.Result {
        if commitSubjectFocused { return .ignored }
        let characters = press.characters

        switch characters {
        case "1": state.focusedPanel = .files; Task { await syncDiff() }; return .handled
        case "2": state.focusedPanel = .history; Task { await syncDiff() }; return .handled
        case "3": state.focusedPanel = .hooks; Task { await syncDiff() }; return .handled
        case "j": state.moveSelectionDown(); Task { await syncDiff() }; return .handled
        case "k": state.moveSelectionUp(); Task { await syncDiff() }; return .handled
        case " ":
            if state.focusedPanel == .files { Task { await toggleStageSelected() } }
            return .handled
        case "a":
            if state.focusedPanel == .files { Task { await toggleStageAll() } }
            return .handled
        case "c":
            commitSubjectFocused = true
            return .handled
        case "C":
            Task { await runCommitAndPush() }
            return .handled
        case "P":
            Task { await runPush() }
            return .handled
        case "p":
            Task { await runPull() }
            return .handled
        case "f":
            Task { await runFetch() }
            return .handled
        case "r":
            Task { await refresh() }
            return .handled
        case "o":
            if state.focusedPanel == .files { openSelectedInEditor() }
            return .handled
        case "d":
            if state.focusedPanel == .files { Task { await discardSelected() } }
            return .handled
        case "?":
            state.helpVisible.toggle()
            return .handled
        case "/":
            state.filterVisible = true
            return .handled
        default: break
        }

        switch press.key {
        case .tab:
            press.modifiers.contains(.shift) ? state.focusPreviousPanel() : state.focusNextPanel()
            Task { await syncDiff() }
            return .handled
        case .upArrow:
            state.moveSelectionUp(); Task { await syncDiff() }; return .handled
        case .downArrow:
            state.moveSelectionDown(); Task { await syncDiff() }; return .handled
        case .return:
            if state.focusedPanel == .files { Task { await syncDiff() } }
            return .handled
        case .escape:
            if state.helpVisible { state.helpVisible = false; return .handled }
            if state.filterVisible {
                state.filter = ""
                state.filterVisible = false
                return .handled
            }
            return .ignored
        default: return .ignored
        }
    }
}

// MARK: Async actions

private extension GitView {
    func loadAll() async {
        await refresh()
    }

    func refresh() async {
        guard let info = store.gitInfo else { state.info = nil; return }
        state.info = info
        do {
            async let files = store.services.git.status(in: info)
            async let branches = store.services.git.branches(in: info)
            async let commits = store.services.git.log(in: info, max: 200)
            state.files = try await files
            state.branches = try await branches
            state.commits = try await commits
            let hooksOverride = settings.gitHooksPathOverride.isEmpty ? nil : settings.gitHooksPathOverride
            state.hooksInfo = try? await store.services.git.hooks(in: info, overridePath: hooksOverride)
            if state.fileSelection == nil { state.fileSelection = state.files.first?.relativePath }
            if state.commitSelection == nil { state.commitSelection = state.commits.first?.sha }
            if state.hookSelection == nil { state.hookSelection = state.hooksInfo?.hooks.first?.id }
            await syncDiff()
            state.lastRefreshedAt = Date()
            // Clear the transient status message so the
            // "Last refreshed Xm ago" stamp takes over once the
            // info-toast disappears.
            state.statusMessage = nil
            // Keep the toolbar's dirty dot in sync with the pane's
            // file list — both should agree on count and freshness.
            store.gitDirtyCount = state.files.count
        } catch {
            note("Refresh failed: \(error.localizedDescription)", kind: .error)
        }
    }

    func syncDiff() async {
        guard let info = state.info else { state.diffText = ""; return }
        switch state.focusedPanel {
        case .files:
            guard let path = state.fileSelection else { state.diffText = ""; return }
            state.diffText = (try? await store.services.git.diff(in: info, relativePath: path)) ?? ""
        case .history:
            guard let sha = state.commitSelection else { state.diffText = ""; return }
            state.diffText = await commitDiff(sha: sha)
        case .hooks:
            await loadSelectedHook()
        }
    }

    func loadSelectedHook() async {
        guard let hook = state.selectedHook else {
            state.hookDraft = ""
            state.hookOriginal = ""
            return
        }
        let content = (try? await store.services.git.readHook(hook)) ?? ""
        state.hookDraft = content
        state.hookOriginal = content
    }

    func commitDiff(sha: String) async -> String {
        guard let info = state.info else { return "" }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["show", "--stat", "--patch", sha]
        process.currentDirectoryURL = info.workTreeRoot
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
            return String(decoding: data, as: UTF8.self)
        } catch {
            return ""
        }
    }

    func toggleStageSelected() async {
        guard let info = state.info, let path = state.fileSelection else { return }
        let entry = state.files.first { $0.relativePath == path }
        let isStaged = entry?.staged ?? false
        do {
            if isStaged {
                try await store.services.git.unstage(in: info, relativePaths: [path])
            } else {
                try await store.services.git.stage(in: info, relativePaths: [path])
            }
            await refresh()
        } catch {
            await handleGitError(error, action: "Stage", info: info, retry: { await toggleStageSelected() })
        }
    }

    func toggleStageAll() async {
        guard let info = state.info else { return }
        let stagedPaths = Set(state.files.filter(\.staged).map(\.relativePath))
        let allPaths = state.files.map(\.relativePath)
        let allStaged = !allPaths.isEmpty && allPaths.allSatisfy { stagedPaths.contains($0) }
        do {
            if allStaged {
                try await store.services.git.unstage(in: info, relativePaths: allPaths)
            } else {
                try await store.services.git.stage(in: info, relativePaths: allPaths)
            }
            await refresh()
        } catch {
            await handleGitError(error, action: "Stage-all", info: info, retry: { await toggleStageAll() })
        }
    }

    /// Unstage every currently-staged file. Bound to Option-clicking the
    /// Stage All button so the user doesn't have to first reach the
    /// "everything staged" toggle state.
    func unstageAll() async {
        guard let info = state.info else { return }
        let stagedPaths = state.files.filter(\.staged).map(\.relativePath)
        guard !stagedPaths.isEmpty else { return }
        do {
            try await store.services.git.unstage(in: info, relativePaths: stagedPaths)
            await refresh()
        } catch {
            await handleGitError(error, action: "Unstage-all", info: info, retry: { await unstageAll() })
        }
    }

    /// Common git-error path: route index.lock failures into the
    /// recovery alert and retry on success; surface anything else
    /// inline.
    @MainActor
    private func handleGitError(
        _ error: Error,
        action: String,
        info: GitRepositoryInfo,
        retry: @escaping () async -> Void
    ) async {
        let message = error.localizedDescription
        guard IndexLockRecovery.matches(message: message) else {
            note("\(action) failed: \(message)", kind: .error)
            return
        }
        switch IndexLockRecovery.present(workTreeRoot: info.workTreeRoot, message: message) {
        case .deleted:
            note("Removed .git/index.lock — retrying \(action.lowercased())…", kind: .info)
            await retry()
        case .cancelled:
            note("\(action) failed: \(message)", kind: .error)
        case .failed(let why):
            note(why, kind: .error)
        }
    }

    func runCommit() async {
        guard let info = state.info else { return }
        state.processOutput = ""
        do {
            for try await event in store.services.git.commit(
                in: info,
                subject: state.commitSubject,
                body: state.commitBody.isEmpty ? nil : state.commitBody,
                runHooks: !state.skipHooks,
                amend: state.amend
            ) {
                switch event {
                case .line(let line): state.processOutput += line + "\n"
                case .finished(let outcome):
                    if outcome.exitCode == 0 {
                        state.commitSubject = ""
                        state.commitBody = ""
                        // Amend and skip-hooks are one-shot — clear
                        // them so the next commit defaults back to a
                        // normal new commit with hooks enabled.
                        state.amend = false
                        state.skipHooks = false
                        note("Committed \(outcome.commitSHA?.prefix(8) ?? "")", kind: .success)
                        await refresh()
                    } else {
                        note("Commit failed: exit \(outcome.exitCode)", kind: .error)
                    }
                }
            }
        } catch {
            note("Commit error: \(error.localizedDescription)", kind: .error)
        }
    }

    func runCommitAndPush() async {
        await runCommit()
        await runPush()
    }

    func runPush() async { await runShell(["push"], successMessage: "Pushed") }
    // Default pull strategy: `--rebase --autostash`. Rebasing keeps
    // history linear (no incidental merge commits when syncing with
    // remote), and autostash transparently stashes dirty changes
    // before the pull and re-applies them after, so the user never
    // has to interrupt a pull to commit or stash by hand.
    func runPull() async {
        await runShell(["pull", "--rebase", "--autostash"], successMessage: "Pulled (rebased)")
    }
    func runFetch() async { await runShell(["fetch"], successMessage: "Fetched") }
    func switchBranch(_ name: String) async {
        await runShell(["switch", name], successMessage: "Switched to \(name)")
    }

    func runShell(_ args: [String], successMessage: String) async {
        guard let info = state.info else { return }
        state.processOutput = ""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = info.workTreeRoot
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
            state.processOutput += String(decoding: data, as: UTF8.self)
            if process.terminationStatus == 0 {
                note(successMessage, kind: .success)
                await refresh()
            } else {
                note("\(args.first ?? "git") failed: exit \(process.terminationStatus)", kind: .error)
            }
        } catch {
            note("Process error: \(error.localizedDescription)", kind: .error)
        }
    }

    func openSelectedInEditor() {
        guard let info = state.info, let path = state.fileSelection else { return }
        let url = info.workTreeRoot.appending(path: path)
        NSWorkspace.shared.open(url)
    }

    func discardSelected() async {
        guard state.info != nil, let path = state.fileSelection else { return }
        let alert = NSAlert()
        alert.messageText = "Discard changes to \(path)?"
        alert.informativeText = "This is irreversible."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        await runShell(["checkout", "--", path], successMessage: "Discarded \(path)")
    }

    func note(_ message: String, kind: GitPaneState.StatusKind) {
        state.statusMessage = message
        state.statusKind = kind
    }
}

// MARK: Diff pane

struct DiffPane: View {
    let text: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                    let s = String(line)
                    Text(s)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(color(for: s))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .textSelection(.enabled)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return .green }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return .red }
        if line.hasPrefix("@@") { return .blue }
        return .primary
    }
}
