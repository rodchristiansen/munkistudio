import SwiftUI
import AppKit
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
    var onNewManifest: () -> Void = {}

    @State private var renameTarget: ManifestRecord?
    @State private var renameText = ""
    @State private var duplicateTarget: ManifestRecord?
    @State private var duplicateText = ""
    @State private var deleteTarget: ManifestRecord?

    var body: some View {
        @Bindable var bindableStore = store
        ScrollViewReader { proxy in
            list
                .onChange(of: store.pendingRevealItemID, initial: true) { _, target in
                    revealItem(target, proxy: proxy)
                }
        }
    }

    private var list: some View {
        @Bindable var bindableStore = store
        return List(selection: $bindableStore.selectedItemID) {
            ForEach(rows) { row in
                if let tag = row.selectionTag {
                    ManifestRow(row: row, folderIcon: grouping.folderIcon)
                        .tag(tag)
                        .listRowSeparator(.hidden)
                        .accessibilityLabel(row.accessibilityLabel)
                        .contextMenu { leafMenu(for: row) }
                } else {
                    ManifestRow(row: row, folderIcon: grouping.folderIcon)
                        .listRowSeparator(.hidden)
                        .accessibilityLabel(row.accessibilityLabel)
                }
            }
        }
        .alert("Rename Manifest", isPresented: renamePresented) {
            TextField("Name", text: $renameText)
            Button("Rename", action: commitRename)
            Button("Cancel", role: .cancel) { renameTarget = nil }
        } message: {
            Text("Names may include slashes to nest the file under manifests/.")
        }
        .alert("Duplicate Manifest", isPresented: duplicatePresented) {
            TextField("Name", text: $duplicateText)
            Button("Duplicate", action: commitDuplicate)
            Button("Cancel", role: .cancel) { duplicateTarget = nil }
        } message: {
            Text("Creates a copy of this manifest's contents under a new name.")
        }
        .alert("Delete Manifest", isPresented: deletePresented, presenting: deleteTarget) { record in
            Button("Delete", role: .destructive) {
                Task { await store.deleteManifest(record) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { record in
            Text("Delete \u{201c}\(record.manifest.manifestName)\u{201d}? This removes the file from manifests/ and can't be undone.")
        }
    }

    @ViewBuilder
    private func leafMenu(for row: ManifestFlatRow) -> some View {
        if case .leaf(let record, _) = row.kind {
            Button("Properties\u{2026}") {
                store.selectedSection = .manifests
                store.selectedItemID = AnyHashable(record.id)
            }
            Button("Show Manifest in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([record.fileURL])
            }
            Divider()
            Button("New Manifest\u{2026}") {
                onNewManifest()
            }
            Button("Duplicate Manifest\u{2026}") {
                duplicateText = record.manifest.manifestName + " copy"
                duplicateTarget = record
            }
            Button("Import from CSV File\u{2026}") {}
                .disabled(true)
                .help("Coming soon — bulk-import managed_installs from a CSV.")
            Button("Delete Manifest\u{2026}", role: .destructive) {
                deleteTarget = record
            }
            Button("Rename Manifest\u{2026}") {
                renameText = record.manifest.manifestName
                renameTarget = record
            }
            Divider()
            Menu("Catalogs") { catalogsMenu(for: record) }
            Menu("Included Manifests") { includedMenu(for: record) }
        }
    }

    @ViewBuilder
    private func catalogsMenu(for record: ManifestRecord) -> some View {
        let current = Set(record.manifest.catalogs ?? [])
        let names = allCatalogs(including: current)
        if names.isEmpty {
            Text("No catalogs available")
        } else {
            ForEach(names, id: \.self) { name in
                Button {
                    Task { await toggleCatalog(name, on: record) }
                } label: {
                    Label(name, systemImage: current.contains(name) ? "checkmark" : "")
                }
            }
        }
    }

    @ViewBuilder
    private func includedMenu(for record: ManifestRecord) -> some View {
        let current = Set(record.manifest.includedManifests ?? [])
        let selfName = record.manifest.manifestName
        let names = store.snapshot.manifests
            .map(\.manifest.manifestName)
            .filter { $0 != selfName }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        if names.isEmpty {
            Text("No other manifests")
        } else {
            ForEach(names, id: \.self) { name in
                Button {
                    Task { await toggleIncluded(name, on: record) }
                } label: {
                    Label(name, systemImage: current.contains(name) ? "checkmark" : "")
                }
            }
        }
    }

    private func allCatalogs(including current: Set<String>) -> [String] {
        let known = Set(store.snapshot.catalogs.map(\.name))
        return Array(known.union(current))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func toggleCatalog(_ name: String, on record: ManifestRecord) async {
        var updated = record.manifest
        var catalogs = updated.catalogs ?? []
        if let index = catalogs.firstIndex(of: name) {
            catalogs.remove(at: index)
        } else {
            catalogs.append(name)
        }
        updated.catalogs = catalogs.isEmpty ? nil : catalogs
        await store.applyManifestEdit(updated, to: record)
    }

    private func toggleIncluded(_ name: String, on record: ManifestRecord) async {
        var updated = record.manifest
        var included = updated.includedManifests ?? []
        if let index = included.firstIndex(of: name) {
            included.remove(at: index)
        } else {
            included.append(name)
        }
        updated.includedManifests = included.isEmpty ? nil : included
        await store.applyManifestEdit(updated, to: record)
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
        guard !name.isEmpty, name != target.manifest.manifestName else { return }
        Task { await store.renameManifest(target, to: name) }
    }

    private func commitDuplicate() {
        guard let target = duplicateTarget else { return }
        let name = duplicateText.trimmingCharacters(in: .whitespacesAndNewlines)
        duplicateTarget = nil
        guard !name.isEmpty else { return }
        Task { await store.duplicateManifest(target, as: name) }
    }

    /// Expand the folders enclosing the reveal target and scroll its row
    /// into view. Driven by search / Back-Forward navigation — never by a
    /// plain row click — so clicking a visible row doesn't yank the list.
    private func revealItem(_ target: AnyHashable?, proxy: ScrollViewProxy) {
        guard let url = target?.base as? URL,
              let record = records.first(where: { $0.fileURL == url }) else { return }
        expandAncestors(of: record)
        store.pendingRevealItemID = nil
        // Two-pass scroll: a lazy List hasn't measured rows it has never
        // drawn, so a single scrollTo to an off-screen row lands short.
        // The first pass jumps roughly there and forces those rows to be
        // realised; the second lands on the row precisely.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            guard let rowID = leafRowID(for: record) else { return }
            proxy.scrollTo(rowID, anchor: .center)
            try? await Task.sleep(for: .milliseconds(120))
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(rowID, anchor: .center)
            }
        }
    }

    /// Expand every folder a record is nested under for the current
    /// grouping, so its leaf row becomes part of the flattened `rows`.
    private func expandAncestors(of record: ManifestRecord) {
        switch grouping {
        case .directories:
            let segments = record.manifest.manifestName.split(separator: "/").map(String.init)
            guard !segments.isEmpty else { return }
            // Expand each path prefix, including the record's own path —
            // a manifest that is also a folder shows its row only when
            // that folder is open.
            for end in 1...segments.count {
                store.expandedManifestPaths.insert(segments[0..<end].joined(separator: "/"))
            }
        case .types:
            store.expandedManifestPaths.insert(
                referencedNames.contains(record.manifest.manifestName) ? "Included" : "Top-level"
            )
        case .catalogs:
            store.expandedManifestPaths.insert(record.manifest.catalogs?.first ?? "No catalog")
        }
    }

    /// The flattened-row id for a record's leaf, or `nil` if it isn't
    /// currently visible (its folders are still collapsed).
    private func leafRowID(for record: ManifestRecord) -> String? {
        for row in rows {
            if case .leaf(let leafRecord, _) = row.kind, leafRecord.fileURL == record.fileURL {
                return row.id
            }
        }
        return nil
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
                Image(systemName: "list.bullet.rectangle")
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
