import SwiftUI
import Core

struct DevelopersListView: View {
    @Environment(RepositoryStore.self) private var store

    var body: some View {
        @Bindable var bindableStore = store
        List(selection: $bindableStore.selectedItemID) {
            ForEach(developers, id: \.name) { developer in
                HStack {
                    Text(developer.name)
                    Spacer()
                    Text("\(developer.count)")
                        .foregroundStyle(.secondary)
                        .font(.caption.monospaced())
                }
                .tag(AnyHashable(developer.name))
            }
        }
        .navigationTitle("Developers (\(developers.count))")
    }

    private var developers: [DeveloperGroup] {
        Dictionary(grouping: store.snapshot.pkginfos, by: { $0.pkginfo.developer ?? "Unknown" })
            .map { DeveloperGroup(name: $0.key, count: $0.value.count) }
            .sorted { $0.name < $1.name }
    }

    struct DeveloperGroup { let name: String; let count: Int }
}

struct DeveloperDetailView: View {
    @Environment(RepositoryStore.self) private var store

    var body: some View {
        if let name = (store.selectedItemID?.base as? String) {
            List {
                ForEach(packages(by: name), id: \.id) { record in
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
                "No developer selected",
                systemImage: "person.2"
            )
        }
    }

    private func packages(by developer: String) -> [PkginfoRecord] {
        store.snapshot.pkginfos.filter { ($0.pkginfo.developer ?? "Unknown") == developer }
    }
}
