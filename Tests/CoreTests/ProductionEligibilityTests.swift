import Foundation
import Testing
@testable import Core

@Suite("Production eligibility badges")
struct ProductionEligibilityTests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let testing = ["Development", "Testing"]
    let staging = ["Development", "Testing", "Staging"]
    let production = ["Development", "Testing", "Staging", "Production"]

    private func candidate(from: [String], to: [String], edited: Date, days: Int = 1) -> PromotionCandidate {
        PromotionCandidate(pkginfoURL: URL(fileURLWithPath: "/repo/pkgsinfo/Example.yaml"),
                           pkgName: "Example", version: "2.0", currentCatalogs: from,
                           targetCatalogs: to, ruleName: "Next stage", lastEditDate: edited, requiredDays: days)
    }

    @Test("eligible labels name the actual next stage")
    func stageLabels() {
        let first = candidate(from: testing, to: staging, edited: now.addingTimeInterval(-172_800))
        #expect(first.readinessLabel(on: now) == "Eligible for Staging")
        let last = candidate(from: staging, to: production, edited: now.addingTimeInterval(-172_800))
        #expect(last.readinessLabel(on: now) == "Eligible for Production")
        let future = candidate(from: staging, to: production, edited: now.addingTimeInterval(-3_600))
        #expect(future.readinessLabel(on: now) == "Production eligible in 1d")
    }

    @Test("Testing countdown includes the remaining Staging window")
    func multiStage() throws {
        let value = candidate(from: testing, to: staging, edited: now)
        let config = PromoterConfig(rules: [PromotionRule(name: "Production", promoteFrom: staging,
                                                         promoteTo: production, daysInCatalog: 1)])
        let outlook = try #require(value.productionEligibility(using: config, on: now))
        #expect(outlook.includesFutureStages)
        #expect(outlook.badgeLabel(on: now) == "Production earliest in 2d")
    }

    @Test("an overdue first stage cannot backdate time spent in the next stage")
    func overdueStage() throws {
        let value = candidate(from: testing, to: staging, edited: now.addingTimeInterval(-7 * 86_400))
        let config = PromoterConfig(rules: [PromotionRule(name: "Production", promoteFrom: staging,
                                                         promoteTo: production, daysInCatalog: 2)])
        let outlook = try #require(value.productionEligibility(using: config, on: now))
        #expect(outlook.badgeLabel(on: now) == "Production earliest in 2d")
    }

    @Test("direct Production eligibility is not a claim that publication happened")
    func directStage() throws {
        let value = candidate(from: staging, to: production, edited: now.addingTimeInterval(-172_800))
        let outlook = try #require(value.productionEligibility(using: PromoterConfig(rules: []), on: now))
        #expect(!outlook.includesFutureStages)
        #expect(outlook.badgeLabel(on: now) == "Eligible for Production")
    }

    @Test("disconnected and cyclic rules do not invent a Production date")
    func incompletePaths() {
        let value = candidate(from: testing, to: staging, edited: now)
        #expect(value.productionEligibility(using: PromoterConfig(rules: []), on: now) == nil)
        let cycle = PromoterConfig(rules: [PromotionRule(name: "Back", promoteFrom: staging,
                                                        promoteTo: testing, daysInCatalog: 1)])
        #expect(value.productionEligibility(using: cycle, on: now) == nil)
    }
}
