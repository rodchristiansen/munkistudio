import Foundation
import Observation
import Core

/// App-wide preferences, persisted to `UserDefaults`. Non-secret values
/// only — API tokens and PATs belong in the Keychain, never here. Each
/// feature that ships an opt-in surface (Pipelines, AI agents, …) adds
/// its own properties to this type as it lands.
@Observable
final class AppSettings {
    /// Auto-open the most recently used repository on launch.
    var reopenLastRepositoryOnLaunch: Bool {
        didSet { defaults.set(reopenLastRepositoryOnLaunch, forKey: Key.reopenLastRepository) }
    }

    /// Whether the first-run onboarding wizard has been completed or
    /// skipped. `false` on a fresh install shows the wizard once.
    var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Key.hasCompletedOnboarding) }
    }

    /// Overrides the auto-detected git hooks directory. Empty = auto.
    var gitHooksPathOverride: String {
        didSet { defaults.set(gitHooksPathOverride, forKey: Key.gitHooksPathOverride) }
    }

    /// Show the Git tab. It only ever appears when the open repository is
    /// a git working tree; this lets the user hide it even then.
    var showGitSection: Bool {
        didSet { defaults.set(showGitSection, forKey: Key.showGitSection) }
    }

    /// Folder of munkipkg package-source projects the Build tab scans.
    var munkipkgProjectsPath: String {
        didSet { defaults.set(munkipkgProjectsPath, forKey: Key.munkipkgProjectsPath) }
    }

    /// Path to the `munkipkg` executable. Empty = the standard
    /// `/usr/local/munki/munkipkg`.
    var munkipkgExecutablePath: String {
        didSet { defaults.set(munkipkgExecutablePath, forKey: Key.munkipkgExecutablePath) }
    }

    /// Show the Promoter tab. Off by default — opt-in from onboarding or
    /// Settings → Features. Requires `autopkgDeploymentPath` to point at
    /// the directory holding `promoter.yml`.
    var enablePromoterTab: Bool {
        didSet { defaults.set(enablePromoterTab, forKey: Key.enablePromoterTab) }
    }

    /// Folder holding the AutoPkg deployment files (`promoter.yml`,
    /// `recipe_list.yaml`, etc.). The Promoter tab reads `promoter.yml`
    /// from here.
    var autopkgDeploymentPath: String {
        didSet { defaults.set(autopkgDeploymentPath, forKey: Key.autopkgDeploymentPath) }
    }

    /// Catalog names hidden from the Promoter tab's display. Many teams
    /// have an internal staging-only catalog (e.g. "Development") that
    /// every pkginfo always lives in — surfacing it in every transition
    /// label is noise. Comma-separated; trimmed and lowercased on read.
    var promoterHiddenCatalogs: String {
        didSet { defaults.set(promoterHiddenCatalogs, forKey: Key.promoterHiddenCatalogs) }
    }

    /// Parsed view of ``promoterHiddenCatalogs`` for the UI. Empty set
    /// when the field is empty so every catalog is shown by default —
    /// nothing is hidden until the user opts in.
    var promoterHiddenCatalogsSet: Set<String> {
        Set(
            promoterHiddenCatalogs
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
    }

    /// Show the Profiles tab. Off by default — opt-in from onboarding or
    /// Settings → Features. Requires `profilesDirectoryPath` to point at
    /// a folder of `.mobileconfig` files.
    var enableProfilesTab: Bool {
        didSet { defaults.set(enableProfilesTab, forKey: Key.enableProfilesTab) }
    }

    /// Folder of `.mobileconfig` profiles the Profiles tab scans.
    var profilesDirectoryPath: String {
        didSet { defaults.set(profilesDirectoryPath, forKey: Key.profilesDirectoryPath) }
    }

    /// Show the Testing tab. Off by default — opt-in from Settings →
    /// Features. Phase A surface is schema validation + a repo-local
    /// checklist; Phase C adds ephemeral install testing in Tart VMs.
    var enableTestingTab: Bool {
        didSet { defaults.set(enableTestingTab, forKey: Key.enableTestingTab) }
    }

    /// Display name attributed to checklist updates ("last tested by …").
    /// Empty = derive from the local user account at write time.
    var testerName: String {
        didSet { defaults.set(testerName, forKey: Key.testerName) }
    }

    /// Backend the Testing pane uses for install steps. `.none` skips
    /// all install steps; `.host` runs against the admin's Mac (smoke
    /// testing only); `.tart` spins up an ephemeral macOS guest per run.
    var testingEnvironmentRaw: String {
        didSet { defaults.set(testingEnvironmentRaw, forKey: Key.testingEnvironmentRaw) }
    }

    /// Tart base image used as the source for ephemeral clones — either
    /// a local VM name (`tart list`) or a remote ref
    /// (`ghcr.io/cirruslabs/macos-sequoia-base:latest`).
    var tartBaseImage: String {
        didSet { defaults.set(tartBaseImage, forKey: Key.tartBaseImage) }
    }

    /// SSH user inside the Tart guest. The base image is expected to
    /// have the admin's authorized_keys set up for this account.
    var tartSSHUser: String {
        didSet { defaults.set(tartSSHUser, forKey: Key.tartSSHUser) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.reopenLastRepositoryOnLaunch =
            defaults.object(forKey: Key.reopenLastRepository) as? Bool ?? true
        self.hasCompletedOnboarding =
            defaults.bool(forKey: Key.hasCompletedOnboarding)
        self.gitHooksPathOverride =
            defaults.string(forKey: Key.gitHooksPathOverride) ?? ""
        self.showGitSection =
            defaults.object(forKey: Key.showGitSection) as? Bool ?? true
        self.munkipkgProjectsPath =
            defaults.string(forKey: Key.munkipkgProjectsPath) ?? ""
        self.munkipkgExecutablePath =
            defaults.string(forKey: Key.munkipkgExecutablePath) ?? ""
        self.enablePromoterTab =
            defaults.bool(forKey: Key.enablePromoterTab)
        self.autopkgDeploymentPath =
            defaults.string(forKey: Key.autopkgDeploymentPath) ?? ""
        self.promoterHiddenCatalogs =
            defaults.string(forKey: Key.promoterHiddenCatalogs) ?? ""
        self.enableProfilesTab =
            defaults.bool(forKey: Key.enableProfilesTab)
        self.profilesDirectoryPath =
            defaults.string(forKey: Key.profilesDirectoryPath) ?? ""
        self.enableTestingTab =
            defaults.bool(forKey: Key.enableTestingTab)
        self.testerName =
            defaults.string(forKey: Key.testerName) ?? ""
        self.testingEnvironmentRaw =
            defaults.string(forKey: Key.testingEnvironmentRaw) ?? "none"
        self.tartBaseImage =
            defaults.string(forKey: Key.tartBaseImage) ?? ""
        self.tartSSHUser =
            defaults.string(forKey: Key.tartSSHUser) ?? "admin"
    }

    private enum Key {
        static let reopenLastRepository = "MunkiStudio.settings.reopenLastRepositoryOnLaunch"
        static let hasCompletedOnboarding = "MunkiStudio.settings.hasCompletedOnboarding"
        static let gitHooksPathOverride = "MunkiStudio.settings.gitHooksPathOverride"
        static let showGitSection = "MunkiStudio.settings.showGitSection"
        static let munkipkgProjectsPath = "MunkiStudio.settings.munkipkgProjectsPath"
        static let munkipkgExecutablePath = MunkipkgDefaults.executablePathKey
        static let enablePromoterTab = "MunkiStudio.settings.enablePromoterTab"
        static let autopkgDeploymentPath = "MunkiStudio.settings.autopkgDeploymentPath"
        static let promoterHiddenCatalogs = "MunkiStudio.settings.promoterHiddenCatalogs"
        static let enableProfilesTab = "MunkiStudio.settings.enableProfilesTab"
        static let profilesDirectoryPath = "MunkiStudio.settings.profilesDirectoryPath"
        static let enableTestingTab = "MunkiStudio.settings.enableTestingTab"
        static let testerName = "MunkiStudio.settings.testerName"
        static let testingEnvironmentRaw = "MunkiStudio.settings.testingEnvironment"
        static let tartBaseImage = "MunkiStudio.settings.tartBaseImage"
        static let tartSSHUser = "MunkiStudio.settings.tartSSHUser"
    }
}
