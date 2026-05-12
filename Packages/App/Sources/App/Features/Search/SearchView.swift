import SwiftUI
import Core

/// Global search across pkginfos and manifests. Matches name, display
/// name, description, category, and developer for packages; manifest name
/// and any of the install-list arrays for manifests.
struct SearchView: View {
    @Environment(RepositoryStore.self) private var store

    var body: some View {
        @Bindable var bindableStore = store
        VStack(alignment: .leading, spacing: 0) {
            TextField("Search the entire repository…", text: $bindableStore.searchQuery)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .padding(12)
            List(selection: $bindableStore.selectedItemID) {
                if !packageHits.isEmpty {
                    Section("Packages (\(packageHits.count))") {
                        ForEach(packageHits, id: \.id) { record in
                            VStack(alignment: .leading) {
                                Text(record.pkginfo.name).bold()
                                if let dn = record.pkginfo.displayName {
                                    Text(dn).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .tag(AnyHashable(record.id))
                        }
                    }
                }
                if !manifestHits.isEmpty {
                    Section("Manifests (\(manifestHits.count))") {
                        ForEach(manifestHits, id: \.id) { record in
                            Text(record.manifest.manifestName).tag(AnyHashable(record.id))
                        }
                    }
                }
                if store.searchQuery.isEmpty {
                    ContentUnavailableView(
                        "Type to search",
                        systemImage: "magnifyingglass",
                        description: Text("Looks at pkginfo fields and manifest references.")
                    )
                } else if packageHits.isEmpty && manifestHits.isEmpty {
                    ContentUnavailableView.search(text: store.searchQuery)
                }
            }
        }
        .navigationTitle("Search")
    }

    private var packageHits: [PkginfoRecord] {
        guard !store.searchQuery.isEmpty else { return [] }
        let query = store.searchQuery.lowercased()
        return store.snapshot.pkginfos.filter { record in
            record.pkginfo.name.lowercased().contains(query)
                || (record.pkginfo.displayName?.lowercased().contains(query) ?? false)
                || (record.pkginfo.description?.lowercased().contains(query) ?? false)
                || (record.pkginfo.category?.lowercased().contains(query) ?? false)
                || (record.pkginfo.developer?.lowercased().contains(query) ?? false)
        }
    }

    private var manifestHits: [ManifestRecord] {
        guard !store.searchQuery.isEmpty else { return [] }
        let query = store.searchQuery.lowercased()
        return store.snapshot.manifests.filter { record in
            if record.manifest.manifestName.lowercased().contains(query) { return true }
            for list in [
                record.manifest.managedInstalls,
                record.manifest.managedUninstalls,
                record.manifest.managedUpdates,
                record.manifest.optionalInstalls,
                record.manifest.includedManifests,
            ] {
                if list?.contains(where: { $0.lowercased().contains(query) }) == true { return true }
            }
            return false
        }
    }
}

struct SearchDetailView: View {
    @Environment(RepositoryStore.self) private var store

    var body: some View {
        if let id = store.selectedItemID,
           let url = id.base as? URL {
            if let pkginfo = store.snapshot.pkginfos.first(where: { $0.fileURL == url }) {
                PackageDetailView()
                    .environment(store)
                    .id(pkginfo.id)
            } else if let manifest = store.snapshot.manifests.first(where: { $0.fileURL == url }) {
                ManifestDetailView()
                    .environment(store)
                    .id(manifest.id)
            } else {
                Text("Item not found").foregroundStyle(.secondary)
            }
        } else {
            ContentUnavailableView(
                "No result selected",
                systemImage: "magnifyingglass"
            )
        }
    }
}
