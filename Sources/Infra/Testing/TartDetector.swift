import Foundation
import Core

/// Detects whether `tart` is installed and probes its version. The
/// Testing settings pane surfaces this so the user gets an "install
/// hint" path when the binary is missing.
public struct TartDetector: Sendable {

    public init() {}

    /// Absolute path to the `tart` binary on PATH, or `nil` if not found.
    public func locate() async -> String? {
        let result = try? await HostTestEnvironment.run(
            command: "/usr/bin/env",
            arguments: ["which", "tart"]
        )
        guard let result, result.exitCode == 0 else { return nil }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// Version string reported by `tart --version`, or `nil` if Tart
    /// isn't installed / didn't respond.
    public func version() async -> String? {
        guard let path = await locate() else { return nil }
        let result = try? await HostTestEnvironment.run(
            command: path,
            arguments: ["--version"]
        )
        guard let result, result.exitCode == 0 else { return nil }
        let line = result.stdout
            .split(separator: "\n").first.map(String.init)
            ?? result.stdout
        return line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Path to the Homebrew binary on this Mac, or `nil` if Homebrew
    /// isn't installed. Apps launched from Finder don't see Homebrew on
    /// `PATH` — checking the canonical install locations directly is
    /// far more reliable than shelling out to `which brew`.
    public func locateHomebrew() async -> String? {
        let candidates = [
            "/opt/homebrew/bin/brew",   // Apple Silicon
            "/usr/local/bin/brew"        // Intel
        ]
        let fm = FileManager.default
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    /// Pull a Tart base image (`tart pull <ref>`). The call resolves
    /// when the pull finishes — typical pulls are 6–10 GB so callers
    /// should show progress while awaiting. Returns nil if Tart isn't
    /// installed.
    public func pullImage(_ ref: String) async throws -> CommandResult? {
        guard let path = await locate() else { return nil }
        return try await HostTestEnvironment.run(
            command: path,
            arguments: ["pull", ref]
        )
    }

    /// List of VMs known to the local Tart store — useful when the user
    /// picks a base image. Output of `tart list --format json` is
    /// parsed; an empty array is returned on any failure so the UI
    /// can degrade gracefully to a free-text field.
    public func listLocalVMs() async -> [String] {
        guard let path = await locate() else { return [] }
        let result = try? await HostTestEnvironment.run(
            command: path,
            arguments: ["list", "--format", "json"]
        )
        guard let result, result.exitCode == 0 else { return [] }
        let data = Data(result.stdout.utf8)
        if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return array.compactMap { $0["Name"] as? String ?? $0["name"] as? String }
        }
        return []
    }
}
