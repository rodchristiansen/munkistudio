import Foundation

/// Stores and retrieves the log of past `repoclean` apply runs. `repoclean`
/// has no native history, so MunkiStudio keeps its own — see
/// ``RepoCleanRecord``. Implementations persist the log outside the repo
/// (the repo's own contents are what got cleaned).
public protocol RepoCleanHistoryService: Sendable {
    /// Past clean runs for the repo at `repoPath`, newest first.
    func records(forRepoAt repoPath: String) async -> [RepoCleanRecord]

    /// Append a completed run to the log.
    func append(_ record: RepoCleanRecord) async throws
}
