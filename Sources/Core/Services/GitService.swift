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

    /// Apply `patch` to the working tree and/or the index.
    /// - `cached`: when `true`, applies to the index only — the basis for
    ///   per-hunk staging via the rich diff view.
    /// - `reverse`: when `true`, applies the patch in reverse — used to
    ///   unstage a single hunk (reverse-apply against the index) or
    ///   discard one chunk from the working tree.
    func applyPatch(
        in info: GitRepositoryInfo,
        patch: String,
        cached: Bool,
        reverse: Bool
    ) async throws

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

    /// The full commit message (subject + body) for `sha`.
    func commitMessage(in info: GitRepositoryInfo, sha: String) async throws -> String
    /// Rewrite the message of `sha`. Works for any commit on the current
    /// branch — not just HEAD — by replaying its descendants.
    func editCommitMessage(in info: GitRepositoryInfo, sha: String, message: String) async throws
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

/// A single git hook — a file in the resolved hooks directory, or a
/// standard hook name that simply isn't set up yet (`exists == false`).
public struct GitHook: Sendable, Hashable, Identifiable {
    /// Hook name without any `.sample` suffix, e.g. `pre-commit`.
    public var name: String
    public var fileURL: URL
    /// `true` when the executable bit is set — git only runs executable
    /// hook files.
    public var isExecutable: Bool
    /// `true` for the inert `*.sample` files git ships by default.
    public var isSample: Bool
    /// `false` when no file exists at `fileURL` — a standard git hook
    /// name surfaced so the user can see it and set it up.
    public var exists: Bool

    public var id: String { fileURL.path }
    /// Whether git will actually run this hook.
    public var isActive: Bool { exists && isExecutable && !isSample }

    public init(name: String, fileURL: URL, isExecutable: Bool, isSample: Bool, exists: Bool = true) {
        self.name = name
        self.fileURL = fileURL
        self.isExecutable = isExecutable
        self.isSample = isSample
        self.exists = exists
    }
}

/// The standard set of git hook names plus a one-line summary of when
/// each runs. Used to list hooks that aren't set up yet and to annotate
/// the hook editor.
public enum GitHookCatalog {
    /// Standard hook names, in roughly the order git documents them.
    public static let standardNames: [String] = [
        "applypatch-msg", "pre-applypatch", "post-applypatch",
        "pre-commit", "pre-merge-commit", "prepare-commit-msg", "commit-msg",
        "post-commit", "pre-rebase", "post-checkout", "post-merge", "pre-push",
        "pre-receive", "update", "post-receive", "post-update",
        "push-to-checkout", "pre-auto-gc", "post-rewrite", "sendemail-validate",
    ]

    /// Server-side hooks — they run on the receiving repository, not the
    /// developer's clone.
    public static let serverSideNames: Set<String> = [
        "pre-receive", "update", "post-receive", "post-update", "push-to-checkout",
    ]

    public static func isServerSide(_ name: String) -> Bool {
        serverSideNames.contains(name)
    }

    /// A short description of when the hook runs.
    public static func summary(for name: String) -> String? {
        switch name {
        case "applypatch-msg": "Runs when `git am` applies a patch — can edit or reject its commit message."
        case "pre-applypatch": "Runs after `git am` applies a patch but before the commit is made."
        case "post-applypatch": "Runs after `git am` applies and commits a patch."
        case "pre-commit": "Runs before a commit is created — the usual place for linting and validation."
        case "pre-merge-commit": "Runs before a merge commit is created."
        case "prepare-commit-msg": "Runs before the commit message editor opens — can pre-fill the message."
        case "commit-msg": "Runs after the commit message is entered — can validate or reject it."
        case "post-commit": "Runs after a commit is created — for notifications and bookkeeping."
        case "pre-rebase": "Runs before a rebase starts — can refuse rebasing certain branches."
        case "post-checkout": "Runs after `git checkout` / `git switch` updates the working tree."
        case "post-merge": "Runs after a successful merge updates the working tree."
        case "pre-push": "Runs before refs are pushed — a good place for final checks."
        case "pre-receive": "Server-side — runs before any refs are updated by a push."
        case "update": "Server-side — runs once per ref being updated by a push."
        case "post-receive": "Server-side — runs after a push has updated all refs."
        case "post-update": "Server-side — runs after a push, e.g. to refresh dumb-HTTP info."
        case "push-to-checkout": "Server-side — runs when a push updates the checked-out branch."
        case "pre-auto-gc": "Runs before an automatic `git gc` — can defer housekeeping."
        case "post-rewrite": "Runs after commits are rewritten by `rebase` or `commit --amend`."
        case "sendemail-validate": "Runs before `git send-email` sends a patch."
        default: nil
        }
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
