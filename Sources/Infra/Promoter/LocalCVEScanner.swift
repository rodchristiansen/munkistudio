import Foundation
import CryptoKit
import Core

/// Runs the configured local scanner without a shell. Reports and advisory
/// evidence live in the app cache, never in the managed repository.
public struct LocalCVEScanner: Sendable {
    public let pythonURL: URL
    public let scriptURL: URL
    public let repositoryURL: URL
    public let reportURL: URL

    public init(repositoryURL: URL, scriptURL: URL, pythonURL: URL) throws {
        let root = try Self.munkiRoot(for: repositoryURL)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: scriptURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: pythonURL.path)
        else { throw ScanError.configuration }
        self.pythonURL = pythonURL
        self.scriptURL = scriptURL
        self.repositoryURL = root
        self.reportURL = try Self.cachedReportURL(for: repositoryURL)
    }

    public var arguments: [String] {
        ["-u", scriptURL.path, "--munki", repositoryURL.path, "--output", reportURL.path]
    }

    public func events() throws -> AsyncThrowingStream<ProcessRunner.StreamEvent, any Error> {
        try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        return ProcessRunner.stream(pythonURL, arguments: arguments, in: scriptURL.deletingLastPathComponent(),
                                    environment: ProcessInfo.processInfo.environment.merging(["PYTHONUNBUFFERED": "1"]) { _, new in new })
    }

    public static func munkiRoot(for repository: URL) throws -> URL {
        let root = repository.standardizedFileURL.resolvingSymlinksInPath()
        if FileManager.default.fileExists(atPath: root.appending(path: "deployment/pkgsinfo").path) { return root }
        if root.lastPathComponent == "deployment",
           FileManager.default.fileExists(atPath: root.appending(path: "pkgsinfo").path) {
            return root.deletingLastPathComponent()
        }
        throw ScanError.repository
    }

    public static func cachedReportURL(for repository: URL) throws -> URL {
        let root = try munkiRoot(for: repository)
        let hash = SHA256.hash(data: Data(root.path.utf8)).map { String(format: "%02x", $0) }.joined()
        let cache = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return cache.appending(path: "MunkiStudio/CVEReports/\(hash)/report.json")
    }

    public static func readReport(at url: URL) async throws -> PromoterCVEReport {
        try await Task.detached(priority: .userInitiated) {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= 25_000_000 else { throw CocoaError(.fileReadTooLarge) }
            let report = try JSONDecoder().decode(PromoterCVEReport.self, from: data)
            guard report.scanDate != nil else { throw CocoaError(.fileReadCorruptFile) }
            return report
        }.value
    }

    public enum ScanError: LocalizedError {
        case configuration, repository, failed(String)
        public var errorDescription: String? {
            switch self {
            case .configuration: "Set a valid CVE scanner script and Python executable in Settings → Promoter."
            case .repository: "The configured CVE scanner expects a Munki repository containing deployment/pkgsinfo."
            case .failed(let detail): "CVE scan failed. \(detail)"
            }
        }
    }
}
