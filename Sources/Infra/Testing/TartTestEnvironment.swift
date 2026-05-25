import Foundation
import Core

/// Ephemeral macOS guest backed by Tart. Each instance clones a base
/// image into a uniquely-named throwaway VM, starts it headless, waits
/// for its IP, and tears the clone down on `teardown()`. SSH-based file
/// copy + command exec use `admin@<ip>` with key auth — the base image
/// is expected to have the admin's `~/.ssh/authorized_keys` baked in.
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
    private let sshUser: String

    /// Background task running `tart run` — kept around so `teardown()`
    /// can cancel it. The process is `tart stop`ed first; cancellation
    /// is the fallback.
    private var runProcess: Process?
    private var ipAddress: String?
    private var prepared = false

    public init(
        tartPath: String,
        baseImage: String,
        sshUser: String = "admin",
        cloneName: String = "munkistudio-test-\(UUID().uuidString.prefix(8))"
    ) {
        self.tartPath = tartPath
        self.baseImage = baseImage
        self.cloneName = cloneName
        self.sshUser = sshUser
        self.displayName = "Tart '\(cloneName)' (from \(baseImage))"
    }

    public func prepare() async throws {
        guard !prepared else { return }

        // Clone the base image — APFS clone, fast.
        let clone = try await HostTestEnvironment.run(
            command: tartPath,
            arguments: ["clone", baseImage, cloneName]
        )
        if clone.exitCode != 0 {
            throw TestEnvironmentError("tart clone failed: \(clone.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        // Start the VM headless in the background.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tartPath)
        process.arguments = ["run", cloneName, "--no-graphics"]
        let null = Pipe()
        process.standardOutput = null
        process.standardError = null
        do {
            try process.run()
        } catch {
            throw TestEnvironmentError("tart run failed: \(error.localizedDescription)")
        }
        runProcess = process

        // Poll for the guest IP. macOS guests take ~10-30s to reach a
        // usable network state; bail after a generous timeout.
        let ip = try await waitForIP()
        ipAddress = ip

        // Wait until SSH actually accepts a connection — `tart ip`
        // returns before sshd is ready.
        try await waitForSSH(at: ip)

        prepared = true
    }

    public func copyFile(from localURL: URL, toGuestPath: String) async throws {
        guard let ip = ipAddress else {
            throw TestEnvironmentError("Environment not prepared.")
        }
        let result = try await HostTestEnvironment.run(
            command: "/usr/bin/scp",
            arguments: [
                "-o", "StrictHostKeyChecking=no",
                "-o", "UserKnownHostsFile=/dev/null",
                localURL.path,
                "\(sshUser)@\(ip):\(toGuestPath)"
            ]
        )
        if result.exitCode != 0 {
            throw TestEnvironmentError("scp failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    public func runCommand(_ command: String, arguments: [String]) async throws -> CommandResult {
        guard let ip = ipAddress else {
            throw TestEnvironmentError("Environment not prepared.")
        }
        let remote = ([command] + arguments).map(Self.shellEscape).joined(separator: " ")
        return try await HostTestEnvironment.run(
            command: "/usr/bin/ssh",
            arguments: [
                "-o", "StrictHostKeyChecking=no",
                "-o", "UserKnownHostsFile=/dev/null",
                "\(sshUser)@\(ip)",
                remote
            ]
        )
    }

    public func teardown() async {
        _ = try? await HostTestEnvironment.run(command: tartPath, arguments: ["stop", cloneName])
        if let runProcess, runProcess.isRunning {
            runProcess.terminate()
        }
        runProcess = nil
        _ = try? await HostTestEnvironment.run(command: tartPath, arguments: ["delete", cloneName])
        ipAddress = nil
        prepared = false
    }

    // MARK: - Helpers

    private func waitForIP() async throws -> String {
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            let result = try? await HostTestEnvironment.run(
                command: tartPath,
                arguments: ["ip", cloneName]
            )
            if let result, result.exitCode == 0 {
                let ip = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if !ip.isEmpty { return ip }
            }
            try? await Task.sleep(for: .seconds(2))
        }
        throw TestEnvironmentError("Timed out waiting for Tart guest IP.")
    }

    private func waitForSSH(at ip: String) async throws {
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            let result = try? await HostTestEnvironment.run(
                command: "/usr/bin/ssh",
                arguments: [
                    "-o", "ConnectTimeout=3",
                    "-o", "StrictHostKeyChecking=no",
                    "-o", "UserKnownHostsFile=/dev/null",
                    "-o", "BatchMode=yes",
                    "\(sshUser)@\(ip)",
                    "true"
                ]
            )
            if result?.exitCode == 0 { return }
            try? await Task.sleep(for: .seconds(2))
        }
        throw TestEnvironmentError("Timed out waiting for sshd in Tart guest.")
    }

    /// Quote a single token for safe inclusion in a remote shell command.
    /// Single-quoted with embedded single quotes escaped.
    private nonisolated static func shellEscape(_ token: String) -> String {
        guard !token.isEmpty else { return "''" }
        if token.range(of: "[^A-Za-z0-9_./:=@-]", options: .regularExpression) == nil {
            return token
        }
        return "'" + token.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
