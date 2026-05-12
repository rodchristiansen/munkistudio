import SwiftUI
import Core

/// Middle-column list of manifests, filtered by a local search field.
struct ManifestsListView: View {
    @Environment(RepositoryStore.self) private var store
    @State private var search: String = ""

    var body: some View {
        @Bindable var bindableStore = store
        List(selection: $bindableStore.selectedItemID) {
            ForEach(filtered, id: \.id) { record in
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.manifest.manifestName)
                    HStack(spacing: 8) {
                        if let cats = record.manifest.catalogs, !cats.isEmpty {
                            Text(cats.joined(separator: ", ")).foregroundStyle(.secondary)
                        }
                        Spacer()
                        FormatBadge(format: record.format)
                    }
                    .font(.caption)
                }
                .tag(AnyHashable(record.id))
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Filter manifests")
        .navigationTitle("Manifests (\(store.snapshot.manifests.count))")
    }

    private var filtered: [ManifestRecord] {
        guard !search.isEmpty else { return store.snapshot.manifests }
        let query = search.lowercased()
        return store.snapshot.manifests.filter { record in
            record.manifest.manifestName.lowercased().contains(query)
                || (record.manifest.displayName?.lowercased().contains(query) ?? false)
        }
    }
}
