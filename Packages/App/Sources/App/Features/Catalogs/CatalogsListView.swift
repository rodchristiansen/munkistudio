import SwiftUI
import Core

/// Catalog list — read-only projection of `pkginfo.catalogs[]` union.
struct CatalogsListView: View {
    @Environment(RepositoryStore.self) private var store
    @State private var search: String = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var bindableStore = store
        VStack(spacing: 0) {
            FilterField(text: $search, prompt: "Filter catalogs", focused: $searchFocused)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            if store.snapshot.catalogs.isEmpty {
                ContentUnavailableView(
                    "No catalogs",
                    systemImage: "books.vertical",
                    description: Text("Catalogs are derived from pkginfo.catalogs[] arrays — add at least one package with a catalog name.")
                )
            } else {
                List(selection: $bindableStore.selectedItemID) {
                    ForEach(filtered, id: \.id) { catalog in
                        HStack {
                            Text(catalog.name)
                            Spacer()
                            Text("\(catalog.pkginfoNames.count)")
                                .foregroundStyle(.secondary)
                                .font(.caption.monospaced())
                        }
                        .tag(AnyHashable(catalog.name))
                    }
                }
            }
        }
        .navigationTitle("Catalogs (\(store.snapshot.catalogs.count))")
    }

    private var filtered: [Catalog] {
        guard !search.isEmpty else { return store.snapshot.catalogs }
        let query = search.lowercased()
        return store.snapshot.catalogs.filter { $0.name.lowercased().contains(query) }
    }
}

struct CatalogDetailView: View {
    @Environment(RepositoryStore.self) private var store

    var body: some View {
        if let catalog = selected {
            List {
                Section("Packages in \(catalog.name)") {
                    ForEach(catalog.pkginfoNames, id: \.self) { name in
                        Text(name)
                    }
                }
            }
            .navigationTitle(catalog.name)
        } else {
            ContentUnavailableView(
                "No catalog selected",
                systemImage: "books.vertical",
                description: Text("Pick a catalog from the list.")
            )
        }
    }

    private var selected: Catalog? {
        guard let id = store.selectedItemID,
              let name = id.base as? String else { return nil }
        return store.snapshot.catalogs.first { $0.name == name }
    }
}
