import Foundation
import Testing
@testable import Core

@Suite("Repository health")
struct RepositoryHealthTests {
    @Test("a complete repo is recognised and warns about nothing")
    func completeRepo() {
        let health = RepositoryHealth(
            hasPkgsinfo: true, hasManifests: true, hasCatalogs: true, hasPkgs: true
        )
        #expect(health.isMunkiRepository)
        #expect(health.warnings.isEmpty)
    }

    /// A repo that has only just been created has no catalogs and no
    /// packages yet. Rejecting it would lock a new user out on their
    /// very first run.
    @Test("a freshly initialised repo is recognised, with warnings")
    func freshlyInitialisedRepo() {
        let health = RepositoryHealth(
            hasPkgsinfo: true, hasManifests: true, hasCatalogs: false, hasPkgs: false
        )
        #expect(health.isMunkiRepository)
        #expect(health.warnings.count == 2)
    }

    @Test("either core directory alone is enough to recognise a repo")
    func eitherCoreDirectoryIsEnough() {
        #expect(
            RepositoryHealth(
                hasPkgsinfo: true, hasManifests: false, hasCatalogs: false, hasPkgs: false
            ).isMunkiRepository
        )
        #expect(
            RepositoryHealth(
                hasPkgsinfo: false, hasManifests: true, hasCatalogs: false, hasPkgs: false
            ).isMunkiRepository
        )
    }

    @Test("a folder with neither core directory is not a repo")
    func nonRepository() {
        let health = RepositoryHealth(
            hasPkgsinfo: false, hasManifests: false, hasCatalogs: true, hasPkgs: true
        )
        #expect(!health.isMunkiRepository)
    }

    @Test("the rejection message names the folder and what to pick instead")
    func rejectionMessageIsActionable() {
        let health = RepositoryHealth(
            hasPkgsinfo: false, hasManifests: false, hasCatalogs: false, hasPkgs: false
        )
        let message = health.rejectionMessage(for: URL(fileURLWithPath: "/Users/someone/Documents"))
        #expect(message.contains("Documents"))
        #expect(message.contains("pkgsinfo"))
        #expect(message.contains("manifests"))
    }

    @Test("probing reads real directories off disk")
    func probesDisk() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "health-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appending(path: "pkgsinfo"), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appending(path: "manifests"), withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let health = RepositoryHealth(probing: root)
        #expect(health.hasPkgsinfo)
        #expect(health.hasManifests)
        #expect(!health.hasCatalogs)
        #expect(!health.hasPkgs)
        #expect(health.isMunkiRepository)
    }

    @Test("a file named pkgsinfo is not a pkgsinfo directory")
    func fileIsNotDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "health-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appending(path: "pkgsinfo"))
        defer { try? FileManager.default.removeItem(at: root) }

        let health = RepositoryHealth(probing: root)
        #expect(!health.hasPkgsinfo)
        #expect(!health.isMunkiRepository)
    }

    @Test("probing a folder that doesn't exist reports nothing found")
    func probesMissingFolder() {
        let health = RepositoryHealth(
            probing: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        )
        #expect(!health.isMunkiRepository)
    }
}
