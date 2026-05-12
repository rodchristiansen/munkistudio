import Foundation

/// Projects catalogs from the pkginfo graph and (optionally) reads the
/// catalog files that `makecatalogs` writes under `catalogs/`. We never
/// write catalog files from the UI — that's `makecatalogs`' job.
public protocol CatalogService: Sendable {
    /// Build the projected catalog list from a set of pkginfo records.
    func catalogs(from records: [PkginfoRecord]) async -> [Catalog]

    /// Read an existing `catalogs/<name>` file for diagnostics (lets the UI
    /// show stale vs. current membership).
    func loadOnDisk(in repository: MunkiRepository) async throws -> [Catalog]
}
