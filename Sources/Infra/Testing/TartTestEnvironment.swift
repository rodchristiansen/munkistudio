import Foundation
import Core

/// Ephemeral macOS guest backed by Tart. Each instance clones a base
/// image into a uniquely-named throwaway VM, starts it headless with a
/// shared host directory mounted in, and tears the clone down on
/// `teardown()`. Command execution goes through `tart exec` (the bundled
/// Tart Guest Agent in cirruslabs images), and file copy uses the shared
/// mount — no SSH, no host keys, no Local Network permission prompt.
///
/// Apple's 2-concurrent-macOS-VM licensing cap means callers should not
/// run more than two `TartTestEnvironment`s in parallel on the same
/// host. The Testing pane enforces this with a queue.
public actor TartTestEnvironment: TestEnvironment {

    public nonisolated let displayName: String
    public nonisolated let kind: TestEnvironmentKind = .tart

    private let tartPath: String
    private let baseImage: String
    private let cloneName: String
    /// Host-side staging dir mounted into the guest under
    /// `/Volumes/My Shared Files/<shareTag>/`. Everything we copy in goes
    /// here first, then a `tart exec cp` moves it to its final path.
    private let stagingDirURL: URL
    private let shareTag = "staging"

    /// Background task running `tart run` — kept around so `teardown()`
    /// can cancel it. `tart stop` is tried first; cancellation is the
    /// fallback.
    private var runProcess: Process?
    private var prepared = false

    public init(
        tartPath: String,
        baseImage: String,
        cloneName: String = "munkistudio-test-\(UUID().uuidString.prefix(8))"
    ) {
        self.tartPath = tartPath
        self.baseImage = baseImage
        self.cloneName = cloneName
        self.stagingDirURL = FileManager.default.temporaryDirectory
            .appending(path: "munkistudio-tart-\(cloneName)", directoryHint: .isDirectory)
        self.displayName = "Tart '\(cloneName)' (from \(baseImage))"
    }

    public func prepare() async throws {
        guard !prepared else { return }

        try FileManager.default.createDirectory(
            at: stagingDirURL,
            withIntermediateDirectories: true
        )

        let clone = try await HostTestEnvironment.run(
            command: tartPath,
            arguments: ["clone", baseImage, cloneName]
        )
        if clone.exitCode != 0 {
            throw TestEnvironmentError("tart clone failed: \(clone.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        // Mount the host staging dir into the guest. With Tart's default
        // virtio-fs automount, the share appears at
        // /Volumes/My Shared Files/<shareTag>/ inside the VM.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tartPath)
        process.arguments = [
            "run",
            cloneName,
            "--no-graphics",
            "--dir=\(shareTag):\(stagingDirURL.path)"
        ]
        let null = Pipe()
        process.standardOutput = null
        process.standardError = null
        do {
            try process.run()
        } catch {
            throw TestEnvironmentError("tart run failed: \(error.localizedDescription)")
        }
        runProcess = process

        // Poll the Guest Agent until it accepts an exec — replaces the
        // old IP/sshd wait. The agent comes up shortly after the VM
        // finishes its first-boot setup.
        try await waitForGuestAgent()

        prepared = true
    }

    public func copyFile(from localURL: URL, toGuestPath: String) async throws {
        guard prepared else {
            throw TestEnvironmentError("Environment not prepared.")
        }
        let basename = localURL.lastPathComponent
        let stagedURL = stagingDirURL.appending(path: basename)
        let fm = FileManager.default
        if fm.fileExists(atPath: stagedURL.path) {
            try fm.removeItem(at: stagedURL)
        }
        try fm.copyItem(at: localURL, to: stagedURL)

        // Move the file from the shared mount to its requested guest
        // path. `cp -f` overwrites any prior copy from a previous run.
        let mountPath = "/Volumes/My Shared Files/\(shareTag)/\(basename)"
        let result = try await runTartExec(
            command: "/bin/cp",
            arguments: ["-f", mountPath, toGuestPath]
        )
        if result.exitCode != 0 {
            throw TestEnvironmentError("Failed to stage \(basename) at \(toGuestPath): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    public func runCommand(_ command: String, arguments: [String]) async throws -> CommandResult {
        guard prepared else {
            throw TestEnvironmentError("Environment not prepared.")
        }
        return try await runTartExec(command: command, arguments: arguments)
    }

    public func teardown() async {
        _ = try? await HostTestEnvironment.run(command: tartPath, arguments: ["stop", cloneName])
        if let runProcess, runProcess.isRunning {
            runProcess.terminate()
        }
        runProcess = nil
        _ = try? await HostTestEnvironment.run(command: tartPath, arguments: ["delete", cloneName])
        try? FileManager.default.removeItem(at: stagingDirURL)
        prepared = false
    }

    // MARK: - Helpers

    private func runTartExec(command: String, arguments: [String]) async throws -> CommandResult {
        try await HostTestEnvironment.run(
            command: tartPath,
            arguments: ["exec", cloneName, command] + arguments
        )
    }

    private func waitForGuestAgent() async throws {
        // Generous: first-boot macOS guests can spend a minute or two on
        // setup before the agent answers. The old SSH wait used 180s; we
        // keep that budget.
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            if Task.isCancelled {
                throw TestEnvironmentError("Cancelled while waiting for Tart Guest Agent.")
            }
            let probe = try? await HostTestEnvironment.run(
                command: tartPath,
                arguments: ["exec", cloneName, "/usr/bin/true"]
            )
            if probe?.exitCode == 0 { return }
            try? await Task.sleep(for: .seconds(2))
        }
        throw TestEnvironmentError("Timed out waiting for the Tart Guest Agent after 180s. Confirm the base image is a cirruslabs image (which bundles the agent) — vanilla VMs need `tart guest install` run inside them once.")
    }
}
