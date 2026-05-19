import Foundation
import CryptoKit
import Core

/// File-backed icon library: enumerates `icons/`, reads/writes bytes,
/// regenerates `_icon_hashes.plist` to mirror what `makecatalogs` would
/// write. Hashing uses CryptoKit (built-in, no extra dep).
public actor FileIconService: IconService {
    public init() {}

    public func load(in repository: MunkiRepository) async throws -> [IconAsset] {
        Self.scanIcons(at: repository.iconsURL)
    }

    /// Synchronous walker. Kept out of the actor so we can use
    /// `NSEnumerator`'s iterator without the async-context restriction.
    private nonisolated static func scanIcons(at iconsURL: URL) -> [IconAsset] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: iconsURL.path) else { return [] }
        guard let enumerator = fm.enumerator(
            at: iconsURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let resolvedRoot = iconsURL.resolvingSymlinksInPath().path
        let prefix = resolvedRoot + "/"
        var assets: [IconAsset] = []
        for case let url as URL in enumerator {
            let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            guard isRegular else { continue }
            guard ["png", "icns", "jpg", "jpeg"].contains(url.pathExtension.lowercased()) else { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            let resolved = url.resolvingSymlinksInPath().path
            let relative = resolved.hasPrefix(prefix)
                ? String(resolved.dropFirst(prefix.count))
                : url.lastPathComponent
            assets.append(IconAsset(filename: relative, sha256: nil, byteSize: size))
        }
        return assets.sorted { $0.filename < $1.filename }
    }

    public func readBytes(of icon: IconAsset, in repository: MunkiRepository) async throws -> Data {
        let url = repository.iconsURL.appending(path: icon.filename)
        return try Data(contentsOf: url)
    }

    public func write(
        data: Data,
        filename: String,
        in repository: MunkiRepository
    ) async throws -> IconAsset {
        let url = repository.iconsURL.appending(path: filename)
        try AtomicWrite.write(data, to: url)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return IconAsset(filename: filename, sha256: hash, byteSize: data.count)
    }

    public func delete(_ icon: IconAsset, in repository: MunkiRepository) async throws {
        let url = repository.iconsURL.appending(path: icon.filename)
        try FileManager.default.removeItem(at: url)
    }

    public func rebuildIconHashes(in repository: MunkiRepository) async throws {
        var hashes: [String: String] = [:]
        let assets = try await load(in: repository)
        for asset in assets {
            let data = try await readBytes(of: asset, in: repository)
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            hashes[asset.filename] = hash
        }
        let plistURL = repository.iconsURL.appending(path: "_icon_hashes.plist")
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: hashes,
            format: .xml,
            options: 0
        )
        try AtomicWrite.write(plistData, to: plistURL)
    }
}
