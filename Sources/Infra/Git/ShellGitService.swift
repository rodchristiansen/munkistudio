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

            // Untracked (`??`) and ignored (`!!`) repeat the same character
            // in both XY columns — git's convention, not a real index /
            // working-tree split. Emit a single entry instead of two so
            // these files don't appear duplicated in the Git pane.
            if staged == "?" && unstaged == "?" {
                entries.append(GitStatusEntry(relativePath: path, kind: .untracked, staged: false))
                continue
            }
            if staged == "!" && unstaged == "!" {
                entries.append(GitStatusEntry(relativePath: path, kind: .ignored, staged: false))
                continue
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
        // Unit-separator (\u{1f}) between fields, record-separator (\u{1e})
        // between commits — robust against tabs / newlines in subjects.
        // `%P` = parent SHAs, `%D` = ref decorations.
        let format = "--pretty=format:%H%x1f%an%x1f%aI%x1f%P%x1f%D%x1f%s%x1e"
        // `--all` so commits on every branch / remote appear (matching
        // VS Code's Git Graph "Show All"); `--topo-order` keeps parents
        // after their children so the lane graph renders cleanly.
        let result = try await ProcessRunner.run(
            gitURL,
            arguments: ["log", "--all", "--topo-order", "--decorate=full", "--max-count=\(max)", format],
            in: info.workTreeRoot
        )
        guard result.exitCode == 0 else {
            throw RepositoryError.process(name: "git log", exitCode: result.exitCode, output: result.stderr)
        }
        let formatter = ISO8601DateFormatter()
        return result.stdout
            .components(separatedBy: "\u{1e}")
            .compactMap { rawRecord -> GitCommit? in
                let record = rawRecord.drop { $0 == "\n" || $0 == "\r" }
                guard !record.isEmpty else { return nil }
                let parts = record.components(separatedBy: "\u{1f}")
                guard parts.count == 6, let date = formatter.date(from: parts[2]) else { return nil }
                let parents = parts[3]
                    .split(separator: " ", omittingEmptySubsequences: true)
                    .map(String.init)
                return GitCommit(
                    sha: parts[0],
                    subject: parts[5],
                    author: parts[1],
                    date: date,
                    parents: parents,
                    refs: Self.parseRefs(parts[4])
                )
            }
    }

    /// Parse a `%D` decoration string (with `--decorate=full`) into refs.
    /// Tokens look like `HEAD -> refs/heads/main`, `refs/remotes/origin/main`,
    /// `tag: refs/tags/v1.0`.
    static func parseRefs(_ raw: String) -> [GitRef] {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        var refs: [GitRef] = []
        for token in trimmed.components(separatedBy: ", ") {
            var value = token.trimmingCharacters(in: .whitespaces)
            var isHead = false
            if value == "HEAD" {
                refs.append(GitRef(name: "HEAD", kind: .head, isHead: true))
                continue
            }
            if value.hasPrefix("HEAD -> ") {
                isHead = true
                value = String(value.dropFirst("HEAD -> ".count))
            }
            if value.hasPrefix("tag: ") {
                var name = String(value.dropFirst("tag: ".count))
                if name.hasPrefix("refs/tags/") { name = String(name.dropFirst("refs/tags/".count)) }
                refs.append(GitRef(name: name, kind: .tag, isHead: false))
            } else if value.hasPrefix("refs/heads/") {
                refs.append(GitRef(name: String(value.dropFirst("refs/heads/".count)), kind: .localBranch, isHead: isHead))
            } else if value.hasPrefix("refs/remotes/") {
                refs.append(GitRef(name: String(value.dropFirst("refs/remotes/".count)), kind: .remoteBranch, isHead: isHead))
            } else if value.hasPrefix("refs/tags/") {
                refs.append(GitRef(name: String(value.dropFirst("refs/tags/".count)), kind: .tag, isHead: false))
            } else if !value.isEmpty {
                let kind: GitRef.Kind = value.contains("/") ? .remoteBranch : .localBranch
                refs.append(GitRef(name: value, kind: kind, isHead: isHead))
            }
        }
        return refs
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

    public func applyPatch(
        in info: GitRepositoryInfo,
        patch: String,
        cached: Bool,
        reverse: Bool
    ) async throws {
        var arguments = ["apply", "--whitespace=nowarn"]
        if cached { arguments.append("--cached") }
        if reverse { arguments.append("--reverse") }
        arguments.append("-")
        let result = try await ProcessRunner.run(
            gitURL,
            arguments: arguments,
            in: info.workTreeRoot,
            input: Data(patch.utf8)
        )
        guard result.exitCode == 0 else {
            throw RepositoryError.process(
                name: "git apply",
                exitCode: result.exitCode,
                output: result.stderr.isEmpty ? result.stdout : result.stderr
            )
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
        let env = GitProcessEnvironment.make()
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await event in ProcessRunner.stream(executable, arguments: args, in: work, environment: env, usePTY: true) {
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

    // MARK: Hooks

    public func hooks(in info: GitRepositoryInfo, overridePath: String?) async throws -> GitHooksInfo {
        let (directory, source) = try await resolveHooksDirectory(in: info, overridePath: overridePath)
        let fm = FileManager.default
        var hooks: [GitHook] = []
        if let entries = try? fm.contentsOfDirectory(atPath: directory.path) {
            for entry in entries where !entry.hasPrefix(".") {
                let fileURL = directory.appending(path: entry)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: fileURL.path, isDirectory: &isDir), !isDir.boolValue else { continue }
                let isSample = entry.hasSuffix(".sample")
                let name = isSample ? String(entry.dropLast(7)) : entry
                hooks.append(GitHook(
                    name: name,
                    fileURL: fileURL,
                    isExecutable: fm.isExecutableFile(atPath: fileURL.path),
                    isSample: isSample
                ))
            }
        }
        // Surface every standard hook that has no file yet as an
        // inactive entry, so the panel shows the full set, not just
        // what's already set up.
        let present = Set(hooks.map(\.name))
        for name in GitHookCatalog.standardNames where !present.contains(name) {
            hooks.append(GitHook(
                name: name,
                fileURL: directory.appending(path: name),
                isExecutable: false,
                isSample: false,
                exists: false
            ))
        }
        // Active hooks first, then alphabetical — the ones git actually
        // runs stay at the top.
        hooks.sort {
            $0.isActive != $1.isActive
                ? $0.isActive
                : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return GitHooksInfo(directory: directory, source: source, hooks: hooks)
    }

    /// Resolve which directory holds the hooks: an explicit Settings
    /// override first, then `core.hooksPath`, then a version-controlled
    /// top-level `.githooks`, then git's default hooks directory.
    private func resolveHooksDirectory(
        in info: GitRepositoryInfo,
        overridePath: String?
    ) async throws -> (URL, GitHooksInfo.Source) {
        let root = info.workTreeRoot
        if let overridePath, !overridePath.trimmingCharacters(in: .whitespaces).isEmpty {
            return (resolvePath(overridePath, relativeTo: root), .override)
        }
        if let configured = try? await configValue("core.hooksPath", in: root), !configured.isEmpty {
            return (resolvePath(configured, relativeTo: root), .coreHooksPath)
        }
        let versioned = root.appending(path: ".githooks")
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: versioned.path, isDirectory: &isDir), isDir.boolValue {
            return (versioned, .versioned)
        }
        let result = try await ProcessRunner.run(
            gitURL, arguments: ["rev-parse", "--git-path", "hooks"], in: root
        )
        let raw = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let dir = raw.isEmpty ? root.appending(path: ".git/hooks") : resolvePath(raw, relativeTo: root)
        return (dir, .standard)
    }

    private func configValue(_ key: String, in workTree: URL) async throws -> String? {
        let result = try await ProcessRunner.run(
            gitURL, arguments: ["config", "--get", key], in: workTree
        )
        guard result.exitCode == 0 else { return nil }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func resolvePath(_ path: String, relativeTo root: URL) -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed)
        }
        if trimmed.hasPrefix("~") {
            return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
        }
        return root.appending(path: trimmed)
    }

    public func readHook(_ hook: GitHook) async throws -> String {
        let data = try Data(contentsOf: hook.fileURL)
        return String(decoding: data, as: UTF8.self)
    }

    public func writeHook(_ hook: GitHook, contents: String) async throws {
        try contents.write(to: hook.fileURL, atomically: true, encoding: .utf8)
    }

    public func setHookActive(_ hook: GitHook, active: Bool) async throws {
        let fm = FileManager.default
        let attrs = try fm.attributesOfItem(atPath: hook.fileURL.path)
        let current = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
        let updated = active ? (current | 0o111) : (current & ~0o111)
        try fm.setAttributes([.posixPermissions: NSNumber(value: updated)], ofItemAtPath: hook.fileURL.path)
    }

    // MARK: Commit operations

    public func tag(in info: GitRepositoryInfo, name: String, at sha: String, message: String?) async throws {
        var args = ["tag"]
        if let message, !message.isEmpty {
            args += ["-a", name, "-m", message, sha]
        } else {
            args += [name, sha]
        }
        try await runGitChecked(args, name: "git tag", in: info)
    }

    public func createBranch(in info: GitRepositoryInfo, name: String, at sha: String) async throws {
        try await runGitChecked(["branch", name, sha], name: "git branch", in: info)
    }

    public func checkoutCommit(in info: GitRepositoryInfo, sha: String) async throws {
        try await runGitChecked(["checkout", sha], name: "git checkout", in: info)
    }

    public func cherryPick(in info: GitRepositoryInfo, sha: String) async throws {
        try await runGitChecked(["cherry-pick", sha], name: "git cherry-pick", in: info)
    }

    public func revert(in info: GitRepositoryInfo, sha: String) async throws {
        try await runGitChecked(["revert", "--no-edit", sha], name: "git revert", in: info)
    }

    public func merge(in info: GitRepositoryInfo, ref: String) async throws {
        try await runGitChecked(["merge", "--no-edit", ref], name: "git merge", in: info)
    }

    public func rebase(in info: GitRepositoryInfo, onto sha: String) async throws {
        try await runGitChecked(["rebase", sha], name: "git rebase", in: info)
    }

    public func reset(in info: GitRepositoryInfo, to sha: String, mode: GitResetMode) async throws {
        try await runGitChecked(["reset", "--\(mode.rawValue)", sha], name: "git reset", in: info)
    }

    public func commitMessage(in info: GitRepositoryInfo, sha: String) async throws -> String {
        let result = try await ProcessRunner.run(
            gitURL, arguments: ["log", "-1", "--pretty=format:%B", sha], in: info.workTreeRoot
        )
        guard result.exitCode == 0 else {
            throw RepositoryError.process(name: "git log", exitCode: result.exitCode, output: result.stderr)
        }
        return result.stdout.trimmingCharacters(in: .newlines)
    }

    /// Reword an arbitrary commit. Rewriting a non-HEAD message means
    /// replaying every commit after it, so this runs a fully scripted
    /// (no human input) interactive rebase: `git rebase -i <sha>^` lists
    /// the target as the first todo entry, `GIT_SEQUENCE_EDITOR` flips
    /// that line from `pick` to `reword`, and `GIT_EDITOR` copies the new
    /// message in. The same path handles HEAD and the root commit.
    public func editCommitMessage(in info: GitRepositoryInfo, sha: String, message: String) async throws {
        let work = info.workTreeRoot

        // The commit must be on the current branch — rebasing only
        // rewrites HEAD's ancestry.
        let ancestor = try await ProcessRunner.run(
            gitURL, arguments: ["merge-base", "--is-ancestor", sha, "HEAD"], in: work
        )
        guard ancestor.exitCode == 0 else {
            throw RepositoryError.process(
                name: "git", exitCode: ancestor.exitCode,
                output: "This commit isn't on the current branch, so its message can't be edited from here."
            )
        }

        // A plain rebase flattens merges — refuse rather than silently
        // rewriting them.
        let merges = try await ProcessRunner.run(
            gitURL, arguments: ["rev-list", "--merges", "--count", "\(sha)..HEAD"], in: work
        )
        if merges.exitCode == 0,
           let count = Int(merges.stdout.trimmingCharacters(in: .whitespacesAndNewlines)), count > 0 {
            throw RepositoryError.process(
                name: "git", exitCode: 1,
                output: "There are merge commits between this commit and HEAD — editing its message would rewrite the merges."
            )
        }

        // The new message goes in a temp file the scripted editor copies
        // over git's commit-message file.
        let messageFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("munkistudio-reword-\(UUID().uuidString).txt")
        try message.write(to: messageFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: messageFile) }

        // `<sha>^` fails for the root commit — fall back to `--root`.
        let parentCheck = try await ProcessRunner.run(
            gitURL, arguments: ["rev-parse", "--verify", "--quiet", "\(sha)^"], in: work
        )
        let base = parentCheck.exitCode == 0 ? "\(sha)^" : "--root"

        var environment = ProcessInfo.processInfo.environment
        environment["GIT_SEQUENCE_EDITOR"] = "sed -i '' -e '1s/^pick /reword /' -e '1s/^p /reword /'"
        environment["GIT_EDITOR"] = "cp \(messageFile.path)"

        let result = try await ProcessRunner.run(
            gitURL,
            arguments: ["rebase", "-i", "--autostash", base],
            in: work,
            environment: environment
        )
        guard result.exitCode == 0 else {
            // A reword never conflicts, but abort defensively so a
            // half-applied rebase can't strand the repo.
            _ = try? await ProcessRunner.run(gitURL, arguments: ["rebase", "--abort"], in: work)
            let output = result.stderr.isEmpty ? result.stdout : result.stderr
            throw RepositoryError.process(name: "git rebase", exitCode: result.exitCode, output: output)
        }
    }

    private func runGitChecked(_ args: [String], name: String, in info: GitRepositoryInfo) async throws {
        let result = try await ProcessRunner.run(gitURL, arguments: args, in: info.workTreeRoot)
        guard result.exitCode == 0 else {
            let output = result.stderr.isEmpty ? result.stdout : result.stderr
            throw RepositoryError.process(name: name, exitCode: result.exitCode, output: output)
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
