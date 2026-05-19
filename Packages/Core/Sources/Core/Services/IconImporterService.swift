import Foundation

/// Generate PNG icons for pkginfo items using the `iconimporter` CLI Munki
/// ships under `/usr/local/munki/`. `iconimporter` extracts an icon from
/// each item's installer payload and writes it into the repo's `icons/`
/// directory as `<item-name>.png`.
public protocol IconImporterService: Sendable {
    /// Run `iconimporter` for a single pkginfo item. `force` regenerates
    /// the icon even when one already exists. Returns the tool's combined
    /// stdout/stderr; throws ``RepositoryError/process(name:exitCode:output:)``
    /// on a non-zero exit.
    @discardableResult
    func generateIcon(
        forItem itemName: String,
        force: Bool,
        in repository: MunkiRepository
    ) async throws -> String
}
