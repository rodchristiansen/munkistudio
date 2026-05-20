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
    }
}
