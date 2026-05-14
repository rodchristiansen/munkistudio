import SwiftUI
import Core

/// Middle-column list of manifests with an inline filter field (the same
/// `FilterField` the Packages pane uses).
struct ManifestsListView: View {
    @Environment(RepositoryStore.self) private var store
    @State private var search: String = ""
    @State private var grouping: ManifestGrouping = .directories
    @State private var sort: PackageSort = .name
    @State private var criteriaGroup = ManifestCriteriaGroup()
    @State private var criteriaExpanded = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var bindableStore = store
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("", selection: $grouping) {
                    ForEach(ManifestGrouping.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { criteriaExpanded.toggle() }
                } label: {
                    Label(
                        criteriaGroup.criteria.isEmpty ? "Rules" : "Rules (\(criteriaGroup.criteria.count))",
                        systemImage: criteriaExpanded ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
                    )
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Build a smart filter over manifest attributes")
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(PackageSort.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                } label: {
                    Label("Sort: \(sort.title)", systemImage: "arrow.up.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            if criteriaExpanded {
                ManifestCriteriaEditor(group: $criteriaGroup)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
            }
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
                ManifestTreeList(records: filtered, grouping: grouping, sort: sort)
            }
        }
        .navigationTitle("Manifests (\(store.snapshot.manifests.count))")
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
    /// Top-level vs. included — bucket manifests by whether anything
    /// in the repo references them via `included_manifests`.
    case types
    case catalogs
    /// File-system layout — the existing slash-path tree.
    case directories
    var id: String { rawValue }
    var title: String {
        switch self {
        case .types: "Types"
        case .catalogs: "Catalogs"
        case .directories: "Directories"
        }
    }
}
