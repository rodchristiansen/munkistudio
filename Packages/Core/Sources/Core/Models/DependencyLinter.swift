import Foundation

/// A problem the ``DependencyLinter`` found in a ``DependencyGraph``.
public struct DependencyFinding: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case cycle
        case redundantRequires
        case conflictingRelationship
        case danglingReference
    }

    public enum Severity: Sendable, Hashable {
        case error, warning
    }

    public var kind: Kind
    public var severity: Severity
    public var title: String
    public var detail: String
    /// Package names involved — used to locate the offending cluster.
    public var nodes: [String]
    /// Graph edges this finding implicates — used to highlight them.
    public var edges: [DependencyGraph.Edge]
    public var id: String

    public init(
        kind: Kind,
        severity: Severity,
        title: String,
        detail: String,
        nodes: [String],
        edges: [DependencyGraph.Edge],
        id: String
    ) {
        self.kind = kind
        self.severity = severity
        self.title = title
        self.detail = detail
        self.nodes = nodes
        self.edges = edges
        self.id = id
    }
}

/// Static analysis over a ``DependencyGraph`` — surfaces circular,
/// redundant, conflicting, and dangling `requires` / `update_for`
/// relationships. Pure; no I/O.
public enum DependencyLinter {
    public static func analyze(_ graph: DependencyGraph) -> [DependencyFinding] {
        var findings: [DependencyFinding] = []
        let requiresEdges = graph.edges.filter { $0.kind == .requires }

        var requiresAdjacency: [String: [String]] = [:]
        for edge in requiresEdges {
            requiresAdjacency[edge.from, default: []].append(edge.to)
        }

        // 1. Circular dependencies — non-trivial strongly-connected
        //    components of the `requires` subgraph.
        var cyclicNodes: Set<String> = []
        for component in stronglyConnectedComponents(
            nodes: graph.nodes.map(\.name), adjacency: requiresAdjacency
        ) where component.count > 1 {
            let members = Set(component)
            cyclicNodes.formUnion(members)
            let names = component.sorted()
            findings.append(DependencyFinding(
                kind: .cycle,
                severity: .error,
                title: "Circular dependency",
                detail: "These packages depend on each other in a cycle: \(names.joined(separator: ", ")). Munki can't resolve a circular `requires` chain.",
                nodes: names,
                edges: requiresEdges.filter { members.contains($0.from) && members.contains($0.to) },
                id: "cycle:\(names.joined(separator: ","))"
            ))
        }

        // 2. Redundant requirements — a direct `requires` edge whose
        //    target is already reachable through other requirements.
        //    Edges inside a cycle are skipped; the cycle finding owns them.
        for edge in requiresEdges {
            if cyclicNodes.contains(edge.from), cyclicNodes.contains(edge.to) { continue }
            let reached = reachable(from: edge.from, skipping: edge, adjacency: requiresAdjacency)
            guard reached.contains(edge.to) else { continue }
            findings.append(DependencyFinding(
                kind: .redundantRequires,
                severity: .warning,
                title: "Redundant requirement",
                detail: "`\(edge.from)` requires `\(edge.to)` directly, but already reaches it through another requirement. The direct entry is redundant.",
                nodes: [edge.from, edge.to],
                edges: [edge],
                id: "redundant:\(edge.from)->\(edge.to)"
            ))
        }

        // 3. Overlapping relationships — a pair of packages linked by
        //    both a `requires` and an `update_for` edge, in either
        //    direction. Declaring both is redundant. Keying on the
        //    unordered pair catches `A requires B` + `B update_for A`,
        //    not just one pkginfo listing the same name twice.
        var edgesByPair: [String: [DependencyGraph.Edge]] = [:]
        for edge in graph.edges {
            let key = [edge.from, edge.to].sorted().joined(separator: "\u{1f}")
            edgesByPair[key, default: []].append(edge)
        }
        for edges in edgesByPair.values {
            let kinds = Set(edges.map(\.kind))
            guard kinds.contains(.requires), kinds.contains(.updateFor) else { continue }
            let names = Set(edges.flatMap { [$0.from, $0.to] }).sorted()
            findings.append(DependencyFinding(
                kind: .conflictingRelationship,
                severity: .warning,
                title: "Overlapping relationship",
                detail: overlapDetail(edges),
                nodes: names,
                edges: edges,
                id: "overlap:\(names.joined(separator: ","))"
            ))
        }

        // 4. Dangling references — an edge targets a package with no
        //    pkginfo in the repo.
        for node in graph.nodes where !node.exists {
            let referrers = graph.edges.filter { $0.to == node.name }
            let referrerNames = referrers.map(\.from).sorted()
            let list = referrerNames.map { "`\($0)`" }.joined(separator: ", ")
            findings.append(DependencyFinding(
                kind: .danglingReference,
                severity: .warning,
                title: "Missing package",
                detail: "`\(node.name)` is referenced by \(list) but no pkginfo for it exists in this repo.",
                nodes: [node.name] + referrerNames,
                edges: referrers,
                id: "dangling:\(node.name)"
            ))
        }

        return findings.sorted {
            if $0.severity != $1.severity { return $0.severity == .error }
            if $0.title != $1.title { return $0.title < $1.title }
            return $0.id < $1.id
        }
    }

    /// Human-readable description of an overlapping `requires` /
    /// `update_for` pair.
    private static func overlapDetail(_ edges: [DependencyGraph.Edge]) -> String {
        guard let requires = edges.first(where: { $0.kind == .requires }),
              let updateFor = edges.first(where: { $0.kind == .updateFor }) else {
            return "These packages are linked by both a `requires` and an `update_for` relationship."
        }
        if requires.from == updateFor.from, requires.to == updateFor.to {
            return "`\(requires.from)` declares `\(requires.to)` as both `requires` and `update_for`. Those mean different things — keep whichever one you intend."
        }
        return "`\(requires.from)` requires `\(requires.to)`, and `\(updateFor.from)` is an `update_for` `\(updateFor.to)`. They reference each other through different mechanisms — that's redundant."
    }

    /// Nodes reachable from `start` over `requires` edges, ignoring the
    /// single direct edge under test.
    private static func reachable(
        from start: String,
        skipping skip: DependencyGraph.Edge,
        adjacency: [String: [String]]
    ) -> Set<String> {
        var visited: Set<String> = []
        var stack: [String] = [start]
        while let node = stack.popLast() {
            for next in adjacency[node] ?? [] {
                if node == skip.from, next == skip.to { continue }
                if visited.insert(next).inserted { stack.append(next) }
            }
        }
        return visited
    }

    /// Tarjan's strongly-connected-components algorithm. Each returned
    /// component with more than one node is a cycle.
    private static func stronglyConnectedComponents(
        nodes: [String],
        adjacency: [String: [String]]
    ) -> [[String]] {
        var index = 0
        var indices: [String: Int] = [:]
        var lowlink: [String: Int] = [:]
        var onStack: Set<String> = []
        var stack: [String] = []
        var components: [[String]] = []

        func strongConnect(_ v: String) {
            indices[v] = index
            lowlink[v] = index
            index += 1
            stack.append(v)
            onStack.insert(v)
            for w in adjacency[v] ?? [] {
                if indices[w] == nil {
                    strongConnect(w)
                    lowlink[v] = min(lowlink[v] ?? 0, lowlink[w] ?? 0)
                } else if onStack.contains(w) {
                    lowlink[v] = min(lowlink[v] ?? 0, indices[w] ?? 0)
                }
            }
            if lowlink[v] == indices[v] {
                var component: [String] = []
                while let w = stack.popLast() {
                    onStack.remove(w)
                    component.append(w)
                    if w == v { break }
                }
                components.append(component)
            }
        }

        for node in nodes where indices[node] == nil {
            strongConnect(node)
        }
        return components
    }
}
