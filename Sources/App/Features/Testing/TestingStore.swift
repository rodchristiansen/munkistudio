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
        case ready
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
        service: any TestingService
    ) async {
        guard let record = snapshot.pkginfos.first(where: { $0.pkginfo.name == entry.packageName }) else {
            errorMessage = "No pkginfo found for \(entry.packageName)."
            return
        }
        phase = .validating(packageName: entry.packageName)
        let result = await service.validate(record, in: snapshot)
        resultsByEntry[entry.id] = result
        phase = .ready
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
