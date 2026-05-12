import Foundation

/// Read / write the pkginfo files in a repository. The service is responsible
/// for the format-preservation rule: a file opened as YAML saves as YAML; a
/// file opened as plist saves as plist; new files use the repository's
/// detected default format unless overridden.
public protocol PackageService: Sendable {
    /// Load every pkginfo under `repository.pkgsinfoURL`, recursively.
    func load(in repository: MunkiRepository) async throws -> [PkginfoRecord]

    /// Save a single pkginfo back to disk in its original format. Writes are
    /// atomic — readers either see the previous version or the new one,
    /// never a half-written file.
    func save(_ record: PkginfoRecord) async throws

    /// Create a new pkginfo file. The destination URL is computed from the
    /// repo root, the package name, and the optional subdirectory.
    func create(
        _ pkginfo: Pkginfo,
        in repository: MunkiRepository,
        subdirectory: String?,
        format: RepoFormat?
    ) async throws -> PkginfoRecord

    /// Delete a pkginfo from disk. Does not delete the corresponding
    /// installer item under `pkgs/` — callers decide whether to cascade.
    func delete(_ record: PkginfoRecord) async throws

    /// Convert a pkginfo file's on-disk format in place (plist↔YAML). Useful
    /// during a repo migration; preserves all keys including unknown ones.
    func convertFormat(
        _ record: PkginfoRecord,
        to format: RepoFormat
    ) async throws -> PkginfoRecord
}
