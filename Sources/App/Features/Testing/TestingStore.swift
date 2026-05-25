import Foundation
import Observation
import Core

/// State for the Testing pane. Holds the checklist mirror, the
/// currently selected entry's most recent ``TestingResult``, and any in-flight
/// run. Persistence flows through `TestingService` so the same file shape can
/// be read by CI or a future CLI.
@MainActor
@Observable
final class TestingStore {

    enum Phase: Equatable {
        case idle
        case validating(packageName: String)
        case validatingAll(current: Int, total: Int, packageName: String)
        case ready
    }

    /// Outcome of the most recent bulk-validate run, surfaced as a
    /// banner above the checklist.
    struct BulkSummary: Equatable {
        var total: Int
        var passed: Int
        var failed: Int
        var warnings: Int
        var exportURL: URL?
        var finishedAt: Date
    }

    var bulkSummary: BulkSummary?

    /// Set while a bulk-validate run is cancellable.
    private var bulkTask: Task<Void, Never>?

    /// Reference to the in-flight single-package validate task so the
    /// user can cancel it from the toolbar. Set by ``setValidateTask``
    /// and cleared on exit.
    private var validateTask: Task<Void, Never>?

    /// Free-text filter for the checklist column.
    var searchQuery: String = ""

    /// How the checklist column groups rows.
    var groupBy: GroupBy = .none

    /// Human-readable label for the step currently in flight. Drives
    /// the "Validating … (current stage)" affordance.
    var validationStage: String?

    enum GroupBy: String, CaseIterable, Hashable {
        case none, category, developer, status
        var title: String {
            switch self {
            case .none:      "All"
            case .category:  "Category"
            case .developer: "Developer"
            case .status:    "Status"
            }
        }
    }

    var isValidatingSingle: Bool {
        if case .validating = phase { return true }
        return false
    }

    func setValidateTask(_ task: Task<Void, Never>?) {
        validateTask = task
    }

    func cancelValidation() {
        validateTask?.cancel()
        validateTask = nil
        validationStage = nil
        phase = .ready
    }

    /// Repository whose checklist is currently loaded. Used to detect
    /// stale state when the user switches repos.
    var loadedRepoURL: URL?

    /// In-memory checklist, edited freely and flushed via ``saveChecklist``.
    var checklist: ChecklistStore = .empty

    /// Currently focused checklist entry — drives the step timeline.
    var selectedEntryID: UUID?

    /// Most recent QA result keyed by checklist entry id. Held in memory
    /// only; runs are cheap to redo.
    var resultsByEntry: [UUID: TestingResult] = [:]

    var phase: Phase = .idle
    var errorMessage: String?

    /// Pending autofix proposal awaiting user confirmation. Set by
    /// ``prepareAutofix(for:)``; cleared when the sheet dismisses.
    var pendingAutofix: AutofixProposal?

    var selectedEntry: ChecklistEntry? {
        guard let selectedEntryID else { return nil }
        return checklist.items.first { $0.id == selectedEntryID }
    }

    var selectedResult: TestingResult? {
        guard let selectedEntryID else { return nil }
        return resultsByEntry[selectedEntryID]
    }

    // MARK: - Sync with snapshot

    /// Reconcile the in-memory checklist with the current pkginfo set.
    /// New packages get a `.untested` entry; existing entries stay put
    /// (their last-tested fields are preserved). Removed packages are
    /// kept in the checklist with a `.warning` marker so the team
    /// notices — we don't silently drop history.
    func reconcile(with snapshot: RepositorySnapshot) {
        var byName: [String: ChecklistEntry] = [:]
        for entry in checklist.items { byName[entry.packageName] = entry }

        var next: [ChecklistEntry] = []
        var seen: Set<String> = []
        for record in snapshot.pkginfos {
            let name = record.pkginfo.name
            if seen.contains(name) { continue }
            seen.insert(name)
            if var entry = byName[name] {
                entry.version = record.pkginfo.version ?? entry.version
                next.append(entry)
            } else {
                next.append(
                    ChecklistEntry(
                        packageName: name,
                        version: record.pkginfo.version,
                        status: .untested
                    )
                )
            }
        }
        // Surface entries whose package was removed.
        for (name, entry) in byName where !seen.contains(name) {
            var marker = entry
            if marker.status != .fail {
                marker.notes = (marker.notes ?? "") + " [package no longer in repo]"
            }
            next.append(marker)
        }
        checklist.items = next.sorted { $0.packageName.localizedCompare($1.packageName) == .orderedAscending }
    }

    // MARK: - Load / save

    func load(repository: MunkiRepository, service: any TestingService) async {
        do {
            checklist = try await service.loadChecklist(in: repository)
            loadedRepoURL = repository.rootURL
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't load checklist: \(error.localizedDescription)"
            checklist = .empty
            loadedRepoURL = repository.rootURL
        }
    }

    func save(repository: MunkiRepository, service: any TestingService) async {
        do {
            try await service.saveChecklist(checklist, in: repository)
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't save checklist: \(error.localizedDescription)"
        }
    }

    // MARK: - Run a validation

    func validate(
        entry: ChecklistEntry,
        snapshot: RepositorySnapshot,
        repository: MunkiRepository,
        services: AppServices,
        munkipkgProjectsFolder: URL?,
        environment: (any TestEnvironment)?,
        environmentError: String? = nil,
        tester: String
    ) async {
        guard let record = snapshot.pkginfos.first(where: { $0.pkginfo.name == entry.packageName }) else {
            errorMessage = "No pkginfo found for \(entry.packageName)."
            return
        }
        phase = .validating(packageName: entry.packageName)
        validationStage = "Schema check"

        // Seed a placeholder so the timeline isn't empty during the
        // long Phase B/C waits — the user gets immediate feedback that
        // something is running.
        resultsByEntry[entry.id] = TestingResult(
            packageName: entry.packageName,
            pkginfoURL: record.fileURL,
            steps: [],
            startedAt: Date(),
            finishedAt: Date()
        )

        // Phase A: schema + script lint.
        var combined = await services.testing.validate(record, in: snapshot)
        resultsByEntry[entry.id] = combined
        if Task.isCancelled { return }

        // Phase B.1: build, only when a munkipkg project with the same
        // name as the package is reachable.
        validationStage = "Build (munkipkg)"
        if let folder = munkipkgProjectsFolder,
           let project = await Self.findMunkipkgProject(
                named: record.pkginfo.name,
                in: folder,
                via: services.munkipkg
           ) {
            let buildStep = await services.testing.validateBuild(
                project: project,
                munkipkg: services.munkipkg
            )
            combined.steps.append(buildStep)
            resultsByEntry[entry.id] = combined
        }
        if Task.isCancelled { return }

        // Phase B.2: artifact validation against the deployed pkgs/.
        validationStage = "Build artifact"
        let artifactStep = await services.testing.validateBuildArtifact(record, in: repository)
        combined.steps.append(artifactStep)
        resultsByEntry[entry.id] = combined
        if Task.isCancelled { return }

        // Phase C: env-driven install / installs[] / uninstall steps.
        // When env construction failed (no base image, Tart missing, …)
        // we add a single info step explaining the skip so the timeline
        // still tells the whole story.
        if let environment {
            await runEnvSteps(
                record: record,
                repository: repository,
                services: services,
                environment: environment,
                into: &combined
            )
        } else if let environmentError {
            combined.steps.append(
                TestingStepResult(
                    kind: .install,
                    title: "Install environment",
                    success: true,
                    severity: .info,
                    messages: ["Skipped: \(environmentError)"]
                )
            )
        }

        combined.finishedAt = Date()
        resultsByEntry[entry.id] = combined
        applyStatusFromResult(combined, to: entry.id, tester: tester)
        validationStage = nil
        phase = .ready
    }

    /// Roll up a `TestingResult` into a `ChecklistStatus` and stamp the
    /// entry. Errors → fail, any warnings → warning, otherwise pass.
    /// Leaves `tester` unset if the caller didn't supply a name (we don't
    /// guess on the user's behalf).
    private func applyStatusFromResult(
        _ result: TestingResult,
        to entryID: UUID,
        tester: String
    ) {
        guard let index = checklist.items.firstIndex(where: { $0.id == entryID }) else { return }
        let status: ChecklistStatus
        if result.failed > 0 {
            status = .fail
        } else if result.warnings > 0 {
            status = .warning
        } else if result.total > 0 {
            status = .pass
        } else {
            return  // empty result — leave the row alone
        }
        var entry = checklist.items[index]
        entry.status = status
        entry.testedAt = result.finishedAt
        if !tester.trimmingCharacters(in: .whitespaces).isEmpty {
            entry.tester = tester
        }
        checklist.items[index] = entry
    }

    private func runEnvSteps(
        record: PkginfoRecord,
        repository: MunkiRepository,
        services: AppServices,
        environment: any TestEnvironment,
        into result: inout TestingResult
    ) async {
        let entryID = checklist.items.first(where: { $0.packageName == result.packageName })?.id

        // Prepare the env. A failure here is itself a step result —
        // we don't throw past the run loop.
        validationStage = "Preparing \(environment.displayName)"
        let prepareStart = Date()
        do {
            try await environment.prepare()
            result.steps.append(
                TestingStepResult(
                    kind: .install,
                    title: "Environment ready",
                    success: true,
                    severity: .info,
                    messages: ["Prepared \(environment.displayName)."],
                    duration: Date().timeIntervalSince(prepareStart)
                )
            )
            if let entryID { resultsByEntry[entryID] = result }
        } catch {
            result.steps.append(
                TestingStepResult(
                    kind: .install,
                    title: "Environment ready",
                    success: false,
                    severity: .error,
                    messages: ["prepare() failed: \(error.localizedDescription)"],
                    duration: Date().timeIntervalSince(prepareStart)
                )
            )
            if let entryID { resultsByEntry[entryID] = result }
            await environment.teardown()
            return
        }

        validationStage = "Install"
        let install = await services.testing.validateInstall(
            record,
            in: repository,
            environment: environment
        )
        result.steps.append(install)
        if let entryID { resultsByEntry[entryID] = result }

        // Only proceed to the installs[] / uninstall checks if the
        // install step succeeded — otherwise we'd be testing against
        // a half-installed guest.
        if install.success {
            validationStage = "Check installs[]"
            let installs = await services.testing.validateInstallsArray(
                record,
                environment: environment
            )
            result.steps.append(installs)
            if let entryID { resultsByEntry[entryID] = result }

            validationStage = "Uninstall"
            let uninstall = await services.testing.validateUninstall(
                record,
                environment: environment
            )
            result.steps.append(uninstall)
            if let entryID { resultsByEntry[entryID] = result }
        }

        validationStage = "Tearing down VM"
        await environment.teardown()
    }

    private static func findMunkipkgProject(
        named name: String,
        in folder: URL,
        via service: any MunkipkgService
    ) async -> MunkipkgProject? {
        do {
            let projects = try await service.projects(in: folder)
            return projects.first { $0.name == name }
                ?? projects.first { $0.buildInfo.name == name }
        } catch {
            return nil
        }
    }

    // MARK: - Bulk validate

    /// Run static-only validation (Phases A + B.2; build is skipped to
    /// keep bulk runs fast) across every checklist entry sequentially.
    /// On finish, write a JSON results file and surface a summary.
    func validateAll(
        snapshot: RepositorySnapshot,
        repository: MunkiRepository,
        services: AppServices,
        tester: String
    ) async {
        bulkTask?.cancel()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runBulk(
                snapshot: snapshot,
                repository: repository,
                services: services,
                tester: tester
            )
        }
        bulkTask = task
        await task.value
    }

    func cancelBulk() {
        bulkTask?.cancel()
        bulkTask = nil
        phase = .ready
    }

    private func runBulk(
        snapshot: RepositorySnapshot,
        repository: MunkiRepository,
        services: AppServices,
        tester: String
    ) async {
        let entries = checklist.items
        let total = entries.count
        guard total > 0 else { return }

        var results: [TestingResult] = []
        for (index, entry) in entries.enumerated() {
            if Task.isCancelled { break }
            phase = .validatingAll(current: index + 1, total: total, packageName: entry.packageName)

            guard let record = snapshot.pkginfos.first(where: { $0.pkginfo.name == entry.packageName }) else {
                continue
            }
            var combined = await services.testing.validate(record, in: snapshot)
            let artifact = await services.testing.validateBuildArtifact(record, in: repository)
            combined.steps.append(artifact)
            combined.finishedAt = Date()
            resultsByEntry[entry.id] = combined
            applyStatusFromResult(combined, to: entry.id, tester: tester)
            results.append(combined)
        }

        var exportURL: URL?
        do {
            exportURL = try await services.testing.exportResults(results, in: repository)
        } catch {
            errorMessage = "Couldn't export results: \(error.localizedDescription)"
        }

        bulkSummary = BulkSummary(
            total: results.count,
            passed: results.filter(\.success).count,
            failed: results.filter { !$0.success }.count,
            warnings: results.filter { $0.warnings > 0 }.count,
            exportURL: exportURL,
            finishedAt: Date()
        )
        phase = .ready
    }

    var isBulkValidating: Bool {
        if case .validatingAll = phase { return true }
        return false
    }

    // MARK: - Autofix

    func prepareAutofix(
        for entry: ChecklistEntry,
        snapshot: RepositorySnapshot,
        service: any TestingService
    ) async {
        guard let record = snapshot.pkginfos.first(where: { $0.pkginfo.name == entry.packageName }) else {
            errorMessage = "No pkginfo found for \(entry.packageName)."
            return
        }
        pendingAutofix = await service.proposeAutofixes(for: record, in: snapshot)
        if pendingAutofix == nil {
            errorMessage = "Nothing to autofix on \(entry.packageName)."
        }
    }

    func cancelAutofix() {
        pendingAutofix = nil
    }

    // MARK: - Checklist edits

    func setStatus(
        _ status: ChecklistStatus,
        for entryID: UUID,
        tester: String
    ) {
        guard let index = checklist.items.firstIndex(where: { $0.id == entryID }) else { return }
        var entry = checklist.items[index]
        entry.status = status
        entry.tester = tester.isEmpty ? entry.tester : tester
        entry.testedAt = Date()
        checklist.items[index] = entry
    }

    /// Pick the next `.untested` entry after the current selection (or
    /// the first one, if nothing is selected). Mirrors Cimian's `-Next`.
    func selectNextUntested() {
        guard !checklist.items.isEmpty else { return }
        let untested = checklist.items.filter { $0.status == .untested }
        guard let first = untested.first else { return }
        if let currentID = selectedEntryID,
           let currentIndex = untested.firstIndex(where: { $0.id == currentID }) {
            let next = untested[(currentIndex + 1) % untested.count]
            selectedEntryID = next.id
        } else {
            selectedEntryID = first.id
        }
    }
}
