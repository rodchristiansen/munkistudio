import Foundation
import Testing
import Core
@testable import Infra

@Suite("FileTestingService — schema, autofix, checklist round-trip")
struct FileTestingServiceTests {

    // MARK: - Schema

    @Test("schema flags missing required fields")
    func schemaFlagsMissingFields() async throws {
        let service = FileTestingService()
        let pkginfo = Pkginfo(name: "")          // empty name
        let record = PkginfoRecord(
            pkginfo: pkginfo,
            fileURL: tempURL("missing-name.plist"),
            format: .plist
        )
        let result = await service.validate(record, in: RepositorySnapshot())
        let schema = try #require(result.steps.first { $0.kind == .schema })
        #expect(schema.success == false)
        #expect(schema.severity == .error)
        #expect(schema.messages.contains { $0.contains("name") })
        #expect(schema.messages.contains { $0.contains("version") })
    }

    @Test("schema warns when claimed catalog is unknown to the repo")
    func schemaWarnsOnUnknownCatalog() async throws {
        let service = FileTestingService()
        var pkginfo = Pkginfo(name: "Widget")
        pkginfo.version = "1.0"
        pkginfo.catalogs = ["Production"]
        let record = PkginfoRecord(
            pkginfo: pkginfo,
            fileURL: tempURL("widget.plist"),
            format: .plist
        )
        // Snapshot declares only a "Development" catalog.
        let snapshot = RepositorySnapshot(
            pkginfos: [record],
            catalogs: [Catalog(name: "Development")]
        )
        let result = await service.validate(record, in: snapshot)
        let schema = try #require(result.steps.first { $0.kind == .schema })
        #expect(schema.success)        // missing-catalog is a warning, not an error
        #expect(schema.severity == .warning)
        #expect(schema.messages.contains { $0.contains("Production") })
    }

    // MARK: - Autofix

    @Test("autofix dedupes supported_architectures")
    func autofixDedupsArchs() async throws {
        let service = FileTestingService()
        var pkginfo = Pkginfo(name: "Widget")
        pkginfo.version = "1.0"
        pkginfo.supportedArchitectures = [.x86_64, .arm64, .x86_64]
        let record = PkginfoRecord(
            pkginfo: pkginfo,
            fileURL: tempURL("widget.plist"),
            format: .plist
        )
        let proposal = try #require(await service.proposeAutofixes(for: record, in: RepositorySnapshot()))
        #expect(proposal.pkginfo.supportedArchitectures == [.x86_64, .arm64])
        #expect(proposal.changes.contains { $0.field == "supported_architectures" })
    }

    @Test("autofix sorts catalogs alphabetically")
    func autofixSortsCatalogs() async throws {
        let service = FileTestingService()
        var pkginfo = Pkginfo(name: "Widget")
        pkginfo.version = "1.0"
        pkginfo.catalogs = ["Production", "Development", "Testing"]
        let record = PkginfoRecord(
            pkginfo: pkginfo,
            fileURL: tempURL("widget.plist"),
            format: .plist
        )
        let proposal = try #require(await service.proposeAutofixes(for: record, in: RepositorySnapshot()))
        #expect(proposal.pkginfo.catalogs == ["Development", "Production", "Testing"])
    }

    @Test("autofix returns nil when there is nothing to do")
    func autofixNoOp() async throws {
        let service = FileTestingService()
        var pkginfo = Pkginfo(name: "Widget")
        pkginfo.version = "1.0"
        pkginfo.catalogs = ["Development"]
        pkginfo.supportedArchitectures = [.arm64]
        let record = PkginfoRecord(
            pkginfo: pkginfo,
            fileURL: tempURL("widget.plist"),
            format: .plist
        )
        let proposal = await service.proposeAutofixes(for: record, in: RepositorySnapshot())
        #expect(proposal == nil)
    }

    // MARK: - Checklist round-trip

    @Test("checklist JSON round-trips and Markdown view names every package")
    func checklistRoundTrip() async throws {
        let service = FileTestingService()
        let repoRoot = try uniqueTempDir()
        defer { try? FileManager.default.removeItem(at: repoRoot) }
        let repository = MunkiRepository(rootURL: repoRoot)

        let store = ChecklistStore(items: [
            ChecklistEntry(packageName: "Widget", version: "1.0", status: .pass, tester: "Rod"),
            ChecklistEntry(packageName: "Gizmo", status: .untested)
        ])
        try await service.saveChecklist(store, in: repository)

        let jsonURL = repoRoot.appending(path: ".munkistudio/testing-checklist.json")
        let mdURL = repoRoot.appending(path: ".munkistudio/testing-checklist.md")
        #expect(FileManager.default.fileExists(atPath: jsonURL.path))
        #expect(FileManager.default.fileExists(atPath: mdURL.path))

        let roundtripped = try await service.loadChecklist(in: repository)
        #expect(roundtripped.items.map(\.packageName) == ["Widget", "Gizmo"])
        #expect(roundtripped.items[0].status == .pass)

        let markdown = try String(contentsOf: mdURL, encoding: .utf8)
        #expect(markdown.contains("Widget"))
        #expect(markdown.contains("Gizmo"))
        #expect(markdown.contains("✅ pass"))
        #expect(markdown.contains("⚪ untested"))
    }

    // MARK: - Helpers

    private func tempURL(_ suffix: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "FileTestingServiceTests-\(UUID().uuidString)-\(suffix)")
    }

    private func uniqueTempDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "FileTestingServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
