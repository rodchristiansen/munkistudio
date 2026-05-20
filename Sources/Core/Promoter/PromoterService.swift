import Foundation

/// Reads AutoPkg promoter configuration and computes the three views the
/// Promoter tab needs (imports / upcoming / history). Also applies user
/// actions (promote now, promote early, defer) by mutating the affected
/// pkginfo and persisting via the supplied ``PackageService``.
///
/// Concrete implementations live in Infra — `FilePromoterService` reads
/// `promoter.yml` from disk and shells out to git for the import /
/// history feeds.
public protocol PromoterService: Sendable {
    /// Load the configuration file at `<deploymentRoot>/promoter.yml`.
    /// Returns a default empty config if the file is missing so the
    /// Promoter view can still render an explainer with a "no config
    /// found" hint instead of erroring out.
    func loadConfig(at deploymentRoot: URL) async throws -> PromoterConfig

    /// Compute the full set of view data for the open repository:
    /// imports, candidates, and history. `pkginfos` is the live set of
    /// records from the repository snapshot — the candidate computation
    /// runs against this so the user sees up-to-date catalog state even
    /// before disk-side changes are visible to git.
    func snapshot(
        repository: MunkiRepository,
        deploymentRoot: URL,
        pkginfos: [PkginfoRecord]
    ) async throws -> PromoterSnapshot

    /// Apply a promotion to a single candidate. Sets the pkginfo's
    /// `catalogs` to the rule's `promoteTo` set, refreshes the
    /// `_metadata.munki-promoter_edit_date` to `now`, and saves via the
    /// underlying ``PackageService``. Works whether or not the
    /// candidate is currently eligible — the App layer is responsible
    /// for confirming "promote early" with the user.
    @discardableResult
    func promote(
        _ candidate: PromotionCandidate,
        in pkginfos: [PkginfoRecord]
    ) async throws -> PkginfoRecord

    /// Defer a candidate by resetting its `munki-promoter_edit_date` to
    /// `now`, restarting its aging timer. Catalogs stay where they are.
    @discardableResult
    func defer_(
        _ candidate: PromotionCandidate,
        in pkginfos: [PkginfoRecord]
    ) async throws -> PkginfoRecord
}
