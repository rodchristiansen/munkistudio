import Foundation
import Core

/// File-backed ``ManifestService``. Manifests may live without an
/// extension (a historic Munki convention), so the walker tolerates empty
/// extensions and ManifestFileCoder treats them as plist.
public actor FileManifestService: ManifestService {
    public init() {}

    public func load(in repository: MunkiRepository) async throws -> (
        records: [ManifestRecord],
        errors: [RepositorySnapshot.LoadError]
    ) {
        let urls = RepoWalker.documentURLs(
            under: repository.manifestsURL,
            allowEmptyExtension: true
        )
        let root = repository.rootURL
        let outcomes = await withTaskGroup(of: Outcome.self) { group -> [Outcome] in
            for url in urls {
                group.addTask {
                    do {
                        let record = try ManifestFileCoder.read(from: url, repositoryRoot: root)
                        return .success(record)
                    } catch {
                        return .failure(RepositorySnapshot.LoadError(
                            fileURL: url,
                            message: String(describing: error)
                        ))
                    }
                }
            }
            var results: [Outcome] = []
            for await outcome in group { results.append(outcome) }
            return results
        }
        var records: [ManifestRecord] = []
        var errors: [RepositorySnapshot.LoadError] = []
        for outcome in outcomes {
            switch outcome {
            case .success(let record): records.append(record)
            case .failure(let error): errors.append(error)
            }
        }
        return (records.sorted { $0.manifest.manifestName < $1.manifest.manifestName }, errors)
    }

    private enum Outcome: Sendable {
        case success(ManifestRecord)
        case failure(RepositorySnapshot.LoadError)
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

    public func rename(
        _ record: ManifestRecord,
        to newName: String,
        in repository: MunkiRepository
    ) async throws -> ManifestRecord {
        // Preserve the file's on-disk extension form — manifests may
        // legitimately live without an extension.
        let ext = record.fileURL.pathExtension
        let filename = ext.isEmpty ? newName : "\(newName).\(ext)"
        let newURL = repository.manifestsURL.appending(path: filename)
        guard newURL != record.fileURL else { return record }
        if FileManager.default.fileExists(atPath: newURL.path) {
            throw RepositoryError.duplicateName(filename)
        }
        var manifest = record.manifest
        manifest.manifestName = newName
        let renamed = ManifestRecord(manifest: manifest, fileURL: newURL, format: record.format)
        try ManifestFileCoder.write(renamed)
        try FileManager.default.removeItem(at: record.fileURL)
        return renamed
    }

    public func duplicate(
        _ record: ManifestRecord,
        as newName: String,
        in repository: MunkiRepository
    ) async throws -> ManifestRecord {
        try await create(named: newName, body: record.manifest, in: repository, format: record.format)
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
