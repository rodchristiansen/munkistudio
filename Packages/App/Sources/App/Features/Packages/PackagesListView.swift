import SwiftUI
import Core

/// Middle-column list of pkginfo records. Backed directly by the store's
/// snapshot; filtering happens here so the data column stays cheap.
struct PackagesListView: View {
    @Environment(RepositoryStore.self) private var store
    @State private var search: String = ""

    var body: some View {
        @Bindable var bindableStore = store
        List(selection: $bindableStore.selectedItemID) {
            ForEach(filtered, id: \.id) { record in
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.pkginfo.name)
                        .font(.body)
                    HStack(spacing: 8) {
                        if let version = record.pkginfo.version {
                            Text(version).foregroundStyle(.secondary)
                        }
                        if let category = record.pkginfo.category {
                            Text(category).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        FormatBadge(format: record.format)
                    }
                    .font(.caption)
                }
                .tag(AnyHashable(record.id))
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Filter packages")
        .navigationTitle("Packages (\(store.snapshot.pkginfos.count))")
    }

    private var filtered: [PkginfoRecord] {
        guard !search.isEmpty else { return store.snapshot.pkginfos }
        let query = search.lowercased()
        return store.snapshot.pkginfos.filter { record in
            record.pkginfo.name.lowercased().contains(query)
                || (record.pkginfo.displayName?.lowercased().contains(query) ?? false)
                || (record.pkginfo.category?.lowercased().contains(query) ?? false)
        }
    }
}

struct FormatBadge: View {
    let format: RepoFormat

    var body: some View {
        Text(format.preferredExtension.uppercased())
            .font(.caption2.monospaced())
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
                .secondary.opacity(0.15),
                in: .capsule
            )
    }
}
