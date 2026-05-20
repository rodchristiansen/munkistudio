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
