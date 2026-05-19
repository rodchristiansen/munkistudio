import Foundation
import Core

/// File-backed ``RepoCleanHistoryService``. `repoclean` keeps no log of
/// its own, so MunkiStudio records each apply run here. The log lives
/// outside any repo — under Application Support — since a repo's own
/// contents are what got cleaned. One JSON file holds every repo's runs;
/// reads filter by repo path.
public actor RepoCleanHistoryStore: RepoCleanHistoryService {
    private let fileURL: URL

    /// `fileURL` overrides the storage location (tests pass a temp file).
    /// The default is `~/Library/Application Support/MunkiStudio/`.
    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = (try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.fileURL = base.appending(path: "MunkiStudio/repoclean-history.json")
        }
    }

    public func records(forRepoAt repoPath: String) -> [RepoCleanRecord] {
        loadAll()
            .filter { $0.repoPath == repoPath }
            .sorted { $0.date > $1.date }
    }

    public func append(_ record: RepoCleanRecord) throws {
        var all = loadAll()
        all.append(record)
        try save(all)
    }

    private func loadAll() -> [RepoCleanRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([RepoCleanRecord].self, from: data)) ?? []
    }

    private func save(_ records: [RepoCleanRecord]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: fileURL, options: .atomic)
    }
}
