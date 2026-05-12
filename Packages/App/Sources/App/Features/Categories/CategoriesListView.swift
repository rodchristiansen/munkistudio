import SwiftUI
import Core

struct CategoriesListView: View {
    @Environment(RepositoryStore.self) private var store

    var body: some View {
        @Bindable var bindableStore = store
        List(selection: $bindableStore.selectedItemID) {
            ForEach(categories, id: \.name) { category in
                HStack {
                    Text(category.name)
                    Spacer()
                    Text("\(category.count)")
                        .foregroundStyle(.secondary)
                        .font(.caption.monospaced())
                }
                .tag(AnyHashable(category.name))
            }
        }
        .navigationTitle("Categories (\(categories.count))")
    }

    private var categories: [CategoryGroup] {
        Dictionary(grouping: store.snapshot.pkginfos, by: { $0.pkginfo.category ?? "Uncategorized" })
            .map { CategoryGroup(name: $0.key, count: $0.value.count) }
            .sorted { $0.name < $1.name }
    }

    struct CategoryGroup { let name: String; let count: Int }
}

struct CategoryDetailView: View {
    @Environment(RepositoryStore.self) private var store

    var body: some View {
        if let name = (store.selectedItemID?.base as? String) {
            List {
                ForEach(packages(in: name), id: \.id) { record in
                    VStack(alignment: .leading) {
                        Text(record.pkginfo.name)
                        if let version = record.pkginfo.version {
                            Text(version).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(name)
        } else {
            ContentUnavailableView(
                "No category selected",
                systemImage: "tag"
            )
        }
    }

    private func packages(in category: String) -> [PkginfoRecord] {
        store.snapshot.pkginfos.filter { ($0.pkginfo.category ?? "Uncategorized") == category }
    }
}
