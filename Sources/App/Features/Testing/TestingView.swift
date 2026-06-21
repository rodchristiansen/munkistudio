import SwiftUI
import Core

/// Full-width pane for the Testing section.
///
/// Three columns: checklist on the left, step timeline in the middle,
/// raw step messages on the right. The toolbar carries the
/// validate / next-untested / save actions plus the tester-name field.
struct TestingView: View {
    @Environment(RepositoryStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @State private var localStore = TestingStore()

    var body: some View {
        Group {
            if let repository = store.repository {
                VStack(spacing: 0) {
                    BulkBanner(state: $localStore)
                    HSplitView {
                        ChecklistColumn(state: $localStore, pkginfoRecordByName: pkginfoRecordByName)
                            .frame(minWidth: 260, idealWidth: 320, maxHeight: .infinity)
                        StepTimelineColumn(state: $localStore)
                            .frame(minWidth: 320, maxHeight: .infinity)
                        DetailInspectorColumn(state: $localStore)
                            .frame(minWidth: 280, idealWidth: 360, maxHeight: .infinity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .toolbar {
                    // Per-package workflow: run the validation pipeline on
                    // the selected row, propose safe autofixes for it.
                    ToolbarItemGroup {
                        if localStore.isValidatingSingle {
                            Button(role: .cancel) {
                                localStore.cancelValidation()
                            } label: {
                                Label("Stop", systemImage: "stop.circle")
                            }
                            .labelStyle(.titleAndIcon)
                        } else {
                            Button {
                                Task { await runSelected() }
                            } label: {
                                Label("Validate", systemImage: "checkmark.seal")
                            }
                            .labelStyle(.titleAndIcon)
                            .disabled(validateButtonDisabled)
                        }

                        Button {
                            Task { await prepareAutofix() }
                        } label: {
                            Label("Autofix", systemImage: "wand.and.stars")
                        }
                        .labelStyle(.titleAndIcon)
                        .disabled(localStore.selectedEntry == nil || localStore.isValidatingSingle)
                    }
                    // Navigation: jump to the next untested entry.
                    ToolbarItemGroup {
                        Button {
                            localStore.selectNextUntested()
                        } label: {
                            Label("Next", systemImage: "arrow.forward.circle")
                        }
                        .labelStyle(.titleAndIcon)
                        .disabled(localStore.checklist.items.allSatisfy { $0.status != .untested })
                    }
                    // Bulk run: validate every checklist row + JSON export.
                    ToolbarItemGroup {
                        if localStore.isBulkValidating {
                            Button(role: .cancel) {
                                localStore.cancelBulk()
                            } label: {
                                Label("Stop", systemImage: "stop.circle")
                            }
                            .labelStyle(.titleAndIcon)
                        } else {
                            Button {
                                Task { await runAll() }
                            } label: {
                                Label("Validate all", systemImage: "checkmark.seal.text.page")
                            }
                            .labelStyle(.titleAndIcon)
                            .disabled(localStore.checklist.items.isEmpty)
                        }
                    }
                    // Refresh the persistent Tart VM. Only useful when a
                    // VM is already cached — the next Validate auto-
                    // prepares a fresh one. While the teardown is in
                    // flight the button shows a spinner.
                    ToolbarItemGroup {
                        Button {
                            Task { await localStore.refreshEnvironment() }
                        } label: {
                            if localStore.environmentBusy {
                                HStack(spacing: 4) {
                                    ProgressView().controlSize(.small)
                                    Text("Refreshing VM\u{2026}")
                                }
                            } else {
                                Label("Refresh VM", systemImage: "arrow.clockwise")
                            }
                        }
                        .labelStyle(.titleAndIcon)
                        .disabled(!localStore.hasCachedEnvironment || localStore.environmentBusy || localStore.isValidatingSingle || localStore.isBulkValidating)
                        .help(localStore.environmentDisplayName.map { "Tear down \($0). The next Validate will spin up a fresh VM." } ?? "No VM cached — the next Validate will create one.")
                    }
                    // Export: write the checklist (JSON + Markdown) so the
                    // team can review it in PRs.
                    ToolbarItemGroup {
                        Button {
                            Task { await save() }
                        } label: {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                        .labelStyle(.titleAndIcon)
                    }
                }
                .sheet(isPresented: Binding(
                    get: { localStore.pendingAutofix != nil },
                    set: { if !$0 { localStore.cancelAutofix() } }
                )) {
                    if let proposal = localStore.pendingAutofix,
                       let entry = localStore.selectedEntry {
                        AutofixSheet(
                            entry: entry,
                            proposal: proposal,
                            onApply: {
                                Task { await applyAutofix(proposal: proposal, entry: entry) }
                            },
                            onCancel: { localStore.cancelAutofix() }
                        )
                    }
                }
                .task(id: repository.rootURL.path) {
                    await localStore.load(repository: repository, service: store.services.testing)
                    localStore.reconcile(with: store.snapshot)
                    await localStore.loadMunkipkgProjects(
                        via: store.services.munkipkg,
                        from: munkipkgProjectsFolderURL
                    )
                }
                .task(id: settings.munkipkgProjectsPath) {
                    await localStore.loadMunkipkgProjects(
                        via: store.services.munkipkg,
                        from: munkipkgProjectsFolderURL
                    )
                }
                .onChange(of: store.snapshot.pkginfos) {
                    localStore.reconcile(with: store.snapshot)
                }
                .alert("Testing error",
                       isPresented: Binding(
                            get: { localStore.errorMessage != nil },
                            set: { if !$0 { localStore.errorMessage = nil } }
                       ),
                       presenting: localStore.errorMessage) { _ in
                    Button("OK", role: .cancel) { localStore.errorMessage = nil }
                } message: { message in
                    Text(message)
                }
            } else {
                ContentUnavailableView(
                    "No repository open",
                    systemImage: "checkmark.seal",
                    description: Text("Open a Munki repository to start tracking QA.")
                )
            }
        }
    }

    /// Validate is disabled when nothing is selected in the active
    /// source. Selection state is parallel between pkgsinfo and
    /// munkipkgs — pick whichever the user is currently in.
    private var validateButtonDisabled: Bool {
        switch localStore.source {
        case .pkgsinfo: return localStore.selectedEntry == nil
        case .munkipkgs: return localStore.selectedMunkipkg == nil
        }
    }

    private func runSelected() async {
        switch localStore.source {
        case .pkgsinfo:
            await runSelectedPkginfo()
        case .munkipkgs:
            await runSelectedMunkipkg()
        }
    }

    private func runSelectedMunkipkg() async {
        guard let project = localStore.selectedMunkipkg else { return }
        let task = Task { @MainActor in
            await localStore.validateMunkipkg(project, services: store.services)
        }
        localStore.setValidateTask(task)
        await task.value
        localStore.setValidateTask(nil)
    }

    private func runSelectedPkginfo() async {
        guard let entry = localStore.selectedEntry,
              let repository = store.repository else { return }
        let configuration = TestEnvironmentFactory.Configuration(settings: settings)
        let environment: (any TestEnvironment)?
        var environmentError: String?
        do {
            environment = try await localStore.environment(for: configuration)
        } catch {
            environment = nil
            environmentError = error.localizedDescription
        }
        let tester = effectiveTester
        let folder = munkipkgProjectsFolderURL
        let task = Task { @MainActor in
            await localStore.validate(
                entry: entry,
                snapshot: store.snapshot,
                repository: repository,
                services: store.services,
                munkipkgProjectsFolder: folder,
                environment: environment,
                environmentError: environmentError,
                tester: tester
            )
        }
        localStore.setValidateTask(task)
        await task.value
        localStore.setValidateTask(nil)
    }

    private var effectiveTester: String {
        let configured = settings.testerName.trimmingCharacters(in: .whitespaces)
        return configured.isEmpty ? NSFullUserName() : configured
    }

    private var pkginfoRecordByName: [String: PkginfoRecord] {
        var lookup: [String: PkginfoRecord] = [:]
        for record in store.snapshot.pkginfos {
            // Repos with multi-version pkginfos for the same name collapse
            // to the latest record seen — good enough for the artifact
            // chip and the row context menu (which only needs one URL to
            // reveal).
            lookup[record.pkginfo.name] = record
        }
        return lookup
    }

    private var munkipkgProjectsFolderURL: URL? {
        let path = settings.munkipkgProjectsPath.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func save() async {
        guard let repository = store.repository else { return }
        await localStore.save(repository: repository, service: store.services.testing)
    }

    private func runAll() async {
        guard let repository = store.repository else { return }
        await localStore.validateAll(
            snapshot: store.snapshot,
            repository: repository,
            services: store.services,
            tester: effectiveTester
        )
    }

    private func prepareAutofix() async {
        guard let entry = localStore.selectedEntry else { return }
        await localStore.prepareAutofix(
            for: entry,
            snapshot: store.snapshot,
            service: store.services.testing
        )
    }

    private func applyAutofix(proposal: AutofixProposal, entry: ChecklistEntry) async {
        guard let record = store.snapshot.pkginfos.first(where: { $0.pkginfo.name == entry.packageName }) else {
            localStore.cancelAutofix()
            return
        }
        let ok = await store.applyPkginfoEdit(proposal.pkginfo, to: record)
        localStore.cancelAutofix()
        if ok, let repository = store.repository {
            // After autofix we only re-run static checks; the env-driven
            // steps are expensive and the user can re-validate when ready.
            await localStore.validate(
                entry: entry,
                snapshot: store.snapshot,
                repository: repository,
                services: store.services,
                munkipkgProjectsFolder: munkipkgProjectsFolderURL,
                environment: nil,
                tester: effectiveTester
            )
        }
    }
}

// MARK: - Bulk banner

/// Sits above the three-column body. Shows either the live progress of
/// a "Validate all" run or the rolled-up summary of the most recent one.
/// Collapses to nothing when neither applies.
private struct BulkBanner: View {
    @Binding var state: TestingStore

    var body: some View {
        Group {
            if case let .validatingAll(current, total, packageName) = state.phase {
                progressBar(current: current, total: total, packageName: packageName)
            } else if let summary = state.bulkSummary {
                summaryBar(summary: summary)
            }
        }
    }

    private func progressBar(current: Int, total: Int, packageName: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Validating \(current) of \(total)").font(.callout)
            Text("·").foregroundStyle(.tertiary)
            Text(packageName)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            ProgressView(value: Double(current), total: Double(max(total, 1)))
                .progressViewStyle(.linear)
                .frame(width: 180)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.thinMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func summaryBar(summary: TestingStore.BulkSummary) -> some View {
        HStack(spacing: 10) {
            Image(systemName: summary.failed == 0
                  ? "checkmark.seal.fill"
                  : "exclamationmark.triangle.fill")
                .foregroundStyle(summary.failed == 0 ? .green : .orange)
            Text(summary.headline).font(.callout)
            if let url = summary.exportURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label("Reveal in Finder", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            Spacer()
            Text(summary.finishedAt, style: .relative)
                .foregroundStyle(.secondary)
                .font(.caption)
            Button {
                state.bulkSummary = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.thinMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private extension TestingStore.BulkSummary {
    var headline: String {
        var parts: [String] = ["\(total) packages"]
        if passed > 0 { parts.append("\(passed) passed") }
        if warnings > 0 { parts.append("\(warnings) with warnings") }
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Autofix sheet

private struct AutofixSheet: View {
    let entry: ChecklistEntry
    let proposal: AutofixProposal
    let onApply: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Autofix proposal").font(.headline)
                    Text(entry.packageName).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(proposal.changes) { change in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(change.field)
                                .font(.system(.body, design: .monospaced))
                                .fontWeight(.semibold)
                            HStack(alignment: .top, spacing: 8) {
                                Text("−")
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(.red)
                                Text(change.before)
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                            HStack(alignment: .top, spacing: 8) {
                                Text("+")
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(.green)
                                Text(change.after)
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                            Text(change.rationale)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Apply", action: onApply)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(minWidth: 520, minHeight: 360)
    }
}

// MARK: - Columns

private struct ChecklistColumn: View {
    @Binding var state: TestingStore
    @Environment(AppSettings.self) private var settings
    @Environment(RepositoryStore.self) private var repoStore
    let pkginfoRecordByName: [String: PkginfoRecord]
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Source picker on top — matches the Packages / Manifests
            // header pattern (full-width segmented control, filter
            // field below). When munkipkgProjectsPath isn't set we
            // collapse the picker entirely; pkgsinfo is the only source.
            if showsSourcePicker {
                HStack(spacing: 8) {
                    Picker("", selection: $state.source) {
                        ForEach(TestingStore.Source.allCases, id: \.self) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
            }

            FilterField(text: $state.searchQuery, prompt: "Filter packages", focused: $searchFocused)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)

            Divider()

            if state.source == .munkipkgs {
                if filteredMunkipkgs.isEmpty {
                    ContentUnavailableView(
                        "No munkipkg projects",
                        systemImage: "hammer",
                        description: Text("Configure a munkipkg projects folder in Settings → Build, or check that the folder contains projects with a build-info file.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: Binding(
                        get: { state.selectedMunkipkgName },
                        set: { state.selectedMunkipkgName = $0 }
                    )) {
                        ForEach(filteredMunkipkgs) { project in
                            munkipkgRow(for: project)
                                .tag(project.name)
                                .simultaneousGesture(
                                    TapGesture(count: 2).onEnded { openInBuild(project) }
                                )
                                .contextMenu { munkipkgContextMenu(project) }
                        }
                    }
                    .listStyle(.inset)
                }
            } else {
                List(selection: Binding(
                    get: { state.selectedEntryID },
                    set: { state.selectedEntryID = $0 }
                )) {
                    ForEach(filteredItems) { entry in
                        row(for: entry)
                            .tag(entry.id)
                            .simultaneousGesture(
                                TapGesture(count: 2).onEnded { openInPackages(entry) }
                            )
                            .contextMenu { pkginfoContextMenu(entry) }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// True when the user has configured a munkipkg projects folder —
    /// gating the Pkgsinfo|Munkipkgs source picker on that setting keeps
    /// the Testing pane single-source for users who haven't wired up the
    /// munkipkg side at all.
    private var showsSourcePicker: Bool {
        !settings.munkipkgProjectsPath.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func row(for entry: ChecklistEntry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: entry.status.systemImage)
                .foregroundStyle(entry.status.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.packageName).font(.body)
                if let version = entry.version {
                    Text(version).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let testedAt = entry.testedAt {
                Text(testedAt, format: .relative(presentation: .numeric))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let chip = artifactType(for: entry) {
                Text(chip.label)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(chip.tint.opacity(0.15), in: .capsule)
                    .foregroundStyle(chip.tint)
            }
        }
    }

    /// Pull the artifact extension off the pkginfo's
    /// `installer_item_location` and translate it to a label + tint.
    /// Returns nil for pkginfos with no installer item (`nopkg`,
    /// `apple_update_metadata`, etc.) so the chip doesn't show.
    private func artifactType(for entry: ChecklistEntry) -> (label: String, tint: Color)? {
        guard let record = pkginfoRecordByName[entry.packageName],
              let location = record.pkginfo.installerItemLocation,
              !location.isEmpty else { return nil }
        let ext = (location as NSString).pathExtension.lowercased()
        switch ext {
        case "pkg", "mpkg": return ("pkg", .blue)
        case "dmg":         return ("dmg", .purple)
        case "zip":         return ("zip", .orange)
        case "":            return nil
        default:            return (ext, .secondary)
        }
    }

    private var passCount: Int {
        state.checklist.items.filter { $0.status == .pass }.count
    }

    /// Search-filtered flat list of checklist entries, sorted by name.
    private var filteredItems: [ChecklistEntry] {
        let query = state.searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        let items: [ChecklistEntry]
        if query.isEmpty {
            items = state.checklist.items
        } else {
            items = state.checklist.items.filter {
                $0.packageName.lowercased().contains(query)
            }
        }
        return items.sorted {
            $0.packageName.localizedCaseInsensitiveCompare($1.packageName) == .orderedAscending
        }
    }

    // MARK: - Munkipkgs source rendering

    /// Search-filtered munkipkg projects list, sorted by project name.
    private var filteredMunkipkgs: [MunkipkgProject] {
        let query = state.searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        let items: [MunkipkgProject]
        if query.isEmpty {
            items = state.munkipkgProjects
        } else {
            items = state.munkipkgProjects.filter {
                $0.name.lowercased().contains(query)
                || $0.buildInfo.identifier.lowercased().contains(query)
            }
        }
        return items
    }

    private func munkipkgRow(for project: MunkipkgProject) -> some View {
        let result = state.munkipkgResultsByName[project.name]
        let status = munkipkgStatus(for: result)
        return HStack(spacing: 8) {
            Image(systemName: status.systemImage)
                .foregroundStyle(status.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name).font(.body)
                Text(project.buildInfo.version).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let finishedAt = result?.finishedAt {
                Text(finishedAt, format: .relative(presentation: .numeric))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Map a munkipkg validation result to the same icon/tint vocabulary
    /// pkgsinfo rows use, so the column reads consistently regardless
    /// of source.
    private func munkipkgStatus(for result: TestingResult?) -> (systemImage: String, tint: Color) {
        guard let result, !result.steps.isEmpty else {
            return ("circle", .secondary)
        }
        if result.failed > 0 { return ("xmark.octagon.fill", .red) }
        if result.warnings > 0 { return ("exclamationmark.triangle.fill", .orange) }
        return ("checkmark.circle.fill", .green)
    }

    // MARK: - Context menus & cross-section navigation

    /// Jump to the Packages section with this pkginfo selected. Sets
    /// `pendingRevealItemID` so PackageTreeList scrolls the row into
    /// view; expanding the category mirrors the Catalogs-list pattern.
    private func openInPackages(_ entry: ChecklistEntry) {
        guard let record = pkginfoRecordByName[entry.packageName] else { return }
        repoStore.selectedSection = .packages
        repoStore.selectedItemID = AnyHashable(record.id)
        repoStore.pendingRevealItemID = AnyHashable(record.id)
        let category = (record.pkginfo.category?.trimmingCharacters(in: .whitespaces)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? "Uncategorized"
        repoStore.expandedCategories.insert(category)
    }

    /// Jump to the Build section with this munkipkg project selected.
    /// `pendingBuildProjectID` is consumed by BuildView on its next
    /// appearance / change tick.
    private func openInBuild(_ project: MunkipkgProject) {
        repoStore.pendingBuildProjectID = project.id
        repoStore.selectedSection = .build
    }

    @ViewBuilder
    private func pkginfoContextMenu(_ entry: ChecklistEntry) -> some View {
        Button("Open in Packages") { openInPackages(entry) }
        if let record = pkginfoRecordByName[entry.packageName] {
            Divider()
            Button("Reveal pkginfo in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([record.fileURL])
            }
            if let installer = installerURL(for: record) {
                Button("Reveal installer in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([installer])
                }
            }
            Divider()
            Button("Copy package name") { copyToPasteboard(entry.packageName) }
            Button("Copy pkginfo path") { copyToPasteboard(record.fileURL.path) }
        }
    }

    @ViewBuilder
    private func munkipkgContextMenu(_ project: MunkipkgProject) -> some View {
        Button("Open in Build") { openInBuild(project) }
        Divider()
        Button("Reveal project in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([project.directoryURL])
        }
        if FileManager.default.fileExists(atPath: project.buildDirectory.path) {
            Button("Reveal build/ in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([project.buildDirectory])
            }
        }
        Divider()
        Button("Copy project name") { copyToPasteboard(project.name) }
        Button("Copy identifier") { copyToPasteboard(project.buildInfo.identifier) }
        Button("Copy project path") { copyToPasteboard(project.directoryURL.path) }
    }

    /// Resolve the on-disk installer for a pkginfo (under `pkgs/`) if
    /// the file exists. Returns nil for `nopkg`-style entries.
    private func installerURL(for record: PkginfoRecord) -> URL? {
        guard let repo = repoStore.repository,
              let location = record.pkginfo.installerItemLocation,
              !location.isEmpty else { return nil }
        let url = repo.pkgsURL.appending(path: location)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

private struct StepTimelineColumn: View {
    @Binding var state: TestingStore
    @Environment(AppSettings.self) private var settings

    /// Title in the column header — package name for pkgsinfo, project
    /// name for munkipkgs.
    private var headerTitle: String {
        switch state.source {
        case .pkgsinfo: state.selectedEntry?.packageName ?? "Select a package"
        case .munkipkgs: state.selectedMunkipkg?.name ?? "Select a project"
        }
    }

    /// Active result — pkgsinfo reads from resultsByEntry, munkipkgs
    /// from munkipkgResultsByName.
    private var activeResult: TestingResult? {
        switch state.source {
        case .pkgsinfo: state.selectedResult
        case .munkipkgs: state.selectedMunkipkgResult
        }
    }

    /// True when the active source has a current selection — gates the
    /// "Not validated yet" empty state vs the "No selection" one.
    private var hasSelection: Bool {
        switch state.source {
        case .pkgsinfo: state.selectedEntry != nil
        case .munkipkgs: state.selectedMunkipkg != nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(headerTitle)
                    .font(.headline)
                Spacer()
                if state.source == .pkgsinfo, let entry = state.selectedEntry {
                    StatusMenu(entry: entry, state: $state)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if let stage = state.validationStage, state.isValidatingSingle {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(stage).font(.callout)
                    Spacer()
                    Text("Click Stop in the toolbar to cancel")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.thinMaterial)
                Divider()
            }

            if let result = activeResult, !result.steps.isEmpty {
                List {
                    Section {
                        ForEach(result.steps) { step in
                            StepRow(step: step)
                        }
                    } header: {
                        HStack {
                            Text("\(result.passed) passed · \(result.warnings) warnings · \(result.failed) errors")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                copyToPasteboard(StepRow.transcript(of: result))
                            } label: {
                                Label("Copy all", systemImage: "doc.on.doc")
                                    .labelStyle(.titleAndIcon)
                            }
                            .buttonStyle(.borderless)
                            .help("Copy the full timeline transcript")
                            Text(result.finishedAt, style: .time)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .listStyle(.inset)
            } else if hasSelection {
                ContentUnavailableView(
                    state.isValidatingSingle ? "Validating…" : "Not validated yet",
                    systemImage: state.isValidatingSingle ? "hourglass" : "play.circle",
                    description: Text(state.isValidatingSingle
                                      ? "Steps will appear here as they complete."
                                      : "Click Validate in the toolbar to run the schema checks.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "No selection",
                    systemImage: "checkmark.seal",
                    description: Text("Pick a package on the left.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct StatusMenu: View {
    let entry: ChecklistEntry
    @Binding var state: TestingStore
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Menu {
            ForEach(ChecklistStatus.allCases, id: \.self) { status in
                Button {
                    state.setStatus(status, for: entry.id, tester: effectiveTester)
                } label: {
                    Label(status.title, systemImage: status.systemImage)
                }
            }
        } label: {
            Label(entry.status.title, systemImage: entry.status.systemImage)
                .foregroundStyle(entry.status.tint)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var effectiveTester: String {
        let configured = settings.testerName.trimmingCharacters(in: .whitespaces)
        if !configured.isEmpty { return configured }
        return NSFullUserName()
    }
}

private struct StepRow: View {
    let step: TestingStepResult
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: step.severity.systemImage)
                    .foregroundStyle(step.severity.tint)
                    .imageScale(.large)
                Text(step.title).font(.headline)
                Spacer()
                if !step.messages.isEmpty {
                    Button {
                        copyToPasteboard(Self.transcript(of: step))
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .imageScale(.small)
                    }
                    .buttonStyle(.borderless)
                    .opacity(isHovering ? 1 : 0.35)
                    .help("Copy this step")
                }
                if step.duration > 0 {
                    Text(step.duration, format: .number.precision(.fractionLength(2)))
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
            ForEach(step.messages, id: \.self) { message in
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
        .onHover { isHovering = $0 }
    }

    /// Render one step as a copy-friendly text block: title line first,
    /// followed by each message indented. Used by both the per-step Copy
    /// button and the timeline-header Copy-all.
    static func transcript(of step: TestingStepResult) -> String {
        var lines: [String] = [step.title]
        for message in step.messages {
            lines.append("  " + message)
        }
        return lines.joined(separator: "\n")
    }

    /// Full-run transcript — every step concatenated with blank lines
    /// between, so a paste lands as a readable log block.
    static func transcript(of result: TestingResult) -> String {
        let header = "\(result.packageName) — \(result.passed) passed, \(result.warnings) warnings, \(result.failed) errors"
        let body = result.steps.map(Self.transcript(of:)).joined(separator: "\n\n")
        return header + "\n\n" + body
    }
}

/// Push a string onto the macOS general pasteboard. Module-private so
/// the Testing pane's Copy buttons share one implementation.
private func copyToPasteboard(_ string: String) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(string, forType: .string)
}

private struct DetailInspectorColumn: View {
    @Binding var state: TestingStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Notes").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if let entry = state.selectedEntry {
                Form {
                    Section {
                        LabeledContent("Status") {
                            Label(entry.status.title, systemImage: entry.status.systemImage)
                                .foregroundStyle(entry.status.tint)
                        }
                        LabeledContent("Version") {
                            Text(entry.version ?? "—").foregroundStyle(.secondary)
                        }
                        LabeledContent("Tester") {
                            Text(entry.tester ?? "—").foregroundStyle(.secondary)
                        }
                        LabeledContent("Tested") {
                            if let testedAt = entry.testedAt {
                                Text(testedAt, style: .date)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("—").foregroundStyle(.tertiary)
                            }
                        }
                    }
                    Section("Notes") {
                        TextEditor(text: Binding(
                            get: { entry.notes ?? "" },
                            set: { newValue in
                                guard let index = state.checklist.items.firstIndex(where: { $0.id == entry.id }) else { return }
                                state.checklist.items[index].notes = newValue.isEmpty ? nil : newValue
                            }
                        ))
                        .frame(minHeight: 100)
                    }
                }
                .formStyle(.grouped)
            } else {
                ContentUnavailableView(
                    "No selection",
                    systemImage: "doc.text",
                    description: Text("Pick a package on the left.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Style helpers

private extension ChecklistStatus {
    var title: String {
        switch self {
        case .untested: "Untested"
        case .pass:     "Pass"
        case .warning:  "Warning"
        case .fail:     "Fail"
        }
    }

    var systemImage: String {
        switch self {
        case .untested: "circle"
        case .pass:     "checkmark.circle.fill"
        case .warning:  "exclamationmark.triangle.fill"
        case .fail:     "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .untested: .secondary
        case .pass:     .green
        case .warning:  .orange
        case .fail:     .red
        }
    }
}

private extension TestingStepResult.Severity {
    var systemImage: String {
        switch self {
        case .info:    "info.circle"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error:   "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .info:    .secondary
        case .success: .green
        case .warning: .orange
        case .error:   .red
        }
    }
}
