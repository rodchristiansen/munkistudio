import SwiftUI
import Core

/// Middle-column list of manifests with an inline filter field (the same
/// `FilterField` the Packages pane uses).
struct ManifestsListView: View {
    @Environment(RepositoryStore.self) private var store
    @State private var search: String = ""
    @State private var criteriaGroup = ManifestCriteriaGroup()
    @State private var filterPopoverShown = false
    @State private var showNewManifest = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var bindableStore = store
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("", selection: $bindableStore.manifestsGrouping) {
                    ForEach(ManifestGrouping.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Spacer()
                Button {
                    showNewManifest = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("New manifest")
                .disabled(store.repository == nil)
                filterButton
                SortMenu(sort: $bindableStore.manifestsSort)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            FilterField(text: $search, prompt: "Filter manifests", focused: $searchFocused)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            if store.snapshot.manifests.isEmpty {
                ContentUnavailableView {
                    Label("No manifests found", systemImage: "list.bullet.rectangle")
                } description: {
                    if let repo = store.repository {
                        Text("Scanned \(repo.manifestsURL.path) — found nothing that parses as a manifest.")
                    } else {
                        Text("Open a Munki repository to see manifests here.")
                    }
                }
            } else {
                ManifestTreeList(
                    records: filtered,
                    grouping: store.manifestsGrouping,
                    sort: store.manifestsSort,
                    forceExpandAll: !search.isEmpty || !criteriaGroup.criteria.isEmpty
                )
            }
        }
        .navigationTitle("Manifests")
        .navigationSubtitle(manifestsSubtitle)
        .sheet(isPresented: $showNewManifest) {
            NewManifestSheet()
        }
        .alert("Couldn't Complete Action", isPresented: errorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.manifestActionError ?? "")
        }
        .onChange(of: store.pendingManifestCriteria, initial: true) { _, new in
            guard let new else { return }
            criteriaGroup = new
            search = ""
            store.pendingManifestCriteria = nil
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { store.manifestActionError != nil },
            set: { if !$0 { store.manifestActionError = nil } }
        )
    }

    /// Manifest count plus the total number of `included_manifests`
    /// references across them, shown as the column's title-bar subtitle.
    private var manifestsSubtitle: String {
        let records = store.snapshot.manifests
        let total = records.count
        let included = records.reduce(0) { $0 + ($1.manifest.includedManifests?.count ?? 0) }
        return "\(total) manifest\(total == 1 ? "" : "s") · \(included) included"
    }

    @ViewBuilder
    private var filterButton: some View {
        FilterButton(
            isActive: !criteriaGroup.criteria.isEmpty,
            count: criteriaGroup.criteria.count,
            onClear: { criteriaGroup.criteria.removeAll() }
        ) {
            if criteriaGroup.criteria.isEmpty {
                criteriaGroup.criteria.append(
                    ManifestCriterion(
                        attribute: .name,
                        op: ManifestAttribute.name.allowedOperators.first ?? .contains,
                        value: ""
                    )
                )
            }
            filterPopoverShown = true
        }
        .popover(isPresented: $filterPopoverShown, arrowEdge: .top) {
            ManifestCriteriaEditor(group: $criteriaGroup)
                .frame(minWidth: 520, idealWidth: 580)
                .padding(12)
        }
    }

    private var filtered: [ManifestRecord] {
        let referencingIndex = referencingIndex
        var base = store.snapshot.manifests
        if !criteriaGroup.criteria.isEmpty {
            base = base.filter { record in
                criteriaGroup.matches(context(for: record, referencingIndex: referencingIndex))
            }
        }
        guard !search.isEmpty else { return base }
        let query = search.lowercased()
        return base.filter { record in
            record.manifest.manifestName.lowercased().contains(query)
                || (record.manifest.displayName?.lowercased().contains(query) ?? false)
        }
    }

    /// Reverse index: each manifest name → the names of manifests that
    /// reference it via `included_manifests`. Built once per render
    /// because the criteria evaluator needs the referencing-count and
    /// referencing-name attributes.
    private var referencingIndex: [String: [String]] {
        var map: [String: [String]] = [:]
        for record in store.snapshot.manifests {
            let me = record.manifest.manifestName
            for ref in record.manifest.includedManifests ?? [] {
                map[ref, default: []].append(me)
            }
        }
        return map
    }

    private func context(for record: ManifestRecord, referencingIndex: [String: [String]]) -> ManifestRecordContext {
        ManifestRecordContext(
            manifest: record.manifest,
            filename: record.fileURL.lastPathComponent,
            referencingManifests: referencingIndex[record.manifest.manifestName] ?? []
        )
    }
}

enum ManifestGrouping: String, CaseIterable, Identifiable, Hashable {
    /// File-system layout — the existing slash-path tree.
    case directories
    /// Top-level vs. included — bucket manifests by whether anything
    /// in the repo references them via `included_manifests`.
    case types
    case catalogs
    var id: String { rawValue }
    var title: String {
        switch self {
        case .directories: "Directories"
        case .types: "Types"
        case .catalogs: "Catalogs"
        }
    }

    /// SF Symbol for folder rows when grouping by this scope.
    var folderIcon: String {
        switch self {
        case .directories: "folder"
        case .types: "square.stack.3d.up"
        case .catalogs: "books.vertical"
        }
    }
}

/// Sheet for creating a new, empty manifest — a name (slashes allowed for
/// nesting) and the on-disk format.
private struct NewManifestSheet: View {
    @Environment(RepositoryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var format: RepoFormat = .plist

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `nil` while the field is empty (show the neutral hint instead) or
    /// when the name is valid; otherwise the reason it's rejected.
    private var rejectionReason: String? {
        name.isEmpty ? nil : Manifest.nameRejectionReason(name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Manifest").font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                TextField("Manifest name", text: $name)
                    .textFieldStyle(.roundedBorder)
                if let rejectionReason {
                    Text(rejectionReason)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    Text("Use slashes to nest, e.g. labs/imac-lab.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Picker("Format", selection: $format) {
                ForEach(RepoFormat.allCases, id: \.self) { fmt in
                    Text(fmt.preferredExtension.uppercased()).tag(fmt)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(Manifest.nameRejectionReason(name) != nil)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { format = store.repository?.defaultFormat ?? .plist }
    }

    private func create() {
        guard Manifest.nameRejectionReason(name) == nil else { return }
        let chosenName = trimmedName
        let chosenFormat = format
        dismiss()
        Task { await store.createManifest(named: chosenName, format: chosenFormat) }
    }
}
