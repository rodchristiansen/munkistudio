import Foundation
import Testing
import Core
@testable import Infra

/// Idempotency round-trip sweep over a real Munki repository on disk.
///
/// Driven by the `MUNKI_REPO_PATH` environment variable so CI doesn't
/// require a fixture corpus. When set, this loads every pkginfo and
/// manifest under the path, saves it to a temp file, then loads + saves
/// again and asserts the two emitted strings are byte-identical.
///
/// Rationale: the first save normalises whitespace, key order, quoting
/// to our canonical form (Munki PR #1261). What we care about is
/// **stability** — once a file passes through our serializer, every
/// subsequent save must produce the same bytes. Any divergence is a
/// serialization bug.
///
/// Run locally with:
///     MUNKI_REPO_PATH=/path/to/munki_repo swift test
@Suite("Round-trip sweep")
struct RoundTripSweepTests {
    @Test("pkgsinfo and manifests stabilise after one round trip")
    func idempotentRoundTrip() async throws {
        guard let path = ProcessInfo.processInfo.environment["MUNKI_REPO_PATH"] else {
            // No-op when the env var isn't set — keeps CI green and lets
            // devs opt-in.
            return
        }
        let root = URL(fileURLWithPath: path)
        let pkgsinfoRoot = root.appending(path: "pkgsinfo")
        let manifestsRoot = root.appending(path: "manifests")

        var pkginfoFiles: [URL] = []
        var manifestFiles: [URL] = []
        if FileManager.default.fileExists(atPath: pkgsinfoRoot.path) {
            pkginfoFiles = try walk(pkgsinfoRoot)
        }
        if FileManager.default.fileExists(atPath: manifestsRoot.path) {
            manifestFiles = try walk(manifestsRoot)
        }

        var pkginfoFailures: [Failure] = []
        for url in pkginfoFiles where ["plist", "yaml", "yml"].contains(url.pathExtension) {
            if let failure = roundTripPkginfo(at: url) {
                pkginfoFailures.append(failure)
            }
        }

        var manifestFailures: [Failure] = []
        for url in manifestFiles where ["plist", "yaml", "yml", ""].contains(url.pathExtension) {
            if let failure = roundTripManifest(at: url, repoRoot: root) {
                manifestFailures.append(failure)
            }
        }

        // Report each failure as its own test row so the runner output
        // is actually usable when triaging — a single boolean assert
        // would hide which files diverged.
        for failure in pkginfoFailures + manifestFailures {
            Issue.record("\(failure.kind) \(failure.relativePath): \(failure.reason)\n--- first emit ---\n\(failure.firstEmit)\n--- second emit ---\n\(failure.secondEmit)\n")
        }
        #expect(pkginfoFailures.isEmpty, "Pkginfo files diverged on second save")
        #expect(manifestFailures.isEmpty, "Manifest files diverged on second save")
        print("Round-trip sweep: \(pkginfoFiles.count) pkginfos, \(manifestFiles.count) manifests checked.")
    }

    private struct Failure {
        let kind: String
        let relativePath: String
        let reason: String
        let firstEmit: String
        let secondEmit: String
    }

    private func roundTripPkginfo(at url: URL) -> Failure? {
        do {
            let original = try PkginfoFileCoder.read(from: url)
            let firstEmit = try emitPkginfo(original.pkginfo, format: original.format)
            let reloaded = try parsePkginfo(firstEmit, format: original.format)
            let secondEmit = try emitPkginfo(reloaded, format: original.format)
            if firstEmit != secondEmit {
                return Failure(
                    kind: "pkginfo",
                    relativePath: url.lastPathComponent,
                    reason: "second emit differs from first",
                    firstEmit: firstEmit,
                    secondEmit: secondEmit
                )
            }
            return nil
        } catch {
            return Failure(
                kind: "pkginfo",
                relativePath: url.lastPathComponent,
                reason: "load error: \(error.localizedDescription)",
                firstEmit: "",
                secondEmit: ""
            )
        }
    }

    private func roundTripManifest(at url: URL, repoRoot: URL) -> Failure? {
        do {
            let record = try ManifestFileCoder.read(from: url, repositoryRoot: repoRoot)
            let firstEmit = try emitManifest(record.manifest, format: record.format)
            let reloaded = try parseManifest(firstEmit, format: record.format, name: record.manifest.manifestName)
            let secondEmit = try emitManifest(reloaded, format: record.format)
            if firstEmit != secondEmit {
                return Failure(
                    kind: "manifest",
                    relativePath: url.lastPathComponent,
                    reason: "second emit differs from first",
                    firstEmit: firstEmit,
                    secondEmit: secondEmit
                )
            }
            return nil
        } catch {
            return Failure(
                kind: "manifest",
                relativePath: url.lastPathComponent,
                reason: "load error: \(error.localizedDescription)",
                firstEmit: "",
                secondEmit: ""
            )
        }
    }

    private func emitPkginfo(_ p: Pkginfo, format: RepoFormat) throws -> String {
        switch format {
        case .yaml:
            return try PkginfoYamlCoder.encode(p)
        case .plist:
            let data = try PkginfoPlistCoder.encode(p)
            return String(decoding: data, as: UTF8.self)
        }
    }

    private func parsePkginfo(_ text: String, format: RepoFormat) throws -> Pkginfo {
        switch format {
        case .yaml:
            return try PkginfoYamlCoder.decode(from: text)
        case .plist:
            let data = Data(text.utf8)
            return try PkginfoPlistCoder.decode(from: data)
        }
    }

    private func emitManifest(_ m: Manifest, format: RepoFormat) throws -> String {
        switch format {
        case .yaml:
            return try ManifestYamlCoder.encode(m)
        case .plist:
            let data = try ManifestPlistCoder.encode(m)
            return String(decoding: data, as: UTF8.self)
        }
    }

    private func parseManifest(_ text: String, format: RepoFormat, name: String) throws -> Manifest {
        switch format {
        case .yaml:
            return try ManifestYamlCoder.decode(from: text, name: name)
        case .plist:
            let data = Data(text.utf8)
            return try ManifestPlistCoder.decode(from: data, name: name)
        }
    }

    private func walk(_ root: URL) throws -> [URL] {
        var out: [URL] = []
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true && !url.lastPathComponent.hasPrefix(".") {
                out.append(url)
            }
        }
        return out
    }
}
