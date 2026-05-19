import Foundation
import Core

/// File-backed ``PackageService``. Reads pkginfo files in parallel via a
/// throwing task group, writes them atomically, and preserves the
/// on-disk format of an existing file.
public actor FilePackageService: PackageService {
    public init() {}

    public func load(in repository: MunkiRepository) async throws -> (
        records: [PkginfoRecord],
        errors: [RepositorySnapshot.LoadError]
    ) {
        let urls = RepoWalker.documentURLs(under: repository.pkgsinfoURL)
        // Each file gets its own try so one corrupt pkginfo doesn't blow
        // up the whole batch.
        let outcomes = await withTaskGroup(of: Outcome.self) { group -> [Outcome] in
            for url in urls {
                group.addTask {
                    do {
                        let record = try PkginfoFileCoder.read(from: url)
                        return .success(record)
                    } catch {
                        return .failure(RepositorySnapshot.LoadError(
                            fileURL: url,
                            message: String(describing: error)
                        ))
                    }
                }
            }
            var results: [Outcome] = []
            for await outcome in group { results.append(outcome) }
            return results
        }
        var records: [PkginfoRecord] = []
        var errors: [RepositorySnapshot.LoadError] = []
        for outcome in outcomes {
            switch outcome {
            case .success(let record): records.append(record)
            case .failure(let error): errors.append(error)
            }
        }
        return (records.sorted { $0.pkginfo.name < $1.pkginfo.name }, errors)
    }

    private enum Outcome: Sendable {
        case success(PkginfoRecord)
        case failure(RepositorySnapshot.LoadError)
    }

    public func save(_ record: PkginfoRecord) async throws {
        try PkginfoFileCoder.write(record)
    }

    public func create(
        _ pkginfo: Pkginfo,
        in repository: MunkiRepository,
        subdirectory: String?,
        format: RepoFormat?
    ) async throws -> PkginfoRecord {
        let chosenFormat = format ?? repository.defaultFormat
        let filename = "\(pkginfo.name)-\(pkginfo.version ?? "1.0").\(chosenFormat.preferredExtension)"
        var url = repository.pkgsinfoURL
        if let subdirectory, !subdirectory.isEmpty {
            url.appendPathComponent(subdirectory)
        }
        url.appendPathComponent(filename)
        if FileManager.default.fileExists(atPath: url.path) {
            throw RepositoryError.duplicateName(filename)
        }
        let record = PkginfoRecord(pkginfo: pkginfo, fileURL: url, format: chosenFormat)
        try PkginfoFileCoder.write(record)
        return record
    }

    public func delete(_ record: PkginfoRecord) async throws {
        try FileManager.default.removeItem(at: record.fileURL)
    }

    public func convertFormat(
        _ record: PkginfoRecord,
        to format: RepoFormat
    ) async throws -> PkginfoRecord {
        guard format != record.format else { return record }
        let newURL = record.fileURL
            .deletingPathExtension()
            .appendingPathExtension(format.preferredExtension)
        let migrated = PkginfoRecord(
            pkginfo: record.pkginfo,
            fileURL: newURL,
            format: format
        )
        try PkginfoFileCoder.write(migrated)
        try FileManager.default.removeItem(at: record.fileURL)
        return migrated
    }
}
