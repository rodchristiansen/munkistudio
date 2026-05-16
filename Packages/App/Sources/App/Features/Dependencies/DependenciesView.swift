import SwiftUI
import Core

/// Full-width section drawing the repo's `requires` / `update_for`
/// relationships. A whole-repo graph is an unreadable hairball, so the
/// graph is split into connected clusters — pick one from the list and
/// see just that neighbourhood. Click a node to jump to its package.
struct DependenciesView: View {
    @Environment(RepositoryStore.self) private var store
    @State private var zoom: CGFloat = 1
    @State private var filter = ""
    @FocusState private var filterFocused: Bool

    /// Cluster selection lives on the store so it survives navigating
    /// away and back (deep-link state, not view-local).
    private var clusterSelection: Binding<String?> {
        Binding(get: { store.dependenciesClusterID },
                set: { store.dependenciesClusterID = $0 })
    }

    private var graph: DependencyGraph {
        DependencyGraphBuilder.build(pkginfos: store.snapshot.pkginfos.map(\.pkginfo))
    }

    private var clusters: [DependencyCluster] {
        DependencyClusterizer.clusters(from: graph)
    }

    private var filteredClusters: [DependencyCluster] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return clusters }
        return clusters.filter { cluster in
            cluster.graph.nodes.contains { $0.name.localizedCaseInsensitiveContains(query) }
        }
    }

    private var selectedCluster: DependencyCluster? {
        clusters.first { $0.id == store.dependenciesClusterID } ?? filteredClusters.first
    }

    var body: some View {
        let clusters = clusters
        VStack(spacing: 0) {
            header(clusterCount: clusters.count, packageCount: graph.nodes.count)
            Divider()
            if clusters.isEmpty {
                ContentUnavailableView(
                    "No Relationships",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("No package in this repo declares a `requires` or `update_for` relationship.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    clusterList
                        .frame(minWidth: 200, idealWidth: 250, maxWidth: 380)
                    graphPane
                        .frame(minWidth: 360, maxWidth: .infinity)
                }
            }
        }
        .onAppear { selectDefaultClusterIfNeeded() }
        .onChange(of: store.snapshot.pkginfos.count) { selectDefaultClusterIfNeeded() }
    }

    private func selectDefaultClusterIfNeeded() {
        if selectedCluster == nil { store.dependenciesClusterID = clusters.first?.id }
    }

    // MARK: - Header

    private func header(clusterCount: Int, packageCount: Int) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Dependencies").font(.headline)
                Text("\(packageCount) connected package\(packageCount == 1 ? "" : "s") in \(clusterCount) cluster\(clusterCount == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            legendItem(color: .blue, dashed: false, label: "requires")
            legendItem(color: .orange, dashed: true, label: "update_for")
            Divider().frame(height: 18)
            HStack(spacing: 4) {
                Button { setZoom(zoom - 0.2) } label: { Image(systemName: "minus.magnifyingglass") }
                    .disabled(zoom <= 0.4)
                Button { zoom = 1 } label: { Text("\(Int(zoom * 100))%").monospacedDigit().frame(width: 42) }
                    .buttonStyle(.plain)
                Button { setZoom(zoom + 0.2) } label: { Image(systemName: "plus.magnifyingglass") }
                    .disabled(zoom >= 2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func legendItem(color: Color, dashed: Bool, label: String) -> some View {
        HStack(spacing: 5) {
            Line()
                .stroke(color, style: StrokeStyle(lineWidth: 2, dash: dashed ? [4, 3] : []))
                .frame(width: 22, height: 2)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func setZoom(_ value: CGFloat) {
        zoom = min(2, max(0.4, (value * 10).rounded() / 10))
    }

    // MARK: - Cluster list

    private var clusterList: some View {
        VStack(spacing: 0) {
            FilterField(text: $filter, prompt: "Filter clusters", focused: $filterFocused)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            List(selection: clusterSelection) {
                ForEach(filteredClusters) { cluster in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cluster.title)
                            .font(.callout.weight(.medium))
                            .lineLimit(1).truncationMode(.middle)
                        Text("\(cluster.nodeCount) package\(cluster.nodeCount == 1 ? "" : "s") · \(cluster.edgeCount) link\(cluster.edgeCount == 1 ? "" : "s")")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .tag(cluster.id)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Graph pane

    @ViewBuilder
    private var graphPane: some View {
        if let cluster = selectedCluster {
            let layout = DependencyLayout.compute(cluster.graph)
            GeometryReader { geo in
                ScrollView([.horizontal, .vertical]) {
                    graphContent(layout)
                        .frame(minWidth: geo.size.width, minHeight: geo.size.height)
                }
            }
        } else {
            ContentUnavailableView("Select a Cluster", systemImage: "sidebar.left")
        }
    }

    private func graphContent(_ layout: DependencyLayout) -> some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                for edge in layout.edges {
                    guard let a = layout.point(for: edge.from),
                          let b = layout.point(for: edge.to) else { continue }
                    drawEdge(context: context, from: a, to: b, kind: edge.kind)
                }
            }
            .frame(width: layout.size.width, height: layout.size.height)

            ForEach(layout.nodes) { placed in
                nodeView(placed.node).position(placed.point)
            }
        }
        .frame(width: layout.size.width, height: layout.size.height)
        .scaleEffect(zoom, anchor: .center)
        .frame(width: layout.size.width * zoom, height: layout.size.height * zoom)
        .padding(32)
    }

    private func nodeView(_ node: DependencyGraph.Node) -> some View {
        let tint: Color = node.exists ? .accentColor : .secondary
        return HStack(spacing: 6) {
            Image(systemName: node.exists ? "shippingbox.fill" : "questionmark.diamond")
                .imageScale(.small)
                .foregroundStyle(tint)
            Text(node.name)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .frame(width: DependencyLayout.nodeW, height: DependencyLayout.nodeH)
        .background(tint.opacity(node.exists ? 0.12 : 0.06), in: .rect(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(tint.opacity(node.exists ? 0.55 : 0.3),
                        style: StrokeStyle(lineWidth: 1, dash: node.exists ? [] : [3, 2]))
        )
        .contentShape(.rect)
        .onTapGesture { navigate(to: node) }
        .help(node.exists ? "Open \(node.name) in Packages" : "\(node.name) — referenced but not present in this repo")
    }

    private func drawEdge(context: GraphicsContext, from: CGPoint, to: CGPoint, kind: DependencyGraph.Edge.Kind) {
        let color: Color = kind == .requires ? .blue : .orange
        let dash: [CGFloat] = kind == .requires ? [] : [5, 4]

        // Trim the segment to each node's vertical border so the line
        // meets the box edge rather than diving under it.
        let halfH = DependencyLayout.nodeH / 2 + 1
        let start = CGPoint(x: from.x, y: from.y + (to.y >= from.y ? halfH : -halfH))
        let end = CGPoint(x: to.x, y: to.y + (to.y >= from.y ? -halfH : halfH))

        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        context.stroke(path, with: .color(color.opacity(0.7)),
                       style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: dash))

        let angle = atan2(end.y - start.y, end.x - start.x)
        let size: CGFloat = 7
        var head = Path()
        head.move(to: end)
        head.addLine(to: CGPoint(x: end.x - size * cos(angle - .pi / 7),
                                 y: end.y - size * sin(angle - .pi / 7)))
        head.addLine(to: CGPoint(x: end.x - size * cos(angle + .pi / 7),
                                 y: end.y - size * sin(angle + .pi / 7)))
        head.closeSubpath()
        context.fill(head, with: .color(color.opacity(0.7)))
    }

    private func navigate(to node: DependencyGraph.Node) {
        guard let record = store.snapshot.pkginfos.first(where: { $0.pkginfo.name == node.name }) else { return }
        store.selectedSection = .packages
        store.selectedItemID = AnyHashable(record.id)
        let category = record.pkginfo.category?.trimmingCharacters(in: .whitespaces)
        store.expandedCategories.insert(category?.isEmpty == false ? category! : "Uncategorized")
    }
}

/// A horizontal hairline used for the legend swatches.
private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

/// One connected component of the dependency graph — a package and the
/// neighbourhood reachable from it through `requires` / `update_for`.
struct DependencyCluster: Identifiable {
    /// Stable across rebuilds: the alphabetically-first node name. Node
    /// names are unique and components disjoint, so this never collides.
    let id: String
    let graph: DependencyGraph
    /// The most depended-upon node — the natural anchor for the cluster.
    let title: String

    var nodeCount: Int { graph.nodes.count }
    var edgeCount: Int { graph.edges.count }
}

enum DependencyClusterizer {
    /// Split a graph into connected components (edges treated as
    /// undirected), largest cluster first.
    static func clusters(from graph: DependencyGraph) -> [DependencyCluster] {
        var parent: [String: String] = [:]
        for node in graph.nodes { parent[node.name] = node.name }

        func find(_ name: String) -> String {
            var root = name
            while let next = parent[root], next != root { root = next }
            var cursor = name
            while let next = parent[cursor], next != root {
                parent[cursor] = root
                cursor = next
            }
            return root
        }
        func union(_ a: String, _ b: String) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }
        for edge in graph.edges where parent[edge.from] != nil && parent[edge.to] != nil {
            union(edge.from, edge.to)
        }

        var nodesByRoot: [String: [DependencyGraph.Node]] = [:]
        for node in graph.nodes {
            nodesByRoot[find(node.name), default: []].append(node)
        }
        var edgesByRoot: [String: [DependencyGraph.Edge]] = [:]
        for edge in graph.edges where parent[edge.from] != nil {
            edgesByRoot[find(edge.from), default: []].append(edge)
        }

        var result: [DependencyCluster] = []
        for (root, nodes) in nodesByRoot {
            let sub = DependencyGraph(nodes: nodes, edges: edgesByRoot[root] ?? [])
            let id = nodes.map(\.name).min() ?? root
            result.append(DependencyCluster(id: id, graph: sub, title: anchor(of: sub)))
        }
        return result.sorted {
            $0.nodeCount != $1.nodeCount ? $0.nodeCount > $1.nodeCount : $0.title < $1.title
        }
    }

    /// The node the most edges point at — the package others depend on.
    private static func anchor(of graph: DependencyGraph) -> String {
        var inDegree: [String: Int] = [:]
        for edge in graph.edges { inDegree[edge.to, default: 0] += 1 }
        let best = graph.nodes.max {
            let lhs = inDegree[$0.name, default: 0]
            let rhs = inDegree[$1.name, default: 0]
            return lhs != rhs ? lhs < rhs : $0.name > $1.name
        }
        return best?.name ?? graph.nodes.first?.name ?? "—"
    }
}

/// A layered (longest-path) layout for a ``DependencyGraph``. Dependencies
/// sink toward the bottom; dependents rise above them. Cycles are broken
/// so a malformed repo can't recurse forever.
struct DependencyLayout {
    struct Placed: Identifiable {
        let node: DependencyGraph.Node
        let point: CGPoint
        var id: String { node.id }
    }

    static let nodeW: CGFloat = 168
    static let nodeH: CGFloat = 38
    static let xGap: CGFloat = 40
    static let yGap: CGFloat = 72

    let nodes: [Placed]
    let edges: [DependencyGraph.Edge]
    let size: CGSize
    private let positions: [String: CGPoint]

    func point(for name: String) -> CGPoint? { positions[name] }

    static func compute(_ graph: DependencyGraph) -> DependencyLayout {
        var targets: [String: [String]] = [:]
        for edge in graph.edges {
            targets[edge.from, default: []].append(edge.to)
        }

        var layerOf: [String: Int] = [:]
        func layer(of name: String, visiting: Set<String>) -> Int {
            if let cached = layerOf[name] { return cached }
            guard !visiting.contains(name) else { return 0 }
            var visiting = visiting
            visiting.insert(name)
            var result = 0
            for target in targets[name] ?? [] {
                result = max(result, 1 + layer(of: target, visiting: visiting))
            }
            layerOf[name] = result
            return result
        }
        for node in graph.nodes { _ = layer(of: node.name, visiting: []) }

        var rows: [Int: [DependencyGraph.Node]] = [:]
        for node in graph.nodes {
            rows[layerOf[node.name] ?? 0, default: []].append(node)
        }
        let maxLayer = rows.keys.max() ?? 0
        let widest = rows.values.map(\.count).max() ?? 1
        let totalW = CGFloat(widest) * nodeW + CGFloat(max(0, widest - 1)) * xGap

        var positions: [String: CGPoint] = [:]
        var placed: [Placed] = []
        for level in 0...maxLayer {
            let row = (rows[level] ?? []).sorted { $0.name < $1.name }
            let rowW = CGFloat(row.count) * nodeW + CGFloat(max(0, row.count - 1)) * xGap
            let startX = (totalW - rowW) / 2 + nodeW / 2
            let y = CGFloat(maxLayer - level) * (nodeH + yGap) + nodeH / 2
            for (index, node) in row.enumerated() {
                let point = CGPoint(x: startX + CGFloat(index) * (nodeW + xGap), y: y)
                positions[node.name] = point
                placed.append(Placed(node: node, point: point))
            }
        }

        let totalH = CGFloat(maxLayer + 1) * nodeH + CGFloat(maxLayer) * yGap
        return DependencyLayout(
            nodes: placed,
            edges: graph.edges,
            size: CGSize(width: max(totalW, nodeW), height: max(totalH, nodeH)),
            positions: positions
        )
    }
}
