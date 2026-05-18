import Foundation
import Observation
import Core

/// State for the Clean section. Drives ``CleanView``: a `repoclean`
/// preview (safe, deletes nothing), a confirmed apply run, and the local
/// history of past runs.
///
/// A preview answers "no" to `repoclean`'s prompt; an apply passes
/// `--auto`. After a successful apply the store records the run — built
/// from the *previewed* plan the user reviewed — to ``RepoCleanHistoryService``.
@MainActor
@Observable
final class CleanStore {
    enum Phase: Equatable {
        /// Nothing run yet.
        case idle
        /// A preview is streaming.
        case previewing
        /// Preview finished — `plan` is populated.
        case ready
        /// An apply run is streaming.
        case cleaning
        /// An apply run finished.
        case done
    }

    /// `--keep` — versions of each item variation to retain.
    var keep: Int = 2
    /// `--show-all` — list items even when nothing of theirs is removed.
    var showAll: Bool = false

    var phase: Phase = .idle
    /// The parsed result of the most recent run.
    var plan: RepoCleanPlan?
    /// Raw streamed `repoclean` output, append-only.
    var output: String = ""
    var outcome: RepoCleanOutcome?
    var errorMessage: String?
    /// Past apply runs for the open repo, newest first.
    var history: [RepoCleanRecord] = []

    private var runTask: Task<Void, Never>?

    var isRunning: Bool { phase == .previewing || phase == .cleaning }

    /// `true` when there is something a clean would remove.
    var hasDeletions: Bool { plan?.hasDeletions ?? false }

    func cancel() {
        runTask?.cancel()
        runTask = nil
    }

    // MARK: Preview

    /// Run a non-destructive preview. Safe to call on tab entry.
    func preview(repository: MunkiRepository, service: any RepoCleanService) {
        cancel()
        phase = .previewing
        output = ""
        plan = nil
        outcome = nil
        errorMessage = nil
        let options = RepoCleanOptions(keep: keep, showAll: showAll, apply: false)
        runTask = Task { [weak self] in
            await self?.consume(service.run(in: repository, options: options), applyRun: false)
        }
    }

    // MARK: Apply

    /// Run the real clean, then record it to history. `onApplied` runs
    /// after a successful delete so the caller can refresh the repo.
    func apply(
        repository: MunkiRepository,
        service: any RepoCleanService,
        historyService: any RepoCleanHistoryService,
        onApplied: @escaping @MainActor () async -> Void
    ) {
        cancel()
        // Record from the plan the user reviewed, not the apply output.
        let reviewedPlan = plan
        phase = .cleaning
        output = ""
        outcome = nil
        errorMessage = nil
        let options = RepoCleanOptions(keep: keep, showAll: showAll, apply: true)
        let repoPath = repository.rootURL.path
        runTask = Task { [weak self] in
            await self?.consume(service.run(in: repository, options: options), applyRun: true)
            guard let self else { return }
            if self.outcome?.exitCode == 0 {
                if let reviewedPlan {
                    await self.record(plan: reviewedPlan, repoPath: repoPath, historyService: historyService)
                }
                await onApplied()
            }
            await self.loadHistory(repoPath: repoPath, historyService: historyService)
        }
    }

    // MARK: History

    func loadHistory(repoPath: String, historyService: any RepoCleanHistoryService) async {
        history = await historyService.records(forRepoAt: repoPath)
    }

    private func record(
        plan: RepoCleanPlan,
        repoPath: String,
        historyService: any RepoCleanHistoryService
    ) async {
        let removed = plan.items.flatMap { item in
            item.doomedVersions.map {
                RepoCleanRecord.RemovedItem(name: item.name, version: $0.version, path: $0.path)
            }
        }
        guard !removed.isEmpty else { return }
        let entry = RepoCleanRecord(
            repoPath: repoPath,
            keep: keep,
            removedItems: removed,
            pkgsDeleted: plan.summary?.pkgsToDelete ?? removed.count,
            pkginfoSpaceSaved: plan.summary?.pkginfoSpaceSavings ?? "",
            pkgSpaceSaved: plan.summary?.pkgSpaceSavings ?? ""
        )
        try? await historyService.append(entry)
    }

    // MARK: Stream consumption

    private func consume(
        _ stream: AsyncThrowingStream<RepoCleanEvent, any Error>,
        applyRun: Bool
    ) async {
        do {
            for try await event in stream {
                switch event {
                case .line(let line): output += line + "\n"
                case .finished(let result): outcome = result
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            output += "\u{2716} \(error.localizedDescription)\n"
        }
        plan = RepoCleanOutputParser.parse(output)
        phase = applyRun ? .done : .ready
    }
}
