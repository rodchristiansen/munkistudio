import Testing
@testable import App

@Suite("Onboarding gate")
struct OnboardingGateTests {
    @Test("a fresh install sees the wizard")
    func freshInstallPresents() {
        #expect(
            OnboardingGate.shouldPresentOnLaunch(
                hasCompletedOnboarding: false,
                isAlreadyConfigured: false
            )
        )
    }

    @Test("a completed install never sees it again")
    func completedNeverPresents() {
        #expect(
            !OnboardingGate.shouldPresentOnLaunch(
                hasCompletedOnboarding: true,
                isAlreadyConfigured: false
            )
        )
        #expect(
            !OnboardingGate.shouldPresentOnLaunch(
                hasCompletedOnboarding: true,
                isAlreadyConfigured: true
            )
        )
    }

    @Test("an upgrade into a build with new steps doesn't re-prompt a working install")
    func configuredInstallIsSuppressed() {
        #expect(
            !OnboardingGate.shouldPresentOnLaunch(
                hasCompletedOnboarding: false,
                isAlreadyConfigured: true
            )
        )
    }

    /// The regression that made the wizard unusable: the presentation
    /// condition was recomputed live, so completing the repository step
    /// flipped `isAlreadyConfigured` to `true` and dismissed the sheet
    /// mid-flow. The gate is a launch-time decision, and this pins the
    /// two evaluations that must not be conflated.
    @Test("opening a repo mid-wizard would flip the launch condition — so it must only be read once")
    func midWizardRepoOpenFlipsTheCondition() {
        let beforeRepoPicked = OnboardingGate.isAlreadyConfigured(
            recentRepositoryCount: 0,
            featurePaths: ["", "", ""]
        )
        let afterRepoPicked = OnboardingGate.isAlreadyConfigured(
            recentRepositoryCount: 1,
            featurePaths: ["", "", ""]
        )
        #expect(beforeRepoPicked == false)
        #expect(afterRepoPicked == true)

        // Same inputs, evaluated at launch: the wizard opens. If this
        // condition were re-read after the repo step it would say
        // "don't present" — which is exactly the bug.
        #expect(
            OnboardingGate.shouldPresentOnLaunch(
                hasCompletedOnboarding: false,
                isAlreadyConfigured: beforeRepoPicked
            )
        )
        #expect(
            !OnboardingGate.shouldPresentOnLaunch(
                hasCompletedOnboarding: false,
                isAlreadyConfigured: afterRepoPicked
            )
        )
    }

    @Test("a recent repository counts as configured")
    func recentsCountAsConfigured() {
        #expect(
            OnboardingGate.isAlreadyConfigured(
                recentRepositoryCount: 1,
                featurePaths: []
            )
        )
    }

    @Test("any non-blank feature path counts as configured")
    func featurePathsCountAsConfigured() {
        #expect(
            OnboardingGate.isAlreadyConfigured(
                recentRepositoryCount: 0,
                featurePaths: ["", "/Users/someone/projects", ""]
            )
        )
    }

    @Test("whitespace-only feature paths don't count")
    func blankPathsDontCount() {
        #expect(
            !OnboardingGate.isAlreadyConfigured(
                recentRepositoryCount: 0,
                featurePaths: ["", "   ", "\t"]
            )
        )
    }

    @Test("completion is backfilled once for a configured install, then left alone")
    func backfillOnlyOnce() {
        #expect(
            OnboardingGate.shouldBackfillCompletion(
                hasCompletedOnboarding: false,
                isAlreadyConfigured: true
            )
        )
        #expect(
            !OnboardingGate.shouldBackfillCompletion(
                hasCompletedOnboarding: true,
                isAlreadyConfigured: true
            )
        )
        // A genuinely fresh install must NOT be backfilled — that would
        // mark onboarding done before the user ever saw it.
        #expect(
            !OnboardingGate.shouldBackfillCompletion(
                hasCompletedOnboarding: false,
                isAlreadyConfigured: false
            )
        )
    }
}
