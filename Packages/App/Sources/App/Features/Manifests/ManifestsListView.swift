import SwiftUI
import Core

/// Middle-column list of manifests with an inline filter field (the same
/// `FilterField` the Packages pane uses).
struct ManifestsListView: View {
    @Environment(RepositoryStore.self) private var store
    @State private var search: String = ""
    @State private var criteriaGroup = ManifestCriteriaGroup()
    @State private var filterPopoverShown = false
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
    }

    /// Manifest count plus how many are pulled in as sub-manifests,
    /// shown as the column's title-bar subtitle.
    private var manifestsSubtitle: String {
        let records = store.snapshot.manifests
        let total = records.count
        let includedNames = Set(records.flatMap { $0.manifest.includedManifests ?? [] })
        let included = records.filter { includedNames.contains($0.manifest.manifestName) }.count
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
