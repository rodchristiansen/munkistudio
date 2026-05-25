import Foundation

/// Testing runner for Munki packages.
///
/// Phase A scope: static validation (schema + script smells) and a
/// repo-local checklist (`<repo>/.munkistudio/testing-checklist.json`)
/// that round-trips with the team. Later phases add build, install, and
/// uninstall steps backed by an ephemeral macOS VM.
///
/// Concrete implementation lives in Infra (`FileTestingService`). Keep
/// the protocol Munki-agnostic — the Cimian/Windows side has its own
/// runner (`fleetmate-windows`) using the same shape.
public protocol TestingService: Sendable {
    /// Validate a single pkginfo against the Phase-A static rules.
    /// Snapshot is passed in so cross-file checks (catalog membership,
    /// duplicate names) have the data they need without re-walking disk.
    func validate(
        _ record: PkginfoRecord,
        in snapshot: RepositorySnapshot
    ) async -> TestingResult

    /// Propose safe autofixes for a single pkginfo (Phase A.5). Returns
    /// `nil` when no autofix-able warning applies. The proposal carries
    /// the updated `Pkginfo` ready to write — the caller (UI) is in
    /// charge of confirming and persisting.
    func proposeAutofixes(
        for record: PkginfoRecord,
        in snapshot: RepositorySnapshot
    ) async -> AutofixProposal?

    /// Phase B.1: run a real `munkipkg --build` against `project` and
    /// surface the result as a single step. Streams the output and
    /// collapses it into one ``TestingStepResult`` for the timeline.
    func validateBuild(
        project: MunkipkgProject,
        munkipkg: any MunkipkgService
    ) async -> TestingStepResult

    /// Phase B.2: check the deployed `.pkg` / `.dmg` for the pkginfo's
    /// `installer_item_location` — existence, size, and (for `.pkg`)
    /// `pkgutil --check-signature`.
    func validateBuildArtifact(
        _ record: PkginfoRecord,
        in repository: MunkiRepository
    ) async -> TestingStepResult

    /// Phase C.3: install the package inside `environment`. Copies the
    /// artifact under `repository.pkgsURL` into the guest and runs
    /// `installer(8)`; captures exit status + the tail of the log.
    func validateInstall(
        _ record: PkginfoRecord,
        in repository: MunkiRepository,
        environment: any TestEnvironment
    ) async -> TestingStepResult

    /// Phase C.3: walk the pkginfo's `installs[]` array inside the
    /// guest, asserting each path / bundle is present after the
    /// install step.
    func validateInstallsArray(
        _ record: PkginfoRecord,
        environment: any TestEnvironment
    ) async -> TestingStepResult

    /// Phase C.3: run the configured uninstall path inside the guest.
    /// v1 understands `uninstall_method: uninstall_script` (and
    /// implicit `uninstall_script` presence); other methods report
    /// "not implemented" until they're added.
    func validateUninstall(
        _ record: PkginfoRecord,
        environment: any TestEnvironment
    ) async -> TestingStepResult

    /// Write a per-run JSON results document under
    /// `.munkistudio/testing-results/`. Returns the URL of the written
    /// file so the UI can offer "Reveal in Finder" affordances.
    @discardableResult
    func exportResults(
        _ results: [TestingResult],
        in repository: MunkiRepository
    ) async throws -> URL

    /// Load the checklist for a repository. Missing file → empty store.
    func loadChecklist(in repository: MunkiRepository) async throws -> ChecklistStore

    /// Persist a checklist back to disk under `.munkistudio/`. Implementations
    /// also write a Markdown view next to the canonical JSON so the file
    /// reviews well in PR diffs.
    func saveChecklist(_ store: ChecklistStore, in repository: MunkiRepository) async throws
}

// MARK: - Autofix

/// A bundle of automatic edits a `TestingService` is willing to apply
/// to one pkginfo. Each `AutofixChange` is one field-level edit with a
/// rationale so the UI can render a reviewable diff.
public struct AutofixProposal: Sendable, Hashable {
    public var pkginfo: Pkginfo
    public var changes: [AutofixChange]

    public init(pkginfo: Pkginfo, changes: [AutofixChange]) {
        self.pkginfo = pkginfo
        self.changes = changes
    }
}

public struct AutofixChange: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var field: String
    public var before: String
    public var after: String
    public var rationale: String

    public init(
        id: UUID = UUID(),
        field: String,
        before: String,
        after: String,
        rationale: String
    ) {
        self.id = id
        self.field = field
        self.before = before
        self.after = after
        self.rationale = rationale
    }
}

// MARK: - Result types

/// One full Testing run on one package: ordered step results plus
/// aggregate counters. Mirrors the C# `QaResult` shape in
/// `fleetmate-windows`.
public struct TestingResult: Sendable, Hashable, Identifiable, Codable {
    public var packageName: String
    public var pkginfoURL: URL
    public var steps: [TestingStepResult]
    public var startedAt: Date
    public var finishedAt: Date

    public var id: URL { pkginfoURL }
    public var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }
    public var total: Int { steps.count }
    public var passed: Int { steps.filter(\.success).count }
    public var failed: Int { steps.filter { !$0.success && $0.severity == .error }.count }
    public var warnings: Int { steps.filter { $0.severity == .warning }.count }
    public var success: Bool { failed == 0 && total > 0 }

    public init(
        packageName: String,
        pkginfoURL: URL,
        steps: [TestingStepResult],
        startedAt: Date,
        finishedAt: Date
    ) {
        self.packageName = packageName
        self.pkginfoURL = pkginfoURL
        self.steps = steps
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

/// One step in a Testing run. `messages` are user-facing; `details` is a
/// free-form bag the UI's detail inspector can render in raw form.
public struct TestingStepResult: Sendable, Hashable, Identifiable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case schema          // pkginfo required fields, catalog membership, arch
        case scriptLint      // pre/postinstall script smells
        case build           // munkipkg --build (Phase B.1)
        case buildArtifact   // .pkg present + signed (Phase B.2)
        case install         // ephemeral install (Phase C)
        case installsCheck   // walk installs[] inside guest (Phase C)
        case uninstall       // uninstall test (Phase C)
    }

    public enum Severity: Int, Sendable, Hashable, Codable, Comparable {
        case info, success, warning, error

        public static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public var id: UUID
    public var kind: Kind
    public var title: String
    public var success: Bool
    public var severity: Severity
    public var messages: [String]
    public var duration: TimeInterval

    public init(
        id: UUID = UUID(),
        kind: Kind,
        title: String,
        success: Bool,
        severity: Severity,
        messages: [String] = [],
        duration: TimeInterval = 0
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.success = success
        self.severity = severity
        self.messages = messages
        self.duration = duration
    }
}

// MARK: - Checklist

/// A repo-local Testing checklist. One row per package the team has
/// decided to track. The Cimian original is a flat Markdown table; we
/// keep the JSON shape canonical and round-trip a Markdown view for
/// human diffs.
public struct ChecklistStore: Sendable, Hashable, Codable {
    public var items: [ChecklistEntry]

    public init(items: [ChecklistEntry] = []) {
        self.items = items
    }

    public static let empty = ChecklistStore()
}

public struct ChecklistEntry: Sendable, Hashable, Identifiable, Codable {
    public var id: UUID
    public var packageName: String
    public var version: String?
    public var status: ChecklistStatus
    public var tester: String?
    public var testedAt: Date?
    public var notes: String?

    public init(
        id: UUID = UUID(),
        packageName: String,
        version: String? = nil,
        status: ChecklistStatus = .untested,
        tester: String? = nil,
        testedAt: Date? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.packageName = packageName
        self.version = version
        self.status = status
        self.tester = tester
        self.testedAt = testedAt
        self.notes = notes
    }
}

public enum ChecklistStatus: String, Sendable, Hashable, Codable, CaseIterable {
    case untested
    case pass
    case warning
    case fail
}
