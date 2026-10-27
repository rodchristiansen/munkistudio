import Foundation
import Testing
@testable import Core

@Suite("Promoter CVE evidence")
struct PromoterCVEReportTests {
    private func report() throws -> PromoterCVEReport {
        let json = #"""
        {
          "generatedAt": "2026-10-26T12:00:00.123456+00:00",
          "scannedPackages": 2,
          "failedRequests": 0,
          "applications": [
            {"name":"ExampleApp","productionVersion":"2.0","latestVersion":"2.1","lookupStatus":"queried"},
            {"name":"UnmappedApp","lookupStatus":"no-product-records"}
          ],
          "patchFindings": [
            {"name":"ExampleApp","version":"2.0","patchStatus":"fixed","cve":{"id":"CVE-2026-12345","score":9.8,"severity":"CRITICAL","description":"Example advisory evidence"}},
            {"name":"ExampleApp","version":"2.0","patchStatus":"unknown","cve":{"id":"CVE-2026-12346","score":7.5,"severity":"HIGH","description":"Applicability requires review"}},
            {"name":"ExampleApp","version":"2.0","patchStatus":"fixed","cve":{"id":"CVE-2026-12345","score":9.8,"severity":"CRITICAL","description":"Duplicate evidence"}}
          ]
        }
        """#
        return try JSONDecoder().decode(PromoterCVEReport.self, from: Data(json.utf8))
    }

    @Test("preserves fixed and unknown evidence while deduplicating repeated records")
    func assessments() throws {
        let value = try report()
        #expect(value.findings.count == 2)
        #expect(value.findings(for: "exampleapp").count == 2)
        #expect(value.findings(for: "OtherApp").isEmpty)
        #expect(value.findings.first?.cve.score == 9.8)
        #expect(value.incompleteApplications == 1)
        #expect(value.scanDate != nil)
    }

    @Test("new Production versions cannot inherit an old fixed assessment")
    func productionBaseline() throws {
        let value = try report()
        #expect(value.matchesProduction(for: "ExampleApp", currentVersion: "2.0"))
        #expect(!value.matchesProduction(for: "ExampleApp", currentVersion: "2.1"))
        #expect(!value.matchesProduction(for: "UnmappedApp", currentVersion: "2.0"))
        #expect(!value.matchesProduction(for: "ExampleApp", currentVersion: nil))
    }

    @Test("source links allow CVE identifiers only")
    func links() throws {
        let value = try report()
        #expect(value.findings.first?.cve.sourceURL?.absoluteString == "https://www.cve.org/CVERecord?id=CVE-2026-12345")
        #expect(value.findings.first?.cve.nvdURL?.host == "nvd.nist.gov")
        let bad = PromoterCVEReport.Advisory(id: "file:///tmp/script", score: 9, severity: "HIGH", description: "")
        #expect(bad.sourceURL == nil)
        #expect(bad.nvdURL == nil)
    }
}
