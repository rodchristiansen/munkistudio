import SwiftUI
import Core

/// Outline view of profiles grouped by directory under the user's
/// profiles folder. Same flattened-row approach as `ManifestTreeList` so
/// `List(selection:)` tags each selectable row directly.
struct ProfileTreeList: View {
    @Environment(ProfileStore.self) private var store
    let records: [ProfileRecord]
    let rootPath: String
    var forceExpandAll: Bool = false

    @State private var renameTarget: ProfileRecord?
    @State private var renameText = ""
    @State private var duplicateTarget: ProfileRecord?
    @State private var duplicateText = ""
    @State private var deleteTarget: ProfileRecord?

    var body: some View {
        @Bindable var bindable = store
        return List(selection: $bindable.selectedID) {
            ForEach(rows) { row in
                if case .leaf(let record, _) = row.kind {
                    ProfileRow(row: row)
                        .tag(record.fileURL)
                        .listRowSeparator(.hidden)
                        .contextMenu { leafMenu(for: record) }
                } else {
                    ProfileRow(row: row)
                        .listRowSeparator(.hidden)
                }
            }
        }
        .alert("Rename Profile", isPresented: renamePresented) {
            TextField("Name", text: $renameText)
            Button("Rename", action: commitRename)
            Button("Cancel", role: .cancel) { renameTarget = nil }
        } message: {
            Text("Names may include slashes to nest the file under the profiles folder.")
        }
        .alert("Duplicate Profile", isPresented: duplicatePresented) {
            TextField("Name", text: $duplicateText)
            Button("Duplicate", action: commitDuplicate)
            Button("Cancel", role: .cancel) { duplicateTarget = nil }
        } message: {
            Text("Creates a copy with a fresh PayloadUUID and PayloadIdentifier.")
        }
        .alert("Delete Profile", isPresented: deletePresented, presenting: deleteTarget) { record in
            Button("Delete", role: .destructive) {
                Task { await store.delete(record) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { record in
            Text("Delete \u{201c}\(record.listLabel)\u{201d}? This removes the .mobileconfig from disk and can't be undone.")
        }
    }

    @ViewBuilder
    private func leafMenu(for record: ProfileRecord) -> some View {
        Button("Rename\u{2026}") {
            renameText = nameForRename(record)
            renameTarget = record
        }
        Button("Duplicate\u{2026}") {
            duplicateText = nameForRename(record) + " copy"
            duplicateTarget = record
        }
        Divider()
        Button("Delete\u{2026}", role: .destructive) {
            deleteTarget = record
        }
    }

    private func nameForRename(_ record: ProfileRecord) -> String {
        let relative = relativePath(of: record.fileURL)
        return relative.hasSuffix(".mobileconfig")
            ? String(relative.dropLast(".mobileconfig".count))
            : relative
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
        Task { await store.rename(target, to: name, directory: rootURL) }
    }

    private func commitDuplicate() {
        guard let target = duplicateTarget else { return }
        let name = duplicateText.trimmingCharacters(in: .whitespacesAndNewlines)
        duplicateTarget = nil
        guard !name.isEmpty else { return }
        Task { await store.duplicate(target, as: name, directory: rootURL) }
    }

    private var rootURL: URL {
        URL(fileURLWithPath: rootPath)
    }

    /// File path relative to the profiles root, slash-joined.
    private func relativePath(of url: URL) -> String {
        let rootComponents = rootURL.standardizedFileURL.pathComponents
        let urlComponents = url.standardizedFileURL.pathComponents
        guard urlComponents.starts(with: rootComponents) else {
            return url.lastPathComponent
        }
        return urlComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    // MARK: Flat-row build

    private var rows: [ProfileFlatRow] {
        var result: [ProfileFlatRow] = []
        let nodes = ProfileNode.build(from: records.map { (relativePath(of: $0.fileURL), $0) })
        for node in nodes {
            appendFlat(node: node, depth: 0, into: &result)
        }
        return result
    }

    private func appendFlat(node: ProfileNode, depth: Int, into result: inout [ProfileFlatRow]) {
        if node.children.isEmpty {
            if let record = node.record {
                result.append(ProfileFlatRow(
                    id: node.fullPath,
                    depth: depth,
                    kind: .leaf(record, label: node.name)
                ))
            }
            return
        }
        let expanded = forceExpandAll || store.expandedPaths.contains(node.fullPath)
        let totalLeaves = node.totalLeafCount
        result.append(ProfileFlatRow(
            id: node.fullPath + ".__folder__",
            depth: depth,
            kind: .folder(path: node.fullPath, name: node.name, count: totalLeaves, expanded: expanded)
        ))
        guard expanded else { return }
        for child in node.children {
            appendFlat(node: child, depth: depth + 1, into: &result)
        }
    }
}

struct ProfileFlatRow: Identifiable, Hashable {
    let id: String
    let depth: Int
    let kind: Kind

    enum Kind: Hashable {
        case leaf(ProfileRecord, label: String)
        case folder(path: String, name: String, count: Int, expanded: Bool)
    }
}

struct ProfileRow: View {
    @Environment(ProfileStore.self) private var store
    let row: ProfileFlatRow

    var body: some View {
        switch row.kind {
        case .leaf(let record, let label):
            HStack(spacing: 6) {
                indentSpacer
                Color.clear.frame(width: 14, height: 1)
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
                    .imageScale(.small)
                Text(label)
                if store.drafts[record.fileURL] != nil {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                        .help("Unsaved changes")
                }
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
                    Image(systemName: "folder")
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
        if store.expandedPaths.contains(path) {
            store.expandedPaths.remove(path)
        } else {
            store.expandedPaths.insert(path)
        }
    }
}

// MARK: Tree model

struct ProfileNode: Sendable {
    var name: String
    var fullPath: String
    var record: ProfileRecord?
    var children: [ProfileNode]

    var totalLeafCount: Int {
        (record != nil ? 1 : 0) + children.reduce(0) { $0 + $1.totalLeafCount }
    }

    static func build(from entries: [(String, ProfileRecord)]) -> [ProfileNode] {
        var roots: [String: NodeBuilder] = [:]
        for (path, record) in entries {
            let segments = path.split(separator: "/").map(String.init)
            guard !segments.isEmpty else { continue }
            insert(record: record, segments: segments[...], into: &roots, prefix: "")
        }
        return roots.values
            .map { $0.finalize() }
            .sorted { folderFirst($0, $1) }
    }

    private static func insert(
        record: ProfileRecord,
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

    static func folderFirst(_ a: ProfileNode, _ b: ProfileNode) -> Bool {
        let aIsFolder = !a.children.isEmpty
        let bIsFolder = !b.children.isEmpty
        if aIsFolder != bIsFolder { return aIsFolder && !bIsFolder }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }

    private struct NodeBuilder {
        var name: String
        var fullPath: String
        var record: ProfileRecord?
        var children: [String: NodeBuilder] = [:]

        func finalize() -> ProfileNode {
            let kids = children.values
                .map { $0.finalize() }
                .sorted { ProfileNode.folderFirst($0, $1) }
            return ProfileNode(name: name, fullPath: fullPath, record: record, children: kids)
        }
    }
}
