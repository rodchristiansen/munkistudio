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

    /// Number of files with uncommitted changes (staged + unstaged +
    /// untracked, excluding ignored). Drives the dirty dot in the
    /// toolbar branch chip.
    var gitDirtyCount: Int = 0

    /// Set while a top-level git action (fetch / pull / push) is in
    /// flight from the toolbar — used to disable buttons and show a
    /// spinner without ferrying state through GitView.
    var gitActionInFlight: GitToolbarAction?

    /// Last status message from a toolbar git action — surfaced as a
    /// transient banner in the toolbar.
    var gitActionMessage: String?

    /// Sidebar destination the user has selected.
    var selectedSection: SidebarSection = .dashboard {
        didSet { scheduleNavigationRecord() }
    }

    /// Item selection within the middle column (pkginfo / manifest / etc.).
    var selectedItemID: AnyHashable? {
        didSet { scheduleNavigationRecord() }
    }

    /// Set when navigation (search, Back / Forward) wants the middle-column
    /// list to scroll the selected item into view. The list view consumes
    /// and clears it. A plain row click never sets this, so clicking an
    /// already-visible row doesn't yank the list around.
    var pendingRevealItemID: AnyHashable?

    /// Build-pane equivalent of `pendingRevealItemID` — a munkipkg
    /// project id (the project directory's path) that the Build view
    /// should select on next appearance. Set by cross-section openers
    /// (Testing tab's double-click, etc.); BuildView consumes and clears.
    var pendingBuildProjectID: String?

    /// Cluster selected in the Dependencies section. Lives on the store
    /// (not view-local `@State`) so it survives the view being torn down
    /// when the user navigates away and back.
    var dependenciesClusterID: String? {
        didSet { scheduleNavigationRecord() }
    }

    /// Dependencies section: Packages vs Manifests mode, and the manifest
    /// focused in Manifests mode. Recorded in navigation history so
    /// Back / Forward restore the exact Dependencies view.
    var dependencyMode: DependencyMode = .packages {
        didSet { scheduleNavigationRecord() }
    }
    var dependenciesManifestName: String? {
        didSet { scheduleNavigationRecord() }
    }

    /// Packages-list view mode. Persisted here — not view-local `@State`
    /// — so the grouping tab and sort survive navigating away and back.
    var packagesGrouping: PackageGrouping = .categories
    var packagesSort: PackageSort = .name

    /// Manifests-list view mode, same rationale.
    var manifestsGrouping: ManifestGrouping = .directories
    var manifestsSort: PackageSort = .name

    /// Git pane state — focused panel plus commit / hook / file
    /// selection. Held on the store so leaving the Git tab and coming
    /// back restores the panel and selection instead of resetting.
    let gitPaneState = GitPaneState()

    /// Installer URLs handed off to the Import wizard — e.g. a `.pkg`
    /// the Build tab just produced. The Import view consumes and clears
    /// these when it appears.
    var pendingImportURLs: [URL] = []

    /// File-importer toggle for the "Open Repository…" menu command.
    /// SwiftUI's `Commands` aren't `View`s, so the command sets this
    /// flag and `ContentView` hosts the `.fileImporter`.
    var openRepositoryPickerRequested: Bool = false

    var loadState: LoadState = .idle

    /// Free-text query backing the global search pane.
    var searchQuery: String = ""

    /// Cached results for the current `searchQuery`. Recomputed by a
    /// `.task(id:)` in the workspace so we don't re-scan every pkginfo
    /// and manifest on every SwiftUI hover — that re-render storm was
    /// the source of the dropdown flicker.
    var searchResults: [SearchScanner.FileResult] = []

    /// Category names currently expanded in the Packages outline. Persisted
    /// only for the duration of a session — we don't want to surprise the
    /// user with stale expanded state on next launch.
    var expandedCategories: Set<String> = []

    /// Manifest tree paths currently expanded in the Manifests outline.
    var expandedManifestPaths: Set<String> = []

    /// Criteria the Manifests list should apply when it next appears —
    /// driven by "Search in Manifests" on a package, which jumps to the
    /// Manifests section pre-filtered to manifests that reference the
    /// chosen package. ``ManifestsListView`` consumes and clears it.
    var pendingManifestCriteria: ManifestCriteriaGroup?

    // MARK: Session drafts
    //
    // Drafts hold in-progress edits keyed by file URL. They persist
    // across selection changes — clicking from one pkginfo to another
    // no longer discards your work — and the toolbar's Save button
    // flushes everything in one go. An entry only exists while it
    // differs from the saved record on disk; setters compare and
    // remove the key when the user reverts a change manually.

    var pkginfoDrafts: [URL: Pkginfo] = [:]
    var manifestDrafts: [URL: Manifest] = [:]
    /// Format conversions (`.plist ↔ .yaml`) are tracked separately so
    /// changing only the format without touching any field still
    /// counts as dirty.
    var draftFormats: [URL: RepoFormat] = [:]
    /// Last error from a session save, surfaced as a toolbar banner.
    var sessionSaveError: String?

    /// Last error from a manifest lifecycle action (create / rename /
    /// duplicate / delete), surfaced as an alert in the Manifests list.
    var manifestActionError: String?

    /// Last error from a pkginfo lifecycle action (rename / duplicate /
    /// delete), surfaced as an alert in the Packages list.
    var packageActionError: String?

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
            await refreshGitStatus()
            Self.appendRecent(rootURL, into: &recentRepositories)
            loadState = .ready
            navHistory.removeAll()
            navIndex = -1
            recordNavigation()
        } catch {
            loadState = .failed(message: error.localizedDescription)
        }
    }

    // MARK: Navigation history

    /// A point in back/forward history — everything needed to restore
    /// where the user was: the section, the middle-column selection, and
    /// any section-specific deep-link state.
    struct NavLocation: Equatable {
        var section: SidebarSection
        var itemID: AnyHashable?
        var dependenciesClusterID: String?
        var dependencyMode: DependencyMode
        var dependenciesManifestName: String?
    }

    private var navHistory: [NavLocation] = []
    private var navIndex: Int = -1
    @ObservationIgnored private var suppressNavRecord = false
    @ObservationIgnored private var navRecordScheduled = false

    var canGoBack: Bool { navIndex > 0 }
    var canGoForward: Bool { navIndex >= 0 && navIndex < navHistory.count - 1 }

    /// One logical move often touches several properties (jumping to a
    /// package sets `selectedSection` then `selectedItemID`). Defer the
    /// record to the next main-actor tick so the burst collapses into a
    /// single history entry once every property has settled.
    private func scheduleNavigationRecord() {
        guard !suppressNavRecord, !navRecordScheduled else { return }
        navRecordScheduled = true
        Task { @MainActor in
            self.navRecordScheduled = false
            self.recordNavigation()
        }
    }

    private func recordNavigation() {
        let location = NavLocation(
            section: selectedSection,
            itemID: selectedItemID,
            dependenciesClusterID: dependenciesClusterID,
            dependencyMode: dependencyMode,
            dependenciesManifestName: dependenciesManifestName
        )
        if navIndex >= 0, navHistory[navIndex] == location { return }
        if navIndex < navHistory.count - 1 {
            navHistory.removeSubrange((navIndex + 1)...)
        }
        navHistory.append(location)
        navIndex = navHistory.count - 1
    }

    func goBack() {
        guard canGoBack else { return }
        navIndex -= 1
        applyNavLocation(navHistory[navIndex])
    }

    func goForward() {
        guard canGoForward else { return }
        navIndex += 1
        applyNavLocation(navHistory[navIndex])
    }

    private func applyNavLocation(_ location: NavLocation) {
        suppressNavRecord = true
        selectedSection = location.section
        selectedItemID = location.itemID
        dependenciesClusterID = location.dependenciesClusterID
        dependencyMode = location.dependencyMode
        dependenciesManifestName = location.dependenciesManifestName
        suppressNavRecord = false
        pendingRevealItemID = location.itemID
    }

    func reload() async {
        guard let repo = repository else { return }
        loadState = .loading
        do {
            let snapshot = try await services.repository.reload(repo)
            self.snapshot = snapshot
            self.gitInfo = await services.git.discover(at: repo.rootURL)
            await refreshGitStatus()
            loadState = .ready
        } catch {
            loadState = .failed(message: error.localizedDescription)
        }
    }

    // MARK: Git actions (toolbar)

    /// Re-read working tree status and refresh the dirty-file count
    /// driving the toolbar indicator. Cheap enough to run after any
    /// toolbar git action.
    func refreshGitStatus() async {
        guard let info = gitInfo else { gitDirtyCount = 0; return }
        if let updated = await services.git.discover(at: info.workTreeRoot) {
            gitInfo = updated
        }
        do {
            let entries = try await services.git.status(in: info)
            gitDirtyCount = entries.count
        } catch {
            gitDirtyCount = 0
        }
    }

    func runGitFetch() async {
        await runGitShell(["fetch"], action: .fetch, successMessage: "Fetched")
    }

    /// Default pull strategy mirrors the GitView pane: `--rebase
    /// --autostash` keeps history linear and avoids interrupting the
    /// user for a stash when their tree is dirty.
    func runGitPull() async {
        await runGitShell(["pull", "--rebase", "--autostash"], action: .pull, successMessage: "Pulled")
    }

    func runGitPush() async {
        await runGitShell(["push"], action: .push, successMessage: "Pushed")
    }

    private func runGitShell(_ args: [String], action: GitToolbarAction, successMessage: String) async {
        guard let info = gitInfo else { return }
        gitActionInFlight = action
        defer { gitActionInFlight = nil }
        let workTreeRoot = info.workTreeRoot
        let result: (Int32, String) = await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = args
            process.currentDirectoryURL = workTreeRoot
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                process.waitUntilExit()
                let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                return (process.terminationStatus, String(decoding: data, as: UTF8.self))
            } catch {
                return (-1, error.localizedDescription)
            }
        }.value
        if result.0 == 0 {
            gitActionMessage = successMessage
        } else {
            // First non-empty line is usually the human-readable error.
            let firstLine = result.1.split(separator: "\n").first.map(String.init) ?? "exit \(result.0)"
            gitActionMessage = "\(action.label) failed: \(firstLine)"
        }
        await refreshGitStatus()
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

    // MARK: Manifest lifecycle

    /// Create a new empty manifest and select it. `name` may contain
    /// slashes to nest the file under `manifests/`.
    @discardableResult
    func createManifest(named name: String, format: RepoFormat?) async -> ManifestRecord? {
        guard let repo = repository else { return nil }
        do {
            let record = try await services.manifests.create(
                named: name,
                body: Manifest(manifestName: name),
                in: repo,
                format: format
            )
            upsert(record)
            selectedItemID = AnyHashable(record.id)
            return record
        } catch {
            manifestActionError = error.localizedDescription
            return nil
        }
    }

    func deleteManifest(_ record: ManifestRecord) async {
        do {
            try await services.manifests.delete(record)
            snapshot.manifests.removeAll { $0.fileURL == record.fileURL }
            manifestDrafts.removeValue(forKey: record.fileURL)
            draftFormats.removeValue(forKey: record.fileURL)
            if selectedItemID == AnyHashable(record.id) {
                selectedItemID = nil
            }
        } catch {
            manifestActionError = error.localizedDescription
        }
    }

    /// Rename a manifest, carrying any unsaved draft edits to the new file.
    @discardableResult
    func renameManifest(_ record: ManifestRecord, to newName: String) async -> ManifestRecord? {
        guard let repo = repository else { return nil }
        let effective = ManifestRecord(
            manifest: draftManifest(for: record),
            fileURL: record.fileURL,
            format: record.format
        )
        do {
            let renamed = try await services.manifests.rename(effective, to: newName, in: repo)
            snapshot.manifests.removeAll { $0.fileURL == record.fileURL }
            manifestDrafts.removeValue(forKey: record.fileURL)
            draftFormats.removeValue(forKey: record.fileURL)
            upsert(renamed)
            selectedItemID = AnyHashable(renamed.id)
            return renamed
        } catch {
            manifestActionError = error.localizedDescription
            return nil
        }
    }

    /// Duplicate a manifest under `newName`, copying current draft edits.
    @discardableResult
    func duplicateManifest(_ record: ManifestRecord, as newName: String) async -> ManifestRecord? {
        guard let repo = repository else { return nil }
        let source = ManifestRecord(
            manifest: draftManifest(for: record),
            fileURL: record.fileURL,
            format: record.format
        )
        do {
            let copy = try await services.manifests.duplicate(source, as: newName, in: repo)
            upsert(copy)
            selectedItemID = AnyHashable(copy.id)
            return copy
        } catch {
            manifestActionError = error.localizedDescription
            return nil
        }
    }

    // MARK: Package lifecycle

    func deletePackage(_ record: PkginfoRecord) async {
        do {
            try await services.packages.delete(record)
            snapshot.pkginfos.removeAll { $0.fileURL == record.fileURL }
            pkginfoDrafts.removeValue(forKey: record.fileURL)
            draftFormats.removeValue(forKey: record.fileURL)
            if selectedItemID == AnyHashable(record.id) {
                selectedItemID = nil
            }
            recomputeCatalogs()
        } catch {
            packageActionError = error.localizedDescription
        }
    }

    /// Rename a pkginfo file, carrying any unsaved draft edits to the new
    /// file URL. Only the file is renamed — the pkginfo `name` key is
    /// untouched.
    @discardableResult
    func renamePackage(_ record: PkginfoRecord, to newName: String) async -> PkginfoRecord? {
        guard let repo = repository else { return nil }
        do {
            let renamed = try await services.packages.rename(record, to: newName, in: repo)
            if let draft = pkginfoDrafts.removeValue(forKey: record.fileURL) {
                pkginfoDrafts[renamed.fileURL] = draft
            }
            if let format = draftFormats.removeValue(forKey: record.fileURL) {
                draftFormats[renamed.fileURL] = format
            }
            snapshot.pkginfos.removeAll { $0.fileURL == record.fileURL }
            upsert(renamed)
            selectedItemID = AnyHashable(renamed.id)
            return renamed
        } catch {
            packageActionError = error.localizedDescription
            return nil
        }
    }

    /// Duplicate a pkginfo file under `newName` and select the copy.
    @discardableResult
    func duplicatePackage(_ record: PkginfoRecord, as newName: String) async -> PkginfoRecord? {
        guard let repo = repository else { return nil }
        do {
            let copy = try await services.packages.duplicate(record, as: newName, in: repo)
            upsert(copy)
            selectedItemID = AnyHashable(copy.id)
            return copy
        } catch {
            packageActionError = error.localizedDescription
            return nil
        }
    }

    /// Apply a single-property tweak to a pkginfo and persist it
    /// immediately. Drives the row context menu's Catalogs / Category /
    /// Developer submenus — those edits commit on click, like MunkiAdmin,
    /// rather than landing in the unsaved-draft pile. Surfaces failures
    /// through ``packageActionError``.
    @discardableResult
    func applyPkginfoEdit(_ updated: Pkginfo, to record: PkginfoRecord) async -> Bool {
        let next = PkginfoRecord(
            pkginfo: updated,
            fileURL: record.fileURL,
            format: record.format,
            createdAt: record.createdAt,
            modifiedAt: Date()
        )
        do {
            try await services.packages.save(next)
            upsert(next)
            return true
        } catch {
            packageActionError = error.localizedDescription
            return false
        }
    }

    /// Apply a single-property tweak to a manifest and persist it
    /// immediately. Drives the row context menu's Catalogs / Included
    /// Manifests submenus — those edits commit on click, like MunkiAdmin,
    /// rather than landing in the unsaved-draft pile. Surfaces failures
    /// through ``manifestActionError``.
    @discardableResult
    func applyManifestEdit(_ updated: Manifest, to record: ManifestRecord) async -> Bool {
        let next = ManifestRecord(
            manifest: updated,
            fileURL: record.fileURL,
            format: record.format,
            createdAt: record.createdAt,
            modifiedAt: Date()
        )
        do {
            try await services.manifests.save(next)
            upsert(next)
            return true
        } catch {
            manifestActionError = error.localizedDescription
            return false
        }
    }

    /// Recompute the catalog projection from the current pkginfo set.
    private func recomputeCatalogs() {
        let captured = snapshot.pkginfos
        Task {
            let catalogs = await services.catalogs.catalogs(from: captured)
            self.snapshot.catalogs = catalogs
        }
    }

    // MARK: Drafts (session-level dirty model)

    func draftPkginfo(for record: PkginfoRecord) -> Pkginfo {
        pkginfoDrafts[record.fileURL] ?? record.pkginfo
    }

    func setDraftPkginfo(_ value: Pkginfo, for record: PkginfoRecord) {
        if value == record.pkginfo {
            pkginfoDrafts.removeValue(forKey: record.fileURL)
        } else {
            pkginfoDrafts[record.fileURL] = value
        }
    }

    func draftManifest(for record: ManifestRecord) -> Manifest {
        manifestDrafts[record.fileURL] ?? record.manifest
    }

    func setDraftManifest(_ value: Manifest, for record: ManifestRecord) {
        if value == record.manifest {
            manifestDrafts.removeValue(forKey: record.fileURL)
        } else {
            manifestDrafts[record.fileURL] = value
        }
    }

    func draftFormat(for url: URL, default fallback: RepoFormat) -> RepoFormat {
        draftFormats[url] ?? fallback
    }

    func setDraftFormat(_ value: RepoFormat, for url: URL, savedFormat: RepoFormat) {
        if value == savedFormat {
            draftFormats.removeValue(forKey: url)
        } else {
            draftFormats[url] = value
        }
    }

    /// Count of files with at least one unsaved change (data or
    /// format). Drives the toolbar Save button's badge.
    var dirtyDraftCount: Int {
        var keys = Set(pkginfoDrafts.keys)
        keys.formUnion(manifestDrafts.keys)
        keys.formUnion(draftFormats.keys)
        return keys.count
    }

    /// Flush every dirty draft to disk. Each file is converted if its
    /// format changed; on success the draft is removed from the
    /// session. A single failure halts the save and surfaces the
    /// error to the toolbar so the user can fix it and retry.
    func saveSession() async {
        sessionSaveError = nil
        // Pkginfos
        for (url, pkginfo) in pkginfoDrafts {
            guard let record = snapshot.pkginfos.first(where: { $0.fileURL == url }) else { continue }
            let format = draftFormat(for: url, default: record.format)
            var savedURL = url
            if savedURL.pathExtension != format.preferredExtension {
                savedURL = savedURL.deletingPathExtension().appendingPathExtension(format.preferredExtension)
            }
            let updated = PkginfoRecord(
                pkginfo: pkginfo,
                fileURL: savedURL,
                format: format,
                createdAt: record.createdAt,
                modifiedAt: Date()
            )
            do {
                try await services.packages.save(updated)
                if savedURL != url {
                    try? FileManager.default.removeItem(at: url)
                }
                pkginfoDrafts.removeValue(forKey: url)
                draftFormats.removeValue(forKey: url)
                upsert(updated)
            } catch {
                sessionSaveError = "\(url.lastPathComponent): \(error.localizedDescription)"
                return
            }
        }
        // Manifests
        for (url, manifest) in manifestDrafts {
            guard let record = snapshot.manifests.first(where: { $0.fileURL == url }) else { continue }
            let format = draftFormat(for: url, default: record.format)
            var savedURL = url
            if savedURL.pathExtension != format.preferredExtension {
                savedURL = savedURL.deletingPathExtension().appendingPathExtension(format.preferredExtension)
            }
            let updated = ManifestRecord(
                manifest: manifest,
                fileURL: savedURL,
                format: format,
                createdAt: record.createdAt,
                modifiedAt: Date()
            )
            do {
                try await services.manifests.save(updated)
                if savedURL != url {
                    try? FileManager.default.removeItem(at: url)
                }
                manifestDrafts.removeValue(forKey: url)
                draftFormats.removeValue(forKey: url)
                upsert(updated)
            } catch {
                sessionSaveError = "\(url.lastPathComponent): \(error.localizedDescription)"
                return
            }
        }
        // Format-only changes for files with no body diff.
        let remainingFormatOnly = draftFormats
        for (url, format) in remainingFormatOnly {
            if let record = snapshot.pkginfos.first(where: { $0.fileURL == url }) {
                var savedURL = url
                if savedURL.pathExtension != format.preferredExtension {
                    savedURL = savedURL.deletingPathExtension().appendingPathExtension(format.preferredExtension)
                }
                let updated = PkginfoRecord(
                    pkginfo: record.pkginfo,
                    fileURL: savedURL,
                    format: format,
                    createdAt: record.createdAt,
                    modifiedAt: Date()
                )
                do {
                    try await services.packages.save(updated)
                    if savedURL != url { try? FileManager.default.removeItem(at: url) }
                    draftFormats.removeValue(forKey: url)
                    upsert(updated)
                } catch {
                    sessionSaveError = "\(url.lastPathComponent): \(error.localizedDescription)"
                    return
                }
            } else if let record = snapshot.manifests.first(where: { $0.fileURL == url }) {
                var savedURL = url
                if savedURL.pathExtension != format.preferredExtension {
                    savedURL = savedURL.deletingPathExtension().appendingPathExtension(format.preferredExtension)
                }
                let updated = ManifestRecord(
                    manifest: record.manifest,
                    fileURL: savedURL,
                    format: format,
                    createdAt: record.createdAt,
                    modifiedAt: Date()
                )
                do {
                    try await services.manifests.save(updated)
                    if savedURL != url { try? FileManager.default.removeItem(at: url) }
                    draftFormats.removeValue(forKey: url)
                    upsert(updated)
                } catch {
                    sessionSaveError = "\(url.lastPathComponent): \(error.localizedDescription)"
                    return
                }
            }
        }
        await refreshGitStatus()
    }

    // MARK: Recent repositories

    private static let recentsKey = "MunkiStudio.recentRepositories"
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

enum GitToolbarAction: Hashable, Sendable {
    case fetch, pull, push

    var label: String {
        switch self {
        case .fetch: "Fetch"
        case .pull: "Pull"
        case .push: "Push"
        }
    }

    var systemImage: String {
        switch self {
        case .fetch: "arrow.down.to.line"
        case .pull: "arrow.down"
        case .push: "arrow.up"
        }
    }
}
