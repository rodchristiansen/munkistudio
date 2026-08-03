import Foundation
import Core

/// A ``GitService`` that reports "not a git repository" and does nothing
/// else.
///
/// Onboarding tests open repositories in temp directories that have no
/// `.git`. The real `ShellGitService` shells out for every one of those
/// opens, which is both slow and — under the test harness's cooperative
/// thread pool — prone to hanging in `Process.waitUntilExit()`. None of
/// it is what these tests are measuring, so it is stubbed out.
struct NoGitService: GitService {
    struct Unsupported: Error {}

    func discover(at path: URL) async -> GitRepositoryInfo? { nil }
    func status(in info: GitRepositoryInfo) async throws -> [GitStatusEntry] { [] }
    func diff(in info: GitRepositoryInfo, relativePath: String) async throws -> String { "" }
    func log(in info: GitRepositoryInfo, max: Int) async throws -> [GitCommit] { [] }
    func stage(in info: GitRepositoryInfo, relativePaths: [String]) async throws {}
    func unstage(in info: GitRepositoryInfo, relativePaths: [String]) async throws {}

    func applyPatch(
        in info: GitRepositoryInfo,
        patch: String,
        cached: Bool,
        reverse: Bool
    ) async throws {}

    func commit(
        in info: GitRepositoryInfo,
        subject: String,
        body: String?,
        runHooks: Bool,
        amend: Bool
    ) -> AsyncThrowingStream<GitProcessEvent, any Error> {
        .init { $0.finish(throwing: Unsupported()) }
    }

    func push(in info: GitRepositoryInfo) -> AsyncThrowingStream<GitProcessEvent, any Error> {
        .init { $0.finish(throwing: Unsupported()) }
    }

    func checkout(in info: GitRepositoryInfo, branch: String) async throws {}
    func branches(in info: GitRepositoryInfo) async throws -> [GitBranch] { [] }
    func identity(in info: GitRepositoryInfo) async throws -> GitIdentity? { nil }
    func setIdentity(in info: GitRepositoryInfo, _ identity: GitIdentity, scope: GitIdentityScope) async throws {}

    func hooks(in info: GitRepositoryInfo, overridePath: String?) async throws -> GitHooksInfo {
        throw Unsupported()
    }

    func readHook(_ hook: GitHook) async throws -> String { "" }
    func writeHook(_ hook: GitHook, contents: String) async throws {}
    func setHookActive(_ hook: GitHook, active: Bool) async throws {}
    func tag(in info: GitRepositoryInfo, name: String, at sha: String, message: String?) async throws {}
    func createBranch(in info: GitRepositoryInfo, name: String, at sha: String) async throws {}
    func checkoutCommit(in info: GitRepositoryInfo, sha: String) async throws {}
    func cherryPick(in info: GitRepositoryInfo, sha: String) async throws {}
    func revert(in info: GitRepositoryInfo, sha: String) async throws {}
    func merge(in info: GitRepositoryInfo, ref: String) async throws {}
    func rebase(in info: GitRepositoryInfo, onto sha: String) async throws {}
    func reset(in info: GitRepositoryInfo, to sha: String, mode: GitResetMode) async throws {}
    func commitMessage(in info: GitRepositoryInfo, sha: String) async throws -> String { "" }
    func editCommitMessage(in info: GitRepositoryInfo, sha: String, message: String) async throws {}
}
