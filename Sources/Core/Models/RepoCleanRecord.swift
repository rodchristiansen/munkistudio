import Foundation

/// A record of one completed `repoclean` apply run. `repoclean` keeps no
/// log of its own, so MunkiStudio writes its own — this is what the Clean
/// tab's history list is built from. Persisted as JSON by a
/// ``RepoCleanHistoryService``.
public struct RepoCleanRecord: Sendable, Codable, Identifiable, Equatable {
    /// One pkginfo version that the run removed.
    public struct RemovedItem: Sendable, Codable, Equatable, Hashable {
        public var name: String
        public var version: String
        public var path: String

        public init(name: String, version: String, path: String) {
            self.name = name
            self.version = version
            self.path = path
        }
    }

    public var id: UUID
    public var date: Date
    /// Filesystem path of the repo this run cleaned.
    public var repoPath: String
    /// The `--keep` value the run used.
    public var keep: Int
    public var removedItems: [RemovedItem]
    public var pkgsDeleted: Int
    /// Savings strings exactly as `repoclean` reported them.
    public var pkginfoSpaceSaved: String
    public var pkgSpaceSaved: String

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        repoPath: String,
        keep: Int,
        removedItems: [RemovedItem],
        pkgsDeleted: Int,
        pkginfoSpaceSaved: String,
        pkgSpaceSaved: String
    ) {
        self.id = id
        self.date = date
        self.repoPath = repoPath
        self.keep = keep
        self.removedItems = removedItems
        self.pkgsDeleted = pkgsDeleted
        self.pkginfoSpaceSaved = pkginfoSpaceSaved
        self.pkgSpaceSaved = pkgSpaceSaved
    }

    /// Number of pkginfo versions removed.
    public var pkginfoItemsDeleted: Int { removedItems.count }
}
