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
    /// Suppress the post-build munkiimport prompt. The actual CLI flag
    /// (`--skip-import` vs `--no-import`) is resolved by the runner from
    /// the installed `munkipkg`'s own help text — if neither is supported
    /// the build still runs, the flag is simply omitted.
    public var skipImport: Bool
    /// `--quiet`
    public var quiet: Bool
    /// `--env <path>` — blank auto-detects `.env` in the project.
    public var envPath: String

    public init(
        exportBomInfo: Bool = false,
        skipNotarization: Bool = false,
        skipStapling: Bool = false,
        skipImport: Bool = true,
        quiet: Bool = false,
        envPath: String = ""
    ) {
        self.exportBomInfo = exportBomInfo
        self.skipNotarization = skipNotarization
        self.skipStapling = skipStapling
        self.skipImport = skipImport
        self.quiet = quiet
        self.envPath = envPath
    }

    /// The flags this options struct can express on its own — the
    /// import-suppression flag is left to the runner, which picks a
    /// spelling the installed binary actually accepts.
    ///
    /// Defaults to munkipkg's vocabulary; use ``arguments(for:)`` to
    /// emit only what a given tool accepts.
    public var arguments: [String] { arguments(for: .munkipkg) }

    /// Flags `tool` actually accepts.
    ///
    /// `--export-bom-info`, `--skip-notarization`, `--skip-stapling` and
    /// `--quiet` are common to both tools. `--env` is munkipkg-only, and
    /// passing it to swiftpkg makes it print usage and exit non-zero
    /// rather than ignoring it.
    public func arguments(for tool: PackagingTool) -> [String] {
        var args: [String] = []
        if exportBomInfo { args.append("--export-bom-info") }
        if skipNotarization { args.append("--skip-notarization") }
        if skipStapling { args.append("--skip-stapling") }
        if quiet { args.append("--quiet") }
        let env = envPath.trimmingCharacters(in: .whitespaces)
        if !env.isEmpty, tool.supportsEnvFile {
            args.append(contentsOf: ["--env", env])
        }
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

    /// The version string of the configured tool, or `nil` when it isn't
    /// installed or doesn't respond.
    func version() async -> String?

    /// Which tool is actually going to run, with its version and path —
    /// the configured executable if one is set, otherwise the first of
    /// ``PackagingTool/detectionOrder`` found on disk. `nil` when neither
    /// is installed.
    func installedTool() async -> InstalledPackagingTool?

    /// Download the latest release of `tool` and install it, prompting
    /// for administrator rights.
    func installLatest(_ tool: PackagingTool) async throws
}

/// A packaging tool found on disk, ready to run.
public struct InstalledPackagingTool: Sendable, Hashable {
    public var tool: PackagingTool
    public var version: String
    public var executablePath: String

    public init(tool: PackagingTool, version: String, executablePath: String) {
        self.tool = tool
        self.version = version
        self.executablePath = executablePath
    }

    /// e.g. "swiftpkg 0.3.1" — what the UI shows when reporting status.
    public var displayLabel: String {
        version.localizedCaseInsensitiveContains(tool.displayName)
            ? version
            : "\(tool.displayName) \(version)"
    }
}
