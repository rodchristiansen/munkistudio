import SwiftUI
import Core
import Infra

/// Application entry. Owns the long-lived ``RepositoryStore`` and the
/// concrete service implementations from Infra. Everything below the
/// scene boundary reaches services through the store rather than touching
/// global state.
@main
struct MunkiStudioApp: SwiftUI.App {
    @State private var store: RepositoryStore
    @State private var settings = AppSettings()
    @State private var promoterStore = PromoterStore()
    @State private var profileStore = ProfileStore()

    init() {
        let packages = FilePackageService()
        let manifests = FileManifestService()
        let catalogs = FileCatalogService()
        let icons = FileIconService()
        let repository = FileRepositoryService(
            packages: packages,
            manifests: manifests,
            catalogs: catalogs,
            icons: icons
        )
        let services = AppServices(
            repository: repository,
            packages: packages,
            manifests: manifests,
            catalogs: catalogs,
            icons: icons,
            git: ShellGitService(),
            makecatalogs: MakecatalogsRunner(),
            munkiimport: MunkiimportRunner(),
            munkipkg: MunkipkgRunner(),
            iconImporter: IconImporterRunner(),
            repoClean: RepoCleanRunner(),
            repoCleanHistory: RepoCleanHistoryStore(),
            promoter: FilePromoterService(packages: packages),
            testing: FileTestingService()
        )
        _store = State(wrappedValue: RepositoryStore(services: services))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(settings)
                .environment(promoterStore)
                .environment(profileStore)
                .frame(minWidth: 1100, minHeight: 700)
                .task(id: promoterRefreshKey) {
                    guard settings.enablePromoterTab else {
                        promoterStore.snapshot = .empty
                        return
                    }
                    await promoterStore.refresh(
                        store: store,
                        deploymentRoot: promoterDeploymentURL
                    )
                }
                .task(id: settings.profilesDirectoryPath) {
                    await profileStore.reload(directory: profilesDirectoryURL)
                }
        }
        .commands {
            MunkiStudioCommands(store: store)
        }

        Settings {
            SettingsView()
                .environment(settings)
                .environment(store)
                .environment(promoterStore)
                .environment(profileStore)
        }
    }

    /// Re-run the promoter refresh whenever any input changes: the
    /// repository, deployment path, or the pkginfo count (a save just
    /// landed or the repo finished loading).
    private var promoterRefreshKey: String {
        let repoPath = store.repository?.rootURL.path ?? "-"
        let deployment = settings.autopkgDeploymentPath
        let enabled = settings.enablePromoterTab ? "1" : "0"
        return "\(enabled)|\(repoPath)|\(deployment)|\(store.snapshot.pkginfos.count)"
    }

    private var promoterDeploymentURL: URL? {
        let path = settings.autopkgDeploymentPath.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    private var profilesDirectoryURL: URL? {
        let path = settings.profilesDirectoryPath.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty, settings.enableProfilesTab else { return nil }
        return URL(fileURLWithPath: path)
    }
}

/// Bag of every service the App layer needs. Constructed once at launch
/// and held by the ``RepositoryStore``; views never see it directly so
/// tests can swap in fakes without ceremony.
struct AppServices: Sendable {
    let repository: any RepositoryService
    let packages: any PackageService
    let manifests: any ManifestService
    let catalogs: any CatalogService
    let icons: any IconService
    let git: any GitService
    let makecatalogs: any MakecatalogsService
    let munkiimport: any MunkiimportService
    let munkipkg: any MunkipkgService
    let iconImporter: any IconImporterService
    let repoClean: any RepoCleanService
    let repoCleanHistory: any RepoCleanHistoryService
    let promoter: any PromoterService
    let testing: any TestingService
}
