import Foundation
import Core

/// `GitService` implemented by shelling out to the system `git` binary.
/// See the plan for the trade-off versus a libgit2 binding — short version:
/// on macOS the git CLI is universal, hooks/signing/SSH-agent all work for
/// free, and CI doesn't need a brew dep.
public final class ShellGitService: GitService {
    private let gitURL: URL

    public init(gitURL: URL = URL(fileURLWithPath: "/usr/bin/git")) {
        self.gitURL = gitURL
    }

    // MARK: Discovery

    public func discover(at path: URL) async -> GitRepositoryInfo? {
        let result = try? await ProcessRunner.run(
            gitURL,
            arguments: ["rev-parse", "--show-toplevel"],
            in: path
        )
        guard let result, result.exitCode == 0 else { return nil }
        let topLevel = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topLevel.isEmpty else { return nil }
        let workTreeRoot = URL(fileURLWithPath: topLevel)
        let relative = relativePath(of: path, under: workTreeRoot)
        let branch = await currentBranch(in: workTreeRoot)
        let (ahead, behind) = await aheadBehind(in: workTreeRoot, branch: branch)
        return GitRepositoryInfo(
            workTreeRoot: workTreeRoot,
            relativeRepoPath: relative,
            currentBranch: branch,
            aheadCount: ahead,
            behindCount: behind
        )
    }

    private func currentBranch(in workTree: URL) async -> String? {
        let result = try? await ProcessRunner.run(
            gitURL,
            arguments: ["rev-parse", "--abbrev-ref", "HEAD"],
            in: workTree
        )
        guard let result, result.exitCode == 0 else { return nil }
        let name = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == "HEAD" ? nil : name
    }

    private func aheadBehind(in workTree: URL, branch: String?) async -> (Int, Int) {
        guard let branch else { return (0, 0) }
        let upstream = "origin/\(branch)"
        let result = try? await ProcessRunner.run(
            gitURL,
            arguments: ["rev-list", "--left-right", "--count", "\(branch)...\(upstream)"],
            in: workTree
        )
        guard let result, result.exitCode == 0 else { return (0, 0) }
        let parts = result.stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\t")
            .compactMap { Int($0) }
        guard parts.count == 2 else { return (0, 0) }
        return (parts[0], parts[1])
    }

    // MARK: Status

    public func status(in info: GitRepositoryInfo) async throws -> [GitStatusEntry] {
        var args = ["status", "--porcelain=v1", "-z", "--untracked-files=all"]
        if !info.relativeRepoPath.isEmpty {
            args += ["--", info.relativeRepoPath]
        }
        let result = try await ProcessRunner.run(gitURL, arguments: args, in: info.workTreeRoot)
        guard result.exitCode == 0 else {
            throw RepositoryError.process(name: "git status", exitCode: result.exitCode, output: result.stderr)
        }
        return parseStatus(result.stdout)
    }

    private func parseStatus(_ output: String) -> [GitStatusEntry] {
        // Each record is `XY <path>\0`; renames are `XY <new>\0<old>\0`.
        var entries: [GitStatusEntry] = []
        let records = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var iterator = records.makeIterator()
        while let record = iterator.next() {
            guard record.count >= 3 else { continue }
            let staged = record[record.startIndex]
            let unstaged = record[record.index(after: record.startIndex)]
            let path = String(record.dropFirst(3))
            let stagedKind = mapStatusChar(staged)
            let unstagedKind = mapStatusChar(unstaged)

            // Renames carry the old path as the next record.
            let renamedFrom: String?
            if staged == "R" || unstaged == "R" {
                renamedFrom = iterator.next()
            } else {
                renamedFrom = nil
            }

            if let stagedKind, staged != " " {
                let kind = renamedFrom.map(GitStatusEntry.Kind.renamed(from:)) ?? stagedKind
                entries.append(GitStatusEntry(relativePath: path, kind: kind, staged: true))
            }
            if let unstagedKind, unstaged != " " {
                entries.append(GitStatusEntry(relativePath: path, kind: unstagedKind, staged: false))
            }
        }
        return entries
    }

    private func mapStatusChar(_ char: Character) -> GitStatusEntry.Kind? {
        switch char {
        case "M": .modified
        case "A": .added
        case "D": .deleted
        case "R": .renamed(from: "")
        case "C": .copied(from: "")
        case "U": .conflicted
        case "?": .untracked
        case "!": .ignored
        default: nil
        }
    }

    // MARK: Diff

    public func diff(in info: GitRepositoryInfo, relativePath: String) async throws -> String {
        let result = try await ProcessRunner.run(
            gitURL,
            arguments: ["diff", "HEAD", "--", relativePath],
            in: info.workTreeRoot
        )
        guard result.exitCode == 0 || result.exitCode == 1 else {
            throw RepositoryError.process(name: "git diff", exitCode: result.exitCode, output: result.stderr)
        }
        if !result.stdout.isEmpty { return result.stdout }
        // Untracked file — synthesize an addition diff.
        let fileURL = info.workTreeRoot.appending(path: relativePath)
        guard let data = try? Data(contentsOf: fileURL) else { return "" }
        let body = String(decoding: data, as: UTF8.self)
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        var diff = "diff --git a/\(relativePath) b/\(relativePath)\n"
        diff += "new file\n--- /dev/null\n+++ b/\(relativePath)\n@@ -0,0 +1,\(lines.count) @@\n"
        for line in lines { diff += "+\(line)\n" }
        return diff
    }

    // MARK: Log

    public func log(in info: GitRepositoryInfo, max: Int) async throws -> [GitCommit] {
        let format = "--pretty=format:%H%x09%an%x09%aI%x09%s"
        let result = try await ProcessRunner.run(
            gitURL,
            arguments: ["log", "--max-count=\(max)", format],
            in: info.workTreeRoot
        )
        guard result.exitCode == 0 else {
            throw RepositoryError.process(name: "git log", exitCode: result.exitCode, output: result.stderr)
        }
        let formatter = ISO8601DateFormatter()
        return result.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                let parts = line.split(separator: "\t", maxSplits: 3).map(String.init)
                guard parts.count == 4, let date = formatter.date(from: parts[2]) else { return nil }
                return GitCommit(sha: parts[0], subject: parts[3], author: parts[1], date: date)
            }
    }

    // MARK: Stage / unstage

    public func stage(in info: GitRepositoryInfo, relativePaths: [String]) async throws {
        guard !relativePaths.isEmpty else { return }
        let result = try await ProcessRunner.run(
            gitURL,
            arguments: ["add", "--"] + relativePaths,
            in: info.workTreeRoot
        )
        guard result.exitCode == 0 else {
            throw RepositoryError.process(name: "git add", exitCode: result.exitCode, output: result.stderr)
        }
    }

    public func unstage(in info: GitRepositoryInfo, relativePaths: [String]) async throws {
        guard !relativePaths.isEmpty else { return }
        let result = try await ProcessRunner.run(
            gitURL,
            arguments: ["reset", "HEAD", "--"] + relativePaths,
            in: info.workTreeRoot
        )
        guard result.exitCode == 0 else {
            throw RepositoryError.process(name: "git reset", exitCode: result.exitCode, output: result.stderr)
        }
    }

    // MARK: Commit / push

    public func commit(
        in info: GitRepositoryInfo,
        subject: String,
        body: String?,
        runHooks: Bool,
        amend: Bool
    ) -> AsyncThrowingStream<GitProcessEvent, any Error> {
        var args: [String] = ["commit"]
        if amend {
            args.append("--amend")
        }
        args.append(contentsOf: ["-m", subject])
        if let body, !body.isEmpty {
            args.append("-m")
            args.append(body)
        }
        if !runHooks {
            args.append("--no-verify")
        }
        return streamGit(args, in: info, captureCommitSHA: true)
    }

    public func push(in info: GitRepositoryInfo) -> AsyncThrowingStream<GitProcessEvent, any Error> {
        let args = ["push"]
        return streamGit(args, in: info, captureCommitSHA: false)
    }

    private func streamGit(
        _ args: [String],
        in info: GitRepositoryInfo,
        captureCommitSHA: Bool
    ) -> AsyncThrowingStream<GitProcessEvent, any Error> {
        let work = info.workTreeRoot
        let executable = gitURL
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await event in ProcessRunner.stream(executable, arguments: args, in: work) {
                        switch event {
                        case .line(let line):
                            continuation.yield(.line(line))
                        case .terminated(let exitCode):
                            let sha: String? = captureCommitSHA
                                ? try? await self.readHeadSHA(in: work)
                                : nil
                            continuation.yield(.finished(GitProcessOutcome(exitCode: exitCode, commitSHA: sha)))
                            continuation.finish()
                        }
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func readHeadSHA(in workTree: URL) async throws -> String? {
        let result = try await ProcessRunner.run(
            gitURL,
            arguments: ["rev-parse", "HEAD"],
            in: workTree
        )
        guard result.exitCode == 0 else { return nil }
        let sha = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    // MARK: Checkout / branches

    public func checkout(in info: GitRepositoryInfo, branch: String) async throws {
        let dirty = try await isDirty(in: info)
        if dirty { throw RepositoryError.dirtyWorkingTree }
        let result = try await ProcessRunner.run(
            gitURL,
            arguments: ["switch", branch],
            in: info.workTreeRoot
        )
        guard result.exitCode == 0 else {
            throw RepositoryError.process(name: "git switch", exitCode: result.exitCode, output: result.stderr)
        }
    }

    private func isDirty(in info: GitRepositoryInfo) async throws -> Bool {
        let result = try await ProcessRunner.run(
            gitURL,
            arguments: ["diff", "--quiet"],
            in: info.workTreeRoot
        )
        // exit 1 means the working tree is dirty; 0 means clean.
        return result.exitCode != 0
    }

    public func branches(in info: GitRepositoryInfo) async throws -> [GitBranch] {
        let result = try await ProcessRunner.run(
            gitURL,
            arguments: ["branch", "--format=%(refname:short)|%(upstream:short)|%(HEAD)"],
            in: info.workTreeRoot
        )
        guard result.exitCode == 0 else {
            throw RepositoryError.process(name: "git branch", exitCode: result.exitCode, output: result.stderr)
        }
        return result.stdout.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 1, !parts[0].isEmpty else { return nil }
            let upstream = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
            let isCurrent = parts.count > 2 && parts[2] == "*"
            return GitBranch(name: parts[0], isCurrent: isCurrent, upstreamName: upstream)
        }
    }

    // MARK: Identity

    public func identity(in info: GitRepositoryInfo) async throws -> GitIdentity? {
        async let nameResult = ProcessRunner.run(gitURL, arguments: ["config", "user.name"], in: info.workTreeRoot)
        async let emailResult = ProcessRunner.run(gitURL, arguments: ["config", "user.email"], in: info.workTreeRoot)
        let (name, email) = try await (nameResult, emailResult)
        guard name.exitCode == 0, email.exitCode == 0 else { return nil }
        let nameValue = name.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let emailValue = email.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nameValue.isEmpty, !emailValue.isEmpty else { return nil }
        return GitIdentity(name: nameValue, email: emailValue)
    }

    public func setIdentity(
        in info: GitRepositoryInfo,
        _ identity: GitIdentity,
        scope: GitIdentityScope
    ) async throws {
        let scopeFlag = scope == .global ? "--global" : "--local"
        let nameResult = try await ProcessRunner.run(
            gitURL,
            arguments: ["config", scopeFlag, "user.name", identity.name],
            in: info.workTreeRoot
        )
        guard nameResult.exitCode == 0 else {
            throw RepositoryError.process(name: "git config user.name", exitCode: nameResult.exitCode, output: nameResult.stderr)
        }
        let emailResult = try await ProcessRunner.run(
            gitURL,
            arguments: ["config", scopeFlag, "user.email", identity.email],
            in: info.workTreeRoot
        )
        guard emailResult.exitCode == 0 else {
            throw RepositoryError.process(name: "git config user.email", exitCode: emailResult.exitCode, output: emailResult.stderr)
        }
    }

    // MARK: Helpers

    private func relativePath(of path: URL, under root: URL) -> String {
        let pathString = path.resolvingSymlinksInPath().path
        let rootString = root.resolvingSymlinksInPath().path
        let prefix = rootString + "/"
        guard pathString.hasPrefix(prefix) else { return "" }
        return String(pathString.dropFirst(prefix.count))
    }
}
