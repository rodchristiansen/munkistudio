import Foundation
import Core

/// `TestEnvironment` that runs against the host Mac directly. Opt-in
/// only — useful for smoke-testing the pipeline (does a build artifact
/// land where pkginfo claims, do the commands shell out correctly) but
/// **not** safe for real install testing because it actually mutates
/// the host. The Testing pane warns the user before selecting this.
public actor HostTestEnvironment: TestEnvironment {
    public let displayName: String = "Host (this Mac)"
    public let kind: TestEnvironmentKind = .host

    public init() {}

    public func prepare() async throws {
        // Nothing to bring up — the host is always available.
    }

    public func copyFile(from localURL: URL, toGuestPath: String) async throws {
        let target = URL(fileURLWithPath: toGuestPath)
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) {
            try fm.removeItem(at: target)
        }
        try fm.copyItem(at: localURL, to: target)
    }

    public func runCommand(_ command: String, arguments: [String]) async throws -> CommandResult {
        try await Self.run(command: command, arguments: arguments)
    }

    public func teardown() async {
        // No-op. Anything the test wrote stays put — the user opted in.
    }

    static func run(command: String, arguments: [String]) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CommandResult, any Error>) in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: command)
            task.arguments = arguments
            let outPipe = Pipe()
            let errPipe = Pipe()
            task.standardOutput = outPipe
            task.standardError = errPipe
            // `terminationHandler` fires on a background dispatch queue
            // when the child exits — no blocking `waitUntilExit()` on
            // the calling thread, which previously meant a long-running
            // shell-out (Tart pull, Tart run) would freeze the UI.
            task.terminationHandler = { proc in
                let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
                let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
                continuation.resume(
                    returning: CommandResult(
                        exitCode: proc.terminationStatus,
                        stdout: String(decoding: outData, as: UTF8.self),
                        stderr: String(decoding: errData, as: UTF8.self)
                    )
                )
            }
            do {
                try task.run()
            } catch {
                continuation.resume(throwing: TestEnvironmentError("Failed to run \(command): \(error.localizedDescription)"))
            }
        }
    }
}
