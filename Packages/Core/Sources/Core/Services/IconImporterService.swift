import Foundation

/// Generate PNG icons for pkginfo items using the `iconimporter` CLI Munki
/// ships under `/usr/local/munki/`. `iconimporter` extracts icons from an
/// item's installer payload and writes them into the repo's `icons/`
/// directory.
public protocol IconImporterService: Sendable {
    /// Run `iconimporter` for one pkginfo item, generating PNG icon(s)
    /// into the repo's `icons/` directory. `force` regenerates even when
    /// an icon already exists.
    ///
    /// Returns the filenames `iconimporter` wrote, in order. A single-app
    /// package yields `["<item>.png"]`; a package with several apps yields
    /// numbered variants (`<item>_1.png`, `<item>_2.png`, …); a package
    /// with no extractable application icon yields an empty array.
    /// Throws ``RepositoryError/process(name:exitCode:output:)`` on a
    /// non-zero exit.
    func generateIcon(
        forItem itemName: String,
        force: Bool,
        in repository: MunkiRepository
    ) async throws -> [String]
}
