import Foundation
import Core

/// File-backed ``ManifestService``. Manifests may live without an
/// extension (a historic Munki convention), so the walker tolerates empty
/// extensions and ManifestFileCoder treats them as plist.
public actor FileManifestService: ManifestService {
    public init() {}

    public func load(in repository: MunkiRepository) async throws -> [ManifestRecord] {
        let urls = RepoWalker.documentURLs(
            under: repository.manifestsURL,
            allowEmptyExtension: true
        )
        let root = repository.rootURL
        return try await withThrowingTaskGroup(of: ManifestRecord.self) { group in
            for url in urls {
                group.addTask { try ManifestFileCoder.read(from: url, repositoryRoot: root) }
            }
            var records: [ManifestRecord] = []
            for try await record in group { records.append(record) }
            return records.sorted { $0.manifest.manifestName < $1.manifest.manifestName }
        }
    }

    public func save(_ record: ManifestRecord) async throws {
        try ManifestFileCoder.write(record)
    }

    public func create(
        named name: String,
        body: Manifest,
        in repository: MunkiRepository,
        format: RepoFormat?
    ) async throws -> ManifestRecord {
        let chosenFormat = format ?? repository.defaultFormat
        let filename = "\(name).\(chosenFormat.preferredExtension)"
        let url = repository.manifestsURL.appending(path: filename)
        if FileManager.default.fileExists(atPath: url.path) {
            throw RepositoryError.duplicateName(filename)
        }
        var manifest = body
        manifest.manifestName = name
        let record = ManifestRecord(manifest: manifest, fileURL: url, format: chosenFormat)
        try ManifestFileCoder.write(record)
        return record
    }

    public func delete(_ record: ManifestRecord) async throws {
        try FileManager.default.removeItem(at: record.fileURL)
    }

    public func convertFormat(
        _ record: ManifestRecord,
        to format: RepoFormat
    ) async throws -> ManifestRecord {
        guard format != record.format else { return record }
        let newURL = record.fileURL
            .deletingPathExtension()
            .appendingPathExtension(format.preferredExtension)
        let migrated = ManifestRecord(
            manifest: record.manifest,
            fileURL: newURL,
            format: format
        )
        try ManifestFileCoder.write(migrated)
        try FileManager.default.removeItem(at: record.fileURL)
        return migrated
    }
}
