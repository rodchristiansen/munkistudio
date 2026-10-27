import Foundation
import Testing
import Core
import Infra
@testable import App

@Suite("Fresh CVE scan workflow")
@MainActor
struct CVEScanTests {
    private let reportJSON = #"{"generatedAt":"2026-10-26T12:00:00Z","scannedPackages":1,"failedRequests":0,"applications":[{"name":"ExampleApp","productionVersion":"1.0","lookupStatus":"queried"}],"patchFindings":[]}"#

    private func fixture(script: String) throws -> (URL, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "CVE scanner \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "deployment/pkgsinfo"), withIntermediateDirectories: true)
        let url = root.appending(path: "scanner with spaces.sh")
        try script.write(to: url, atomically: true, encoding: .utf8)
        return (root, url, try LocalCVEScanner.cachedReportURL(for: root))
    }

    private func cleanup(_ fixture: (URL, URL, URL)) {
        try? FileManager.default.removeItem(at: fixture.0)
        try? FileManager.default.removeItem(at: fixture.2.deletingLastPathComponent())
    }

    private func seedReport(_ store: PromoterStore, root: URL) async throws {
        let url = root.appending(path: "previous.json")
        try reportJSON.write(to: url, atomically: true, encoding: .utf8)
        await store.loadCVEReport(from: url, repositoryURL: root)
    }

    @Test("successful scan streams progress and replaces the report using literal paths")
    func success() async throws {
        let script = """
        while [ "$#" -gt 0 ]; do
            case "$1" in --output) output="$2"; shift 2 ;; *) shift ;; esac
        done
        echo 'Checked ExampleApp: complete'
        cat > "$output" <<'JSON'
        \(reportJSON)
        JSON
        """
        let value = try fixture(script: script)
        defer { cleanup(value) }
        let runner = try LocalCVEScanner(repositoryURL: value.0.appending(path: "deployment"), scriptURL: value.1,
                                        pythonURL: URL(fileURLWithPath: "/bin/sh"))
        #expect(runner.repositoryURL == value.0.standardizedFileURL.resolvingSymlinksInPath())
        #expect(runner.arguments.contains(value.1.path))
        let store = PromoterStore()
        let task = try #require(store.startCVEScan(repositoryURL: value.0, scriptPath: value.1.path, pythonPath: "/bin/sh"))
        #expect(store.cveScanning)
        #expect(store.startCVEScan(repositoryURL: value.0, scriptPath: value.1.path, pythonPath: "/bin/sh") == nil)
        await task.value
        #expect(!store.cveScanning)
        #expect(store.cveError == nil)
        #expect(store.cveReport?.scannedPackages == 1)
        #expect(store.cveReportURL == value.2)
        #expect(store.cveScanProgress.contains("Scan complete"))
    }

    @Test("failed scans preserve the previous visible report")
    func failure() async throws {
        let value = try fixture(script: "echo 'Test scanner failed' >&2\nexit 23\n")
        defer { cleanup(value) }
        let store = PromoterStore()
        try await seedReport(store, root: value.0)
        let previousURL = store.cveReportURL
        let task = try #require(store.startCVEScan(repositoryURL: value.0, scriptPath: value.1.path, pythonPath: "/bin/sh"))
        await task.value
        #expect(store.cveReportURL == previousURL)
        #expect(store.cveReport?.scannedPackages == 1)
        #expect(store.cveError?.contains("Test scanner failed") == true)
        #expect(!store.cveScanning)
    }

    @Test("invalid saved results cannot replace valid evidence")
    func invalidReport() async throws {
        let value = try fixture(script: "exit 0\n")
        defer { cleanup(value) }
        let store = PromoterStore()
        try await seedReport(store, root: value.0)
        let previousURL = store.cveReportURL
        let invalid = value.0.appending(path: "bad.json")
        try "{}".write(to: invalid, atomically: true, encoding: .utf8)
        await store.loadCVEReport(from: invalid, repositoryURL: value.0)
        #expect(store.cveReportURL == previousURL)
        #expect(store.cveError != nil)
    }

    @Test("cancelling a scan retains previous evidence and permits another scan")
    func cancellation() async throws {
        let value = try fixture(script: "exec /bin/sleep 30\n")
        defer { cleanup(value) }
        let store = PromoterStore()
        try await seedReport(store, root: value.0)
        let previousURL = store.cveReportURL
        let task = try #require(store.startCVEScan(repositoryURL: value.0, scriptPath: value.1.path, pythonPath: "/bin/sh"))
        await Task.yield()
        store.cancelCVEScan()
        await task.value
        #expect(!store.cveScanning)
        #expect(store.cveReportURL == previousURL)
        #expect(store.cveScanProgress.contains("cancelled"))
    }

    @Test("missing configuration reports an actionable error")
    func missingConfiguration() {
        let store = PromoterStore()
        let task = store.startCVEScan(repositoryURL: URL(fileURLWithPath: "/missing"), scriptPath: "", pythonPath: "")
        #expect(task == nil)
        #expect(store.cveError?.contains("Settings") == true)
        #expect(!store.cveScanning)
    }

    @Test("scanner configuration persists and resets with the other settings")
    func settings() throws {
        let suite = "MunkiStudio.CVEScanTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.cveScannerScript = "/tools/scanner.py"
        settings.cvePythonExecutable = "/tools/python"
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.cveScannerScript == "/tools/scanner.py")
        #expect(reloaded.cvePythonExecutable == "/tools/python")
        reloaded.resetToDefaults()
        let reset = AppSettings(defaults: defaults)
        #expect(reset.cveScannerScript.isEmpty)
        #expect(reset.cvePythonExecutable.isEmpty)
    }
}
