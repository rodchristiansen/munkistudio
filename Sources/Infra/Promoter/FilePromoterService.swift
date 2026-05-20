import Foundation
import Core
import Yams

/// File-backed `PromoterService`. Reads `promoter.yml` with Yams, builds
/// the candidate list from the open repository's pkginfo snapshot, and
/// shells out to git for the import / history feeds.
public struct FilePromoterService: PromoterService {
    private let packages: any PackageService
    private let gitURL: URL
    private let now: @Sendable () -> Date

    public init(
        packages: any PackageService,
        gitURL: URL = URL(fileURLWithPath: "/usr/bin/git"),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.packages = packages
        self.gitURL = gitURL
        self.now = now
    }

    // MARK: Config

    public func loadConfig(at deploymentRoot: URL) async throws -> PromoterConfig {
        let configURL = deploymentRoot.appending(path: "promoter.yml")
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return PromoterConfig(rules: [])
        }
        let data = try Data(contentsOf: configURL)
        let text = String(decoding: data, as: UTF8.self)
        return try Self.parseConfig(text)
    }

    /// Parse a `promoter.yml` payload. Public-static so tests can call
    /// it without a service instance.
    public static func parseConfig(_ text: String) throws -> PromoterConfig {
        let yaml = try Yams.load(yaml: text) as? [String: Any] ?? [:]
        let promotionsAny = yaml["promotions"] as? [String: Any] ?? [:]
        var rules: [PromotionRule] = []
        for (name, body) in promotionsAny {
            guard let dict = body as? [String: Any] else { continue }
            let promoteFrom = (dict["promote_from"] as? [String]) ?? []
            let promoteTo = (dict["promote_to"] as? [String]) ?? []
            let daysInCatalog = (dict["days_in_catalog"] as? Int) ?? 1
            var customItems: [String: PromotionRule.ItemOverride] = [:]
            if let custom = dict["custom_items"] as? [String: Any] {
                for (pattern, overrideAny) in custom {
                    if let overrideDict = overrideAny as? [String: Any],
                       let days = overrideDict["days_in_catalog"] as? Int {
                        customItems[pattern] = PromotionRule.ItemOverride(daysInCatalog: days)
                    }
                }
            }
            rules.append(PromotionRule(
                name: name,
                promoteFrom: promoteFrom,
                promoteTo: promoteTo,
                daysInCatalog: daysInCatalog,
                customItems: customItems
            ))
        }
        // Stable display order: ascending by source-set size, then name.
        rules.sort {
            if $0.promoteFrom.count != $1.promoteFrom.count {
                return $0.promoteFrom.count < $1.promoteFrom.count
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return PromoterConfig(rules: rules)
    }

    // MARK: Snapshot

    public func snapshot(
        repository: MunkiRepository,
        deploymentRoot: URL,
        pkginfos: [PkginfoRecord]
    ) async throws -> PromoterSnapshot {
        let config = try await loadConfig(at: deploymentRoot)
        let candidates = Self.candidates(from: pkginfos, config: config, now: now())
        let history = try await gitHistory(in: repository, limit: 50)
        let imports = try await autopkgImports(in: repository, pkginfos: pkginfos, limit: 50)
        return PromoterSnapshot(
            config: config,
            imports: imports,
            candidates: candidates,
            history: history
        )
    }

    /// Pure function so the candidate computation is unit-testable
    /// without disk or git access.
    public static func candidates(
        from pkginfos: [PkginfoRecord],
        config: PromoterConfig,
        now: Date
    ) -> [PromotionCandidate] {
        guard !config.rules.isEmpty else { return [] }
        var result: [PromotionCandidate] = []
        for record in pkginfos {
            let catalogs = record.pkginfo.catalogs ?? []
            guard let rule = config.nextRule(forCatalogs: catalogs) else { continue }
            let editDate = lastEditDate(for: record) ?? record.modifiedAt ?? now
            let days = rule.daysInCatalog(for: record.pkginfo.name)
            result.append(PromotionCandidate(
                pkginfoURL: record.fileURL,
                pkgName: record.pkginfo.name,
                version: record.pkginfo.version,
                currentCatalogs: catalogs,
                targetCatalogs: rule.promoteTo,
                ruleName: rule.name,
                lastEditDate: editDate,
                requiredDays: days
            ))
        }
        // Eligible first, then by days remaining ascending, then by name.
        result.sort { lhs, rhs in
            let lhsEligible = lhs.isEligible(on: now)
            let rhsEligible = rhs.isEligible(on: now)
            if lhsEligible != rhsEligible { return lhsEligible && !rhsEligible }
            let lhsDays = lhs.daysRemaining(on: now)
            let rhsDays = rhs.daysRemaining(on: now)
            if lhsDays != rhsDays { return lhsDays < rhsDays }
            return lhs.pkgName.localizedCaseInsensitiveCompare(rhs.pkgName) == .orderedAscending
        }
        return result
    }

    // MARK: Actions

    public func promote(
        _ candidate: PromotionCandidate,
        in pkginfos: [PkginfoRecord]
    ) async throws -> PkginfoRecord {
        guard let record = pkginfos.first(where: { $0.fileURL == candidate.pkginfoURL }) else {
            throw PromoterError.recordNotFound
        }
        var pkginfo = record.pkginfo
        pkginfo.catalogs = candidate.targetCatalogs
        pkginfo.metadata = Self.stampedMetadata(pkginfo.metadata, date: now())
        let updated = PkginfoRecord(
            pkginfo: pkginfo,
            fileURL: record.fileURL,
            format: record.format,
            createdAt: record.createdAt,
            modifiedAt: now()
        )
        try await packages.save(updated)
        return updated
    }

    public func defer_(
        _ candidate: PromotionCandidate,
        in pkginfos: [PkginfoRecord]
    ) async throws -> PkginfoRecord {
        guard let record = pkginfos.first(where: { $0.fileURL == candidate.pkginfoURL }) else {
            throw PromoterError.recordNotFound
        }
        var pkginfo = record.pkginfo
        pkginfo.metadata = Self.stampedMetadata(pkginfo.metadata, date: now())
        let updated = PkginfoRecord(
            pkginfo: pkginfo,
            fileURL: record.fileURL,
            format: record.format,
            createdAt: record.createdAt,
            modifiedAt: now()
        )
        try await packages.save(updated)
        return updated
    }

    // MARK: Metadata helpers

    /// Extract the canonical edit date from a pkginfo record. Prefers
    /// `munki-promoter_edit_date`, falls back to `creation_date`, then
    /// to `nil` so the caller can substitute `modifiedAt`.
    public static func lastEditDate(for record: PkginfoRecord) -> Date? {
        let metadata = record.pkginfo.metadata ?? [:]
        if let value = metadata["munki-promoter_edit_date"], let date = dateFromPlistValue(value) {
            return date
        }
        if let value = metadata["creation_date"], let date = dateFromPlistValue(value) {
            return date
        }
        return nil
    }

    private static func dateFromPlistValue(_ value: PlistValue) -> Date? {
        switch value {
        case .date(let date): return date
        case .string(let text): return parseISO8601(text)
        default: return nil
        }
    }

    private static func stampedMetadata(
        _ existing: [String: PlistValue]?,
        date: Date
    ) -> [String: PlistValue] {
        var metadata = existing ?? [:]
        metadata["munki-promoter_edit_date"] = .string(formatISO8601(date))
        return metadata
    }

    /// Parse `2026-05-19T14:14:20Z` and the fractional-seconds variant.
    /// Returns nil on anything else — defensive because pkginfo metadata
    /// is open-shape and external tools can write any string.
    static func parseISO8601(_ text: String) -> Date? {
        if let date = try? Date(text, strategy: .iso8601) { return date }
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        return try? Date(text, strategy: fractional)
    }

    static func formatISO8601(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    // MARK: Git feeds

    /// Read promoter-relevant commits touching the pkgsinfo subtree.
    /// Excludes the AutoPkg import commits — those are returned by
    /// `autopkgImports(in:)`.
    private func gitHistory(
        in repository: MunkiRepository,
        limit: Int
    ) async throws -> [PromotionHistoryEntry] {
        let pkgsinfoRel = relativePath(repository.pkgsinfoURL, base: repository.rootURL) ?? "pkgsinfo"
        let format = "%H%x1f%cI%x1f%s"
        let args = [
            "log",
            "--max-count=\(limit)",
            "--pretty=format:" + format,
            "--",
            pkgsinfoRel
        ]
        let output = try await ProcessRunner.run(gitURL, arguments: args, in: repository.rootURL)
        guard output.exitCode == 0 else { return [] }
        var entries: [PromotionHistoryEntry] = []
        for line in output.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3 else { continue }
            let subject = parts[2]
            // Keep only the promoter commits — AutoPkg imports go in the
            // imports feed and would otherwise clutter the history pane.
            guard subject.lowercased().hasPrefix("promoter") else { continue }
            guard let date = Self.parseISO8601(parts[1]) else { continue }
            let affected = await affectedFiles(in: repository, commit: parts[0])
            entries.append(PromotionHistoryEntry(
                commitHash: parts[0],
                date: date,
                subject: subject,
                affected: affected
            ))
        }
        return entries
    }

    /// Read AutoPkg import commits and parse the pkginfo records they
    /// touched. Each commit can introduce multiple pkginfo files; one
    /// `AutoPkgImport` row is emitted per file.
    private func autopkgImports(
        in repository: MunkiRepository,
        pkginfos: [PkginfoRecord],
        limit: Int
    ) async throws -> [AutoPkgImport] {
        let pkgsinfoRel = relativePath(repository.pkgsinfoURL, base: repository.rootURL) ?? "pkgsinfo"
        let format = "%H%x1f%cI%x1f%s"
        let args = [
            "log",
            "--max-count=\(limit * 2)",
            "--pretty=format:" + format,
            "--",
            pkgsinfoRel
        ]
        let output = try await ProcessRunner.run(gitURL, arguments: args, in: repository.rootURL)
        guard output.exitCode == 0 else { return [] }
        var imports: [AutoPkgImport] = []
        // Map URL → record so we can resolve each touched file back to
        // its current name/version/catalogs without re-parsing.
        let recordsByURL = Dictionary(uniqueKeysWithValues: pkginfos.map { ($0.fileURL.standardizedFileURL.path, $0) })
        for line in output.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3 else { continue }
            let subject = parts[2]
            guard subject.lowercased().hasPrefix("autopkg import") else { continue }
            guard let date = Self.parseISO8601(parts[1]) else { continue }
            let touched = await affectedFiles(in: repository, commit: parts[0])
            for url in touched {
                let path = url.standardizedFileURL.path
                if let record = recordsByURL[path] {
                    imports.append(AutoPkgImport(
                        commitHash: parts[0],
                        date: date,
                        pkgName: record.pkginfo.name,
                        version: record.pkginfo.version,
                        pkginfoURL: url,
                        catalogs: record.pkginfo.catalogs ?? []
                    ))
                } else {
                    // File no longer exists in the repo (renamed,
                    // deleted, or moved); still surface the row so the
                    // history is honest, just without resolved metadata.
                    let bare = url.deletingPathExtension().lastPathComponent
                    imports.append(AutoPkgImport(
                        commitHash: parts[0],
                        date: date,
                        pkgName: bare,
                        version: nil,
                        pkginfoURL: url,
                        catalogs: []
                    ))
                }
            }
            if imports.count >= limit { break }
        }
        return imports
    }

    private func affectedFiles(in repository: MunkiRepository, commit: String) async -> [URL] {
        let args = ["show", "--no-color", "--name-only", "--pretty=format:", commit]
        guard let output = try? await ProcessRunner.run(gitURL, arguments: args, in: repository.rootURL),
              output.exitCode == 0 else {
            return []
        }
        var urls: [URL] = []
        for raw in output.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            let path = String(raw).trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else { continue }
            urls.append(repository.rootURL.appending(path: path))
        }
        return urls
    }

    private func relativePath(_ url: URL, base: URL) -> String? {
        let urlComponents = url.standardizedFileURL.pathComponents
        let baseComponents = base.standardizedFileURL.pathComponents
        guard urlComponents.starts(with: baseComponents) else { return nil }
        let tail = urlComponents.dropFirst(baseComponents.count)
        return tail.joined(separator: "/")
    }

}

public enum PromoterError: Error, LocalizedError {
    case recordNotFound

    public var errorDescription: String? {
        switch self {
        case .recordNotFound:
            return "The pkginfo record for this candidate is no longer in the open repository."
        }
    }
}
