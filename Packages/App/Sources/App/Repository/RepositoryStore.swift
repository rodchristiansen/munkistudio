import Foundation
import Observation
import Core
import Infra

/// Top-level store for the open Munki repository. Holds the latest
/// ``RepositorySnapshot``, the loading state, and a derived set of
/// projections (catalog index, category index, developer index) the UI
/// pulls from.
///
/// Notes for maintainers:
/// - The store is `@Observable`, not an actor — views read from it
///   synchronously and SwiftUI dependency-tracks individual properties.
///   Mutating work happens on `@MainActor`; service calls hop off via
///   `Task { ... }` and re-bind on completion.
/// - Recent repositories are remembered as plain file URLs in
///   `UserDefaults`. Sandboxed builds will need to upgrade these to
///   security-scoped bookmarks; that's a v2 concern.
@Observable
@MainActor
final class RepositoryStore {
    /// Currently opened repository, if any.
    var repository: MunkiRepository?

    /// Latest fully loaded snapshot.
    var snapshot: RepositorySnapshot = RepositorySnapshot()

    /// Git working tree state for the currently opened repo, if it lives
    /// inside a git repository.
    var gitInfo: GitRepositoryInfo?

    /// Sidebar destination the user has selected.
    var selectedSection: SidebarSection = .packages

    /// Item selection within the middle column (pkginfo / manifest / etc.).
    var selectedItemID: AnyHashable?

    var loadState: LoadState = .idle

    /// Free-text query backing the global search pane.
    var searchQuery: String = ""

    /// Most recently opened repositories, newest first.
    private(set) var recentRepositories: [URL]

    let services: AppServices

    init(services: AppServices) {
        self.services = services
        self.recentRepositories = Self.loadRecents()
    }

    // MARK: Opening

    func open(rootURL: URL) async {
        loadState = .loading
        do {
            let repo = try await services.repository.open(rootURL: rootURL)
            self.repository = repo
            let snapshot = try await services.repository.reload(repo)
            self.snapshot = snapshot
            self.gitInfo = await services.git.discover(at: rootURL)
            Self.appendRecent(rootURL, into: &recentRepositories)
            loadState = .ready
        } catch {
            loadState = .failed(message: error.localizedDescription)
        }
    }

    func reload() async {
        guard let repo = repository else { return }
        loadState = .loading
        do {
            let snapshot = try await services.repository.reload(repo)
            self.snapshot = snapshot
            self.gitInfo = await services.git.discover(at: repo.rootURL)
            loadState = .ready
        } catch {
            loadState = .failed(message: error.localizedDescription)
        }
    }

    // MARK: Mutation

    /// Replace one pkginfo record in the snapshot after save.
    func upsert(_ record: PkginfoRecord) {
        if let index = snapshot.pkginfos.firstIndex(where: { $0.fileURL == record.fileURL }) {
            snapshot.pkginfos[index] = record
        } else {
            snapshot.pkginfos.append(record)
        }
        // Catalog projection is cheap to recompute.
        let captured = snapshot.pkginfos
        Task {
            let catalogs = await services.catalogs.catalogs(from: captured)
            self.snapshot.catalogs = catalogs
        }
    }

    func upsert(_ record: ManifestRecord) {
        if let index = snapshot.manifests.firstIndex(where: { $0.fileURL == record.fileURL }) {
            snapshot.manifests[index] = record
        } else {
            snapshot.manifests.append(record)
        }
    }

    // MARK: Recent repositories

    private static let recentsKey = "MunkiAdmin.recentRepositories"
    private static let recentsLimit = 8

    private static func loadRecents() -> [URL] {
        let defaults = UserDefaults.standard
        let paths = defaults.array(forKey: recentsKey) as? [String] ?? []
        return paths.map { URL(fileURLWithPath: $0) }
    }

    private static func appendRecent(_ url: URL, into recents: inout [URL]) {
        recents.removeAll { $0.path == url.path }
        recents.insert(url, at: 0)
        if recents.count > recentsLimit {
            recents.removeLast(recents.count - recentsLimit)
        }
        UserDefaults.standard.set(recents.map(\.path), forKey: recentsKey)
    }

    enum LoadState: Equatable {
        case idle
        case loading
        case ready
        case failed(message: String)
    }
}
