import Foundation
import Testing
import Core
@testable import Infra

@Suite("Packaging tool resolution and release assets")
struct PackagingToolResolutionTests {
    /// `MunkipkgRunner` reads the executable override from standard
    /// defaults, so each test sets and clears that one key.
    private static func withConfiguredPath<T>(
        _ path: String?,
        _ body: () throws -> T
    ) rethrows -> T {
        let key = MunkipkgDefaults.executablePathKey
        let previous = UserDefaults.standard.string(forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        if let path {
            UserDefaults.standard.set(path, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        return try body()
    }

    /// A hand-set path pointing at swiftpkg must be driven with
    /// swiftpkg's CLI. Assuming munkipkg here would append `--build`,
    /// which swiftpkg rejects.
    @Test("an explicit swiftpkg path resolves as swiftpkg")
    func explicitSwiftpkgPath() {
        Self.withConfiguredPath("/opt/homebrew/bin/swiftpkg") {
            let resolved = MunkipkgRunner().resolved
            #expect(resolved.tool == .swiftpkg)
            #expect(resolved.url.path == "/opt/homebrew/bin/swiftpkg")
        }
    }

    @Test("an explicit munkipkg path resolves as munkipkg")
    func explicitMunkipkgPath() {
        Self.withConfiguredPath("/usr/local/munki/munkipkg") {
            let resolved = MunkipkgRunner().resolved
            #expect(resolved.tool == .munkipkg)
        }
    }

    /// Before swiftpkg existed, a hand-set path could only be munkipkg.
    /// An unrecognised name keeps that reading rather than guessing.
    @Test("an unrecognised explicit path falls back to munkipkg")
    func unrecognisedPathFallsBack() {
        Self.withConfiguredPath("/usr/local/bin/pkgtool") {
            let resolved = MunkipkgRunner().resolved
            #expect(resolved.tool == .munkipkg)
            #expect(resolved.url.path == "/usr/local/bin/pkgtool")
        }
    }

    @Test("a tilde in the configured path is expanded")
    func tildeIsExpanded() {
        Self.withConfiguredPath("~/bin/swiftpkg") {
            let resolved = MunkipkgRunner().resolved
            #expect(!resolved.url.path.contains("~"))
            #expect(resolved.tool == .swiftpkg)
        }
    }

    @Test("a blank configured path falls through to detection")
    func blankPathFallsThroughToDetection() {
        Self.withConfiguredPath("   ") {
            let resolved = MunkipkgRunner().resolved
            // Whichever tool is (or isn't) installed on this machine, a
            // blank override must never be treated as a literal path.
            #expect(resolved.url.path == resolved.tool.defaultExecutablePath)
        }
    }

    @Test("with nothing configured the resolved path is a known default")
    func detectionUsesKnownDefaults() {
        Self.withConfiguredPath(nil) {
            let resolved = MunkipkgRunner().resolved
            #expect(PackagingTool.allCases.map(\.defaultExecutablePath).contains(resolved.url.path))
        }
    }

    // MARK: Release asset selection

    private static func release(_ names: [String]) -> GitHubRelease {
        let json = """
        {"assets": [\(names.map {
            "{\"name\": \"\($0)\", \"browser_download_url\": \"https://example.invalid/\($0)\"}"
        }.joined(separator: ","))]}
        """
        return try! JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8))
    }

    /// The real release also carries a "combined" package bundling the
    /// Swiftpkgr desktop app, a tarball and a checksums file. Only the
    /// CLI package should ever be installed.
    @Test("the CLI package is picked out of a full swiftpkg release")
    func picksCLIPackage() {
        let release = Self.release([
            "SHA256SUMS",
            "swiftpkg-0.3.1-cli.pkg",
            "swiftpkg-0.3.1-combined.pkg",
            "swiftpkg-0.3.1-universal.tar.gz",
            "Swiftpkgr-0.3.1.zip",
        ])
        #expect(MunkipkgRunner.swiftpkgCLIAsset(in: release)?.name == "swiftpkg-0.3.1-cli.pkg")
    }

    @Test("a release with no CLI package selects nothing")
    func noCLIPackage() {
        let release = Self.release([
            "SHA256SUMS",
            "swiftpkg-0.3.1-combined.pkg",
            "Swiftpkgr-0.3.1.zip",
        ])
        #expect(MunkipkgRunner.swiftpkgCLIAsset(in: release) == nil)
    }

    @Test("an empty release selects nothing rather than the first asset")
    func emptyRelease() {
        #expect(MunkipkgRunner.swiftpkgCLIAsset(in: Self.release([])) == nil)
    }

    @Test("asset matching survives a version bump")
    func matchesFutureVersions() {
        let release = Self.release(["swiftpkg-1.10.0-cli.pkg"])
        #expect(MunkipkgRunner.swiftpkgCLIAsset(in: release)?.name == "swiftpkg-1.10.0-cli.pkg")
    }
}
