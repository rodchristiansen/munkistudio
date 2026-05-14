import Foundation
import Core

/// Dispatch Manifest I/O to plist or YAML coders by file extension.
public enum ManifestFileCoder {
    public static func read(from url: URL, repositoryRoot: URL) throws -> ManifestRecord {
        guard let format = RepoFormat.fromPathExtension(url.pathExtension) else {
            // Manifest files conventionally have no extension — treat them
            // as plist when the extension is empty.
            if url.pathExtension.isEmpty {
                return try readUnextended(from: url, repositoryRoot: repositoryRoot)
            }
            throw RepositoryError.unsupportedFormat(url.pathExtension)
        }
        let data = try Data(contentsOf: url)
        let name = manifestName(for: url, repositoryRoot: repositoryRoot)
        do {
            let manifest: Manifest
            switch format {
            case .plist:
                manifest = try ManifestPlistCoder.decode(from: data, name: name)
            case .yaml:
                let yaml = String(decoding: data, as: UTF8.self)
                manifest = try ManifestYamlCoder.decode(from: yaml, name: name)
            }
            let (created, modified) = FileTimestamps.read(url)
            return ManifestRecord(
                manifest: manifest,
                fileURL: url,
                format: format,
                createdAt: created,
                modifiedAt: modified
            )
        } catch {
            throw RepositoryError.parse(file: url, message: String(describing: error))
        }
    }

    public static func write(_ record: ManifestRecord) throws {
        let data: Data
        do {
            switch record.format {
            case .plist:
                data = try ManifestPlistCoder.encode(record.manifest)
            case .yaml:
                let yaml = try ManifestYamlCoder.encode(record.manifest)
                data = Data(yaml.utf8)
            }
        } catch {
            throw RepositoryError.write(file: record.fileURL, message: String(describing: error))
        }
        try AtomicWrite.write(data, to: record.fileURL)
    }

    private static func readUnextended(from url: URL, repositoryRoot: URL) throws -> ManifestRecord {
        let data = try Data(contentsOf: url)
        let name = manifestName(for: url, repositoryRoot: repositoryRoot)
        // Try plist first (the historic convention), fall back to YAML
        // so the occasional extensionless YAML manifest still loads.
        do {
            let manifest = try ManifestPlistCoder.decode(from: data, name: name)
            let (created, modified) = FileTimestamps.read(url)
            return ManifestRecord(
                manifest: manifest,
                fileURL: url,
                format: .plist,
                createdAt: created,
                modifiedAt: modified
            )
        } catch {
            do {
                let yaml = String(decoding: data, as: UTF8.self)
                let manifest = try ManifestYamlCoder.decode(from: yaml, name: name)
                let (created, modified) = FileTimestamps.read(url)
                return ManifestRecord(
                    manifest: manifest,
                    fileURL: url,
                    format: .yaml,
                    createdAt: created,
                    modifiedAt: modified
                )
            } catch {
                throw RepositoryError.parse(file: url, message: String(describing: error))
            }
        }
    }

    /// Manifest name = the path of the file relative to `manifests/`, with
    /// the extension dropped. Subdirectories become slash-separated parts
    /// in the name, which matches Munki's `included_manifests` references.
    ///
    /// We resolve symlinks on both sides because macOS exposes the temp
    /// directory under both `/var/folders/...` and
    /// `/private/var/folders/...`; the prefix-strip needs them to agree.
    public static func manifestName(for url: URL, repositoryRoot: URL) -> String {
        let resolvedURL = url.resolvingSymlinksInPath().path
        let manifestsRoot = repositoryRoot
            .resolvingSymlinksInPath()
            .appending(path: "manifests")
            .path
        let prefix = manifestsRoot + "/"
        let relative = resolvedURL.hasPrefix(prefix)
            ? String(resolvedURL.dropFirst(prefix.count))
            : url.lastPathComponent
        return (relative as NSString).deletingPathExtension
    }
}
