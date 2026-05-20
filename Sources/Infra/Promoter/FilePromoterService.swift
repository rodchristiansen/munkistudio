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
        // Imports + history happen in parallel — each is its own bounded
        // pipeline. History is the slow path (computing per-pkginfo
        // catalog deltas means calling `git show` per touched file), so
        // letting it overlap with imports halves the wait when the user
        // first lands on the Promoter tab.
        async let history = gitHistory(in: repository, limit: 25)
        async let imports = autopkgImports(in: repository, pkginfos: pkginfos, limit: 50)
        return PromoterSnapshot(
            config: config,
            imports: try await imports,
            candidates: candidates,
            history: try await history
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

    /// Read promoter-relevant commits touching the pkgsinfo subtree and
    /// compute per-pkginfo `before`/`after` catalog deltas so the
    /// history pane can show the actual transitions, not just file
    /// counts. AutoPkg-import commits are filtered out here — they are
    /// returned by ``autopkgImports(in:pkginfos:limit:)``.
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

        // Two-pass: parse the cheap metadata sequentially, then fan
        // out per-commit delta computation in parallel. Sequential
        // deltas were measuring 25+ seconds on real-size repos because
        // each touched file fires two `git show` invocations.
        struct CommitInfo: Sendable {
            let hash: String
            let date: Date
            let subject: String
        }
        var commits: [CommitInfo] = []
        for line in output.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3 else { continue }
            let subject = parts[2]
            guard subject.lowercased().hasPrefix("promoter") else { continue }
            guard let date = Self.parseISO8601(parts[1]) else { continue }
            commits.append(CommitInfo(hash: parts[0], date: date, subject: subject))
        }
        guard !commits.isEmpty else { return [] }

        let captured = self
        let entries = await withTaskGroup(of: (Int, PromotionHistoryEntry).self) { group in
            for (index, info) in commits.enumerated() {
                group.addTask {
                    let touched = await captured.affectedFiles(in: repository, commit: info.hash)
                    let deltas = await captured.deltas(in: repository, commit: info.hash, paths: touched)
                    return (index, PromotionHistoryEntry(
                        commitHash: info.hash,
                        date: info.date,
                        subject: info.subject,
                        deltas: deltas
                    ))
                }
            }
            var result: [(Int, PromotionHistoryEntry)] = []
            for await pair in group { result.append(pair) }
            result.sort { $0.0 < $1.0 }
            return result.map(\.1)
        }
        return entries
    }

    /// Read AutoPkg import commits and parse the pkginfo records they
    /// touched. One ``AutoPkgImport`` row per touched file. When the
    /// file no longer matches a current pkginfo (renamed / moved), we
    /// parse the file body at the introducing commit so the row still
    /// carries version + catalogs instead of falling back to "—".
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
                } else if let snapshot = await pkginfoSnapshotAtCommit(
                    in: repository,
                    commit: parts[0],
                    path: relativePath(url, base: repository.rootURL) ?? url.lastPathComponent
                ) {
                    imports.append(AutoPkgImport(
                        commitHash: parts[0],
                        date: date,
                        pkgName: snapshot.name ?? url.deletingPathExtension().lastPathComponent,
                        version: snapshot.version,
                        pkginfoURL: url,
                        catalogs: snapshot.catalogs
                    ))
                } else {
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

    fileprivate func affectedFiles(in repository: MunkiRepository, commit: String) async -> [URL] {
        let args = ["show", "--no-color", "--name-only", "--pretty=format:", commit]
        guard let output = try? await ProcessRunner.run(gitURL, arguments: args, in: repository.rootURL),
              output.exitCode == 0 else {
            return []
        }
        // `git show --name-only` emits paths relative to the GIT root,
        // which may not be the Munki repo root (e.g. when the Munki repo
        // is nested as `<git-root>/deployment/`). Append to the git root
        // so the resulting absolute URLs match `PkginfoRecord.fileURL`
        // exactly — otherwise every recordsByURL lookup misses and the
        // delta computation's pkgsinfo filter rejects every row.
        let base = await gitRootURL(workingDir: repository.rootURL) ?? repository.rootURL
        var urls: [URL] = []
        for raw in output.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            let path = String(raw).trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else { continue }
            urls.append(base.appending(path: path))
        }
        return urls
    }

    /// Resolve the git repository root containing `workingDir`. Returns
    /// `nil` if `workingDir` isn't inside a git tree at all.
    fileprivate func gitRootURL(workingDir: URL) async -> URL? {
        guard let output = try? await ProcessRunner.run(
            gitURL,
            arguments: ["rev-parse", "--show-toplevel"],
            in: workingDir
        ), output.exitCode == 0 else {
            return nil
        }
        let trimmed = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: trimmed)
    }

    /// Read pkginfo data at a specific commit (`git show <commit>:<path>`)
    /// and return the catalog/name/version triple. `nil` when the path
    /// doesn't exist in that commit (added, deleted, or renamed).
    fileprivate func pkginfoSnapshotAtCommit(
        in repository: MunkiRepository,
        commit: String,
        path: String
    ) async -> PkginfoCatalogSnapshot? {
        let args = ["show", "\(commit):\(path)"]
        guard let output = try? await ProcessRunner.run(gitURL, arguments: args, in: repository.rootURL),
              output.exitCode == 0 else {
            return nil
        }
        return Self.parsePkginfoSnapshot(text: output.stdout, path: path)
    }

    /// Compute the catalog deltas for every pkginfo touched by a single
    /// commit. Files-per-commit is capped (large promoter runs occasionally
    /// touch dozens of files) to keep per-commit work bounded; the UI
    /// surfaces the total count separately so the user knows when only a
    /// subset is detailed.
    fileprivate static let maxFilesPerCommit = 20

    fileprivate func deltas(
        in repository: MunkiRepository,
        commit: String,
        paths: [URL]
    ) async -> [PromotionDelta] {
        // Path comparisons happen against the git root so the same
        // logic works for both standard Munki layouts (`<repoRoot>/pkgsinfo`
        // == `<gitRoot>/pkgsinfo`) and nested layouts where the Munki
        // root is below the git root (e.g. `<gitRoot>/deployment/pkgsinfo`).
        let gitRoot = await gitRootURL(workingDir: repository.rootURL) ?? repository.rootURL
        let pkgsinfoRel = relativePath(repository.pkgsinfoURL, base: gitRoot) ?? "pkgsinfo"
        let candidates = paths
            .filter { url in
                (relativePath(url, base: gitRoot) ?? url.lastPathComponent)
                    .hasPrefix(pkgsinfoRel)
            }
            .prefix(Self.maxFilesPerCommit)
        guard !candidates.isEmpty else { return [] }
        let repo = repository
        let root = gitRoot
        let captured = self
        return await withTaskGroup(of: (Int, PromotionDelta?).self) { group in
            for (index, url) in candidates.enumerated() {
                group.addTask {
                    let rel = captured.relativePath(url, base: root) ?? url.lastPathComponent
                    async let after = captured.pkginfoSnapshotAtCommit(in: repo, commit: commit, path: rel)
                    async let before = captured.pkginfoSnapshotAtCommit(in: repo, commit: "\(commit)~1", path: rel)
                    let (afterSnap, beforeSnap) = await (after, before)
                    let name = afterSnap?.name ?? beforeSnap?.name ?? url.deletingPathExtension().lastPathComponent
                    return (index, PromotionDelta(
                        pkginfoURL: url,
                        pkgName: name,
                        version: afterSnap?.version ?? beforeSnap?.version,
                        before: beforeSnap?.catalogs ?? [],
                        after: afterSnap?.catalogs ?? []
                    ))
                }
            }
            var collected: [(Int, PromotionDelta)] = []
            for await (index, delta) in group {
                if let delta { collected.append((index, delta)) }
            }
            collected.sort { $0.0 < $1.0 }
            return collected.map(\.1)
        }
    }

    /// Tuple-ish snapshot of just the fields the Promoter UI needs from
    /// a pkginfo at a point in time. Public so the App layer and tests
    /// can reuse the parser without re-implementing it.
    public struct PkginfoCatalogSnapshot: Sendable, Hashable {
        public let name: String?
        public let version: String?
        public let catalogs: [String]

        public init(name: String?, version: String?, catalogs: [String]) {
            self.name = name
            self.version = version
            self.catalogs = catalogs
        }
    }

    /// Extract catalogs/name/version from a pkginfo text payload.
    /// Detects YAML vs. plist by file extension. Public so tests can
    /// exercise both formats directly.
    public static func parsePkginfoSnapshot(text: String, path: String) -> PkginfoCatalogSnapshot? {
        let lower = path.lowercased()
        if lower.hasSuffix(".yaml") || lower.hasSuffix(".yml") {
            guard let object = try? Yams.load(yaml: text) as? [String: Any] else { return nil }
            return PkginfoCatalogSnapshot(
                name: object["name"] as? String,
                version: Self.flexibleString(object["version"]),
                catalogs: (object["catalogs"] as? [String]) ?? []
            )
        }
        guard let data = text.data(using: .utf8),
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        return PkginfoCatalogSnapshot(
            name: object["name"] as? String,
            version: Self.flexibleString(object["version"]),
            catalogs: (object["catalogs"] as? [String]) ?? []
        )
    }

    private static func flexibleString(_ any: Any?) -> String? {
        if let string = any as? String { return string }
        if let int = any as? Int { return String(int) }
        if let double = any as? Double { return String(double) }
        return nil
    }

    fileprivate func relativePath(_ url: URL, base: URL) -> String? {
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
