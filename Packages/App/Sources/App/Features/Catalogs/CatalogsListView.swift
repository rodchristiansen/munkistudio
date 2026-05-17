import SwiftUI
import Core

/// Catalog list — read-only projection of `pkginfo.catalogs[]` union.
struct CatalogsListView: View {
    @Environment(RepositoryStore.self) private var store
    @State private var search: String = ""
    @State private var makecatalogsPresented: Bool = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var bindableStore = store
        VStack(spacing: 0) {
            HStack {
                FilterField(text: $search, prompt: "Filter catalogs", focused: $searchFocused)
                Button {
                    makecatalogsPresented = true
                } label: {
                    Label("makecatalogs", systemImage: "books.vertical")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Rebuild catalog files from pkginfo metadata")
            }
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
                        HStack(spacing: 6) {
                            Text(catalog.name)
                            Text("\(catalog.pkginfoNames.count)")
                                .foregroundStyle(.tertiary)
                                .font(.caption.monospaced())
                            Spacer(minLength: 0)
                        }
                        .tag(AnyHashable(catalog.name))
                    }
                }
            }
        }
        .navigationTitle("Catalogs")
        .navigationSubtitle("\(store.snapshot.catalogs.count) total")
        .sheet(isPresented: $makecatalogsPresented) {
            MakecatalogsSheet()
        }
    }

    private var filtered: [Catalog] {
        guard !search.isEmpty else { return store.snapshot.catalogs }
        let query = search.lowercased()
        return store.snapshot.catalogs.filter { $0.name.lowercased().contains(query) }
    }
}

struct CatalogDetailView: View {
    @Environment(RepositoryStore.self) private var store
    @State private var packageQuery: String = ""
    @State private var expandedGroups: Set<String> = []
    @FocusState private var queryFocused: Bool

    var body: some View {
        if let catalog = selected {
            VStack(spacing: 0) {
                FilterField(
                    text: $packageQuery,
                    prompt: "Filter packages in \(catalog.name)",
                    focused: $queryFocused
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                List {
                    ForEach(groupedPackages(in: catalog), id: \.name) { group in
                        if group.records.count == 1, let only = group.records.first {
                            CatalogPackageRow(record: only)
                                .padding(.leading, 24)
                                .onTapGesture(count: 2) { openInPackages(only) }
                        } else {
                            // Hand-rolled disclosure: SwiftUI's
                            // DisclosureGroup only toggles when you click
                            // the chevron — we want the whole row to
                            // expand on tap to match Finder-style trees.
                            let isExpanded = expandedGroups.contains(group.name)
                            Button {
                                toggle(group.name)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                        .foregroundStyle(.secondary)
                                        .imageScale(.small)
                                        .frame(width: 14)
                                    Image(systemName: "folder")
                                        .foregroundStyle(.secondary)
                                        .imageScale(.small)
                                    Text(group.name).bold()
                                    Text("\(group.records.count) versions")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.tertiary)
                                    Spacer(minLength: 0)
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            if isExpanded {
                                ForEach(group.records, id: \.id) { record in
                                    CatalogPackageRow(record: record)
                                        .padding(.leading, 24)
                                        .onTapGesture(count: 2) { openInPackages(record) }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("\(catalog.name) (\(catalog.pkginfoNames.count))")
        } else {
            ContentUnavailableView(
                "No catalog selected",
                systemImage: "books.vertical",
                description: Text("Pick a catalog from the list.")
            )
        }
    }

    private func toggle(_ name: String) {
        if expandedGroups.contains(name) {
            expandedGroups.remove(name)
        } else {
            expandedGroups.insert(name)
        }
    }

    private var selected: Catalog? {
        guard let id = store.selectedItemID,
              let name = id.base as? String else { return nil }
        return store.snapshot.catalogs.first { $0.name == name }
    }

    /// Group all pkginfo records that belong to this catalog by their
    /// `name`. Same-named packages with multiple versions collapse into
    /// one row with a disclosure for the versions.
    private func groupedPackages(in catalog: Catalog) -> [VersionGroup] {
        let nameSet = Set(catalog.pkginfoNames)
        var records = store.snapshot.pkginfos.filter { record in
            nameSet.contains(record.pkginfo.name)
        }
        if !packageQuery.isEmpty {
            let query = packageQuery.lowercased()
            records = records.filter { record in
                record.pkginfo.name.lowercased().contains(query)
                    || (record.pkginfo.version?.lowercased().contains(query) ?? false)
            }
        }
        return Dictionary(grouping: records, by: { $0.pkginfo.name })
            .map { (name, recs) in
                VersionGroup(
                    name: name,
                    records: recs.sorted { ($0.pkginfo.version ?? "") > ($1.pkginfo.version ?? "") }
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private struct VersionGroup { let name: String; let records: [PkginfoRecord] }

    /// Switch the workspace to the Packages section and select the
    /// double-clicked pkginfo. Wraps the store mutation so the view
    /// stays declarative.
    private func openInPackages(_ record: PkginfoRecord) {
        store.selectedSection = .packages
        store.selectedItemID = AnyHashable(record.id)
        // Expand the category the package lives in so the user sees the
        // selection rather than a collapsed folder.
        let category = record.pkginfo.category?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? "Uncategorized"
        store.expandedCategories.insert(category)
    }
}

struct CatalogPackageRow: View {
    let record: PkginfoRecord

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "shippingbox")
                .foregroundStyle(Color.munkiStudioBrand)
                .imageScale(.small)
            Text(record.pkginfo.name)
            if let version = record.pkginfo.version {
                Text(version)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
    }
}
