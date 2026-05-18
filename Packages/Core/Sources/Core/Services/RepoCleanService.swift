import Foundation

/// Invoke the `repoclean` CLI Munki ships under `/usr/local/munki/` and
/// stream its output. `repoclean` removes older package / pkginfo versions,
/// keeping the most recent few of each item. We don't reimplement it in
/// Swift — admin trust is anchored to "the same binary the server runs."
///
/// A run is either a **preview** (`RepoCleanOptions.apply == false`) — which
/// answers "no" to repoclean's confirmation prompt and deletes nothing — or
/// an **apply** (`apply == true`) — which passes `--auto` and performs the
/// deletions. Both stream the same listing of items and versions.
public protocol RepoCleanService: Sendable {
    /// Stream lines from a `repoclean` run as they're emitted. The returned
    /// sequence finishes when the process exits; the final element is a
    /// ``RepoCleanOutcome``.
    func run(
        in repository: MunkiRepository,
        options: RepoCleanOptions
    ) -> AsyncThrowingStream<RepoCleanEvent, any Error>
}

/// Per-run options for `repoclean`.
public struct RepoCleanOptions: Sendable, Hashable {
    /// `--keep` — how many versions of each item variation to retain.
    public var keep: Int
    /// `--show-all` — list every item, including those with no deletions.
    public var showAll: Bool
    /// `false` previews (nothing deleted); `true` passes `--auto` and
    /// performs the deletions.
    public var apply: Bool

    public init(keep: Int = 2, showAll: Bool = false, apply: Bool = false) {
        self.keep = keep
        self.showAll = showAll
        self.apply = apply
    }
}

public enum RepoCleanEvent: Sendable {
    case line(String)
    case finished(RepoCleanOutcome)
}

public struct RepoCleanOutcome: Sendable {
    public var exitCode: Int32
    /// `true` when the run actually deleted items (an apply run that
    /// exited cleanly), `false` for a preview.
    public var applied: Bool

    public init(exitCode: Int32, applied: Bool) {
        self.exitCode = exitCode
        self.applied = applied
    }
}
