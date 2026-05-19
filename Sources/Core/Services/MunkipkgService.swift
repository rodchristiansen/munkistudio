import Foundation

/// `UserDefaults` keys shared between the App settings layer and the
/// Infra service implementations. Lives in Core so neither side has to
/// import the other just to agree on a key string.
public enum MunkipkgDefaults {
    /// Overrides the `munkipkg` executable path. Empty = standard path.
    public static let executablePathKey = "MunkiStudio.settings.munkipkgExecutablePath"
}

/// Streamed events from a `munkipkg --build` run.
public enum MunkipkgEvent: Sendable {
    /// A line of munkipkg output.
    case line(String)
    /// The build finished. `productURL` is the built `.pkg` on success.
    case finished(exitCode: Int32, productURL: URL?)
}

/// CLI options for a `munkipkg --build` run — mirrors the BUILD OPTIONS
/// section of `munkipkg --help`.
public struct MunkipkgBuildOptions: Sendable, Hashable {
    /// `--export-bom-info`
    public var exportBomInfo: Bool
    /// `--skip-notarization`
    public var skipNotarization: Bool
    /// `--skip-stapling`
    public var skipStapling: Bool
    /// `--no-import`
    public var noImport: Bool
    /// `--quiet`
    public var quiet: Bool
    /// `--env <path>` — blank auto-detects `.env` in the project.
    public var envPath: String

    public init(
        exportBomInfo: Bool = false,
        skipNotarization: Bool = false,
        skipStapling: Bool = false,
        noImport: Bool = true,
        quiet: Bool = false,
        envPath: String = ""
    ) {
        self.exportBomInfo = exportBomInfo
        self.skipNotarization = skipNotarization
        self.skipStapling = skipStapling
        self.noImport = noImport
        self.quiet = quiet
        self.envPath = envPath
    }

    /// The munkipkg flags for these options — without `--build` or the
    /// project path.
    public var arguments: [String] {
        var args: [String] = []
        if exportBomInfo { args.append("--export-bom-info") }
        if skipNotarization { args.append("--skip-notarization") }
        if skipStapling { args.append("--skip-stapling") }
        if noImport { args.append("--no-import") }
        if quiet { args.append("--quiet") }
        let env = envPath.trimmingCharacters(in: .whitespaces)
        if !env.isEmpty { args.append(contentsOf: ["--env", env]) }
        return args
    }
}

/// An error surfaced by ``MunkipkgService`` — carries a message fit to
/// show the user directly.
public struct MunkipkgError: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Discovers and builds munkipkg package-source projects. Implementations
/// shell out to the `munkipkg` binary — see ``MunkipkgEvent`` for the
/// streamed build output.
public protocol MunkipkgService: Sendable {
    /// Discover projects directly under `folder` — directories that hold
    /// a `build-info` file.
    func projects(in folder: URL) async throws -> [MunkipkgProject]

    /// Re-read a single project's `build-info` and `scripts/`.
    func loadProject(at directory: URL) async throws -> MunkipkgProject

    /// Write `buildInfo` back to the project's `build-info` file in
    /// `format`. When `format` differs from the project's current
    /// on-disk format, the old build-info file is removed so exactly one
    /// remains.
    func saveBuildInfo(
        _ buildInfo: BuildInfo,
        to project: MunkipkgProject,
        format: BuildInfoFormat
    ) async throws

    /// Read a script file's contents.
    func readScript(_ script: MunkipkgScript) async throws -> String

    /// Write a script file's contents, keeping its executable bit.
    func writeScript(_ script: MunkipkgScript, contents: String) async throws

    /// Run `munkipkg --build` with `options`, streaming output. The final
    /// event carries the built `.pkg` URL on success.
    func build(
        _ project: MunkipkgProject,
        options: MunkipkgBuildOptions
    ) -> AsyncThrowingStream<MunkipkgEvent, any Error>

    /// The version string of the configured `munkipkg`, or `nil` when it
    /// isn't installed or doesn't respond.
    func version() async -> String?

    /// Download the latest `munkipkg` release of the Swift fork and
    /// install it to `/usr/local/munki`, prompting for administrator
    /// rights for the privileged copy.
    func installLatest() async throws
}
