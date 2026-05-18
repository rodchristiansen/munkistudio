import Foundation

/// A directed relationship graph. Used for two kinds of relationship:
/// pkginfo `requires` / `update_for` edges (``DependencyGraphBuilder``)
/// and manifest `included_manifests` edges (``ManifestGraphBuilder``).
/// Pure data — the edge `kind` distinguishes which.
public struct DependencyGraph: Sendable {
    public struct Node: Sendable, Hashable, Identifiable {
        public var name: String
        /// `true` when an item (pkginfo or manifest) with this exact
        /// name exists in the repo — `false` for a referenced-but-absent
        /// relationship target.
        public var exists: Bool

        public var id: String { name }

        public init(name: String, exists: Bool) {
            self.name = name
            self.exists = exists
        }
    }

    public struct Edge: Sendable, Hashable {
        public enum Kind: Sendable, Hashable { case requires, updateFor, manifestInclusion }

        public var from: String
        public var to: String
        public var kind: Kind

        public init(from: String, to: String, kind: Kind) {
            self.from = from
            self.to = to
            self.kind = kind
        }
    }

    public var nodes: [Node]
    public var edges: [Edge]

    public init(nodes: [Node], edges: [Edge]) {
        self.nodes = nodes
        self.edges = edges
    }

    /// A graph with no nodes. A node-only graph (standalone manifests
    /// with no inclusion edges) is not empty.
    public var isEmpty: Bool { nodes.isEmpty }
}

public enum DependencyGraphBuilder {
    /// Build a relationship graph from pkginfos. Only packages that take
    /// part in at least one `requires` / `update_for` relationship become
    /// nodes — unconnected packages are omitted so the graph stays about
    /// relationships rather than the whole catalog.
    public static func build(pkginfos: [Pkginfo]) -> DependencyGraph {
        let existing = Set(pkginfos.map(\.name))
        var edges: [DependencyGraph.Edge] = []
        var seen = Set<String>()
        var nodeNames = Set<String>()

        func addEdge(from: String, to: String, kind: DependencyGraph.Edge.Kind) {
            guard from != to, !from.isEmpty, !to.isEmpty else { return }
            let key = "\(from)\u{1f}\(to)\u{1f}\(kind)"
            guard seen.insert(key).inserted else { return }
            edges.append(.init(from: from, to: to, kind: kind))
            nodeNames.insert(from)
            nodeNames.insert(to)
        }

        for pkg in pkginfos {
            for required in pkg.requires ?? [] {
                addEdge(from: pkg.name, to: required, kind: .requires)
            }
            for target in pkg.updateFor ?? [] {
                addEdge(from: pkg.name, to: target, kind: .updateFor)
            }
        }

        let nodes = nodeNames.sorted().map {
            DependencyGraph.Node(name: $0, exists: existing.contains($0))
        }
        return DependencyGraph(nodes: nodes, edges: edges)
    }
}

public enum ManifestGraphBuilder {
    /// Build an inclusion graph from manifests. An edge runs from a
    /// manifest to each manifest it pulls in via `included_manifests`.
    /// Unlike the package graph, every manifest is kept as a node even
    /// with no inclusion relationship — a standalone client manifest is
    /// still a meaningful entry in the tree.
    ///
    /// `manifestName` is stored without a file extension, but real repos
    /// reference includes inconsistently — `CoreManifest`, `Assigned.yaml`
    /// and `Foo.plist` all occur. Both sides are canonicalised to the
    /// extensionless form so a reference always resolves to its manifest.
    public static func build(manifests: [Manifest]) -> DependencyGraph {
        let existing = Set(manifests.map { canonicalName($0.manifestName) })
        var edges: [DependencyGraph.Edge] = []
        var seen = Set<String>()
        var nodeNames = Set<String>()

        for manifest in manifests {
            let name = canonicalName(manifest.manifestName)
            guard !name.isEmpty else { continue }
            nodeNames.insert(name)
            for included in manifest.includedManifests ?? [] {
                let target = canonicalName(included)
                guard name != target, !target.isEmpty else { continue }
                let key = "\(name)\u{1f}\(target)"
                guard seen.insert(key).inserted else { continue }
                edges.append(.init(from: name, to: target, kind: .manifestInclusion))
                nodeNames.insert(target)
            }
        }

        let nodes = nodeNames.sorted().map {
            DependencyGraph.Node(name: $0, exists: existing.contains($0))
        }
        return DependencyGraph(nodes: nodes, edges: edges)
    }

    /// Drop a manifest file extension so a reference (`Assigned.yaml`)
    /// matches the extensionless `manifestName` (`Assigned`).
    public static func canonicalName(_ name: String) -> String {
        for ext in [".yaml", ".yml", ".plist"] where name.hasSuffix(ext) {
            return String(name.dropLast(ext.count))
        }
        return name
    }
}
