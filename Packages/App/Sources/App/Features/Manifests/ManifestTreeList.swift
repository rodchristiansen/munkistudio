import SwiftUI
import Core

/// Outline view of manifests grouped by slash-separated paths.
///
/// Two corrections over the previous DisclosureGroup-based implementation:
/// 1. **Whole-row tap** toggles a folder's expansion — not just the
///    chevron — so the click target matches what users expect.
/// 2. **File-and-folder** nodes (a manifest that also names a directory
///    of children, e.g. `Shared/Faculty` exists *and* `Shared/Faculty/Desktop`
///    exists) render the manifest leaf *alongside* the folder rather than
///    swallowing it. Previously the leaf disappeared entirely.
struct ManifestTreeList: View {
    @Environment(RepositoryStore.self) private var store
    let records: [ManifestRecord]

    var body: some View {
        @Bindable var bindableStore = store
        List(selection: $bindableStore.selectedItemID) {
            ForEach(rootNodes, id: \.fullPath) { node in
                ManifestTreeRows(node: node, depth: 0)
            }
        }
        .listStyle(.sidebar)
    }

    private var rootNodes: [ManifestNode] {
        ManifestNode.build(from: records)
    }
}

/// Recursive renderer. Returns a folder header (if the node has children)
/// plus, when expanded, the children. If the node *also* carries a
/// manifest record, an extra leaf row is emitted *first* so users can
/// open the manifest itself even when its name doubles as a folder.
struct ManifestTreeRows: View {
    @Environment(RepositoryStore.self) private var store
    let node: ManifestNode
    let depth: Int

    var body: some View {
        if node.children.isEmpty {
            ManifestLeafRow(node: node, depth: depth)
        } else {
            ManifestFolderRow(node: node, depth: depth)
            if isExpanded {
                if let record = node.record {
                    // Leaf for the manifest itself, shown at the same
                    // depth as its sibling folders so the path is clear.
                    ManifestLeafRow(
                        node: ManifestNode(
                            name: node.name,
                            fullPath: node.fullPath + ".__self__",
                            record: record,
                            children: []
                        ),
                        depth: depth + 1,
                        labelOverride: node.name
                    )
                }
                ForEach(node.children, id: \.fullPath) { child in
                    ManifestTreeRows(node: child, depth: depth + 1)
                }
            }
        }
    }

    private var isExpanded: Bool {
        store.expandedManifestPaths.contains(node.fullPath)
    }
}

/// A row for a manifest leaf. Tagged with the record's URL so the
/// surrounding `List`'s selection binding can fire when it's clicked.
struct ManifestLeafRow: View {
    let node: ManifestNode
    let depth: Int
    var labelOverride: String?

    var body: some View {
        HStack(spacing: 6) {
            indentSpacer
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
                .imageScale(.small)
                .frame(width: 14)
            Text(labelOverride ?? node.name)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .tag(node.record.map { AnyHashable($0.id) })
    }

    private var indentSpacer: some View {
        Color.clear.frame(width: CGFloat(depth) * 14 + 12, height: 1)
    }
}

/// A folder row. Whole row is tappable: a tap toggles expansion, a
/// double-tap also toggles expansion (so it never feels broken).
struct ManifestFolderRow: View {
    @Environment(RepositoryStore.self) private var store
    let node: ManifestNode
    let depth: Int

    var body: some View {
        HStack(spacing: 6) {
            indentSpacer
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .foregroundStyle(.secondary)
                .imageScale(.small)
                .frame(width: 14)
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
                .imageScale(.small)
            Text(node.name).bold()
            Text("\(totalLeafCount)")
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        .onTapGesture { toggle() }
        // Non-selectable: tagging with nil means the surrounding List
        // doesn't treat the folder click as a selection change.
        .tag(AnyHashable?.none)
    }

    private var indentSpacer: some View {
        Color.clear.frame(width: CGFloat(depth) * 14, height: 1)
    }

    private var isExpanded: Bool {
        store.expandedManifestPaths.contains(node.fullPath)
    }

    private func toggle() {
        if isExpanded {
            store.expandedManifestPaths.remove(node.fullPath)
        } else {
            store.expandedManifestPaths.insert(node.fullPath)
        }
    }

    private var totalLeafCount: Int {
        countLeaves(in: node)
    }

    private func countLeaves(in node: ManifestNode) -> Int {
        (node.hasManifest ? 1 : 0) + node.children.reduce(0) { $0 + countLeaves(in: $1) }
    }
}

// MARK: Model

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
