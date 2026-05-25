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

    // MARK: - Autofix

    public func proposeAutofixes(
        for record: PkginfoRecord,
        in snapshot: RepositorySnapshot
    ) async -> AutofixProposal? {
        var pkginfo = record.pkginfo
        var changes: [AutofixChange] = []

        // 1) Dedupe supported_architectures, preserving first-seen order.
        if let archs = pkginfo.supportedArchitectures, Set(archs).count != archs.count {
            var seen: Set<SupportedArchitecture> = []
            var deduped: [SupportedArchitecture] = []
            for arch in archs where !seen.contains(arch) {
                seen.insert(arch)
                deduped.append(arch)
            }
            changes.append(
                AutofixChange(
                    field: "supported_architectures",
                    before: archs.map(\.rawValue).joined(separator: ", "),
                    after: deduped.map(\.rawValue).joined(separator: ", "),
                    rationale: "Removed duplicate entries from supported_architectures."
                )
            )
            pkginfo.supportedArchitectures = deduped
        }

        // 2) Empty catalogs array → nil. Munki defaults to "all catalogs"
        //    when the key is absent; an empty array is a no-op that
        //    confuses readers.
        if let catalogs = pkginfo.catalogs, catalogs.isEmpty {
            changes.append(
                AutofixChange(
                    field: "catalogs",
                    before: "[]",
                    after: "(removed)",
                    rationale: "Removed empty catalogs list — an empty array hides the package from every catalog."
                )
            )
            pkginfo.catalogs = nil
        }

        // 3) Sort catalogs alphabetically (case-insensitive) for stable diffs.
        if let catalogs = pkginfo.catalogs, catalogs.count > 1 {
            let sorted = catalogs.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            if sorted != catalogs {
                changes.append(
                    AutofixChange(
                        field: "catalogs",
                        before: catalogs.joined(separator: ", "),
                        after: sorted.joined(separator: ", "),
                        rationale: "Sorted catalogs alphabetically for stable PR diffs."
                    )
                )
                pkginfo.catalogs = sorted
            }
        }

        guard !changes.isEmpty else { return nil }
        return AutofixProposal(pkginfo: pkginfo, changes: changes)
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
        let jsonURL = Self.checklistURL(in: repository)
        try FileManager.default.createDirectory(
            at: jsonURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let json = try encoder.encode(store)
        try json.write(to: jsonURL, options: .atomic)

        // Markdown view — JSON stays canonical, but the .md round-trips
        // cleanly through `git diff` so reviewers can read the run
        // history without a JSON viewer. Modelled on Cimian's
        // quality/checklist.md.
        let markdown = Self.markdown(for: store)
        let mdURL = Self.checklistMarkdownURL(in: repository)
        try markdown.data(using: .utf8)?.write(to: mdURL, options: .atomic)
    }

    private static func checklistURL(in repository: MunkiRepository) -> URL {
        repository.rootURL
            .appending(path: ".munkistudio")
            .appending(path: "testing-checklist.json")
    }

    private static func checklistMarkdownURL(in repository: MunkiRepository) -> URL {
        repository.rootURL
            .appending(path: ".munkistudio")
            .appending(path: "testing-checklist.md")
    }

    private static func markdown(for store: ChecklistStore) -> String {
        let isoFormatter = ISO8601DateFormatter()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        dateFormatter.timeZone = TimeZone(identifier: "UTC")

        let totals = ChecklistTotals(store: store)
        var lines: [String] = []
        lines.append("# Testing Checklist")
        lines.append("")
        lines.append("Canonical store: `.munkistudio/testing-checklist.json` (this file is auto-generated).")
        lines.append("")
        lines.append("**\(totals.pass) ✅ pass** · **\(totals.warning) ⚠️ warning** · **\(totals.fail) ❌ fail** · **\(totals.untested) ⚪ untested** · total \(totals.total)")
        lines.append("")
        lines.append("| Package | Version | Status | Tester | Tested | Notes |")
        lines.append("|---|---|---|---|---|---|")
        for entry in store.items {
            let symbol: String
            switch entry.status {
            case .untested: symbol = "⚪ untested"
            case .pass:     symbol = "✅ pass"
            case .warning:  symbol = "⚠️ warning"
            case .fail:     symbol = "❌ fail"
            }
            let version = entry.version ?? "—"
            let tester = (entry.tester?.isEmpty == false ? entry.tester! : "—")
            let testedAt: String
            if let date = entry.testedAt {
                testedAt = dateFormatter.string(from: date)
            } else {
                testedAt = "—"
            }
            let notes = (entry.notes ?? "")
                .replacingOccurrences(of: "|", with: "\\|")
                .replacingOccurrences(of: "\n", with: " ")
            lines.append("| \(entry.packageName) | \(version) | \(symbol) | \(tester) | \(testedAt) | \(notes) |")
        }
        lines.append("")
        lines.append("_Last generated \(isoFormatter.string(from: Date()))_")
        lines.append("")
        return lines.joined(separator: "\n")
    }
}

private struct ChecklistTotals {
    var total: Int = 0
    var pass: Int = 0
    var warning: Int = 0
    var fail: Int = 0
    var untested: Int = 0

    init(store: ChecklistStore) {
        total = store.items.count
        for item in store.items {
            switch item.status {
            case .pass: pass += 1
            case .warning: warning += 1
            case .fail: fail += 1
            case .untested: untested += 1
            }
        }
    }
}

private func max(
    _ lhs: TestingStepResult.Severity,
    _ rhs: TestingStepResult.Severity
) -> TestingStepResult.Severity {
    lhs > rhs ? lhs : rhs
}
