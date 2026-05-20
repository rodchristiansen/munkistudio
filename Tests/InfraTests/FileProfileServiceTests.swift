import Foundation
import Testing
import Core
@testable import Infra

@Suite("FileProfileService disk lifecycle")
struct FileProfileServiceTests {
    @Test("create writes a starter profile and parses identifying metadata")
    func createAndParse() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let service = FileProfileService()
        let record = try await service.create(named: "wifi/staff", in: tempDir)

        let expectedURL = tempDir.appending(path: "wifi").appending(path: "staff.mobileconfig")
        #expect(record.fileURL == expectedURL)
        #expect(FileManager.default.fileExists(atPath: expectedURL.path))
        #expect(record.profile.identifier?.hasPrefix("com.munkistudio.profile.") == true)
        #expect(record.profile.uuid != nil)
        #expect(record.profile.displayName == "staff")
    }

    @Test("load walks subdirectories and surfaces every .mobileconfig")
    func loadWalksTree() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let service = FileProfileService()
        _ = try await service.create(named: "shared/network", in: tempDir)
        _ = try await service.create(named: "kiosk/restrictions", in: tempDir)
        _ = try await service.create(named: "rootlevel", in: tempDir)

        let records = try await service.load(in: tempDir)
        let labels = records.map { $0.fileURL.lastPathComponent }.sorted()
        #expect(labels == ["network.mobileconfig", "restrictions.mobileconfig", "rootlevel.mobileconfig"])
    }

    @Test("duplicate regenerates PayloadUUID + PayloadIdentifier")
    func duplicateRegeneratesIdentity() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let service = FileProfileService()
        let original = try await service.create(named: "source", in: tempDir)
        let copy = try await service.duplicate(original, as: "source-copy", in: tempDir)

        #expect(copy.fileURL != original.fileURL)
        #expect(copy.profile.uuid != original.profile.uuid)
        #expect(copy.profile.identifier != original.profile.identifier)
        #expect(copy.profile.displayName == "source-copy")
    }

    @Test("save rewrites the file atomically and re-parses metadata")
    func saveRewritesFile() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let service = FileProfileService()
        let record = try await service.create(named: "edit-target", in: tempDir)

        let updatedXML = record.xmlString.replacingOccurrences(
            of: "<string>edit-target</string>",
            with: "<string>Edited Display Name</string>"
        )
        let saved = try await service.save(record, xmlString: updatedXML)
        #expect(saved.profile.displayName == "Edited Display Name")

        let reloaded = try await service.load(in: tempDir)
        #expect(reloaded.first?.profile.displayName == "Edited Display Name")
    }

    @Test("rename moves the file and updates the URL")
    func renameMovesFile() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let service = FileProfileService()
        let record = try await service.create(named: "before", in: tempDir)
        let renamed = try await service.rename(record, to: "after/renamed", in: tempDir)

        #expect(!FileManager.default.fileExists(atPath: record.fileURL.path))
        #expect(FileManager.default.fileExists(atPath: renamed.fileURL.path))
        #expect(renamed.fileURL.lastPathComponent == "renamed.mobileconfig")
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "munkistudio-profile-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
