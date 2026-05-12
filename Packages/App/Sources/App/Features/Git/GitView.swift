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
    @State private var state = GitPaneState()
    @FocusState private var paneFocused: Bool
    @FocusState private var commitSubjectFocused: Bool

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
        .onAppear { paneFocused = true }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            if store.gitInfo != nil {
                branchPicker
            } else {
                Text("Not a git repository").foregroundStyle(.secondary)
            }
            Spacer()
            Button { Task { await refresh() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh (r)")
            Button { Task { await runPush() } } label: {
                Image(systemName: "arrow.up.circle")
            }
            .help("Push (P)")
            Button { Task { await runPull() } } label: {
                Image(systemName: "arrow.down.circle")
            }
            .help("Pull (p)")
            Button { Task { await runFetch() } } label: {
                Image(systemName: "arrow.down.to.line.circle")
            }
            .help("Fetch (f)")
            Button { state.helpVisible.toggle() } label: {
                Image(systemName: "questionmark.circle")
            }
            .help("Show shortcuts (?)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var branchPicker: some View {
        HStack(spacing: 6) {
            Text("Branch:").foregroundStyle(.secondary)
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
                HStack(spacing: 4) {
                    Text(state.info?.currentBranch ?? "(none)")
                        .font(.callout.monospaced())
                    Image(systemName: "chevron.down")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .frame(minWidth: 140, alignment: .leading)
            .fixedSize()
        }
    }

    // MARK: Body

    private var mainBody: some View {
        // Aim for a 1:2 split — Files/History gets a third, diff gets
        // two-thirds. HSplitView still lets the user drag from there.
        GeometryReader { geometry in
            let leftWidth = max(280, geometry.size.width / 3)
            HSplitView {
                VStack(spacing: 0) {
                    panelTabs
                    Divider()
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
                    Divider()
                    commitComposer
                }
                .frame(minWidth: 280, idealWidth: leftWidth, maxWidth: 600)

                DiffPane(text: state.diffText)
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
                    Task { await syncDiff() }
                } label: {
                    HStack(spacing: 4) {
                        Text(numberLabel(for: panel))
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                        Text(label(for: panel))
                            .font(.callout)
                        Text("\(count(for: panel))")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        state.focusedPanel == panel ? Color.accentColor.opacity(0.15) : Color.clear,
                        in: .rect(cornerRadius: 5)
                    )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func numberLabel(for panel: GitPaneState.Panel) -> String {
        switch panel {
        case .files: "1"
        case .history: "2"
        }
    }

    private func label(for panel: GitPaneState.Panel) -> String {
        switch panel {
        case .files: "Files"
        case .history: "History"
        }
    }

    private func count(for panel: GitPaneState.Panel) -> Int {
        switch panel {
        case .files: state.files.count
        case .history: state.commits.count
        }
    }

    @ViewBuilder
    private var focusedPanelContents: some View {
        switch state.focusedPanel {
        case .files: GitFilesPanel(state: state)
        case .history: GitCommitsPanel(state: state)
        }
    }

    // MARK: Commit composer

    private var commitComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Commit").font(.headline)
                Spacer()
                if let message = state.statusMessage {
                    Label(message, systemImage: statusIcon(for: state.statusKind))
                        .foregroundStyle(statusColor(for: state.statusKind))
                        .font(.callout)
                }
            }
            TextField("Subject", text: Bindable(state).commitSubject)
                .textFieldStyle(.roundedBorder)
                .focused($commitSubjectFocused)
            TextEditor(text: Bindable(state).commitBody)
                .frame(minHeight: 50, maxHeight: 80)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.regularMaterial, in: .rect(cornerRadius: 6))
            HStack {
                Toggle("Run hooks", isOn: Bindable(state).runHooks)
                Spacer()
                Button("Commit") { Task { await runCommit() } }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(state.commitSubject.isEmpty)
                Button("Commit & Push") { Task { await runCommitAndPush() } }
                    .disabled(state.commitSubject.isEmpty)
            }
            if !state.processOutput.isEmpty {
                ScrollView {
                    Text(state.processOutput)
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 100)
                .background(.regularMaterial, in: .rect(cornerRadius: 6))
            }
        }
        .padding(12)
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
            async let commits = store.services.git.log(in: info, max: 50)
            state.files = try await files
            state.branches = try await branches
            state.commits = try await commits
            if state.fileSelection == nil { state.fileSelection = state.files.first?.relativePath }
            if state.commitSelection == nil { state.commitSelection = state.commits.first?.sha }
            await syncDiff()
            note("Refreshed", kind: .info)
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
        }
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
            note("Stage failed: \(error.localizedDescription)", kind: .error)
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
            note("Stage-all failed: \(error.localizedDescription)", kind: .error)
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
                runHooks: state.runHooks
            ) {
                switch event {
                case .line(let line): state.processOutput += line + "\n"
                case .finished(let outcome):
                    if outcome.exitCode == 0 {
                        state.commitSubject = ""
                        state.commitBody = ""
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
    func runPull() async { await runShell(["pull"], successMessage: "Pulled") }
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
