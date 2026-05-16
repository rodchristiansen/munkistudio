import Foundation

/// Git operations the UI cares about. Mirrors the surface CimianAdmin's
/// `IGitService` exposes so the SwiftUI Git pane can be a near-1:1 port.
///
/// Implementations shell out to `/usr/bin/git` — see the plan's "Git
/// integration" section for the trade-off vs. a libgit2 binding.
public protocol GitService: Sendable {
    /// Walk upward from `path` to locate the enclosing repo. Returns nil
    /// when the path isn't in a git working tree.
    func discover(at path: URL) async -> GitRepositoryInfo?

    /// Get the working tree status, scoped to the discovery's
    /// `relativeRepoPath` so a Munki subdirectory inside a larger monorepo
    /// only sees its own changes.
    func status(in info: GitRepositoryInfo) async throws -> [GitStatusEntry]

    /// Unified diff for one path. Staged + unstaged changes combined.
    func diff(in info: GitRepositoryInfo, relativePath: String) async throws -> String

    /// `git log --max-count=N` formatted with subject + author + date.
    func log(in info: GitRepositoryInfo, max: Int) async throws -> [GitCommit]

    /// Stage / unstage paths. Empty arrays are valid no-ops.
    func stage(in info: GitRepositoryInfo, relativePaths: [String]) async throws
    func unstage(in info: GitRepositoryInfo, relativePaths: [String]) async throws

    /// Create a commit. Streams hook output as it arrives so the composer
    /// UI can show progress; the final event carries the resulting SHA on
    /// success.
    func commit(
        in info: GitRepositoryInfo,
        subject: String,
        body: String?,
        runHooks: Bool,
        amend: Bool
    ) -> AsyncThrowingStream<GitProcessEvent, any Error>

    /// Push the current branch to `origin`. Streams output.
    func push(in info: GitRepositoryInfo) -> AsyncThrowingStream<GitProcessEvent, any Error>

    /// Switch branches. Refuses on a dirty working tree.
    func checkout(in info: GitRepositoryInfo, branch: String) async throws

    func branches(in info: GitRepositoryInfo) async throws -> [GitBranch]
    func identity(in info: GitRepositoryInfo) async throws -> GitIdentity?
    func setIdentity(in info: GitRepositoryInfo, _ identity: GitIdentity, scope: GitIdentityScope) async throws

    /// Resolve the hooks directory and list the hooks in it. When
    /// `overridePath` is non-nil it wins; otherwise resolution order is
    /// `core.hooksPath`, a top-level `.githooks`, then `.git/hooks`.
    func hooks(in info: GitRepositoryInfo, overridePath: String?) async throws -> GitHooksInfo

    /// Read a hook file's contents.
    func readHook(_ hook: GitHook) async throws -> String

    /// Write a hook file's contents.
    func writeHook(_ hook: GitHook, contents: String) async throws

    /// Toggle whether git runs the hook — flips its executable bit.
    func setHookActive(_ hook: GitHook, active: Bool) async throws

    /// Create a tag at `sha`. A non-empty `message` makes an annotated tag.
    func tag(in info: GitRepositoryInfo, name: String, at sha: String, message: String?) async throws
    /// Create a branch `name` pointing at `sha`. Does not switch to it.
    func createBranch(in info: GitRepositoryInfo, name: String, at sha: String) async throws
    /// Check out a commit directly — detaches HEAD.
    func checkoutCommit(in info: GitRepositoryInfo, sha: String) async throws
    /// Cherry-pick `sha` onto the current branch.
    func cherryPick(in info: GitRepositoryInfo, sha: String) async throws
    /// Revert `sha` with a new commit on the current branch.
    func revert(in info: GitRepositoryInfo, sha: String) async throws
    /// Merge `ref` into the current branch.
    func merge(in info: GitRepositoryInfo, ref: String) async throws
    /// Rebase the current branch onto `sha`.
    func rebase(in info: GitRepositoryInfo, onto sha: String) async throws
    /// Reset the current branch to `sha` with the given mode.
    func reset(in info: GitRepositoryInfo, to sha: String, mode: GitResetMode) async throws
}

/// Reset modes mirroring `git reset --soft/--mixed/--hard`.
public enum GitResetMode: String, Sendable, CaseIterable {
    case soft, mixed, hard
}

public struct GitRepositoryInfo: Sendable, Hashable {
    /// Absolute path to the top of the working tree (the directory
    /// containing `.git`).
    public var workTreeRoot: URL

    /// Relative path from `workTreeRoot` to the Munki repo root the UI
    /// opened. Often `""` when the Munki repo *is* the git repo.
    public var relativeRepoPath: String

    public var currentBranch: String?
    public var aheadCount: Int
    public var behindCount: Int

    public init(
        workTreeRoot: URL,
        relativeRepoPath: String,
        currentBranch: String? = nil,
        aheadCount: Int = 0,
        behindCount: Int = 0
    ) {
        self.workTreeRoot = workTreeRoot
        self.relativeRepoPath = relativeRepoPath
        self.currentBranch = currentBranch
        self.aheadCount = aheadCount
        self.behindCount = behindCount
    }
}

public struct GitStatusEntry: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case modified
        case added
        case deleted
        case renamed(from: String)
        case copied(from: String)
        case untracked
        case ignored
        case conflicted
    }

    public var relativePath: String
    public var kind: Kind
    public var staged: Bool

    public var id: String { relativePath }

    public init(relativePath: String, kind: Kind, staged: Bool) {
        self.relativePath = relativePath
        self.kind = kind
        self.staged = staged
    }
}

public struct GitCommit: Sendable, Hashable, Identifiable {
    public var sha: String
    public var subject: String
    public var author: String
    public var date: Date
    /// Parent SHAs. Empty for the root commit; two or more for a merge.
    public var parents: [String]
    /// Branch / tag / HEAD decorations pointing at this commit.
    public var refs: [GitRef]

    public var id: String { sha }

    public init(
        sha: String,
        subject: String,
        author: String,
        date: Date,
        parents: [String] = [],
        refs: [GitRef] = []
    ) {
        self.sha = sha
        self.subject = subject
        self.author = author
        self.date = date
        self.parents = parents
        self.refs = refs
    }
}

/// A branch / tag / HEAD decoration on a commit.
public struct GitRef: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case head, localBranch, remoteBranch, tag
    }

    public var name: String
    public var kind: Kind
    /// `true` when HEAD currently points here.
    public var isHead: Bool

    public init(name: String, kind: Kind, isHead: Bool = false) {
        self.name = name
        self.kind = kind
        self.isHead = isHead
    }
}

public struct GitBranch: Sendable, Hashable, Identifiable {
    public var name: String
    public var isCurrent: Bool
    public var upstreamName: String?

    public var id: String { name }

    public init(name: String, isCurrent: Bool, upstreamName: String? = nil) {
        self.name = name
        self.isCurrent = isCurrent
        self.upstreamName = upstreamName
    }
}

public struct GitIdentity: Sendable, Hashable {
    public var name: String
    public var email: String

    public init(name: String, email: String) {
        self.name = name
        self.email = email
    }
}

public enum GitIdentityScope: Sendable {
    case local
    case global
}

/// A single hook file in the resolved hooks directory.
public struct GitHook: Sendable, Hashable, Identifiable {
    /// Hook name without any `.sample` suffix, e.g. `pre-commit`.
    public var name: String
    public var fileURL: URL
    /// `true` when the executable bit is set — git only runs executable
    /// hook files.
    public var isExecutable: Bool
    /// `true` for the inert `*.sample` files git ships by default.
    public var isSample: Bool

    public var id: String { fileURL.path }
    /// Whether git will actually run this hook.
    public var isActive: Bool { isExecutable && !isSample }

    public init(name: String, fileURL: URL, isExecutable: Bool, isSample: Bool) {
        self.name = name
        self.fileURL = fileURL
        self.isExecutable = isExecutable
        self.isSample = isSample
    }
}

/// The resolved git hooks directory plus the hooks found in it.
public struct GitHooksInfo: Sendable, Hashable {
    /// How the directory was resolved — surfaced in the UI so the user
    /// knows which location is in effect.
    public enum Source: String, Sendable, Hashable {
        case override = "Settings override"
        case coreHooksPath = "core.hooksPath"
        case versioned = "Version-controlled (.githooks)"
        case standard = "Default (.git/hooks)"
    }

    public var directory: URL
    public var source: Source
    public var hooks: [GitHook]

    public init(directory: URL, source: Source, hooks: [GitHook]) {
        self.directory = directory
        self.source = source
        self.hooks = hooks
    }
}

/// Streamed events from a long-running git operation.
public enum GitProcessEvent: Sendable {
    /// A single line of stdout/stderr.
    case line(String)
    /// Process finished. `commitSHA` populated for commit operations.
    case finished(GitProcessOutcome)
}

public struct GitProcessOutcome: Sendable {
    public var exitCode: Int32
    public var commitSHA: String?

    public init(exitCode: Int32, commitSHA: String? = nil) {
        self.exitCode = exitCode
        self.commitSHA = commitSHA
    }
}
