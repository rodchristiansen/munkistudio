import Foundation
import Testing
import Infra
@testable import App

@Suite("Onboarding steps")
struct OnboardingStepTests {
    @Test("welcome comes first and the repository step comes straight after")
    func repositoryIsTheFirstRealStep() {
        #expect(OnboardingView.Step.allCases.first == .welcome)
        #expect(OnboardingView.Step(rawValue: 1) == .repository)
    }

    /// Promoter is the least common setup and the most likely to be
    /// skipped, so it must not sit between the user and anything else.
    @Test("promoter is the last step")
    func promoterIsLast() {
        #expect(OnboardingView.Step.allCases.last == .promoter)
    }

    @Test("every step is reachable in order with no gaps")
    func stepsAreContiguous() {
        for (index, step) in OnboardingView.Step.allCases.enumerated() {
            #expect(step.rawValue == index)
        }
    }

    @Test(
        "every config filename the Promoter tab reads is reported as found",
        arguments: ["promoter.yml", "promoter.yaml", "config.yml", "config.yaml"]
    )
    func findsPromoterConfig(name: String) throws {
        let root = try Self.makeFolder(containing: [name])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(OnboardingView.describePromoterConfig(in: root) == "Found \(name).")
    }

    /// munki-promoter parses its config with `yaml.safe_load` only —
    /// there is no plist form. Claiming otherwise sent people looking
    /// for a file the tool never reads.
    @Test("a plist is not treated as a promoter config")
    func plistIsNotAConfig() throws {
        let root = try Self.makeFolder(containing: ["promoter.plist"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(OnboardingView.describePromoterConfig(in: root).contains("No promoter config"))
    }

    /// What onboarding reports and what the tab loads must not drift, so
    /// this step asks the service rather than keeping its own list.
    @Test("the step reports exactly the filenames the service reads")
    func stepAgreesWithService() throws {
        for name in FilePromoterService.configFileNames {
            let root = try Self.makeFolder(containing: [name])
            defer { try? FileManager.default.removeItem(at: root) }
            #expect(OnboardingView.describePromoterConfig(in: root) == "Found \(name).")
        }
    }

    @Test("a folder with no promoter config says so")
    func noPromoterConfig() throws {
        let root = try Self.makeFolder(containing: ["recipe_list.yaml"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(OnboardingView.describePromoterConfig(in: root).contains("No promoter config"))
    }

    private static func makeFolder(containing files: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "promoter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in files {
            try Data().write(to: root.appending(path: name))
        }
        return root
    }
}
