import Foundation
import Testing
import Core
import Infra
@testable import App

/// End-to-end-ish cover for the onboarding path: picking a folder in the
/// wizard's repository step and what the user is told about it.
@Suite("Onboarding repository step")
@MainActor
struct OnboardingFlowTests {
    private static func makeStore(defaults: UserDefaults) -> RepositoryStore {
        let packages = FilePackageService()
        let manifests = FileManifestService()
        let catalogs = FileCatalogService()
        let icons = FileIconService()
        let services = AppServices(
            repository: FileRepositoryService(
                packages: packages,
                manifests: manifests,
                catalogs: catalogs,
                icons: icons
            ),
            packages: packages,
            manifests: manifests,
            catalogs: catalogs,
            icons: icons,
            git: NoGitService(),
            makecatalogs: MakecatalogsRunner(),
            munkiimport: MunkiimportRunner(),
            munkipkg: MunkipkgRunner(),
            iconImporter: IconImporterRunner(),
            repoClean: RepoCleanRunner(),
            repoCleanHistory: RepoCleanHistoryStore(),
            promoter: FilePromoterService(packages: packages)
        )
        return RepositoryStore(services: services, defaults: defaults)
    }

    private static func makeScratchDefaults() -> (UserDefaults, String) {
        let suite = "MunkiStudioTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    private static func makeRepo(
        directories: [String] = ["pkgsinfo", "manifests", "catalogs", "pkgs"]
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "munkistudio-tests-\(UUID().uuidString)")
        for name in directories {
            try FileManager.default.createDirectory(
                at: root.appending(path: name),
                withIntermediateDirectories: true
            )
        }
        return root
    }

    @Test("opening a complete Munki repo succeeds with no warnings")
    func opensCompleteRepo() async throws {
        let (defaults, suite) = Self.makeScratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = try Self.makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = Self.makeStore(defaults: defaults)
        await store.open(rootURL: root)

        #expect(store.loadState == .ready)
        #expect(store.repository?.rootURL == root)
        #expect(store.repositoryWarnings.isEmpty)
        #expect(store.recentRepositories.first == root)
    }

    /// The wrong-folder case. It used to "succeed" into an empty studio
    /// with no explanation — the most common thing the first round of
    /// testers hit, and indistinguishable from the app being broken.
    @Test("picking a folder that isn't a Munki repo fails loudly and isn't remembered")
    func rejectsNonRepositoryFolder() async throws {
        let (defaults, suite) = Self.makeScratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let notARepo = try Self.makeRepo(directories: ["Documents", "Downloads"])
        defer { try? FileManager.default.removeItem(at: notARepo) }

        let store = Self.makeStore(defaults: defaults)
        await store.open(rootURL: notARepo)

        guard case .failed(let message) = store.loadState else {
            Issue.record("expected a failed open, got \(store.loadState)")
            return
        }
        #expect(message.contains("doesn't look like a Munki repository"))
        #expect(message.contains("pkgsinfo"))
        #expect(store.repository == nil)
        // A rejected folder must not pollute Recent — otherwise it also
        // makes the install look "configured" and suppresses onboarding.
        #expect(store.recentRepositories.isEmpty)
        #expect(defaults.array(forKey: RepositoryStore.recentsKey) == nil)
    }

    @Test("an empty folder is rejected, not opened as a blank repo")
    func rejectsEmptyFolder() async throws {
        let (defaults, suite) = Self.makeScratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let empty = try Self.makeRepo(directories: [])
        defer { try? FileManager.default.removeItem(at: empty) }

        let store = Self.makeStore(defaults: defaults)
        await store.open(rootURL: empty)

        #expect(store.repository == nil)
        if case .failed = store.loadState {} else {
            Issue.record("expected a failed open, got \(store.loadState)")
        }
    }

    @Test("a partial repo opens but says what's missing")
    func partialRepoOpensWithWarnings() async throws {
        let (defaults, suite) = Self.makeScratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        // A freshly initialised repo: pkgsinfo + manifests, nothing else.
        let root = try Self.makeRepo(directories: ["pkgsinfo", "manifests"])
        defer { try? FileManager.default.removeItem(at: root) }

        let store = Self.makeStore(defaults: defaults)
        await store.open(rootURL: root)

        #expect(store.loadState == .ready)
        #expect(store.repository != nil)
        #expect(store.repositoryWarnings.count == 2)
        #expect(store.repositoryWarnings.contains { $0.contains("catalogs/") })
        #expect(store.repositoryWarnings.contains { $0.contains("pkgs/") })
    }

    @Test("warnings from a bad open don't linger over the next good one")
    func warningsResetBetweenOpens() async throws {
        let (defaults, suite) = Self.makeScratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let partial = try Self.makeRepo(directories: ["pkgsinfo", "manifests"])
        let complete = try Self.makeRepo()
        defer {
            try? FileManager.default.removeItem(at: partial)
            try? FileManager.default.removeItem(at: complete)
        }

        let store = Self.makeStore(defaults: defaults)
        await store.open(rootURL: partial)
        #expect(!store.repositoryWarnings.isEmpty)

        await store.open(rootURL: complete)
        #expect(store.repositoryWarnings.isEmpty)
        #expect(store.loadState == .ready)
    }

    /// Guards the fix directly: the sheet's presentation is stored state,
    /// so completing the repository step leaves the wizard up.
    @Test("opening a repo during the wizard leaves the sheet up")
    func wizardSurvivesItsOwnRepositoryStep() async throws {
        let (defaults, suite) = Self.makeScratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = try Self.makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = Self.makeStore(defaults: defaults)
        store.isShowingOnboarding = true

        await store.open(rootURL: root)

        #expect(store.isShowingOnboarding, "the wizard must survive its own repository step")
        #expect(store.recentRepositories.count == 1)
    }

    @Test("recents are capped, de-duplicated, and newest-first")
    func recentsBehaviour() async throws {
        let (defaults, suite) = Self.makeScratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = try Self.makeRepo()
        let second = try Self.makeRepo()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        let store = Self.makeStore(defaults: defaults)
        await store.open(rootURL: first)
        await store.open(rootURL: second)
        await store.open(rootURL: first)

        #expect(store.recentRepositories == [first, second])

        // Recents persist to the injected domain, never to .standard.
        let persisted = defaults.array(forKey: RepositoryStore.recentsKey) as? [String]
        #expect(persisted == [first.path, second.path])
        #expect(
            UserDefaults.standard.array(forKey: RepositoryStore.recentsKey) as? [String] != [first.path, second.path]
        )
    }

    @Test("clearing recents empties the list and the stored key")
    func clearRecents() async throws {
        let (defaults, suite) = Self.makeScratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = try Self.makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = Self.makeStore(defaults: defaults)
        await store.open(rootURL: root)
        #expect(!store.recentRepositories.isEmpty)

        store.clearRecents()

        #expect(store.recentRepositories.isEmpty)
        #expect(defaults.array(forKey: RepositoryStore.recentsKey) == nil)
        // A cleared install reads as unconfigured again, so a reset
        // genuinely returns the user to the first-run wizard.
        #expect(
            !OnboardingGate.isAlreadyConfigured(
                recentRepositoryCount: store.recentRepositories.count,
                featurePaths: ["", "", ""]
            )
        )
    }

    @Test("removing one recent leaves the others")
    func removeRecent() async throws {
        let (defaults, suite) = Self.makeScratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = try Self.makeRepo()
        let second = try Self.makeRepo()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        let store = Self.makeStore(defaults: defaults)
        await store.open(rootURL: first)
        await store.open(rootURL: second)

        store.removeRecent(first)

        #expect(store.recentRepositories == [second])
        #expect(defaults.array(forKey: RepositoryStore.recentsKey) as? [String] == [second.path])
    }
}
