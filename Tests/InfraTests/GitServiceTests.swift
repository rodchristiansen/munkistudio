import Foundation
import Testing
import Core
@testable import Infra

@Suite("ShellGitService against a real on-disk repo", .serialized)
struct GitServiceTests {
    @Test("discover, status, diff, and log work on a freshly seeded repo")
    func endToEnd() async throws {
        let scratch = try await GitScratch.make()
        defer { scratch.cleanup() }

        let service = ShellGitService()
        let info = try #require(await service.discover(at: scratch.url))
        #expect(info.workTreeRoot.resolvingSymlinksInPath().path == scratch.url.resolvingSymlinksInPath().path)
        #expect(info.relativeRepoPath == "")
        #expect(info.currentBranch != nil)

        // Modify a tracked file and add a new one — both should show up.
        let trackedURL = scratch.url.appending(path: "README.md")
        try "modified\n".write(to: trackedURL, atomically: true, encoding: .utf8)
        let newURL = scratch.url.appending(path: "newfile.txt")
        try "hello".write(to: newURL, atomically: true, encoding: .utf8)

        let entries = try await service.status(in: info)
        let paths = Set(entries.map(\.relativePath))
        #expect(paths.contains("README.md"))
        #expect(paths.contains("newfile.txt"))

        let diff = try await service.diff(in: info, relativePath: "README.md")
        #expect(diff.contains("-initial"))
        #expect(diff.contains("+modified"))

        let untrackedDiff = try await service.diff(in: info, relativePath: "newfile.txt")
        #expect(untrackedDiff.contains("new file"))
        #expect(untrackedDiff.contains("+hello"))

        let log = try await service.log(in: info, max: 5)
        #expect(log.count >= 1)
        #expect(log.first?.subject == "initial")
    }

    @Test("untracked files appear once in status output, not duplicated")
    func untrackedFilesNotDuplicated() async throws {
        let scratch = try await GitScratch.make()
        defer { scratch.cleanup() }
        let service = ShellGitService()
        let info = try #require(await service.discover(at: scratch.url))

        // Two distinct untracked files — neither should appear twice.
        try "one".write(
            to: scratch.url.appending(path: "untracked-a.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "two".write(
            to: scratch.url.appending(path: "untracked-b.txt"),
            atomically: true,
            encoding: .utf8
        )

        let entries = try await service.status(in: info)
        let untracked = entries.filter { entry in
            if case .untracked = entry.kind { return true } else { return false }
        }
        let counts = Dictionary(grouping: untracked, by: \.relativePath).mapValues(\.count)
        #expect(counts["untracked-a.txt"] == 1)
        #expect(counts["untracked-b.txt"] == 1)
    }

    @Test("stage + commit produces a SHA via the streaming API")
    func stageAndCommit() async throws {
        let scratch = try await GitScratch.make()
        defer { scratch.cleanup() }

        // We need a writable identity for `git commit` not to refuse.
        let service = ShellGitService()
        let info = try #require(await service.discover(at: scratch.url))
        try await service.setIdentity(
            in: info,
            GitIdentity(name: "Test Runner", email: "test@example.com"),
            scope: .local
        )

        let newURL = scratch.url.appending(path: "track-me.txt")
        try "added".write(to: newURL, atomically: true, encoding: .utf8)
        try await service.stage(in: info, relativePaths: ["track-me.txt"])

        var outcome: GitProcessOutcome?
        for try await event in service.commit(
            in: info,
            subject: "add track-me",
            body: nil,
            runHooks: false,
            amend: false
        ) {
            if case .finished(let result) = event { outcome = result }
        }
        #expect(outcome?.exitCode == 0)
        #expect(outcome?.commitSHA?.count == 40)
    }
}

/// Spins up an isolated git repo with a single committed file so each
/// test starts from a known state.
struct GitScratch {
    let url: URL

    static func make() async throws -> GitScratch {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "munki-git-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let git = URL(fileURLWithPath: "/usr/bin/git")
        try await runOrFail(git, ["init", "-b", "main"], in: root)
        try await runOrFail(git, ["config", "user.email", "test@example.com"], in: root)
        try await runOrFail(git, ["config", "user.name", "Test"], in: root)
        try await runOrFail(git, ["config", "commit.gpgsign", "false"], in: root)
        try "initial\n".write(
            to: root.appending(path: "README.md"),
            atomically: true,
            encoding: .utf8
        )
        try await runOrFail(git, ["add", "README.md"], in: root)
        try await runOrFail(git, ["commit", "-m", "initial"], in: root)
        return GitScratch(url: root)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: url)
    }

    private static func runOrFail(_ git: URL, _ args: [String], in dir: URL) async throws {
        let result = try await ProcessRunner.run(git, arguments: args, in: dir)
        if result.exitCode != 0 {
            throw NSError(
                domain: "GitScratch",
                code: Int(result.exitCode),
                userInfo: [NSLocalizedDescriptionKey: "git \(args.joined(separator: " ")) failed: \(result.stderr)"]
            )
        }
    }
}
