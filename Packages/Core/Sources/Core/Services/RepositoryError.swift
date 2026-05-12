import Foundation

/// Errors any of the Core service protocols can throw. Concrete services
/// wrap their own underlying failures (YAML parse, file system, git CLI)
/// into one of these so callers can switch on a small, stable surface.
public enum RepositoryError: Error, Sendable, LocalizedError {
    case notAMunkiRepository(URL)
    case fileNotFound(URL)
    case parse(file: URL, message: String)
    case write(file: URL, message: String)
    case unsupportedFormat(String)
    case duplicateName(String)
    case process(name: String, exitCode: Int32, output: String)
    case dirtyWorkingTree

    public var errorDescription: String? {
        switch self {
        case .notAMunkiRepository(let url):
            "\(url.path) doesn't look like a Munki repository (no pkgsinfo/ or manifests/)."
        case .fileNotFound(let url):
            "Missing file: \(url.path)."
        case .parse(let file, let message):
            "Could not parse \(file.lastPathComponent): \(message)"
        case .write(let file, let message):
            "Could not save \(file.lastPathComponent): \(message)"
        case .unsupportedFormat(let ext):
            "Unsupported file format: \(ext)."
        case .duplicateName(let name):
            "Another item already uses the name \(name)."
        case .process(let name, let exitCode, let output):
            "\(name) failed (exit \(exitCode)): \(output)"
        case .dirtyWorkingTree:
            "Refusing to switch branches with uncommitted changes."
        }
    }
}
