import SwiftUI
import Core

/// Outline view of manifests grouped by their slash-separated paths.
/// `Assigned/Faculty/Instructor/AdrianaJaroszewicz` becomes a four-level
/// tree where the leaf is the only selectable node (folder rows expand
/// children but don't open an editor).
struct ManifestTreeList: View {
    @Environment(RepositoryStore.self) private var store
    let records: [ManifestRecord]

    var body: some View {
        @Bindable var bindableStore = store
        List(selection: $bindableStore.selectedItemID) {
            ForEach(rootNodes, id: \.fullPath) { node in
                ManifestNodeRow(node: node)
            }
        }
    }

    private var rootNodes: [ManifestNode] {
        ManifestNode.build(from: records)
    }
}

/// Builds itself recursively from a list of manifest records. Leaves carry
/// the `record`; intermediate folders have it `nil`.
struct ManifestNode: Identifiable {
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

    private static func folderFirst(_ a: ManifestNode, _ b: ManifestNode) -> Bool {
        if a.hasManifest != b.hasManifest {
            return !a.hasManifest && b.hasManifest
        }
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

/// One row in the outline. We render the row body manually so we can show
/// both a `DisclosureGroup` chevron (for nodes with children) and a tag
/// the List can use as selection (for leaves).
struct ManifestNodeRow: View {
    @Environment(RepositoryStore.self) private var store
    let node: ManifestNode

    var body: some View {
        if node.children.isEmpty {
            leafRow
        } else {
            DisclosureGroup(isExpanded: expansionBinding) {
                ForEach(node.children, id: \.fullPath) { child in
                    ManifestNodeRow(node: child)
                }
            } label: {
                folderLabel
            }
        }
    }

    private var leafRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
                .imageScale(.small)
            Text(node.name)
            Spacer()
        }
        .tag(node.record.map { AnyHashable($0.id) })
    }

    private var folderLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
                .imageScale(.small)
            if node.hasManifest {
                Text(node.name).bold()
                Text("(file + folder)").font(.caption2).foregroundStyle(.tertiary)
            } else {
                Text(node.name).bold()
            }
            Spacer()
            Text("\(leafCount(in: node))")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .contentShape(.rect)
        .onTapGesture(count: 2) {
            if let record = node.record {
                store.selectedItemID = AnyHashable(record.id)
            }
        }
    }

    private var expansionBinding: Binding<Bool> {
        Binding(
            get: { store.expandedManifestPaths.contains(node.fullPath) },
            set: { isExpanded in
                if isExpanded {
                    store.expandedManifestPaths.insert(node.fullPath)
                } else {
                    store.expandedManifestPaths.remove(node.fullPath)
                }
            }
        )
    }

    private func leafCount(in node: ManifestNode) -> Int {
        (node.hasManifest ? 1 : 0) + node.children.reduce(0) { $0 + leafCount(in: $1) }
    }
}
