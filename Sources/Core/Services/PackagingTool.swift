import Foundation

/// Which package-building CLI the Build tab drives.
///
/// `munkipkg` is Munki's original tool; `swiftpkg` is the Swift
/// reimplementation the community is moving to. They share a project
/// layout — a directory with a `build-info` file and a payload — so
/// project discovery, build-info editing and script I/O are identical.
/// Only the invocation differs, and it differs enough to matter:
///
/// - munkipkg builds with `munkipkg --build <project>`; swiftpkg builds
///   with `swiftpkg <project>` and has no `--build` flag at all.
/// - swiftpkg has no post-build munkiimport prompt, so no
///   `--skip-import` / `--no-import` to suppress, and no `--env`.
///
/// Getting either of those wrong doesn't fail loudly — it makes the
/// tool print usage and exit non-zero — so the distinction is modelled
/// here rather than guessed at the call site.
public enum PackagingTool: String, Sendable, Hashable, CaseIterable, Identifiable {
    case munkipkg
    case swiftpkg

    public var id: String { rawValue }

    /// Display name for UI.
    public var displayName: String {
        switch self {
        case .munkipkg: "munkipkg"
        case .swiftpkg: "swiftpkg"
        }
    }

    /// Every location this tool is plausibly installed to, in the order
    /// they should be probed.
    ///
    /// Both tools have more than one common install route, and a GUI app
    /// can't lean on `PATH` to find them: launched from Finder it
    /// inherits a minimal `/usr/bin:/bin:/usr/sbin:/sbin`, which
    /// contains neither Homebrew nor Munki. So the locations are listed
    /// explicitly.
    ///
    /// swiftpkg's own installer package puts it in `/usr/local/bin`, but
    /// its README recommends Homebrew — which on Apple Silicon means
    /// `/opt/homebrew/bin`. Omitting that made a brew-installed swiftpkg
    /// invisible to detection on every Apple Silicon Mac.
    public var candidateExecutablePaths: [String] {
        switch self {
        case .munkipkg:
            [
                "/usr/local/munki/munkipkg",
                "/usr/local/bin/munkipkg",
                "/opt/homebrew/bin/munkipkg",
            ]
        case .swiftpkg:
            [
                "/usr/local/bin/swiftpkg",
                "/opt/homebrew/bin/swiftpkg",
            ]
        }
    }

    /// Where the tool's own installer puts the binary — the first
    /// candidate, and the path reported after an in-app install.
    public var defaultExecutablePath: String {
        candidateExecutablePaths[0]
    }

    /// The leading arguments that put the tool into build mode, before
    /// any options or the project path. swiftpkg builds by default.
    public var buildModeArguments: [String] {
        switch self {
        case .munkipkg: ["--build"]
        case .swiftpkg: []
        }
    }

    /// Identify the tool from an executable path, by filename.
    ///
    /// Returns `nil` for an unrecognised name so callers can fall back
    /// rather than silently driving a binary with the wrong CLI.
    public static func inferred(fromExecutablePath path: String) -> PackagingTool? {
        let name = (path as NSString).lastPathComponent.lowercased()
        if name.contains("swiftpkg") { return .swiftpkg }
        if name.contains("munkipkg") { return .munkipkg }
        return nil
    }

    /// Detection order when nothing is configured explicitly: swiftpkg
    /// first, as the actively developed successor, then munkipkg.
    public static let detectionOrder: [PackagingTool] = [.swiftpkg, .munkipkg]
}

/// Which optional flags a specific installed binary accepts, read from
/// its own `--help`.
///
/// These are deliberately *not* hardcoded per tool. Both tools are moving
/// targets and they disagree on spelling:
///
/// - munkipkg takes `--env PATH` and `--skip-import`.
/// - swiftpkg 0.3.1 takes neither.
/// - swiftpkg on `next` takes `--env-file PATH`, and accepts
///   `--skip-import` for munki-pkg compatibility.
///
/// swiftpkg parses with `swift-argument-parser`, so an unrecognised flag
/// is a hard parse failure rather than something it shrugs off. Guessing
/// from the tool's identity alone would break a build the moment either
/// project shipped a release — so the installed binary is asked instead.
public struct PackagingToolCapabilities: Sendable, Hashable {
    /// Flag that suppresses the post-build munkiimport prompt, or `nil`
    /// when this binary has none.
    public var skipImportFlag: String?

    /// Flag that points the tool at a `.env` file, or `nil` when this
    /// binary has none.
    public var envFileFlag: String?

    public init(skipImportFlag: String? = nil, envFileFlag: String? = nil) {
        self.skipImportFlag = skipImportFlag
        self.envFileFlag = envFileFlag
    }

    /// Nothing optional supported — the safe assumption when `--help`
    /// can't be read, since omitting a flag still builds.
    public static let none = PackagingToolCapabilities()

    /// Read capabilities out of a `--help` payload.
    ///
    /// Longest spelling first in each family: `--env-file` contains
    /// `--env` as a prefix, so checking `--env` first would match
    /// swiftpkg's help and then pass munkipkg's shorter flag to a binary
    /// that doesn't take it.
    public static func detected(fromHelp help: String) -> PackagingToolCapabilities {
        PackagingToolCapabilities(
            skipImportFlag: ["--skip-import", "--no-import"].first { help.contains($0) },
            envFileFlag: ["--env-file", "--env"].first { help.contains($0) }
        )
    }
}
