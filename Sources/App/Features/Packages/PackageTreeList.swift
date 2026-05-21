import SwiftUI
import AppKit
import Core

/// Flat list of category folder + package leaf rows so `List(selection:)`
/// actually tags every selectable row. Folder rows are Buttons that
/// toggle expansion when *any* part is clicked, not just the chevron.
struct PackageTreeList: View {
    @Environment(RepositoryStore.self) private var store
    let records: [PkginfoRecord]
    let grouping: PackageGrouping
    let sort: PackageSort
    var forceExpandAll: Bool = false

    @State private var renameTarget: PkginfoRecord?
    @State private var renameText = ""
    @State private var duplicateTarget: PkginfoRecord?
    @State private var duplicateText = ""
    @State private var deleteTarget: PkginfoRecord?

    var body: some View {
        @Bindable var bindableStore = store
        ScrollViewReader { proxy in
            List(selection: $bindableStore.selectedItemID) {
                ForEach(rows) { row in
                    if let tag = row.selectionTag {
                        PackageRowView(row: row, folderIcon: grouping.folderIcon)
                            .tag(tag)
                            .listRowSeparator(.hidden)
                            .accessibilityLabel(row.accessibilityLabel)
                            .contextMenu { leafMenu(for: row) }
                    } else {
                        PackageRowView(row: row, folderIcon: grouping.folderIcon)
                            .listRowSeparator(.hidden)
                            .accessibilityLabel(row.accessibilityLabel)
                    }
                }
            }
            .onChange(of: store.pendingRevealItemID, initial: true) { _, target in
                revealItem(target, proxy: proxy)
            }
            .alert("Rename Package File", isPresented: renamePresented) {
                TextField("Filename", text: $renameText)
                Button("Rename", action: commitRename)
                Button("Cancel", role: .cancel) { renameTarget = nil }
            } message: {
                Text("Renames the pkginfo file on disk. The package name and any manifest references are left unchanged.")
            }
            .alert("Duplicate Package", isPresented: duplicatePresented) {
                TextField("Filename", text: $duplicateText)
                Button("Duplicate", action: commitDuplicate)
                Button("Cancel", role: .cancel) { duplicateTarget = nil }
            } message: {
                Text("Creates a copy of this pkginfo file under a new filename.")
            }
            .alert("Delete Package", isPresented: deletePresented, presenting: deleteTarget) { record in
                Button("Delete", role: .destructive) {
                    Task { await store.deletePackage(record) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { record in
                Text("Delete \u{201c}\(record.fileURL.lastPathComponent)\u{201d}? This removes the pkginfo file from disk and can't be undone.")
            }
        }
    }

    @ViewBuilder
    private func leafMenu(for row: PackageFlatRow) -> some View {
        if case .leaf(let record) = row.kind {
            Button("Properties\u{2026}") {
                store.selectedSection = .packages
                store.selectedItemID = AnyHashable(record.id)
            }
            Button("Rename\u{2026}") {
                renameText = record.fileURL.deletingPathExtension().lastPathComponent
                renameTarget = record
            }
            Divider()
            Button("Show pkginfo in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([record.fileURL])
            }
            Button("Show installer in Finder") {
                revealInstaller(for: record)
            }
            .disabled(installerURL(for: record) == nil)
            Button("Search in Manifests") {
                searchInManifests(for: record)
            }
            Divider()
            Button("Import Packages\u{2026}") {
                store.selectedSection = .importer
            }
            Button("Duplicate\u{2026}") {
                duplicateText = record.fileURL.deletingPathExtension().lastPathComponent + " copy"
                duplicateTarget = record
            }
            Button("Delete Package\u{2026}", role: .destructive) {
                deleteTarget = record
            }
            Divider()
            Menu("Catalogs") { catalogsMenu(for: record) }
            Menu("Category") { categoryMenu(for: record) }
            Menu("Developer") { developerMenu(for: record) }
        }
    }

    /// File URL of the installer item the pkginfo points at, resolved
    /// under the repo's `pkgs/` root. `nil` when the location is unset
    /// or the file no longer exists.
    private func installerURL(for record: PkginfoRecord) -> URL? {
        guard let repo = store.repository,
              let location = record.pkginfo.installerItemLocation?
                .trimmingCharacters(in: .whitespaces),
              !location.isEmpty else { return nil }
        let url = repo.pkgsURL.appending(path: location)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func revealInstaller(for record: PkginfoRecord) {
        guard let url = installerURL(for: record) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Jump to the Manifests section pre-filtered to manifests that
    /// reference this package in any install list — the same scope
    /// MunkiAdmin's "Search in Manifests" produces.
    private func searchInManifests(for record: PkginfoRecord) {
        let group = ManifestCriteriaGroup(
            quantifier: .any,
            criteria: [
                ManifestCriterion(
                    attribute: .anyInstallsItem,
                    op: .equals,
                    value: record.pkginfo.name
                )
            ]
        )
        store.pendingManifestCriteria = group
        store.selectedSection = .manifests
    }

    @ViewBuilder
    private func catalogsMenu(for record: PkginfoRecord) -> some View {
        let current = Set(record.pkginfo.catalogs ?? [])
        let available = catalogs(including: current)
        if available.isEmpty {
            Text("No catalogs available")
        } else {
            ForEach(available, id: \.self) { name in
                Button {
                    Task { await toggleCatalog(name, on: record) }
                } label: {
                    Label(name, systemImage: current.contains(name) ? "checkmark" : "")
                }
            }
        }
    }

    @ViewBuilder
    private func categoryMenu(for record: PkginfoRecord) -> some View {
        let current = record.pkginfo.category?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        let names = knownCategories(including: current)
        Button {
            Task { await setCategory(nil, on: record) }
        } label: {
            Label("(none)", systemImage: current == nil ? "checkmark" : "")
        }
        if !names.isEmpty {
            Divider()
            ForEach(names, id: \.self) { name in
                Button {
                    Task { await setCategory(name, on: record) }
                } label: {
                    Label(name, systemImage: current == name ? "checkmark" : "")
                }
            }
        }
    }

    @ViewBuilder
    private func developerMenu(for record: PkginfoRecord) -> some View {
        let current = record.pkginfo.developer?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        let names = knownDevelopers(including: current)
        Button {
            Task { await setDeveloper(nil, on: record) }
        } label: {
            Label("(none)", systemImage: current == nil ? "checkmark" : "")
        }
        if !names.isEmpty {
            Divider()
            ForEach(names, id: \.self) { name in
                Button {
                    Task { await setDeveloper(name, on: record) }
                } label: {
                    Label(name, systemImage: current == name ? "checkmark" : "")
                }
            }
        }
    }

    private func catalogs(including current: Set<String>) -> [String] {
        let known = Set(store.snapshot.catalogs.map(\.name))
        return Array(known.union(current)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func knownCategories(including current: String?) -> [String] {
        var names = Set(store.snapshot.pkginfos.compactMap {
            $0.pkginfo.category?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        })
        if let current { names.insert(current) }
        return Array(names).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func knownDevelopers(including current: String?) -> [String] {
        var names = Set(store.snapshot.pkginfos.compactMap {
            $0.pkginfo.developer?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        })
        if let current { names.insert(current) }
        return Array(names).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func toggleCatalog(_ name: String, on record: PkginfoRecord) async {
        var updated = record.pkginfo
        var catalogs = updated.catalogs ?? []
        if let index = catalogs.firstIndex(of: name) {
            catalogs.remove(at: index)
        } else {
            catalogs.append(name)
        }
        updated.catalogs = catalogs.isEmpty ? nil : catalogs
        await store.applyPkginfoEdit(updated, to: record)
    }

    private func setCategory(_ value: String?, on record: PkginfoRecord) async {
        var updated = record.pkginfo
        updated.category = value
        await store.applyPkginfoEdit(updated, to: record)
    }

    private func setDeveloper(_ value: String?, on record: PkginfoRecord) async {
        var updated = record.pkginfo
        updated.developer = value
        await store.applyPkginfoEdit(updated, to: record)
    }

    private var renamePresented: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }
    private var duplicatePresented: Binding<Bool> {
        Binding(get: { duplicateTarget != nil }, set: { if !$0 { duplicateTarget = nil } })
    }
    private var deletePresented: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    }

    private func commitRename() {
        guard let target = renameTarget else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        renameTarget = nil
        guard !name.isEmpty else { return }
        Task { await store.renamePackage(target, to: name) }
    }

    private func commitDuplicate() {
        guard let target = duplicateTarget else { return }
        let name = duplicateText.trimmingCharacters(in: .whitespacesAndNewlines)
        duplicateTarget = nil
        guard !name.isEmpty else { return }
        Task { await store.duplicatePackage(target, as: name) }
    }

    /// Expand the category holding the reveal target and scroll its row
    /// into view. Driven by search / Back-Forward navigation — never by a
    /// plain row click — so clicking a visible row doesn't yank the list.
    private func revealItem(_ target: AnyHashable?, proxy: ScrollViewProxy) {
        guard let url = target?.base as? URL,
              let record = records.first(where: { $0.fileURL == url }) else { return }
        store.expandedCategories.insert(groupKey(for: record))
        store.pendingRevealItemID = nil
        // Two-pass scroll: a lazy List hasn't measured rows it has never
        // drawn, so a single scrollTo to an off-screen row lands short.
        // The first pass jumps roughly there and forces those rows to be
        // realised; the second lands on the row precisely.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            proxy.scrollTo(url.path, anchor: .center)
            try? await Task.sleep(for: .milliseconds(120))
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(url.path, anchor: .center)
            }
        }
    }

    private var rows: [PackageFlatRow] {
        var result: [PackageFlatRow] = []
        for node in nodes {
            let isExpanded = forceExpandAll || store.expandedCategories.contains(node.category)
            result.append(PackageFlatRow(
                id: node.category + ".__folder__",
                kind: .folder(category: node.category, count: node.records.count, expanded: isExpanded)
            ))
            if isExpanded {
                for record in node.records {
                    result.append(PackageFlatRow(
                        id: record.fileURL.path,
                        kind: .leaf(record)
                    ))
                }
            }
        }
        return result
    }

    /// Group key per record for the current ``grouping`` mode. Strings
    /// keep the bucket logic uniform even for grouping modes that
    /// could theoretically use richer types.
    private func groupKey(for record: PkginfoRecord) -> String {
        switch grouping {
        case .categories:
            (record.pkginfo.category?.trimmingCharacters(in: .whitespaces).nilIfEmpty) ?? "Uncategorized"
        case .types:
            record.pkginfo.installerType.map(typeLabel) ?? "Unspecified"
        case .developers:
            (record.pkginfo.developer?.trimmingCharacters(in: .whitespaces).nilIfEmpty) ?? "Unknown developer"
        case .directories:
            directoryLabel(for: record)
        }
    }

    private func typeLabel(_ type: InstallerType) -> String {
        switch type {
        case .unknown(let value): value.isEmpty ? "Unspecified" : value
        default: type.rawValue
        }
    }

    private func directoryLabel(for record: PkginfoRecord) -> String {
        guard let repo = store.repository else { return record.fileURL.deletingLastPathComponent().lastPathComponent }
        let root = repo.pkgsinfoURL.resolvingSymlinksInPath().path
        let dir = record.fileURL.deletingLastPathComponent().resolvingSymlinksInPath().path
        let prefix = root + "/"
        if dir == root { return "/" }
        if dir.hasPrefix(prefix) { return String(dir.dropFirst(prefix.count)) }
        return record.fileURL.deletingLastPathComponent().lastPathComponent
    }

    private var nodes: [CategoryNode] {
        Dictionary(grouping: records) { groupKey(for: $0) }
            .map { CategoryNode(category: $0.key, records: $0.value.sorted(by: sortRecords)) }
            .sorted { $0.category.localizedCaseInsensitiveCompare($1.category) == .orderedAscending }
    }

    private func sortRecords(_ a: PkginfoRecord, _ b: PkginfoRecord) -> Bool {
        switch sort {
        case .name:
            return a.pkginfo.name.localizedCaseInsensitiveCompare(b.pkginfo.name) == .orderedAscending
        case .recentlyModified:
            return (a.modifiedAt ?? .distantPast) > (b.modifiedAt ?? .distantPast)
        }
    }
}

struct PackageFlatRow: Identifiable, Hashable {
    let id: String
    let kind: Kind

    enum Kind: Hashable {
        case folder(category: String, count: Int, expanded: Bool)
        case leaf(PkginfoRecord)
    }

    var selectionTag: AnyHashable? {
        switch kind {
        case .leaf(let record): AnyHashable(record.id)
        case .folder: nil
        }
    }

    var accessibilityLabel: String {
        switch kind {
        case .leaf(let record):
            let version = record.pkginfo.version.map { " version \($0)" } ?? ""
            return "Package \(record.pkginfo.name)\(version)"
        case .folder(let category, let count, let expanded):
            return "Category \(category), \(count) packages, \(expanded ? "expanded" : "collapsed")"
        }
    }
}

struct PackageRowView: View {
    @Environment(RepositoryStore.self) private var store
    let row: PackageFlatRow
    let folderIcon: String

    var body: some View {
        switch row.kind {
        case .folder(let category, let count, let expanded):
            Button {
                toggle(category)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .foregroundStyle(.secondary)
                        .imageScale(.small)
                        .frame(width: 14)
                    Image(systemName: folderIcon)
                        .foregroundStyle(.tint)
                    Text(category).bold()
                    Text("\(count)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 3)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        case .leaf(let record):
            HStack(spacing: 6) {
                // Reserve chevron column so leaves align with folder rows.
                Color.clear.frame(width: 14, height: 1)
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
            .padding(.vertical, 3)
        }
    }

    private func toggle(_ category: String) {
        if store.expandedCategories.contains(category) {
            store.expandedCategories.remove(category)
        } else {
            store.expandedCategories.insert(category)
        }
    }
}

struct CategoryNode: Identifiable {
    var category: String
    var records: [PkginfoRecord]
    var id: String { category }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
