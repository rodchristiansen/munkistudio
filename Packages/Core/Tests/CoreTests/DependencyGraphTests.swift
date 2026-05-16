import Foundation
import Testing
@testable import Core

@Suite("Dependency graph builder")
struct DependencyGraphTests {
    private func pkg(_ name: String, requires: [String]? = nil, updateFor: [String]? = nil) -> Pkginfo {
        var pkginfo = Pkginfo(name: name)
        pkginfo.requires = requires
        pkginfo.updateFor = updateFor
        return pkginfo
    }

    @Test("builds a requires edge between two packages")
    func requiresEdge() {
        let graph = DependencyGraphBuilder.build(pkginfos: [
            pkg("App", requires: ["Helper"]),
            pkg("Helper"),
        ])
        #expect(graph.edges == [.init(from: "App", to: "Helper", kind: .requires)])
        #expect(Set(graph.nodes.map(\.name)) == ["App", "Helper"])
    }

    @Test("builds an update_for edge")
    func updateForEdge() {
        let graph = DependencyGraphBuilder.build(pkginfos: [
            pkg("AppPatch", updateFor: ["App"]),
            pkg("App"),
        ])
        #expect(graph.edges == [.init(from: "AppPatch", to: "App", kind: .updateFor)])
    }

    @Test("drops self-referential edges")
    func dropsSelfEdge() {
        let graph = DependencyGraphBuilder.build(pkginfos: [pkg("App", requires: ["App"])])
        #expect(graph.edges.isEmpty)
        #expect(graph.nodes.isEmpty)
    }

    @Test("drops edges with an empty endpoint name")
    func dropsEmptyName() {
        let graph = DependencyGraphBuilder.build(pkginfos: [pkg("App", requires: [""])])
        #expect(graph.edges.isEmpty)
    }

    @Test("de-duplicates a repeated relationship")
    func deduplicatesEdges() {
        let graph = DependencyGraphBuilder.build(pkginfos: [
            pkg("App", requires: ["Helper", "Helper"]),
            pkg("Helper"),
        ])
        #expect(graph.edges.count == 1)
    }

    @Test("marks a referenced-but-absent package as not existing")
    func missingPackageNotExisting() {
        let graph = DependencyGraphBuilder.build(pkginfos: [pkg("App", requires: ["Ghost"])])
        #expect(graph.nodes.first { $0.name == "Ghost" }?.exists == false)
        #expect(graph.nodes.first { $0.name == "App" }?.exists == true)
    }

    @Test("omits packages that take part in no relationship")
    func omitsUnconnectedPackages() {
        let graph = DependencyGraphBuilder.build(pkginfos: [
            pkg("App", requires: ["Helper"]),
            pkg("Helper"),
            pkg("Loner"),
        ])
        #expect(graph.nodes.contains { $0.name == "Loner" } == false)
    }

    @Test("keeps requires and update_for between the same pair as distinct edges")
    func distinctEdgeKinds() {
        let graph = DependencyGraphBuilder.build(pkginfos: [
            pkg("A", requires: ["B"], updateFor: ["B"]),
            pkg("B"),
        ])
        #expect(graph.edges.count == 2)
        #expect(Set(graph.edges.map(\.kind)) == [.requires, .updateFor])
    }
}
