import Foundation
import Observation

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

    /// Overrides the auto-detected git hooks directory. Empty = auto.
    var gitHooksPathOverride: String {
        didSet { defaults.set(gitHooksPathOverride, forKey: Key.gitHooksPathOverride) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.reopenLastRepositoryOnLaunch =
            defaults.object(forKey: Key.reopenLastRepository) as? Bool ?? true
        self.gitHooksPathOverride =
            defaults.string(forKey: Key.gitHooksPathOverride) ?? ""
    }

    private enum Key {
        static let reopenLastRepository = "MunkiStudio.settings.reopenLastRepositoryOnLaunch"
        static let gitHooksPathOverride = "MunkiStudio.settings.gitHooksPathOverride"
    }
}
