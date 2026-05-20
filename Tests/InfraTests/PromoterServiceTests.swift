import Foundation
import Testing
import Core
@testable import Infra

@Suite("Promoter config parser and candidate computation")
struct PromoterServiceTests {
    @Test("parses promoter.yml with custom_items overrides")
    func parsesPromoterYaml() throws {
        let yaml = """
        promotions:
          testing to staging:
            promote_from:
              - Development
              - Testing
            promote_to:
              - Development
              - Testing
              - Staging
            days_in_catalog: 1
            custom_items:
              "macOS-*":
                days_in_catalog: 3
          staging to production:
            promote_from:
              - Development
              - Testing
              - Staging
            promote_to:
              - Development
              - Testing
              - Staging
              - Production
            days_in_catalog: 1
        """
        let config = try FilePromoterService.parseConfig(yaml)
        #expect(config.rules.count == 2)
        let testingToStaging = try #require(config.rules.first { $0.name == "testing to staging" })
        #expect(testingToStaging.promoteFrom == ["Development", "Testing"])
        #expect(testingToStaging.promoteTo == ["Development", "Testing", "Staging"])
        #expect(testingToStaging.daysInCatalog == 1)
        #expect(testingToStaging.daysInCatalog(for: "macOS-Sequoia") == 3)
        #expect(testingToStaging.daysInCatalog(for: "Firefox") == 1)
    }

    @Test("nextRule matches by exact catalog set")
    func nextRuleMatch() {
        let config = PromoterConfig(rules: [
            PromotionRule(
                name: "a",
                promoteFrom: ["Development", "Testing"],
                promoteTo: ["Development", "Testing", "Staging"],
                daysInCatalog: 1
            ),
            PromotionRule(
                name: "b",
                promoteFrom: ["Development", "Testing", "Staging"],
                promoteTo: ["Development", "Testing", "Staging", "Production"],
                daysInCatalog: 1
            ),
        ])
        #expect(config.nextRule(forCatalogs: ["Testing", "Development"])?.name == "a")
        #expect(config.nextRule(forCatalogs: ["Staging", "Testing", "Development"])?.name == "b")
        #expect(config.nextRule(forCatalogs: ["Production"]) == nil)
    }

    @Test("candidate computation flags eligible items past the aging window")
    func candidatesEligibility() {
        let now = Date(timeIntervalSince1970: 1_715_000_000)
        let twoDaysAgo = now.addingTimeInterval(-2 * 86_400)
        let oneHourAgo = now.addingTimeInterval(-3_600)

        let config = PromoterConfig(rules: [
            PromotionRule(
                name: "testing to staging",
                promoteFrom: ["Development", "Testing"],
                promoteTo: ["Development", "Testing", "Staging"],
                daysInCatalog: 1
            ),
        ])

        var firefox = Pkginfo(name: "Firefox")
        firefox.version = "126.0"
        firefox.catalogs = ["Development", "Testing"]
        firefox.metadata = [
            "munki-promoter_edit_date": .string(FilePromoterService.formatISO8601(twoDaysAgo))
        ]

        var slack = Pkginfo(name: "Slack")
        slack.version = "4.0"
        slack.catalogs = ["Development", "Testing"]
        slack.metadata = [
            "munki-promoter_edit_date": .string(FilePromoterService.formatISO8601(oneHourAgo))
        ]

        var production = Pkginfo(name: "Excluded")
        production.version = "1.0"
        production.catalogs = ["Production"]

        let records = [firefox, slack, production].enumerated().map { index, p in
            PkginfoRecord(
                pkginfo: p,
                fileURL: URL(fileURLWithPath: "/tmp/\(p.name)-\(index).yaml"),
                format: .yaml,
                modifiedAt: now
            )
        }

        let candidates = FilePromoterService.candidates(from: records, config: config, now: now)
        #expect(candidates.count == 2)

        let firefoxCandidate = candidates.first { $0.pkgName == "Firefox" }
        let slackCandidate = candidates.first { $0.pkgName == "Slack" }

        #expect(firefoxCandidate?.isEligible(on: now) == true)
        #expect(slackCandidate?.isEligible(on: now) == false)
        #expect(candidates.first?.pkgName == "Firefox") // eligible first
        #expect(candidates.contains { $0.pkgName == "Excluded" } == false)
    }

    @Test("ISO 8601 parser accepts plain and fractional-seconds forms")
    func iso8601Parser() {
        let plain = "2026-05-19T14:14:20Z"
        let fractional = "2026-05-19T14:14:20.123Z"
        #expect(FilePromoterService.parseISO8601(plain) != nil)
        #expect(FilePromoterService.parseISO8601(fractional) != nil)
        #expect(FilePromoterService.parseISO8601("not a date") == nil)
    }
}
