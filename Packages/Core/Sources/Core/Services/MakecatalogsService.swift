import Foundation

/// Invoke the `makecatalogs` CLI Munki ships under `/usr/local/munki/` and
/// stream its output. We don't try to reimplement makecatalogs in Swift —
/// Munki maintains it, and admin trust is anchored to "the same binary the
/// server runs."
public protocol MakecatalogsService: Sendable {
    /// Stream lines from a `makecatalogs` run as they're emitted. The
    /// returned sequence finishes when the process exits; the final element
    /// is a ``MakecatalogsOutcome``.
    func run(
        in repository: MunkiRepository,
        options: MakecatalogsOptions
    ) -> AsyncThrowingStream<MakecatalogsEvent, any Error>
}

/// Per-run options for `makecatalogs`. Defaults match the CLI's defaults.
public struct MakecatalogsOptions: Sendable {
    public var force: Bool
    public var skipPkgcheck: Bool
    public var outputFormat: RepoFormat?

    public init(
        force: Bool = false,
        skipPkgcheck: Bool = false,
        outputFormat: RepoFormat? = nil
    ) {
        self.force = force
        self.skipPkgcheck = skipPkgcheck
        self.outputFormat = outputFormat
    }
}

public enum MakecatalogsEvent: Sendable {
    case line(String)
    case finished(MakecatalogsOutcome)
}

public struct MakecatalogsOutcome: Sendable {
    public var exitCode: Int32
    public var hadWarnings: Bool

    public init(exitCode: Int32, hadWarnings: Bool) {
        self.exitCode = exitCode
        self.hadWarnings = hadWarnings
    }
}
