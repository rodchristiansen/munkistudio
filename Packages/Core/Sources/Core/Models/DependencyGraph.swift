import Foundation

/// A directed graph of pkginfo relationships — `requires` and
/// `update_for` edges. Pure data; built by ``DependencyGraphBuilder``.
public struct DependencyGraph: Sendable {
    public struct Node: Sendable, Hashable, Identifiable {
        public var name: String
        /// `true` when a pkginfo with this exact name exists in the repo.
        public var exists: Bool

        public var id: String { name }

        public init(name: String, exists: Bool) {
            self.name = name
            self.exists = exists
        }
    }

    public struct Edge: Sendable, Hashable {
        public enum Kind: Sendable, Hashable { case requires, updateFor }

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

    public var isEmpty: Bool { edges.isEmpty }
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
