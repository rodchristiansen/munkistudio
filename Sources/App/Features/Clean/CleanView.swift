import SwiftUI
import Core

/// Full-width Clean section. Previews what `repoclean` would remove from
/// the open repo (safe — deletes nothing), runs a confirmed clean, and
/// lists past runs from the local history.
struct CleanView: View {
    @Environment(RepositoryStore.self) private var store

    @State private var model = CleanStore()
    @State private var mode: Mode = .preview
    @State private var confirmApply = false

    enum Mode: String, CaseIterable, Identifiable {
        case preview = "Preview"
        case history = "History"
        var id: String { rawValue }
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            header(model: model)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSubtitle(subtitle)
        .task(id: store.repository?.rootURL) {
            guard let repo = store.repository else { return }
            await model.loadHistory(
                repoPath: repo.rootURL.path,
                historyService: store.services.repoCleanHistory
            )
            // Run unconditionally: the task re-fires when the open repo
            // changes, and the new repo needs its own preview even though
            // the model still carries the previous repo's phase.
            runPreview()
        }
        .onDisappear { model.cancel() }
        .onChange(of: model.keep) { rescanIfPossible() }
        .onChange(of: model.showAll) { rescanIfPossible() }
        .alert("Clean up this repo?", isPresented: $confirmApply) {
            Button("Clean Up", role: .destructive) { runApply() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
    }

    // MARK: Header

    @ViewBuilder
    private func header(model: CleanStore) -> some View {
        HStack(spacing: 14) {
            Picker("View", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            if mode == .preview {
                Stepper(value: $model.keep, in: 1...20) {
                    Text("Keep \(model.keep) version\(model.keep == 1 ? "" : "s")")
                        .font(.callout)
                }
                .fixedSize()
                .help("How many versions of each item variation repoclean retains")

                Toggle("Show all items", isOn: $model.showAll)
                    .toggleStyle(.checkbox)
                    .font(.callout)
                    .help("List items even when none of their versions would be removed")
            }

            Spacer()

            if mode == .preview {
                Button {
                    runPreview()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .disabled(model.isRunning || store.repository == nil)

                Button {
                    confirmApply = true
                } label: {
                    Label("Clean Up\u{2026}", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.hasDeletions || model.isRunning || model.phase != .ready)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .preview: previewPane
        case .history: historyPane
        }
    }

    @ViewBuilder
    private var previewPane: some View {
        switch model.phase {
        case .idle:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .previewing:
            runningView(title: "Scanning the repo\u{2026}")
        case .cleaning:
            runningView(title: "Cleaning up\u{2026}")
        case .ready:
            readyView
        case .done:
            doneView
        }
    }

    // MARK: Running

    private func runningView(title: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(title).font(.headline)
            }
            .padding(16)
            Divider()
            logPanel
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var logPanel: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(model.output.isEmpty ? "Waiting for repoclean\u{2026}" : model.output)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(model.output.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                Color.clear.frame(height: 1).id("bottom")
            }
            .onChange(of: model.output) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    // MARK: Ready (preview finished)

    @ViewBuilder
    private var readyView: some View {
        if let error = model.errorMessage {
            ContentUnavailableView {
                Label("repoclean failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { runPreview() }
            }
        } else if !model.hasDeletions {
            ContentUnavailableView {
                Label("Nothing to clean up", systemImage: "sparkles")
            } description: {
                Text("repoclean found no versions to remove while keeping \(model.keep) of each item.")
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let summary = model.plan?.summary {
                        summaryBanner(summary)
                    }
                    ForEach(itemsToShow) { item in
                        itemCard(item)
                    }
                    rawLogDisclosure
                }
                .padding(16)
            }
        }
    }

    private var itemsToShow: [RepoCleanPlan.Item] {
        guard let plan = model.plan else { return [] }
        return model.showAll ? plan.items : plan.itemsWithDeletions
    }

    private func summaryBanner(_ summary: RepoCleanPlan.Summary) -> some View {
        HStack(spacing: 16) {
            Image(systemName: "trash")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("^[\(summary.pkginfoItemsToDelete) pkginfo item](inflect: true) and ^[\(summary.pkgsToDelete) package](inflect: true) would be removed")
                    .font(.headline)
                Text("Reclaims \(summary.pkgSpaceSavings) of packages, \(summary.pkginfoSpaceSavings) of pkginfo \u{00b7} keeping \(model.keep) version\(model.keep == 1 ? "" : "s") of each item")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: .rect(cornerRadius: 10))
    }

    private func itemCard(_ item: RepoCleanPlan.Item) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.name).font(.headline)
                Spacer()
                let doomed = item.doomedVersions.count
                if doomed > 0 {
                    Text("^[\(doomed) version](inflect: true) to remove")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            if !item.catalogs.isEmpty {
                Text(item.catalogs.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(item.versions, id: \.self) { version in
                versionRow(version)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 10))
    }

    private func versionRow(_ version: RepoCleanPlan.Version) -> some View {
        HStack(spacing: 8) {
            Image(systemName: version.willDelete ? "trash" : "checkmark.circle")
                .foregroundStyle(version.willDelete ? .orange : .green)
                .imageScale(.small)
            Text(version.version)
                .font(.system(.callout, design: .monospaced))
                .strikethrough(version.willDelete, color: .orange)
            Text(version.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if version.willDelete {
                Text("will be removed").font(.caption).foregroundStyle(.orange)
            } else {
                Text("kept").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var rawLogDisclosure: some View {
        DisclosureGroup("repoclean output") {
            Text(model.output)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        }
        .font(.callout)
    }

    // MARK: Done (apply finished)

    @ViewBuilder
    private var doneView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                let failed = (model.outcome?.exitCode ?? -1) != 0
                HStack(spacing: 16) {
                    Image(systemName: failed ? "xmark.octagon.fill" : "checkmark.seal.fill")
                        .font(.title2)
                        .foregroundStyle(failed ? .red : .green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(failed ? "Clean up failed" : "Clean up complete")
                            .font(.headline)
                        if let record = model.history.first, !failed {
                            Text("Removed ^[\(record.pkginfoItemsDeleted) pkginfo item](inflect: true) and ^[\(record.pkgsDeleted) package](inflect: true) \u{00b7} reclaimed \(record.pkgSpaceSaved)")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else if failed {
                            Text("repoclean exited with code \(model.outcome?.exitCode ?? -1).")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Scan Again") { runPreview() }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background((failed ? Color.red : Color.green).opacity(0.12), in: .rect(cornerRadius: 10))

                rawLogDisclosure
            }
            .padding(16)
        }
    }

    // MARK: History

    @ViewBuilder
    private var historyPane: some View {
        if model.history.isEmpty {
            ContentUnavailableView {
                Label("No clean-ups yet", systemImage: "clock.arrow.circlepath")
            } description: {
                Text("Clean-up runs for this repo will be listed here once you run one.")
            }
        } else {
            List(model.history) { record in
                historyRow(record)
            }
            .listStyle(.inset)
        }
    }

    private func historyRow(_ record: RepoCleanRecord) -> some View {
        DisclosureGroup {
            ForEach(record.removedItems, id: \.self) { item in
                HStack(spacing: 8) {
                    Text(item.name).font(.callout)
                    Text(item.version).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    Spacer()
                    Text(item.path).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.callout)
                    Text("^[\(record.pkginfoItemsDeleted) pkginfo item](inflect: true), ^[\(record.pkgsDeleted) package](inflect: true) removed \u{00b7} kept \(record.keep)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !record.pkgSpaceSaved.isEmpty {
                    Text(record.pkgSpaceSaved)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Subtitle + actions

    private var subtitle: String {
        switch model.phase {
        case .idle, .previewing: "Scanning\u{2026}"
        case .cleaning: "Cleaning up\u{2026}"
        case .ready:
            if let summary = model.plan?.summary, summary.pkginfoItemsToDelete > 0 {
                "\(summary.pkginfoItemsToDelete) item\(summary.pkginfoItemsToDelete == 1 ? "" : "s") to remove"
            } else {
                "Repo is tidy"
            }
        case .done: "Clean up finished"
        }
    }

    private var confirmMessage: String {
        guard let summary = model.plan?.summary else {
            return "This permanently deletes the items marked for removal. repoclean cannot undo this."
        }
        return """
        This permanently deletes \(summary.pkginfoItemsToDelete) pkginfo item\(summary.pkginfoItemsToDelete == 1 ? "" : "s") \
        and \(summary.pkgsToDelete) package\(summary.pkgsToDelete == 1 ? "" : "s"), reclaiming \(summary.pkgSpaceSavings). \
        repoclean cannot undo this.
        """
    }

    private func runPreview() {
        guard let repo = store.repository else { return }
        model.preview(repository: repo, service: store.services.repoClean)
    }

    private func rescanIfPossible() {
        guard mode == .preview, !model.isRunning, store.repository != nil else { return }
        runPreview()
    }

    private func runApply() {
        guard let repo = store.repository else { return }
        model.apply(
            repository: repo,
            service: store.services.repoClean,
            historyService: store.services.repoCleanHistory
        ) {
            await store.reload()
        }
    }
}
