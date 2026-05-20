import Foundation

/// PATH and environment to hand to `git` subprocesses we spawn from
/// MunkiStudio.
///
/// macOS apps launched from Finder / LaunchServices inherit a stripped
/// environment — `PATH` is the system default
/// `/usr/bin:/bin:/usr/sbin:/sbin`, nothing more. That bites the moment
/// a user's repo runs hooks: a typical Munki `pre-commit` hook shells
/// out to `makecatalogs` (`/usr/local/munki/makecatalogs`) and bails
/// with `ERROR: makecatalogs not found` because that directory isn't in
/// PATH for the subprocess.
///
/// The hooks expect a "normal admin shell" PATH, so we prepend the
/// well-known admin tool locations to whatever PATH we inherited.
/// Order matters: Munki tools first (so a Homebrew `makecatalogs` shim
/// can't shadow the real one), then Homebrew on both architectures,
/// then `/usr/local/bin` for hand-installed binaries, then the
/// inherited PATH.
public enum GitProcessEnvironment {
    /// The directories prepended to PATH when invoking git. Kept in a
    /// constant so tests can assert on the exact ordering — drift here
    /// is exactly the bug class this exists to prevent.
    public static let prependedPathEntries: [String] = [
        "/usr/local/munki",     // makecatalogs, makepkginfo, …
        "/opt/homebrew/bin",    // Apple Silicon Homebrew
        "/opt/homebrew/sbin",
        "/usr/local/bin",       // Intel Homebrew / hand-installed
        "/usr/local/sbin"
    ]

    /// Build the environment dict to pass to a git subprocess. Starts
    /// from the current process's environment so anything the user
    /// configured (LANG, GIT_*, SSH_AUTH_SOCK, …) survives.
    public static func make() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let inherited = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        // Drop any prepended entry that's already present so we don't
        // duplicate it ahead of where the user put it.
        let existing = Set(inherited.split(separator: ":").map(String.init))
        let prepend = prependedPathEntries.filter { !existing.contains($0) }
        env["PATH"] = (prepend + [inherited]).joined(separator: ":")
        return env
    }
}
