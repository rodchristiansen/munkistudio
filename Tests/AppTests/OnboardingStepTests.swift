import Foundation
import Testing
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

    @Test("a YAML promoter config reads as found", arguments: ["promoter.yml", "promoter.yaml"])
    func findsYamlPromoterConfig(name: String) throws {
        let root = try Self.makeFolder(containing: [name])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(OnboardingView.describePromoterConfig(in: root) == "Found \(name).")
    }

    /// plist is the project's default on-disk format, so a deployment
    /// folder can legitimately hold `promoter.plist`. It must be
    /// recognised — but reported honestly, because the promoter service
    /// parses YAML only.
    @Test("a plist promoter config is recognised but flagged as not yet loadable")
    func findsPlistPromoterConfig() throws {
        let root = try Self.makeFolder(containing: ["promoter.plist"])
        defer { try? FileManager.default.removeItem(at: root) }

        let description = OnboardingView.describePromoterConfig(in: root)
        #expect(description.contains("promoter.plist"))
        #expect(description.contains("YAML only"))
    }

    @Test("YAML wins when both a YAML and a plist config are present")
    func yamlWinsOverPlist() throws {
        let root = try Self.makeFolder(containing: ["promoter.yml", "promoter.plist"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(OnboardingView.describePromoterConfig(in: root) == "Found promoter.yml.")
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
