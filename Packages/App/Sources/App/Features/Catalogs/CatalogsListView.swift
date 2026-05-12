import SwiftUI
import Core

/// Catalog list — read-only projection of `pkginfo.catalogs[]` union.
struct CatalogsListView: View {
    @Environment(RepositoryStore.self) private var store

    var body: some View {
        @Bindable var bindableStore = store
        List(selection: $bindableStore.selectedItemID) {
            ForEach(store.snapshot.catalogs, id: \.id) { catalog in
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
        .navigationTitle("Catalogs (\(store.snapshot.catalogs.count))")
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
