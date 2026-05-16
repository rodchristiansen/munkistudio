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
            munkiimport: MunkiimportRunner()
        )
        _store = State(wrappedValue: RepositoryStore(services: services))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(settings)
                .frame(minWidth: 1100, minHeight: 700)
        }
        .commands {
            MunkiStudioCommands(store: store)
        }

        Settings {
            SettingsView()
                .environment(settings)
        }
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
}
