import Foundation
import Core

/// Façade that dispatches Pkginfo I/O to the appropriate format coder
/// based on the file's extension. This is the entry point Infra's
/// `PackageService` calls — it keeps the rest of the codebase ignorant of
/// whether a given pkginfo lives as `.plist` or `.yaml` on disk.
public enum PkginfoFileCoder {
    public static func read(from url: URL) throws -> PkginfoRecord {
        guard let format = RepoFormat.fromPathExtension(url.pathExtension) else {
            throw RepositoryError.unsupportedFormat(url.pathExtension)
        }
        let data = try Data(contentsOf: url)
        do {
            let pkginfo: Pkginfo
            switch format {
            case .plist:
                pkginfo = try PkginfoPlistCoder.decode(from: data)
            case .yaml:
                let yaml = String(decoding: data, as: UTF8.self)
                pkginfo = try PkginfoYamlCoder.decode(from: yaml)
            }
            let (created, modified) = FileTimestamps.read(url)
            return PkginfoRecord(
                pkginfo: pkginfo,
                fileURL: url,
                format: format,
                createdAt: created,
                modifiedAt: modified
            )
        } catch {
            throw RepositoryError.parse(file: url, message: String(describing: error))
        }
    }

    public static func write(_ record: PkginfoRecord) throws {
        let data: Data
        do {
            switch record.format {
            case .plist:
                data = try PkginfoPlistCoder.encode(record.pkginfo)
            case .yaml:
                let yaml = try PkginfoYamlCoder.encode(record.pkginfo)
                data = Data(yaml.utf8)
            }
        } catch {
            throw RepositoryError.write(file: record.fileURL, message: String(describing: error))
        }
        try AtomicWrite.write(data, to: record.fileURL)
    }
}
