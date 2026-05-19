import SwiftUI
import Core

/// Which relationship graph the Dependencies section is showing.
enum DependencyMode: String, Hashable, CaseIterable, Sendable {
    case packages, manifests
}

/// Full-width section drawing the repo's relationship graphs. Two modes:
/// Packages shows `requires` / `update_for` between pkginfos, split into
/// connected clusters. Manifests shows `included_manifests` edges: the
/// left panel is the manifests/ filesystem tree; selecting a manifest
/// maps the subtree downstream of it through `included_manifests`.
struct DependenciesView: View {
    @Environment(RepositoryStore.self) private var store
    @State private var zoom: CGFloat = 1
    @State private var filter = ""
    @FocusState private var filterFocused: Bool

    // Packages mode — graph + clusters + linter findings, cached so
    // zoom / filter / selection changes don't rebuild on every body pass.
    @State private var graph = DependencyGraph(nodes: [], edges: [])
    @State private var clusters: [DependencyCluster] = []
    @State private var findings: [DependencyFinding] = []
    @State private var showingIssues = false

    // Manifests mode — the inclusion graph (drives the map) and the
    // filesystem tree of the manifests/ folder (drives the left panel).
    @State private var manifestGraph = DependencyGraph(nodes: [], edges: [])
    @State private var manifestTree: [ManifestFSNode] = []

    private var mode: DependencyMode { store.dependencyMode }

    // MARK: - Bindings

    private var modeBinding: Binding<DependencyMode> {
        Binding(get: { store.dependencyMode }, set: { store.dependencyMode = $0 })
    }

    /// Cluster selection lives on the store so it survives navigating
    /// away and back (deep-link state, not view-local).
    private var clusterSelection: Binding<String?> {
        Binding(get: { store.dependenciesClusterID },
                set: { store.dependenciesClusterID = $0 })
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

    /// The manifest filesystem tree, pruned to the filter query.
    private var filteredTree: [ManifestFSNode] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return manifestTree }
        return manifestTree.compactMap { prune($0, query: query) }
    }

    private func prune(_ node: ManifestFSNode, query: String) -> ManifestFSNode? {
        let selfMatches = node.name.localizedCaseInsensitiveContains(query)
        switch node.kind {
        case .manifest:
            return selfMatches ? node : nil
        case .directory:
            let matchedChildren = node.children.compactMap { prune($0, query: query) }
            guard selfMatches || !matchedChildren.isEmpty else { return nil }
            return ManifestFSNode(
                kind: .directory,
                name: node.name,
                manifestName: nil,
                children: selfMatches ? node.children : matchedChildren,
                id: node.id
            )
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .navigationSubtitle(subtitle)
        .onAppear { rebuildGraph() }
        .onChange(of: store.snapshot.pkginfos) { rebuildGraph() }
        .onChange(of: store.snapshot.manifests) { rebuildGraph() }
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .packages: packagesContent
        case .manifests: manifestsContent
        }
    }

    @ViewBuilder
    private var packagesContent: some View {
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

    @ViewBuilder
    private var manifestsContent: some View {
        if manifestTree.isEmpty {
            ContentUnavailableView(
                "No Relationships",
                systemImage: "point.3.connected.trianglepath.dotted",
                description: Text("No manifest in this repo includes another via `included_manifests`.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HSplitView {
                manifestList
                    .frame(minWidth: 200, idealWidth: 260, maxWidth: 400)
                manifestGraphPane
                    .frame(minWidth: 360, maxWidth: .infinity)
            }
        }
    }

    /// Graph size, shown as the window's toolbar subtitle.
    private var subtitle: String {
        switch mode {
        case .packages:
            let packages = graph.nodes.count
            return "\(packages) connected package\(packages == 1 ? "" : "s") "
                + "in \(clusters.count) cluster\(clusters.count == 1 ? "" : "s")"
        case .manifests:
            let count = manifestGraph.nodes.count
            let links = manifestGraph.edges.count
            return "\(count) manifest\(count == 1 ? "" : "s") · "
                + "\(links) inclusion link\(links == 1 ? "" : "s")"
        }
    }

    /// Rebuild both cached graphs from the current snapshot.
    private func rebuildGraph() {
        graph = DependencyGraphBuilder.build(pkginfos: store.snapshot.pkginfos.map(\.pkginfo))
        clusters = DependencyClusterizer.clusters(from: graph)
        findings = DependencyLinter.analyze(graph)
        selectDefaultClusterIfNeeded()

        manifestGraph = ManifestGraphBuilder.build(manifests: store.snapshot.manifests.map(\.manifest))
        manifestTree = ManifestFSTree.build(
            manifestNames: store.snapshot.manifests.map(\.manifest.manifestName),
            inclusionGraph: manifestGraph
        )
        selectDefaultManifestIfNeeded()
    }

    /// Seed or correct the cluster selection. `selectedCluster` masks a
    /// nil / stale id behind a `filteredClusters.first` fallback, so the
    /// check has to look at the stored id directly — otherwise the id
    /// never gets initialized and the list shows no selected row.
    private func selectDefaultClusterIfNeeded() {
        let id = store.dependenciesClusterID
        let isValid = id != nil && clusters.contains { $0.id == id }
        if !isValid { store.dependenciesClusterID = clusters.first?.id }
    }

    /// Seed or correct the manifest selection the same way.
    private func selectDefaultManifestIfNeeded() {
        let name = store.dependenciesManifestName
        let isValid = name != nil && manifestGraph.nodes.contains { $0.name == name }
        if !isValid { store.dependenciesManifestName = ManifestFSTree.firstManifest(in: manifestTree) }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            Picker("", selection: modeBinding) {
                Text("Packages").tag(DependencyMode.packages)
                Text("Manifests").tag(DependencyMode.manifests)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if mode == .packages { issuesButton }
            Spacer()
            legend
            Divider().frame(height: 18)
            zoomControls
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var legend: some View {
        switch mode {
        case .packages:
            legendItem(color: .blue, dashed: false, label: "requires")
            legendItem(color: .orange, dashed: true, label: "update_for")
        case .manifests:
            legendItem(color: .purple, dashed: false, label: "includes")
            legendItem(color: .purple, dashed: true, label: "conditional include")
        }
    }

    private var zoomControls: some View {
        HStack(spacing: 4) {
            Button { setZoom(zoom - 0.2) } label: { Image(systemName: "minus.magnifyingglass") }
                .disabled(zoom <= 0.4)
            Button { zoom = 1 } label: { Text("\(Int(zoom * 100))%").monospacedDigit().frame(width: 42) }
                .buttonStyle(.plain)
            Button { setZoom(zoom + 0.2) } label: { Image(systemName: "plus.magnifyingglass") }
                .disabled(zoom >= 2)
        }
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

    // MARK: - Issues (Packages mode)

    @ViewBuilder
    private var issuesButton: some View {
        if !findings.isEmpty {
            let hasError = findings.contains { $0.severity == .error }
            let tint: Color = hasError ? .red : .orange
            Button { showingIssues.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("\(findings.count) issue\(findings.count == 1 ? "" : "s")")
                }
                .font(.callout.weight(.semibold))
                .foregroundStyle(tint)
            }
            .buttonStyle(.plain)
            .help("Dependency problems found in this repo")
            .popover(isPresented: $showingIssues, arrowEdge: .bottom) {
                issuesList
            }
        }
    }

    private var issuesList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(findings) { finding in
                    Button { jump(to: finding) } label: { findingRow(finding) }
                        .buttonStyle(.plain)
                    Divider()
                }
            }
        }
        .frame(width: 440, height: min(CGFloat(findings.count) * 92, 420))
    }

    private func findingRow(_ finding: DependencyFinding) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: finding.severity == .error
                  ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(finding.severity == .error ? .red : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.title).font(.callout.weight(.semibold))
                Text(.init(finding.detail))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }

    private func jump(to finding: DependencyFinding) {
        showingIssues = false
        guard let name = finding.nodes.first,
              let cluster = clusters.first(where: { cluster in
                  cluster.graph.nodes.contains { $0.name == name }
              })
        else { return }
        store.dependenciesClusterID = cluster.id
    }

    /// Highest severity among findings touching `cluster`, if any.
    private func severity(of cluster: DependencyCluster) -> DependencyFinding.Severity? {
        let names = Set(cluster.graph.nodes.map(\.name))
        let relevant = findings.filter { $0.nodes.contains { names.contains($0) } }
        guard !relevant.isEmpty else { return nil }
        return relevant.contains { $0.severity == .error } ? .error : .warning
    }

    /// Edges of the selected cluster implicated by a finding.
    private var problemEdges: Set<DependencyGraph.Edge> {
        guard let cluster = selectedCluster else { return [] }
        let names = Set(cluster.graph.nodes.map(\.name))
        var result: Set<DependencyGraph.Edge> = []
        for finding in findings where finding.nodes.contains(where: { names.contains($0) }) {
            result.formUnion(finding.edges)
        }
        return result
    }

    // MARK: - Cluster list (Packages mode)

    private var clusterList: some View {
        VStack(spacing: 0) {
            FilterField(text: $filter, prompt: "Filter clusters", focused: $filterFocused)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            List(selection: clusterSelection) {
                ForEach(filteredClusters) { cluster in
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cluster.title)
                                .font(.callout.weight(.medium))
                                .lineLimit(1).truncationMode(.middle)
                            Text("\(cluster.nodeCount) package\(cluster.nodeCount == 1 ? "" : "s") · \(cluster.edgeCount) link\(cluster.edgeCount == 1 ? "" : "s")")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if let severity = severity(of: cluster) {
                            Image(systemName: severity == .error
                                  ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(severity == .error ? .red : .orange)
                                .imageScale(.small)
                        }
                    }
                    .tag(cluster.id)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Manifest filesystem tree (Manifests mode)

    private var manifestList: some View {
        VStack(spacing: 0) {
            FilterField(text: $filter, prompt: "Filter manifests", focused: $filterFocused)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(filteredTree) { node in
                        ManifestFSRow(
                            node: node,
                            depth: 0,
                            selectedName: store.dependenciesManifestName,
                            onSelect: { store.dependenciesManifestName = $0 },
                            onOpen: { openManifest($0) }
                        )
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
            .scrollContentBackground(.hidden)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Graph panes

    @ViewBuilder
    private var graphPane: some View {
        if let cluster = selectedCluster {
            let layout = DependencyLayout.compute(cluster.graph)
            GeometryReader { geo in
                ScrollView([.horizontal, .vertical]) {
                    graphContent(layout, problems: problemEdges)
                        .frame(minWidth: geo.size.width, minHeight: geo.size.height)
                }
            }
        } else {
            ContentUnavailableView("Select a Cluster", systemImage: "sidebar.left")
        }
    }

    @ViewBuilder
    private var manifestGraphPane: some View {
        if let name = store.dependenciesManifestName,
           manifestGraph.nodes.contains(where: { $0.name == name }) {
            let subgraph = downstreamSubgraph(from: name, in: manifestGraph)
            // Flipped: the manifests an include chain bottoms out at —
            // the foundational ones — sit at the top, the selected
            // manifest at the bottom.
            let layout = DependencyLayout.compute(subgraph, flipped: true)
            GeometryReader { geo in
                ScrollView([.horizontal, .vertical]) {
                    graphContent(layout, problems: [])
                        .frame(minWidth: geo.size.width, minHeight: geo.size.height)
                }
            }
        } else {
            ContentUnavailableView("Select a Manifest", systemImage: "sidebar.left")
        }
    }

    /// The subgraph reachable downstream of `name` — the manifest plus
    /// everything it pulls in, transitively. The visited set guards the
    /// walk against inclusion cycles.
    private func downstreamSubgraph(from name: String, in graph: DependencyGraph) -> DependencyGraph {
        let targets = Dictionary(grouping: graph.edges, by: \.from).mapValues { $0.map(\.to) }
        var reachable: Set<String> = [name]
        var queue = [name]
        while let current = queue.popLast() {
            for target in targets[current] ?? [] where reachable.insert(target).inserted {
                queue.append(target)
            }
        }
        return DependencyGraph(
            nodes: graph.nodes.filter { reachable.contains($0.name) },
            edges: graph.edges.filter { reachable.contains($0.from) && reachable.contains($0.to) }
        )
    }

    private func graphContent(
        _ layout: DependencyLayout,
        problems: Set<DependencyGraph.Edge>
    ) -> some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                for edge in layout.edges {
                    guard let a = layout.point(for: edge.from),
                          let b = layout.point(for: edge.to) else { continue }
                    drawEdge(context: context, from: a, to: b, kind: edge.kind,
                             isProblem: problems.contains(edge))
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
        let icon: String = node.exists
            ? (mode == .manifests ? "list.bullet.rectangle.fill" : "shippingbox.fill")
            : "questionmark.diamond"
        return HStack(spacing: 6) {
            Image(systemName: icon)
                .imageScale(.small)
                .foregroundStyle(tint)
            Text(nodeLabel(node))
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
        // Single-tap focuses the node; double-tap opens it in its tab.
        // count:1 is attached first so focus isn't delayed.
        .onTapGesture { handleNodeSingleTap(node) }
        .onTapGesture(count: 2) { handleNodeDoubleTap(node) }
        .help(nodeHelp(node))
    }

    /// The card label — a manifest's `manifestName` is a `/`-path, but the
    /// card shows only its leaf component.
    private func nodeLabel(_ node: DependencyGraph.Node) -> String {
        node.name.split(separator: "/").last.map(String.init) ?? node.name
    }

    private func handleNodeSingleTap(_ node: DependencyGraph.Node) {
        switch mode {
        case .packages: navigate(to: node)
        case .manifests: store.dependenciesManifestName = node.name
        }
    }

    private func handleNodeDoubleTap(_ node: DependencyGraph.Node) {
        switch mode {
        case .packages: navigate(to: node)
        case .manifests: openManifest(node.name)
        }
    }

    private func nodeHelp(_ node: DependencyGraph.Node) -> String {
        guard node.exists else {
            return "\(node.name) — referenced but not present in this repo"
        }
        switch mode {
        case .packages:
            return "Open \(node.name) in Packages"
        case .manifests:
            return "\(node.name) — click to focus, double-click to open in Manifests"
        }
    }

    private func drawEdge(
        context: GraphicsContext,
        from: CGPoint,
        to: CGPoint,
        kind: DependencyGraph.Edge.Kind,
        isProblem: Bool
    ) {
        let baseColor: Color
        switch kind {
        case .requires: baseColor = .blue
        case .updateFor: baseColor = .orange
        case .manifestInclusion: baseColor = .purple
        case .conditionalInclusion: baseColor = .purple
        }
        let color: Color = isProblem ? .red : baseColor
        let dash: [CGFloat] = (kind == .updateFor || kind == .conditionalInclusion) ? [5, 4] : []
        let opacity: Double = isProblem ? 0.95 : 0.7
        let lineWidth: CGFloat = isProblem ? 2.5 : 1.5

        // Trim the segment to each node's vertical border so the line
        // meets the box edge rather than diving under it.
        let halfH = DependencyLayout.nodeH / 2 + 1
        let start = CGPoint(x: from.x, y: from.y + (to.y >= from.y ? halfH : -halfH))
        let end = CGPoint(x: to.x, y: to.y + (to.y >= from.y ? -halfH : halfH))

        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        context.stroke(path, with: .color(color.opacity(opacity)),
                       style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, dash: dash))

        let angle = atan2(end.y - start.y, end.x - start.x)
        let size: CGFloat = 7
        var head = Path()
        head.move(to: end)
        head.addLine(to: CGPoint(x: end.x - size * cos(angle - .pi / 7),
                                 y: end.y - size * sin(angle - .pi / 7)))
        head.addLine(to: CGPoint(x: end.x - size * cos(angle + .pi / 7),
                                 y: end.y - size * sin(angle + .pi / 7)))
        head.closeSubpath()
        context.fill(head, with: .color(color.opacity(opacity)))
    }

    /// Open a package node in the Packages tab. The section + item
    /// change records a navigation entry, so Back / Forward return here.
    private func navigate(to node: DependencyGraph.Node) {
        guard let record = store.snapshot.pkginfos.first(where: { $0.pkginfo.name == node.name }) else { return }
        store.selectedSection = .packages
        store.selectedItemID = AnyHashable(record.id)
        let category = record.pkginfo.category?.trimmingCharacters(in: .whitespaces)
        store.expandedCategories.insert(category?.isEmpty == false ? category! : "Uncategorized")
    }

    /// Open a manifest in the Manifests tab — used by the double-tap on
    /// a tree row or a graph node. `manifestName` is canonicalised the
    /// same way the graph is so a record always matches.
    private func openManifest(_ manifestName: String) {
        guard let record = store.snapshot.manifests.first(where: {
            ManifestGraphBuilder.canonicalName($0.manifest.manifestName) == manifestName
        }) else { return }
        store.selectedSection = .manifests
        store.selectedItemID = AnyHashable(record.id)
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

// MARK: - Manifest filesystem tree

/// One entry in the manifests/ filesystem tree — either a directory
/// (a group) or a manifest file (selectable, drives the map).
struct ManifestFSNode: Identifiable {
    enum Kind { case directory, manifest }
    let kind: Kind
    /// Last path component — the display name.
    let name: String
    /// The full `manifestName` (a `/`-path) for a `.manifest`; nil for
    /// a directory.
    let manifestName: String?
    let children: [ManifestFSNode]
    let id: String
}

enum ManifestFSTree {
    /// Build the manifests/ directory tree from manifest names (each a
    /// `/`-separated path). Manifest files sort before subfolders at
    /// every level; manifests are ordered by how many other manifests
    /// include them, so a foundational manifest rises to the top.
    static func build(manifestNames: [String], inclusionGraph: DependencyGraph) -> [ManifestFSNode] {
        var inDegree: [String: Int] = [:]
        for edge in inclusionGraph.edges { inDegree[edge.to, default: 0] += 1 }
        // Only list manifests that include something — a manifest with no
        // `included_manifests` has no downstream to explore, so it isn't
        // a useful entry (it still appears in the map as a leaf node).
        let includers = Set(inclusionGraph.edges.map(\.from))
        let entries = manifestNames
            .filter { includers.contains(ManifestGraphBuilder.canonicalName($0)) }
            .map { (name: $0, parts: $0.split(separator: "/").map(String.init)) }
            .filter { !$0.parts.isEmpty }
        return level(entries, depth: 0, parentPath: "", inDegree: inDegree)
    }

    private static func level(
        _ entries: [(name: String, parts: [String])],
        depth: Int,
        parentPath: String,
        inDegree: [String: Int]
    ) -> [ManifestFSNode] {
        var manifests: [ManifestFSNode] = []
        var dirEntries: [String: [(name: String, parts: [String])]] = [:]
        var dirOrder: [String] = []

        for entry in entries {
            let component = entry.parts[depth]
            if entry.parts.count == depth + 1 {
                manifests.append(ManifestFSNode(
                    kind: .manifest, name: component, manifestName: entry.name,
                    children: [], id: "m:" + entry.name))
            } else {
                if dirEntries[component] == nil { dirOrder.append(component) }
                dirEntries[component, default: []].append(entry)
            }
        }

        // Manifests: most-included first, alphabetical to break ties.
        manifests.sort { lhs, rhs in
            let l = inDegree[ManifestGraphBuilder.canonicalName(lhs.manifestName ?? ""), default: 0]
            let r = inDegree[ManifestGraphBuilder.canonicalName(rhs.manifestName ?? ""), default: 0]
            if l != r { return l > r }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        let directories = dirOrder
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { dir -> ManifestFSNode in
                let path = parentPath.isEmpty ? dir : parentPath + "/" + dir
                return ManifestFSNode(
                    kind: .directory, name: dir, manifestName: nil,
                    children: level(dirEntries[dir] ?? [], depth: depth + 1,
                                    parentPath: path, inDegree: inDegree),
                    id: "d:" + path)
            }

        return manifests + directories
    }

    /// The first selectable manifest, depth-first — the importance-sorted
    /// top entry, used as the default selection.
    static func firstManifest(in nodes: [ManifestFSNode]) -> String? {
        for node in nodes {
            switch node.kind {
            case .manifest:
                return node.manifestName
            case .directory:
                if let found = firstManifest(in: node.children) { return found }
            }
        }
        return nil
    }
}

/// One row of the manifest filesystem tree. Directories toggle their
/// children; manifests select and scope the map downstream of them.
private struct ManifestFSRow: View {
    let node: ManifestFSNode
    let depth: Int
    let selectedName: String?
    let onSelect: (String) -> Void
    let onOpen: (String) -> Void

    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            rowContent
            if expanded {
                ForEach(node.children) { child in
                    ManifestFSRow(node: child, depth: depth + 1,
                                  selectedName: selectedName,
                                  onSelect: onSelect, onOpen: onOpen)
                }
            }
        }
    }

    private var isSelected: Bool {
        node.kind == .manifest && node.manifestName == selectedName
    }

    private var rowContent: some View {
        HStack(spacing: 5) {
            if node.kind == .directory {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
            } else {
                Color.clear.frame(width: 12)
            }
            Image(systemName: node.kind == .directory ? "folder.fill" : "list.bullet.rectangle")
                .imageScale(.small)
                .foregroundStyle(node.kind == .directory ? Color.secondary : Color.accentColor)
                .frame(width: 16)
            Text(node.name)
                .font(.callout)
                .fontWeight(node.kind == .directory ? .medium : .regular)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .padding(.leading, CGFloat(depth) * 14 + 4)
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected ? Color.accentColor.opacity(0.18) : Color.clear,
            in: .rect(cornerRadius: 4)
        )
        .contentShape(.rect)
        // count:1 first so selection isn't delayed; double-tap on a
        // manifest opens it in the Manifests tab.
        .onTapGesture {
            switch node.kind {
            case .directory: expanded.toggle()
            case .manifest: if let name = node.manifestName { onSelect(name) }
            }
        }
        .onTapGesture(count: 2) {
            if node.kind == .manifest, let name = node.manifestName { onOpen(name) }
        }
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

    /// `flipped` inverts the vertical order — used for the manifest map,
    /// where the foundational manifests an include chain bottoms out at
    /// belong at the top.
    static func compute(_ graph: DependencyGraph, flipped: Bool = false) -> DependencyLayout {
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
            let y = CGFloat(flipped ? level : maxLayer - level) * (nodeH + yGap) + nodeH / 2
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
