import Foundation
import Testing
import Core
@testable import Infra

@Suite("File-backed repository services")
struct FileRepositoryTests {
    @Test("open detects format majority and reload returns a populated snapshot")
    func openAndReload() async throws {
        let scratch = try ScratchRepo.make()
        defer { scratch.cleanup() }

        try scratch.writePkginfo("AppA", version: "1.0", catalogs: ["testing"], format: .plist)
        try scratch.writePkginfo("AppB", version: "2.0", catalogs: ["testing", "production"], format: .yaml)
        try scratch.writePkginfo("AppC", version: "3.0", catalogs: ["production"], format: .yaml)
        try scratch.writeManifest("lab1", catalogs: ["production"], managedInstalls: ["AppB"], format: .yaml)

        let service = FileRepositoryService()
        let repo = try await service.open(rootURL: scratch.rootURL)
        // 2 YAML pkginfos vs 1 plist → majority YAML.
        #expect(repo.defaultFormat == .yaml)

        let snapshot = try await service.reload(repo)
        #expect(snapshot.pkginfos.count == 3)
        #expect(snapshot.manifests.count == 1)
        #expect(snapshot.manifests.first?.manifest.manifestName == "lab1")
        #expect(snapshot.loadErrors.isEmpty)
        let catalogNames = snapshot.catalogs.map(\.name).sorted()
        #expect(catalogNames == ["production", "testing"])
        let production = snapshot.catalogs.first { $0.name == "production" }
        #expect(production?.pkginfoNames == ["AppB", "AppC"])
    }

    @Test("convertFormat round-trips a pkginfo through plist <-> YAML on disk")
    func convertFormatRoundTrip() async throws {
        let scratch = try ScratchRepo.make()
        defer { scratch.cleanup() }

        try scratch.writePkginfo("AppA", version: "1.5", catalogs: ["testing"], format: .plist)
        let packages = FilePackageService()
        let repo = MunkiRepository(rootURL: scratch.rootURL, defaultFormat: .plist)
        let initial = try await packages.load(in: repo)
        guard let first = initial.records.first else {
            Issue.record("Expected one pkginfo to load")
            return
        }
        #expect(first.format == .plist)

        let converted = try await packages.convertFormat(first, to: .yaml)
        #expect(converted.format == .yaml)
        #expect(converted.fileURL.pathExtension == "yaml")
        #expect(FileManager.default.fileExists(atPath: converted.fileURL.path))
        #expect(!FileManager.default.fileExists(atPath: first.fileURL.path))
    }

    @Test("bad pkginfo files don't fail the whole load — they appear in loadErrors")
    func partialLoadWithBadFile() async throws {
        let scratch = try ScratchRepo.make()
        defer { scratch.cleanup() }

        try scratch.writePkginfo("Good", version: "1.0", catalogs: ["testing"], format: .yaml)
        // A bogus file masquerading as YAML — `: : :` is invalid.
        let badURL = scratch.rootURL.appending(path: "pkgsinfo").appending(path: "Broken.yaml")
        try Data(": : :".utf8).write(to: badURL)

        let service = FileRepositoryService()
        let repo = try await service.open(rootURL: scratch.rootURL)
        let snapshot = try await service.reload(repo)
        #expect(snapshot.pkginfos.count == 1)
        #expect(snapshot.pkginfos.first?.pkginfo.name == "Good")
        #expect(snapshot.loadErrors.count == 1)
        #expect(snapshot.loadErrors.first?.fileURL.lastPathComponent == "Broken.yaml")
    }

    @Test("FileIconService computes hashes and writes _icon_hashes.plist")
    func iconHashes() async throws {
        let scratch = try ScratchRepo.make()
        defer { scratch.cleanup() }

        let icons = FileIconService()
        let repo = MunkiRepository(rootURL: scratch.rootURL, defaultFormat: .plist)
        let payload = Data("not really a png but bytes are bytes".utf8)
        let asset = try await icons.write(data: payload, filename: "AppA.png", in: repo)
        #expect(asset.sha256 != nil)
        try await icons.rebuildIconHashes(in: repo)

        let plistURL = repo.iconsURL.appending(path: "_icon_hashes.plist")
        let data = try Data(contentsOf: plistURL)
        let dict = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: String]
        #expect(dict?["AppA.png"] == asset.sha256)
    }
}

/// Tiny helper that materializes a temp directory shaped like a Munki repo
/// and lets tests drop pkginfo/manifest files into it without ceremony.
struct ScratchRepo {
    let rootURL: URL

    static func make() throws -> ScratchRepo {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "munki-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for sub in ["pkgsinfo", "manifests", "catalogs", "pkgs", "icons"] {
            try FileManager.default.createDirectory(
                at: url.appending(path: sub),
                withIntermediateDirectories: true
            )
        }
        return ScratchRepo(rootURL: url)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func writePkginfo(_ name: String, version: String, catalogs: [String], format: RepoFormat) throws {
        var pkginfo = Pkginfo(name: name)
        pkginfo.version = version
        pkginfo.catalogs = catalogs
        let filename = "\(name).\(format.preferredExtension)"
        let url = rootURL.appending(path: "pkgsinfo").appending(path: filename)
        let record = PkginfoRecord(pkginfo: pkginfo, fileURL: url, format: format)
        try PkginfoFileCoder.write(record)
    }

    func writeManifest(
        _ name: String,
        catalogs: [String],
        managedInstalls: [String],
        format: RepoFormat
    ) throws {
        var manifest = Manifest(manifestName: name)
        manifest.catalogs = catalogs
        manifest.managedInstalls = managedInstalls
        let filename = "\(name).\(format.preferredExtension)"
        let url = rootURL.appending(path: "manifests").appending(path: filename)
        let record = ManifestRecord(manifest: manifest, fileURL: url, format: format)
        try ManifestFileCoder.write(record)
    }
}
