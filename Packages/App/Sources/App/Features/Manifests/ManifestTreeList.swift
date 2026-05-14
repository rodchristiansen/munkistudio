import SwiftUI
import Core

/// Outline view of manifests grouped by slash-separated paths.
///
/// The list is built as a single flattened sequence of rows (folders +
/// leaves) so SwiftUI's `List(selection:)` actually tags each selectable
/// row directly. Nested recursive views break selection routing in
/// `NavigationSplitView` content columns — found that out the hard way.
struct ManifestTreeList: View {
    @Environment(RepositoryStore.self) private var store
    let records: [ManifestRecord]
    let grouping: ManifestGrouping
    let sort: PackageSort
    var forceExpandAll: Bool = false

    var body: some View {
        @Bindable var bindableStore = store
        List(selection: $bindableStore.selectedItemID) {
            ForEach(rows) { row in
                if let tag = row.selectionTag {
                    ManifestRow(row: row, folderIcon: grouping.folderIcon)
                        .tag(tag)
                        .listRowSeparator(.hidden)
                        .accessibilityLabel(row.accessibilityLabel)
                } else {
                    ManifestRow(row: row, folderIcon: grouping.folderIcon)
                        .listRowSeparator(.hidden)
                        .accessibilityLabel(row.accessibilityLabel)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var rows: [ManifestFlatRow] {
        switch grouping {
        case .directories:
            var result: [ManifestFlatRow] = []
            for node in ManifestNode.build(from: records) {
                appendFlat(node: node, depth: 0, into: &result)
            }
            return result
        case .types:
            return flatGrouped { record in
                referencedNames.contains(record.manifest.manifestName) ? "Included" : "Top-level"
            }
        case .catalogs:
            return flatGrouped { record in
                record.manifest.catalogs?.first ?? "No catalog"
            }
        }
    }

    /// Names referenced from any other manifest's `included_manifests`.
    /// Used by the Types grouping to split "top-level" vs. "included".
    private var referencedNames: Set<String> {
        var refs: Set<String> = []
        for record in store.snapshot.manifests {
            if let included = record.manifest.includedManifests {
                refs.formUnion(included)
            }
        }
        return refs
    }

    /// Build a one-level folder/leaf flat list for flat groupings
    /// (Types, Catalogs). Folder expansion still uses
    /// `expandedManifestPaths` for persistence across re-renders.
    private func flatGrouped(by key: (ManifestRecord) -> String) -> [ManifestFlatRow] {
        let buckets = Dictionary(grouping: records, by: key)
        let folderNames = buckets.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        var result: [ManifestFlatRow] = []
        for name in folderNames {
            let groupRecords = (buckets[name] ?? []).sorted(by: sortRecords)
            let expanded = forceExpandAll || store.expandedManifestPaths.contains(name)
            result.append(ManifestFlatRow(
                id: name + ".__folder__",
                depth: 0,
                kind: .folder(path: name, name: name, count: groupRecords.count, expanded: expanded)
            ))
            if expanded {
                for record in groupRecords {
                    result.append(ManifestFlatRow(
                        id: name + "/" + record.fileURL.path,
                        depth: 1,
                        kind: .leaf(record, label: record.manifest.manifestName)
                    ))
                }
            }
        }
        return result
    }

    private func sortRecords(_ a: ManifestRecord, _ b: ManifestRecord) -> Bool {
        switch sort {
        case .name:
            return a.manifest.manifestName.localizedCaseInsensitiveCompare(b.manifest.manifestName) == .orderedAscending
        case .recentlyModified:
            return (a.modifiedAt ?? .distantPast) > (b.modifiedAt ?? .distantPast)
        }
    }

    private func appendFlat(node: ManifestNode, depth: Int, into result: inout [ManifestFlatRow]) {
        if node.children.isEmpty {
            // Pure leaf — must have a record by construction.
            if let record = node.record {
                result.append(ManifestFlatRow(
                    id: node.fullPath,
                    depth: depth,
                    kind: .leaf(record, label: node.name)
                ))
            }
            return
        }
        let isExpanded = forceExpandAll || store.expandedManifestPaths.contains(node.fullPath)
        let totalLeaves = countLeaves(in: node)
        result.append(ManifestFlatRow(
            id: node.fullPath + ".__folder__",
            depth: depth,
            kind: .folder(path: node.fullPath, name: node.name, count: totalLeaves, expanded: isExpanded)
        ))
        guard isExpanded else { return }
        // A file-and-folder node renders its own manifest as a leaf right
        // inside the expanded folder so users can still open it.
        if let record = node.record {
            result.append(ManifestFlatRow(
                id: node.fullPath + ".__self__",
                depth: depth + 1,
                kind: .leaf(record, label: node.name)
            ))
        }
        for child in node.children {
            appendFlat(node: child, depth: depth + 1, into: &result)
        }
    }

    private func countLeaves(in node: ManifestNode) -> Int {
        (node.hasManifest ? 1 : 0) + node.children.reduce(0) { $0 + countLeaves(in: $1) }
    }
}

struct ManifestFlatRow: Identifiable, Hashable {
    let id: String
    let depth: Int
    let kind: Kind

    enum Kind: Hashable {
        case leaf(ManifestRecord, label: String)
        case folder(path: String, name: String, count: Int, expanded: Bool)
    }

    /// Selection tag — leaves return their record id; folders return nil
    /// so clicking them doesn't change selection (the row itself toggles
    /// expansion via a button).
    var selectionTag: AnyHashable? {
        switch kind {
        case .leaf(let record, _): AnyHashable(record.id)
        case .folder: nil
        }
    }

    var accessibilityLabel: String {
        switch kind {
        case .leaf(_, let label): "Manifest \(label)"
        case .folder(_, let name, let count, let expanded):
            "Folder \(name), \(count) manifests, \(expanded ? "expanded" : "collapsed")"
        }
    }
}

struct ManifestRow: View {
    @Environment(RepositoryStore.self) private var store
    let row: ManifestFlatRow
    let folderIcon: String

    var body: some View {
        switch row.kind {
        case .leaf(_, let label):
            HStack(spacing: 6) {
                indentSpacer
                Color.clear.frame(width: 14, height: 1)
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
                    .imageScale(.small)
                Text(label)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .contentShape(.rect)
        case .folder(let path, let name, let count, let expanded):
            Button {
                toggle(path: path)
            } label: {
                HStack(spacing: 6) {
                    indentSpacer
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .foregroundStyle(.secondary)
                        .imageScale(.small)
                        .frame(width: 14)
                    Image(systemName: folderIcon)
                        .foregroundStyle(.tint)
                        .imageScale(.small)
                    Text(name).bold()
                    Text("\(count)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 3)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }

    private var indentSpacer: some View {
        Color.clear.frame(width: CGFloat(row.depth) * 14, height: 1)
    }

    private func toggle(path: String) {
        if store.expandedManifestPaths.contains(path) {
            store.expandedManifestPaths.remove(path)
        } else {
            store.expandedManifestPaths.insert(path)
        }
    }
}

// MARK: Model (unchanged tree-build algorithm)

struct ManifestNode: Identifiable, Sendable {
    var name: String
    var fullPath: String
    var record: ManifestRecord?
    var children: [ManifestNode]

    var id: String { fullPath }
    var hasManifest: Bool { record != nil }

    static func build(from records: [ManifestRecord]) -> [ManifestNode] {
        var roots: [String: NodeBuilder] = [:]
        for record in records {
            let segments = record.manifest.manifestName.split(separator: "/").map(String.init)
            guard !segments.isEmpty else { continue }
            insert(record: record, segments: segments[...], into: &roots, prefix: "")
        }
        return roots.values
            .map { $0.finalize() }
            .sorted { folderFirst($0, $1) }
    }

    private static func insert(
        record: ManifestRecord,
        segments: ArraySlice<String>,
        into bucket: inout [String: NodeBuilder],
        prefix: String
    ) {
        guard let head = segments.first else { return }
        let path = prefix.isEmpty ? head : prefix + "/" + head
        let isLeaf = segments.count == 1
        var builder = bucket[head] ?? NodeBuilder(name: head, fullPath: path)
        if isLeaf {
            builder.record = record
        } else {
            insert(record: record, segments: segments.dropFirst(), into: &builder.children, prefix: path)
        }
        bucket[head] = builder
    }

    static func folderFirst(_ a: ManifestNode, _ b: ManifestNode) -> Bool {
        let aIsFolder = !a.children.isEmpty
        let bIsFolder = !b.children.isEmpty
        if aIsFolder != bIsFolder { return aIsFolder && !bIsFolder }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }

    private struct NodeBuilder {
        var name: String
        var fullPath: String
        var record: ManifestRecord?
        var children: [String: NodeBuilder] = [:]

        func finalize() -> ManifestNode {
            let kids = children.values
                .map { $0.finalize() }
                .sorted { ManifestNode.folderFirst($0, $1) }
            return ManifestNode(name: name, fullPath: fullPath, record: record, children: kids)
        }
    }
}
