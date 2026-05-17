import Foundation
import Testing
@testable import Core

@Suite("Manifest graph builder")
struct ManifestGraphBuilderTests {
    private func manifest(_ name: String, includes: [String]? = nil) -> Manifest {
        var manifest = Manifest(manifestName: name)
        manifest.includedManifests = includes
        return manifest
    }

    @Test("builds an inclusion edge between two manifests")
    func inclusionEdge() {
        let graph = ManifestGraphBuilder.build(manifests: [
            manifest("site-default", includes: ["labs"]),
            manifest("labs"),
        ])
        #expect(graph.edges == [.init(from: "site-default", to: "labs", kind: .manifestInclusion)])
        #expect(Set(graph.nodes.map(\.name)) == ["site-default", "labs"])
    }

    @Test("keeps an isolated manifest as a node")
    func keepsIsolatedManifest() {
        let graph = ManifestGraphBuilder.build(manifests: [manifest("standalone")])
        #expect(graph.edges.isEmpty)
        #expect(graph.nodes.map(\.name) == ["standalone"])
    }

    @Test("marks a referenced-but-absent manifest as not existing")
    func missingManifestNotExisting() {
        let graph = ManifestGraphBuilder.build(manifests: [manifest("site-default", includes: ["ghost"])])
        #expect(graph.nodes.first { $0.name == "ghost" }?.exists == false)
        #expect(graph.nodes.first { $0.name == "site-default" }?.exists == true)
    }

    @Test("drops a self-inclusion")
    func dropsSelfInclusion() {
        let graph = ManifestGraphBuilder.build(manifests: [manifest("loop", includes: ["loop"])])
        #expect(graph.edges.isEmpty)
        #expect(graph.nodes.map(\.name) == ["loop"])
    }

    @Test("de-duplicates a repeated inclusion")
    func deduplicatesInclusions() {
        let graph = ManifestGraphBuilder.build(manifests: [
            manifest("site-default", includes: ["labs", "labs"]),
            manifest("labs"),
        ])
        #expect(graph.edges.count == 1)
    }

    @Test("resolves includes that carry a file extension")
    func resolvesExtensionedReference() {
        let graph = ManifestGraphBuilder.build(manifests: [
            manifest("Assigned/Faculty", includes: ["CoreManifest.yaml", "Assigned.yaml"]),
            manifest("CoreManifest"),
            manifest("Assigned"),
        ])
        #expect(Set(graph.edges.map(\.to)) == ["CoreManifest", "Assigned"])
        #expect(graph.nodes.allSatisfy { $0.exists })
    }

    @Test("builds an edge per distinct included manifest")
    func multipleInclusions() {
        let graph = ManifestGraphBuilder.build(manifests: [
            manifest("site-default", includes: ["labs", "staff", "kiosk"]),
            manifest("labs"),
            manifest("staff"),
            manifest("kiosk"),
        ])
        #expect(graph.edges.count == 3)
        #expect(Set(graph.edges.map(\.to)) == ["labs", "staff", "kiosk"])
        #expect(graph.edges.allSatisfy { $0.kind == .manifestInclusion })
    }
}
