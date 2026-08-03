import Foundation
import Testing
@testable import App

@Suite("Sandbox mode + settings reset")
struct AppDefaultsTests {
    /// A throwaway defaults domain per test, so nothing here can touch a
    /// real install's preferences.
    private static func makeScratchDefaults() -> (UserDefaults, String) {
        let suite = "MunkiStudioTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    @Test("the launch argument selects sandbox mode")
    func launchArgumentSelectsSandbox() {
        #expect(AppDefaults.isSandbox(arguments: ["MunkiStudio", "--sandbox"], environment: [:]))
        #expect(!AppDefaults.isSandbox(arguments: ["MunkiStudio"], environment: [:]))
    }

    @Test("the environment variable selects sandbox mode", arguments: ["1", "true", "TRUE", "yes", "on", " 1 "])
    func environmentSelectsSandbox(value: String) {
        #expect(
            AppDefaults.isSandbox(
                arguments: ["MunkiStudio"],
                environment: [AppDefaults.environmentVariable: value]
            )
        )
    }

    @Test("an off-ish environment value doesn't select sandbox mode", arguments: ["0", "false", "no", "", "off"])
    func environmentOffDoesNotSelectSandbox(value: String) {
        #expect(
            !AppDefaults.isSandbox(
                arguments: ["MunkiStudio"],
                environment: [AppDefaults.environmentVariable: value]
            )
        )
    }

    @Test("a normal launch uses the standard domain, not the sandbox suite")
    func normalLaunchUsesStandardDefaults() {
        let defaults = AppDefaults.makeLaunchDefaults(arguments: ["MunkiStudio"], environment: [:])
        #expect(defaults === UserDefaults.standard)
    }

    @Test("a sandbox launch starts from a wiped suite every time")
    func sandboxLaunchWipesItsSuite() {
        // Dirty the sandbox suite as though a previous sandbox run had
        // completed onboarding and opened a repo.
        let previous = UserDefaults(suiteName: AppDefaults.sandboxSuiteName)!
        previous.set(true, forKey: "MunkiStudio.settings.hasCompletedOnboarding")
        previous.set(["/tmp/repo"], forKey: RepositoryStore.recentsKey)

        let defaults = AppDefaults.makeLaunchDefaults(
            arguments: ["MunkiStudio", "--sandbox"],
            environment: [:]
        )

        #expect(defaults !== UserDefaults.standard)
        #expect(defaults.bool(forKey: "MunkiStudio.settings.hasCompletedOnboarding") == false)
        #expect(defaults.array(forKey: RepositoryStore.recentsKey) == nil)

        defaults.removePersistentDomain(forName: AppDefaults.sandboxSuiteName)
    }

    @Test("settings persist and round-trip through their defaults domain")
    @MainActor
    func settingsRoundTrip() {
        let (defaults, suite) = Self.makeScratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        // Fresh-install expectations — the two that decide onboarding.
        #expect(settings.hasCompletedOnboarding == false)
        #expect(settings.reopenLastRepositoryOnLaunch == true)

        settings.hasCompletedOnboarding = true
        settings.autopkgDeploymentPath = "/tmp/deployment"
        settings.enablePromoterTab = true

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.hasCompletedOnboarding)
        #expect(reloaded.autopkgDeploymentPath == "/tmp/deployment")
        #expect(reloaded.enablePromoterTab)
    }

    @Test("reset returns every setting to its fresh-install value, in memory and on disk")
    @MainActor
    func resetClearsEverything() {
        let (defaults, suite) = Self.makeScratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        settings.hasCompletedOnboarding = true
        settings.reopenLastRepositoryOnLaunch = false
        settings.showGitSection = false
        settings.munkipkgProjectsPath = "/tmp/projects"
        settings.autopkgDeploymentPath = "/tmp/deployment"
        settings.profilesDirectoryPath = "/tmp/profiles"
        settings.enablePromoterTab = true
        settings.enableProfilesTab = true
        settings.promoterHiddenCatalogs = "Development"
        settings.gitHooksPathOverride = "/tmp/hooks"
        settings.munkipkgExecutablePath = "/tmp/munkipkg"

        settings.resetToDefaults()

        #expect(settings.hasCompletedOnboarding == false)
        #expect(settings.reopenLastRepositoryOnLaunch == true)
        #expect(settings.showGitSection == true)
        #expect(settings.munkipkgProjectsPath.isEmpty)
        #expect(settings.autopkgDeploymentPath.isEmpty)
        #expect(settings.profilesDirectoryPath.isEmpty)
        #expect(settings.enablePromoterTab == false)
        #expect(settings.enableProfilesTab == false)
        #expect(settings.promoterHiddenCatalogs.isEmpty)
        #expect(settings.gitHooksPathOverride.isEmpty)
        #expect(settings.munkipkgExecutablePath.isEmpty)

        // And the reset must survive a relaunch, not just live in memory.
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.hasCompletedOnboarding == false)
        #expect(reloaded.autopkgDeploymentPath.isEmpty)
        #expect(reloaded.enablePromoterTab == false)
    }

    /// A setting missing from `allKeys` would survive "Reset All
    /// Settings" and quietly keep an install out of the first-run state.
    @Test("every settings key is covered by the reset list")
    @MainActor
    func resetListCoversEveryWrittenKey() {
        let (defaults, suite) = Self.makeScratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        settings.hasCompletedOnboarding = true
        settings.reopenLastRepositoryOnLaunch = false
        settings.showGitSection = false
        settings.munkipkgProjectsPath = "/tmp/projects"
        settings.autopkgDeploymentPath = "/tmp/deployment"
        settings.profilesDirectoryPath = "/tmp/profiles"
        settings.enablePromoterTab = true
        settings.enableProfilesTab = true
        settings.promoterHiddenCatalogs = "Development"
        settings.gitHooksPathOverride = "/tmp/hooks"
        settings.munkipkgExecutablePath = "/tmp/munkipkg"

        let written = Set(defaults.dictionaryRepresentation().keys)
            .filter { $0.hasPrefix("MunkiStudio.") }
        let covered = Set(AppSettings.allKeys)
        #expect(written.subtracting(covered).isEmpty)
    }

    @Test("the owned-key list covers settings and the recents list")
    func ownedKeysIncludeRecents() {
        #expect(AppDefaults.ownedKeys.contains(RepositoryStore.recentsKey))
        for key in AppSettings.allKeys {
            #expect(AppDefaults.ownedKeys.contains(key))
        }
    }

    @Test("resetAll wipes MunkiStudio keys and leaves other keys alone")
    func resetAllIsScoped() {
        let (defaults, suite) = Self.makeScratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(true, forKey: "MunkiStudio.settings.hasCompletedOnboarding")
        defaults.set(["/tmp/repo"], forKey: RepositoryStore.recentsKey)
        // AppKit's, not ours — a reset must not touch it.
        defaults.set("frame", forKey: "NSWindow Frame MainWindow")

        AppDefaults.resetAll(in: defaults)

        #expect(defaults.bool(forKey: "MunkiStudio.settings.hasCompletedOnboarding") == false)
        #expect(defaults.array(forKey: RepositoryStore.recentsKey) == nil)
        #expect(defaults.string(forKey: "NSWindow Frame MainWindow") == "frame")
    }
}
