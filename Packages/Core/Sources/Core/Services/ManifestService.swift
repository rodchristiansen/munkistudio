import Foundation

/// Read / write manifest files. Mirrors ``PackageService`` and preserves
/// format on save.
public protocol ManifestService: Sendable {
    func load(in repository: MunkiRepository) async throws -> (
        records: [ManifestRecord],
        errors: [RepositorySnapshot.LoadError]
    )
    func save(_ record: ManifestRecord) async throws

    /// Create a new manifest. The filename is derived from `name`; nested
    /// paths (e.g. `lab1/imac-21.5`) are allowed and create directories as
    /// needed.
    func create(
        named name: String,
        body: Manifest,
        in repository: MunkiRepository,
        format: RepoFormat?
    ) async throws -> ManifestRecord

    func delete(_ record: ManifestRecord) async throws

    /// Rename a manifest. The file moves to a path derived from `newName`
    /// (nested paths allowed) and `manifestName` is updated to match.
    func rename(
        _ record: ManifestRecord,
        to newName: String,
        in repository: MunkiRepository
    ) async throws -> ManifestRecord

    /// Duplicate a manifest under `newName`, copying its full contents.
    func duplicate(
        _ record: ManifestRecord,
        as newName: String,
        in repository: MunkiRepository
    ) async throws -> ManifestRecord

    func convertFormat(
        _ record: ManifestRecord,
        to format: RepoFormat
    ) async throws -> ManifestRecord
}
