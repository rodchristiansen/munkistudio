import Foundation
import Observation
import Core
import Infra

/// App-scoped store for the Promoter feature. Loaded into the
/// `Environment` by `MunkiStudioApp` so both the Promoter tab and
/// other surfaces (Dashboard stat tiles, future search hits) can read
/// the same snapshot without re-shelling git.
@Observable
@MainActor
final class PromoterStore {
    var snapshot: PromoterSnapshot = .empty
    var loading: Bool = false
    var busyURL: URL?
    var errorMessage: String?
    var cveReport: PromoterCVEReport?
    var cveReportURL: URL?
    var cveRepositoryURL: URL?
    var cveLoading = false
    var cveError: String?
    var cveScanning = false
    var cveScanProgress = ""
    var cveScanSnapshot: CVEScanProgress?
    var cveScanStartedAt: Date?
    var cveScanLastUpdate: Date?
    @ObservationIgnored private var cveScanTask: Task<Void, Never>?
    private var cveRequestID = UUID()

    func clearCVEReport() {
        cancelCVEScan()
        cveRequestID = UUID()
        cveReport = nil
        cveReportURL = nil
        cveRepositoryURL = nil
        cveError = nil
        cveLoading = false
        cveScanProgress = ""
        cveScanSnapshot = nil
        cveScanStartedAt = nil
        cveScanLastUpdate = nil
    }

    func cancelCVEScan() {
        cveRequestID = UUID()
        cveScanTask?.cancel()
        cveScanTask = nil
        if cveScanning { cveScanProgress = "Scan cancelled; the previous report is retained." }
        cveScanning = false
    }

    @discardableResult
    func startCVEScan(repositoryURL: URL, scriptPath: String, pythonPath: String) -> Task<Void, Never>? {
        guard !cveScanning && !cveLoading else { return nil }
        cveError = nil
        guard !scriptPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !pythonPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            cveError = LocalCVEScanner.ScanError.configuration.localizedDescription
            return nil
        }
        let scanner: LocalCVEScanner
        do {
            scanner = try LocalCVEScanner(repositoryURL: repositoryURL,
                                          scriptURL: URL(fileURLWithPath: scriptPath),
                                          pythonURL: URL(fileURLWithPath: pythonPath))
        } catch {
            cveError = error.localizedDescription
            return nil
        }
        cveRequestID = UUID()
        let requestID = cveRequestID
        cveRepositoryURL = repositoryURL
        cveScanning = true
        cveScanProgress = "Starting fresh CVE scan…"
        cveScanSnapshot = nil
        cveScanStartedAt = Date()
        cveScanLastUpdate = nil
        let task = Task {
            var output: [String] = []
            do {
                var exitCode: Int32?
                for try await event in try scanner.events() {
                    try Task.checkCancellation()
                    guard requestID == cveRequestID else { return }
                    switch event {
                    case .line(let line):
                        output.append(line)
                        if output.count > 8 { output.removeFirst() }
                        if let progress = CVEScanProgress.parse(line) {
                            cveScanSnapshot = progress
                            cveScanLastUpdate = Date()
                            cveScanProgress = progress.summary
                        } else if cveScanSnapshot == nil, !line.isEmpty {
                            cveScanProgress = line.hasPrefix("Checked ") ? "Last completed app: " + line.dropFirst(8) : line
                        }
                    case .terminated(let code): exitCode = code
                    }
                }
                try Task.checkCancellation()
                guard exitCode == 0 else { throw LocalCVEScanner.ScanError.failed(output.joined(separator: "\n")) }
                let report = try await LocalCVEScanner.readReport(at: scanner.reportURL)
                guard requestID == cveRequestID else { return }
                cveReport = report
                cveReportURL = scanner.reportURL
                cveScanProgress = "Scan complete: \(report.scannedPackages) apps, \(report.failedRequests) request failures."
            } catch is CancellationError {
                if requestID == cveRequestID { cveScanProgress = "Scan cancelled; the previous report is retained." }
            } catch {
                if requestID == cveRequestID { cveError = error.localizedDescription }
            }
            if requestID == cveRequestID {
                cveScanning = false
                cveScanTask = nil
            }
        }
        cveScanTask = task
        return task
    }

    func loadCVEReport(from url: URL, repositoryURL: URL) async {
        guard !cveScanning else { return }
        cveRequestID = UUID()
        let requestID = cveRequestID
        cveLoading = true
        cveError = nil
        do {
            let report = try await LocalCVEScanner.readReport(at: url)
            guard requestID == cveRequestID else { return }
            cveReport = report
            cveReportURL = url
            cveRepositoryURL = repositoryURL
        } catch {
            guard requestID == cveRequestID else { return }
            cveError = "Could not read the CVE report: \(error.localizedDescription)"
        }
        if requestID == cveRequestID { cveLoading = false }
    }

    enum Action {
        case promote(PromotionCandidate)
        case defer_(PromotionCandidate)
    }

    func refresh(store: RepositoryStore, deploymentRoot: URL?) async {
        guard let repo = store.repository, let deploymentRoot else {
            snapshot = .empty
            return
        }
        loading = true
        defer { loading = false }
        do {
            snapshot = try await store.services.promoter.snapshot(
                repository: repo,
                deploymentRoot: deploymentRoot,
                pkginfos: store.snapshot.pkginfos
            )
        } catch {
            snapshot = .empty
            errorMessage = error.localizedDescription
        }
    }

    func apply(_ action: Action, store: RepositoryStore) async {
        let candidate: PromotionCandidate
        switch action {
        case .promote(let c): candidate = c
        case .defer_(let c): candidate = c
        }
        busyURL = candidate.pkginfoURL
        defer { busyURL = nil }
        do {
            let updated: PkginfoRecord
            switch action {
            case .promote(let c):
                updated = try await store.services.promoter.promote(c, in: store.snapshot.pkginfos)
            case .defer_(let c):
                updated = try await store.services.promoter.defer_(c, in: store.snapshot.pkginfos)
            }
            store.upsert(updated)
            // Recompute candidates against the new pkginfo state — no
            // need to re-shell git for imports / history, since neither
            // changed.
            let config = snapshot.config
            let recomputed = FilePromoterService.candidates(
                from: store.snapshot.pkginfos,
                config: config,
                now: Date()
            )
            snapshot = PromoterSnapshot(
                config: config,
                imports: snapshot.imports,
                candidates: recomputed,
                history: snapshot.history
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
