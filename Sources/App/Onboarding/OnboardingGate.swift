import Foundation

/// Decides whether the first-run wizard opens on a given launch.
///
/// Pure on purpose. Every problem the first round of testing turned up
/// here was a decision bug, not a drawing bug, and a decision that lives
/// in a `View`'s computed binding can't be tested — or reasoned about,
/// which is how the sheet ended up tearing itself down mid-flow.
enum OnboardingGate {
    /// Whether the wizard should open on this launch.
    ///
    /// Evaluate **once**, at launch, and store the answer. It must never
    /// back a live SwiftUI binding: opening a repository inside the
    /// wizard makes the install "configured", so a recomputed binding
    /// flips to `false` the instant the user completes the repository
    /// step and yanks the sheet away before they can finish it.
    static func shouldPresentOnLaunch(
        hasCompletedOnboarding: Bool,
        isAlreadyConfigured: Bool
    ) -> Bool {
        !hasCompletedOnboarding && !isAlreadyConfigured
    }

    /// True once the install carries real configuration: a repository
    /// opened at some point, or a feature folder set by hand in
    /// Settings. Keeps first-run onboarding away from a working install
    /// upgrading into a build that adds new steps.
    static func isAlreadyConfigured(
        recentRepositoryCount: Int,
        featurePaths: [String]
    ) -> Bool {
        if recentRepositoryCount > 0 { return true }
        return featurePaths.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Whether an already-configured install that has never recorded a
    /// completion should have one written now. Without this, every
    /// launch re-runs the suppression check; with it, the flag sticks.
    static func shouldBackfillCompletion(
        hasCompletedOnboarding: Bool,
        isAlreadyConfigured: Bool
    ) -> Bool {
        !hasCompletedOnboarding && isAlreadyConfigured
    }
}
