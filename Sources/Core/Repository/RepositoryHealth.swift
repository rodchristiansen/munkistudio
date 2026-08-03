import Foundation

/// What a candidate folder actually contains, measured against the Munki
/// repo layout. Used to reject a wrong folder at the moment it is picked
/// rather than opening it and presenting an empty studio.
///
/// The judgement is deliberately generous: a repo is recognised as soon
/// as it has `pkgsinfo/` or `manifests/`, because a freshly initialised
/// repo legitimately has no `catalogs/` (nothing has run `makecatalogs`
/// yet) and no `pkgs/` (nothing has been imported yet). Those show up as
/// warnings instead.
public struct RepositoryHealth: Sendable, Equatable {
    public var hasPkgsinfo: Bool
    public var hasManifests: Bool
    public var hasCatalogs: Bool
    public var hasPkgs: Bool

    public init(
        hasPkgsinfo: Bool,
        hasManifests: Bool,
        hasCatalogs: Bool,
        hasPkgs: Bool
    ) {
        self.hasPkgsinfo = hasPkgsinfo
        self.hasManifests = hasManifests
        self.hasCatalogs = hasCatalogs
        self.hasPkgs = hasPkgs
    }

    /// Probe `rootURL` on disk. Only directories count — a *file* named
    /// `pkgsinfo` is not a pkgsinfo directory.
    public init(probing rootURL: URL) {
        let repository = MunkiRepository(rootURL: rootURL)
        self.init(
            hasPkgsinfo: Self.isDirectory(repository.pkgsinfoURL),
            hasManifests: Self.isDirectory(repository.manifestsURL),
            hasCatalogs: Self.isDirectory(repository.catalogsURL),
            hasPkgs: Self.isDirectory(repository.pkgsURL)
        )
    }

    /// Whether this folder is a Munki repository at all. `false` means
    /// the user picked the wrong folder — their home directory, the
    /// parent of the repo, an empty share mount point.
    public var isMunkiRepository: Bool { hasPkgsinfo || hasManifests }

    /// Non-fatal gaps worth telling the user about after a successful
    /// open. Empty for a complete repo.
    public var warnings: [String] {
        var warnings: [String] = []
        if !hasPkgsinfo {
            warnings.append("No pkgsinfo/ folder — the Packages tab will be empty.")
        }
        if !hasManifests {
            warnings.append("No manifests/ folder — the Manifests tab will be empty.")
        }
        if !hasCatalogs {
            warnings.append("No catalogs/ folder — run makecatalogs to build it.")
        }
        if !hasPkgs {
            warnings.append("No pkgs/ folder — imported installers have nowhere to land.")
        }
        return warnings
    }

    /// Why `rootURL` was rejected, phrased so the user knows what to pick
    /// instead. Only meaningful when ``isMunkiRepository`` is `false`.
    public func rejectionMessage(for rootURL: URL) -> String {
        "\"\(rootURL.lastPathComponent)\" doesn't look like a Munki repository — "
            + "it has no pkgsinfo/ or manifests/ folder. "
            + "Choose the repo root, the folder that contains pkgsinfo/, pkgs/, catalogs/ and manifests/."
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }
}
