import Foundation
import Core

/// File-backed `TestingService` implementation. Phase A: schema
/// validation from the in-memory snapshot + script lint over each script
/// slot in the pkginfo + a JSON checklist persisted under
/// `<repo>/.munkistudio/testing-checklist.json`.
public struct FileTestingService: TestingService {

    public init() {}

    // MARK: - Validation

    public func validate(
        _ record: PkginfoRecord,
        in snapshot: RepositorySnapshot
    ) async -> TestingResult {
        let started = Date()
        var steps: [TestingStepResult] = []

        steps.append(schemaStep(for: record, in: snapshot))
        steps.append(scriptLintStep(for: record))

        let finished = Date()
        return TestingResult(
            packageName: record.pkginfo.name,
            pkginfoURL: record.fileURL,
            steps: steps,
            startedAt: started,
            finishedAt: finished
        )
    }

    private func schemaStep(
        for record: PkginfoRecord,
        in snapshot: RepositorySnapshot
    ) -> TestingStepResult {
        let started = Date()
        let pkginfo = record.pkginfo
        var messages: [String] = []
        var severity: TestingStepResult.Severity = .success

        let loadError = snapshot.loadErrors.first { $0.fileURL == record.fileURL }
        if let loadError {
            messages.append("Parser: \(loadError.message)")
            severity = .error
        }

        if pkginfo.name.trimmingCharacters(in: .whitespaces).isEmpty {
            messages.append("Missing required field: name")
            severity = max(severity, .error)
        }
        if (pkginfo.version ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            messages.append("Missing required field: version")
            severity = max(severity, .error)
        }
        if let catalogs = pkginfo.catalogs, catalogs.isEmpty {
            messages.append("Catalogs array present but empty")
            severity = max(severity, .warning)
        } else if pkginfo.catalogs == nil {
            messages.append("No catalogs declared")
            severity = max(severity, .warning)
        }

        // Catalog membership — anything claimed should exist in the repo's
        // catalog projection. A typo here means the package never appears
        // on a client.
        let knownCatalogs = Set(snapshot.catalogs.map(\.name))
        for claimed in pkginfo.catalogs ?? [] {
            if !knownCatalogs.contains(claimed) {
                messages.append("Catalog '\(claimed)' is not declared by any other pkginfo")
                severity = max(severity, .warning)
            }
        }

        if let archs = pkginfo.supportedArchitectures {
            if Set(archs).count != archs.count {
                messages.append("Duplicate entries in supported_architectures")
                severity = max(severity, .warning)
            }
        }

        if messages.isEmpty {
            messages.append("Required fields present, catalogs known, architectures OK.")
        }

        return TestingStepResult(
            kind: .schema,
            title: "Schema check",
            success: severity != .error,
            severity: severity,
            messages: messages,
            duration: Date().timeIntervalSince(started)
        )
    }

    private func scriptLintStep(for record: PkginfoRecord) -> TestingStepResult {
        let started = Date()
        let pkginfo = record.pkginfo

        let slots: [(String, String?)] = [
            ("preinstall_script",     pkginfo.preinstallScript),
            ("postinstall_script",    pkginfo.postinstallScript),
            ("preuninstall_script",   pkginfo.preuninstallScript),
            ("postuninstall_script",  pkginfo.postuninstallScript),
            ("uninstall_script",      pkginfo.uninstallScript),
            ("version_script",        pkginfo.versionScript),
        ]

        var messages: [String] = []
        var severity: TestingStepResult.Severity = .success

        var present = 0
        for (slot, source) in slots {
            guard let source, !source.isEmpty else { continue }
            present += 1
            let language = ScriptLanguage.detect(in: source)
            let warnings = ScriptLinter.warnings(source, language: language)
            for warning in warnings {
                messages.append("\(slot): \(warning)")
                severity = max(severity, .warning)
            }
        }

        if present == 0 {
            messages.append("No scripts in this pkginfo.")
            severity = .info
        } else if messages.isEmpty {
            messages.append("\(present) script\(present == 1 ? "" : "s") clean.")
        }

        return TestingStepResult(
            kind: .scriptLint,
            title: "Script lint",
            success: severity != .error,
            severity: severity,
            messages: messages,
            duration: Date().timeIntervalSince(started)
        )
    }

    // MARK: - Checklist

    public func loadChecklist(in repository: MunkiRepository) async throws -> ChecklistStore {
        let url = Self.checklistURL(in: repository)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .empty
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ChecklistStore.self, from: data)
    }

    public func saveChecklist(
        _ store: ChecklistStore,
        in repository: MunkiRepository
    ) async throws {
        let url = Self.checklistURL(in: repository)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(store)
        try data.write(to: url, options: .atomic)
    }

    private static func checklistURL(in repository: MunkiRepository) -> URL {
        repository.rootURL
            .appending(path: ".munkistudio")
            .appending(path: "testing-checklist.json")
    }
}

private func max(
    _ lhs: TestingStepResult.Severity,
    _ rhs: TestingStepResult.Severity
) -> TestingStepResult.Severity {
    lhs > rhs ? lhs : rhs
}
