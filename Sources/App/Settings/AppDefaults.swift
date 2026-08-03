import Foundation

/// Where MunkiStudio persists preferences, and the resets that let
/// someone walk first-run onboarding again without editing `defaults` by
/// hand.
///
/// Sandbox mode (`--sandbox`, or `MUNKISTUDIO_SANDBOX=1`) swaps the
/// standard domain for a throwaway suite that is wiped on every launch,
/// so each run is a genuine fresh install. Nothing downstream knows about
/// it — the settings object and the repository store are simply handed a
/// different `UserDefaults`.
enum AppDefaults {
    /// Preference suite used in sandbox mode. A separate domain from the
    /// real one, so a sandbox run can never touch real settings.
    static let sandboxSuiteName = "systems.focused.MunkiStudio.sandbox"

    static let launchArgument = "--sandbox"
    static let environmentVariable = "MUNKISTUDIO_SANDBOX"

    /// True when this launch was asked to run against the throwaway
    /// suite. Both spellings exist because `open` can pass arguments
    /// (`open -a MunkiStudio --args --sandbox`) but a plain double-click
    /// can't, while `launchctl setenv` reaches either.
    static func isSandbox(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if arguments.contains(launchArgument) { return true }
        guard let raw = environment[environmentVariable] else { return false }
        return isTruthy(raw)
    }

    /// The defaults every persisted setting reads and writes. In sandbox
    /// mode the suite is wiped first, so onboarding always runs from
    /// scratch. Call once, at launch — it has a side effect.
    static func makeLaunchDefaults(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> UserDefaults {
        guard isSandbox(arguments: arguments, environment: environment),
              let suite = UserDefaults(suiteName: sandboxSuiteName)
        else { return .standard }
        suite.removePersistentDomain(forName: sandboxSuiteName)
        // `UserDefaults(suiteName:)` does *not* isolate reads: the app's
        // own bundle domain stays in the instance's search list, so a
        // wiped suite still reads the real install's settings straight
        // through and the wizard never appears. Drop that domain so the
        // sandbox starts genuinely empty.
        if let appDomain = Bundle.main.bundleIdentifier {
            suite.removeSuite(named: appDomain)
        }
        return suite
    }

    /// Every key MunkiStudio owns. A reset clears exactly these —
    /// anything else in the domain (window frames, split-view autosaves)
    /// belongs to AppKit and is left alone.
    static var ownedKeys: [String] {
        AppSettings.allKeys + [RepositoryStore.recentsKey]
    }

    /// Wipe every MunkiStudio-owned key, returning the install to a
    /// fresh state — the next launch shows onboarding again.
    static func resetAll(in defaults: UserDefaults) {
        for key in ownedKeys { defaults.removeObject(forKey: key) }
    }

    static func isTruthy(_ raw: String) -> Bool {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "1", "true", "yes", "on": true
        default: false
        }
    }
}
