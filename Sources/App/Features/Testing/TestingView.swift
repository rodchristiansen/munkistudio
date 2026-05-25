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
                        ChecklistColumn(state: $localStore)
                            .frame(minWidth: 260, idealWidth: 300, maxHeight: .infinity)
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
                        Button {
                            Task { await runSelected() }
                        } label: {
                            Label("Validate", systemImage: "checkmark.seal")
                        }
                        .labelStyle(.titleAndIcon)
                        .disabled(localStore.selectedEntry == nil)

                        Button {
                            Task { await prepareAutofix() }
                        } label: {
                            Label("Autofix", systemImage: "wand.and.stars")
                        }
                        .labelStyle(.titleAndIcon)
                        .disabled(localStore.selectedEntry == nil)
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
                    // Persistence: flush the checklist (JSON + Markdown).
                    ToolbarItemGroup {
                        Button {
                            Task { await save() }
                        } label: {
                            Label("Save checklist", systemImage: "tray.and.arrow.down")
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

    private func runSelected() async {
        guard let entry = localStore.selectedEntry,
              let repository = store.repository else { return }
        let configuration = TestEnvironmentFactory.Configuration(settings: settings)
        let environment: (any TestEnvironment)?
        do {
            environment = try await TestEnvironmentFactory.make(configuration: configuration)
        } catch {
            localStore.errorMessage = error.localizedDescription
            return
        }
        await localStore.validate(
            entry: entry,
            snapshot: store.snapshot,
            repository: repository,
            services: store.services,
            munkipkgProjectsFolder: munkipkgProjectsFolderURL,
            environment: environment,
            tester: effectiveTester
        )
    }

    private var effectiveTester: String {
        let configured = settings.testerName.trimmingCharacters(in: .whitespaces)
        return configured.isEmpty ? NSFullUserName() : configured
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

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Checklist").font(.headline)
                Spacer()
                Text("\(passCount)/\(state.checklist.items.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            List(selection: Binding(
                get: { state.selectedEntryID },
                set: { state.selectedEntryID = $0 }
            )) {
                ForEach(state.checklist.items) { entry in
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
                    }
                    .tag(entry.id)
                }
            }
            .listStyle(.inset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var passCount: Int {
        state.checklist.items.filter { $0.status == .pass }.count
    }
}

private struct StepTimelineColumn: View {
    @Binding var state: TestingStore
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(state.selectedEntry?.packageName ?? "Select a package")
                    .font(.headline)
                Spacer()
                if let entry = state.selectedEntry {
                    StatusMenu(entry: entry, state: $state)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if let result = state.selectedResult {
                List {
                    Section {
                        ForEach(result.steps) { step in
                            StepRow(step: step)
                        }
                    } header: {
                        HStack {
                            Text("\(result.passed) passed · \(result.warnings) warnings · \(result.failed) errors")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(result.finishedAt, style: .time)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .listStyle(.inset)
            } else if state.selectedEntry != nil {
                ContentUnavailableView(
                    "Not validated yet",
                    systemImage: "play.circle",
                    description: Text("Click Validate in the toolbar to run the schema checks.")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: step.severity.systemImage)
                    .foregroundStyle(step.severity.tint)
                Text(step.title).font(.body)
                Spacer()
                if step.duration > 0 {
                    Text(step.duration, format: .number.precision(.fractionLength(2)))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            ForEach(step.messages, id: \.self) { message in
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }
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
