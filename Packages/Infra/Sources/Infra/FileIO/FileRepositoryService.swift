import Foundation
import Core

/// Default ``RepositoryService`` implementation for local / SMB-mounted
/// Munki repos. It walks the standard directory layout, detects the
/// majority on-disk format, and assembles a ``RepositorySnapshot`` by
/// delegating to the other Infra services.
public actor FileRepositoryService: RepositoryService {
    private let packages: any PackageService
    private let manifests: any ManifestService
    private let catalogsService: any CatalogService
    private let icons: any IconService

    public init(
        packages: any PackageService = FilePackageService(),
        manifests: any ManifestService = FileManifestService(),
        catalogs: any CatalogService = FileCatalogService(),
        icons: any IconService = FileIconService()
    ) {
        self.packages = packages
        self.manifests = manifests
        self.catalogsService = catalogs
        self.icons = icons
    }

    public func open(rootURL: URL) async throws -> MunkiRepository {
        let format = detectFormatMajority(at: rootURL.appending(path: "pkgsinfo"))
        return MunkiRepository(rootURL: rootURL, defaultFormat: format)
    }

    public func validate(_ repository: MunkiRepository) async -> [String] {
        var warnings: [String] = []
        let fm = FileManager.default
        if !fm.fileExists(atPath: repository.pkgsinfoURL.path) {
            warnings.append("Missing pkgsinfo/ directory.")
        }
        if !fm.fileExists(atPath: repository.manifestsURL.path) {
            warnings.append("Missing manifests/ directory.")
        }
        return warnings
    }

    public func reload(_ repository: MunkiRepository) async throws -> RepositorySnapshot {
        async let pkginfoTask = packages.load(in: repository)
        async let manifestTask = manifests.load(in: repository)
        async let iconTask = icons.load(in: repository)

        let pkginfoRecords = try await pkginfoTask
        let manifestRecords = try await manifestTask
        let iconAssets = try await iconTask
        let catalogList = await catalogsService.catalogs(from: pkginfoRecords)

        return RepositorySnapshot(
            pkginfos: pkginfoRecords,
            manifests: manifestRecords,
            catalogs: catalogList,
            icons: iconAssets
        )
    }

    private func detectFormatMajority(at directory: URL) -> RepoFormat {
        var counts: [RepoFormat: Int] = [:]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return .plist
        }
        for case let url as URL in enumerator {
            if let format = RepoFormat.fromPathExtension(url.pathExtension) {
                counts[format, default: 0] += 1
            }
        }
        // Tie or empty → plist (Munki's historic default).
        if (counts[.yaml] ?? 0) > (counts[.plist] ?? 0) { return .yaml }
        return .plist
    }
}
