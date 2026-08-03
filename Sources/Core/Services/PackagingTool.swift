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

    /// Where the tool's own installer puts the binary.
    public var defaultExecutablePath: String {
        switch self {
        case .munkipkg: "/usr/local/munki/munkipkg"
        case .swiftpkg: "/usr/local/bin/swiftpkg"
        }
    }

    /// Whether the tool accepts a flag to suppress a post-build
    /// munkiimport prompt. swiftpkg never prompts, so there is nothing
    /// to suppress.
    public var supportsSkipImport: Bool {
        switch self {
        case .munkipkg: true
        case .swiftpkg: false
        }
    }

    /// Whether the tool accepts `--env <path>`.
    public var supportsEnvFile: Bool {
        switch self {
        case .munkipkg: true
        case .swiftpkg: false
        }
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
