import SwiftUI
import Core

/// Flat list of category folder + package leaf rows so `List(selection:)`
/// actually tags every selectable row. Folder rows are Buttons that
/// toggle expansion when *any* part is clicked, not just the chevron.
struct PackageTreeList: View {
    @Environment(RepositoryStore.self) private var store
    let records: [PkginfoRecord]
    let grouping: PackageGrouping
    let sort: PackageSort

    var body: some View {
        @Bindable var bindableStore = store
        // `List(selection:) { ForEach }` form: `.tag()` only works inside
        // a ForEach. The shorthand `List(data, selection:)` uses item ids,
        // which makes leaves untaggable for our URL-based selection.
        List(selection: $bindableStore.selectedItemID) {
            ForEach(rows) { row in
                if let tag = row.selectionTag {
                    PackageRowView(row: row)
                        .tag(tag)
                        .listRowSeparator(.hidden)
                        .accessibilityLabel(row.accessibilityLabel)
                } else {
                    PackageRowView(row: row)
                        .listRowSeparator(.hidden)
                        .accessibilityLabel(row.accessibilityLabel)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var rows: [PackageFlatRow] {
        var result: [PackageFlatRow] = []
        for node in nodes {
            let isExpanded = store.expandedCategories.contains(node.category)
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
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)
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
