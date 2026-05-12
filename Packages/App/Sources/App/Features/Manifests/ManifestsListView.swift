import SwiftUI
import Core

/// Middle-column list of manifests with an inline filter field (the same
/// `FilterField` the Packages pane uses).
struct ManifestsListView: View {
    @Environment(RepositoryStore.self) private var store
    @State private var search: String = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var bindableStore = store
        VStack(spacing: 0) {
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
                ManifestTreeList(records: filtered)
            }
        }
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
