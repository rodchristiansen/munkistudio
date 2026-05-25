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
                HSplitView {
                    ChecklistColumn(state: $localStore)
                        .frame(minWidth: 260, idealWidth: 300)
                    StepTimelineColumn(state: $localStore)
                        .frame(minWidth: 320)
                    DetailInspectorColumn(state: $localStore)
                        .frame(minWidth: 280, idealWidth: 360)
                }
                .toolbar {
                    ToolbarItemGroup {
                        Button {
                            Task { await runSelected() }
                        } label: {
                            Label("Validate", systemImage: "checkmark.seal")
                        }
                        .disabled(localStore.selectedEntry == nil)

                        Button {
                            localStore.selectNextUntested()
                        } label: {
                            Label("Next untested", systemImage: "arrow.forward.circle")
                        }
                        .disabled(localStore.checklist.items.allSatisfy { $0.status != .untested })

                        Button {
                            Task { await save() }
                        } label: {
                            Label("Save checklist", systemImage: "tray.and.arrow.down")
                        }
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
        guard let entry = localStore.selectedEntry else { return }
        await localStore.validate(
            entry: entry,
            snapshot: store.snapshot,
            service: store.services.testing
        )
    }

    private func save() async {
        guard let repository = store.repository else { return }
        await localStore.save(repository: repository, service: store.services.testing)
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
            } else {
                ContentUnavailableView(
                    "No selection",
                    systemImage: "checkmark.seal",
                    description: Text("Pick a package on the left.")
                )
            }
        }
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
            }
        }
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
