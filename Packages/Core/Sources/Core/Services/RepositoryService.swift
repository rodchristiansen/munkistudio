import Foundation

/// Opens, validates, and watches a Munki repository directory.
///
/// Concrete implementations live in Infra: `FileRepositoryService` walks a
/// local or SMB-mounted directory and uses `DispatchSource.FileSystemObject`
/// to notice external edits. The protocol stays unaware of any specific
/// backend so we can add S3 / Git plugin backends behind the same surface.
public protocol RepositoryService: Sendable {
    /// Inspect the contents of `rootURL` and return a populated
    /// ``MunkiRepository`` value, including the detected default format
    /// (whichever extension the majority of pkginfos use).
    func open(rootURL: URL) async throws -> MunkiRepository

    /// Validate that the directory looks like a Munki repo (has at least
    /// `pkgsinfo/` or `manifests/`). Returns a list of human-readable
    /// warnings rather than throwing — an empty array means everything
    /// checks out.
    func validate(_ repository: MunkiRepository) async -> [String]

    /// Push a snapshot of the on-disk graph into the SwiftData mirror so
    /// the UI can query/search/cross-reference without re-walking the disk.
    func reload(_ repository: MunkiRepository) async throws -> RepositorySnapshot
}

/// Fully materialized snapshot of a Munki repo at one point in time.
/// Suitable for handing to a SwiftData importer or for offline tests.
public struct RepositorySnapshot: Sendable {
    public var pkginfos: [PkginfoRecord]
    public var manifests: [ManifestRecord]
    public var catalogs: [Catalog]
    public var icons: [IconAsset]

    /// Per-file errors collected during load. A bad pkginfo doesn't fail
    /// the snapshot; the offending file ends up here so the UI can offer
    /// a "n files couldn't be parsed" affordance.
    public var loadErrors: [LoadError]

    public init(
        pkginfos: [PkginfoRecord] = [],
        manifests: [ManifestRecord] = [],
        catalogs: [Catalog] = [],
        icons: [IconAsset] = [],
        loadErrors: [LoadError] = []
    ) {
        self.pkginfos = pkginfos
        self.manifests = manifests
        self.catalogs = catalogs
        self.icons = icons
        self.loadErrors = loadErrors
    }

    public struct LoadError: Sendable, Hashable, Identifiable {
        public var fileURL: URL
        public var message: String

        public var id: URL { fileURL }

        public init(fileURL: URL, message: String) {
            self.fileURL = fileURL
            self.message = message
        }
    }
}

/// A pkginfo plus the on-disk metadata we need to write it back exactly
/// where it came from in the exact format it was authored in.
public struct PkginfoRecord: Sendable, Hashable, Identifiable {
    public var pkginfo: Pkginfo
    public var fileURL: URL
    public var format: RepoFormat

    public var id: URL { fileURL }

    public init(pkginfo: Pkginfo, fileURL: URL, format: RepoFormat) {
        self.pkginfo = pkginfo
        self.fileURL = fileURL
        self.format = format
    }
}

/// A manifest plus its on-disk location and format.
public struct ManifestRecord: Sendable, Hashable, Identifiable {
    public var manifest: Manifest
    public var fileURL: URL
    public var format: RepoFormat

    public var id: URL { fileURL }

    public init(manifest: Manifest, fileURL: URL, format: RepoFormat) {
        self.manifest = manifest
        self.fileURL = fileURL
        self.format = format
    }
}
