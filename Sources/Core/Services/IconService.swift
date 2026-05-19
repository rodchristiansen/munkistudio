import Foundation

/// Manage the `icons/` directory: load existing PNGs, write extracted icons,
/// recompute the `_icon_hashes.plist` after a change.
public protocol IconService: Sendable {
    func load(in repository: MunkiRepository) async throws -> [IconAsset]

    /// Read raw bytes for an icon. Returned data is decoupled from the
    /// asset record so callers can drive lazy / async image loads.
    func readBytes(of icon: IconAsset, in repository: MunkiRepository) async throws -> Data

    /// Write (or overwrite) an icon. Returns the updated record including
    /// the new SHA256 hash.
    func write(
        data: Data,
        filename: String,
        in repository: MunkiRepository
    ) async throws -> IconAsset

    func delete(_ icon: IconAsset, in repository: MunkiRepository) async throws

    /// Regenerate `_icon_hashes.plist` from the current contents of
    /// `icons/`. Munki clients use it to short-circuit downloads.
    func rebuildIconHashes(in repository: MunkiRepository) async throws
}
