import Foundation
import Core

/// Catalogs are derived from the union of `pkginfo.catalogs[]` arrays. The
/// projection happens here; the disk reader is provided too for diagnostic
/// "what's the server actually serving" views.
public actor FileCatalogService: CatalogService {
    public init() {}

    public func catalogs(from records: [PkginfoRecord]) async -> [Catalog] {
        var membership: [String: [String]] = [:]
        for record in records {
            guard let cats = record.pkginfo.catalogs else { continue }
            for cat in cats {
                membership[cat, default: []].append(record.pkginfo.name)
            }
        }
        return membership
            .map { Catalog(name: $0.key, pkginfoNames: $0.value.sorted()) }
            .sorted { $0.name < $1.name }
    }

    public func loadOnDisk(in repository: MunkiRepository) async throws -> [Catalog] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: repository.catalogsURL.path) else { return [] }
        let urls = (try? fm.contentsOfDirectory(at: repository.catalogsURL, includingPropertiesForKeys: nil)) ?? []
        var catalogs: [Catalog] = []
        for url in urls where !url.lastPathComponent.hasPrefix(".") {
            let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            guard isRegular else { continue }
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                continue
            }
            // makecatalogs emits an array of pkginfo dictionaries. Extract
            // each item's `name`. We tolerate both plist and YAML here in
            // case Munki PR #1261 lands and the admin enables YAML output.
            if let array = try? decodeCatalogArray(data: data, format: detectFormat(url)) {
                let names = array.compactMap { $0["name"] as? String }
                catalogs.append(Catalog(name: url.lastPathComponent, pkginfoNames: names))
            }
        }
        return catalogs.sorted { $0.name < $1.name }
    }

    private func detectFormat(_ url: URL) -> RepoFormat {
        RepoFormat.fromPathExtension(url.pathExtension) ?? .plist
    }

    private func decodeCatalogArray(data: Data, format: RepoFormat) throws -> [[String: Any]] {
        switch format {
        case .plist:
            let any = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            return (any as? [[String: Any]]) ?? []
        case .yaml:
            let yaml = String(decoding: data, as: UTF8.self)
            let any = try Yams.load(yaml: yaml, MunkiYamlResolver.strict)
            return (any as? [[String: Any]]) ?? []
        }
    }
}

import Yams
