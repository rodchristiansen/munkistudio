import Foundation

/// An isolated runtime the Testing pane can install a Munki package
/// into. Phase C uses this to run a `.pkg` against a clean ephemeral
/// macOS guest via Tart; future phases can add other backends (a CI
/// runner, a remote Mac, etc.) behind the same surface.
///
/// Lifecycle: `prepare()` brings the environment up, `copyFile` /
/// `runCommand` operate on it, `teardown()` tears it down. Implementations
/// should be safe to `teardown()` even after a failed `prepare()`.
public protocol TestEnvironment: Sendable {
    /// Human-readable label for the timeline and logs.
    var displayName: String { get }

    /// What kind of environment this is — used by the UI to render
    /// affordances (a Tart icon vs the host icon) and by tests to
    /// branch on capability.
    var kind: TestEnvironmentKind { get }

    /// Bring the environment up. Implementations should be idempotent:
    /// calling `prepare()` twice should be a no-op after the first
    /// success.
    func prepare() async throws

    /// Copy a local file into the guest at `guestPath`. For host
    /// environments this is a regular file copy.
    func copyFile(from localURL: URL, toGuestPath: String) async throws

    /// Run a command inside the guest. `arguments` are passed verbatim;
    /// the environment is responsible for quoting / shell context.
    func runCommand(_ command: String, arguments: [String]) async throws -> CommandResult

    /// Tear the environment down. Implementations should swallow
    /// secondary errors — `teardown()` is `async` rather than `throws`
    /// because there's nothing useful for a caller to do with a failure.
    func teardown() async
}

public enum TestEnvironmentKind: String, Sendable, Hashable, Codable, CaseIterable {
    /// No environment configured — install steps will skip.
    case none
    /// Run on the host Mac directly. Opt-in only; clearly unsafe for
    /// real install testing but useful for smoke testing the pipeline.
    case host
    /// Ephemeral Tart VM cloned from a base image, torn down after.
    case tart
}

public struct CommandResult: Sendable, Hashable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String

    public var success: Bool { exitCode == 0 }

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public struct TestEnvironmentError: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
