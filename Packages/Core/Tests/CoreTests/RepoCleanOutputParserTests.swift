import Foundation
import Testing
@testable import Core

@Suite("repoclean output parser")
struct RepoCleanOutputParserTests {
    /// A two-item run with one doomed version each, plus the closing
    /// summary — modelled on real `repoclean` output.
    private let sample = """
    Analyzing manifest files...
    Analyzing pkginfo files...
    Analyzing installer items...
    name: Nudge
    catalogs: Development, Production, Staging, Testing
    minimum_os_version: 10.5.0
    receipts: com.github.macadmins.Nudge
    versions:
         2.1.2.81856 (pkgsinfo/utilities/Nudge-2.1.2.81856__1.yaml)
         1.1.14.81533 (pkgsinfo/utilities/Nudge-1.1.14.81533.yaml)
         1.1.13.81510 (pkgsinfo/utilities/Nudge-1.1.13.81510.yaml) [to be DELETED]

    name: ReportMate
    catalogs: Development, Production, Staging, Testing
    receipts: com.github.reportmate
    versions:
         2026.05.14.2345 (pkgsinfo/mgmt/ReportMate-2026.05.14.2345.yaml)
         2026.03.21.1956 (pkgsinfo/mgmt/ReportMate-2026.03.21.1956.yaml) [to be DELETED]

    Total pkginfo items:     1368
    Item variants:           1076
    pkginfo items to delete: 2
    pkgs to delete:          2
    pkginfo space savings:   2.4 KB
    pkg space savings:       76.5 MB
    """

    @Test("parses one item per name block")
    func parsesItems() {
        let plan = RepoCleanOutputParser.parse(sample)
        #expect(plan.items.map(\.name) == ["Nudge", "ReportMate"])
    }

    @Test("parses every version row under an item")
    func parsesVersions() {
        let plan = RepoCleanOutputParser.parse(sample)
        let nudge = plan.items.first { $0.name == "Nudge" }
        #expect(nudge?.versions.count == 3)
        #expect(nudge?.versions.map(\.version) == ["2.1.2.81856", "1.1.14.81533", "1.1.13.81510"])
    }

    @Test("flags only the versions marked [to be DELETED]")
    func flagsDoomedVersions() {
        let plan = RepoCleanOutputParser.parse(sample)
        let nudge = plan.items.first { $0.name == "Nudge" }
        #expect(nudge?.doomedVersions.map(\.version) == ["1.1.13.81510"])
        #expect(nudge?.doomedVersions.first?.path == "pkgsinfo/utilities/Nudge-1.1.13.81510.yaml")
    }

    @Test("captures the path of a variant pkginfo")
    func parsesVariantPath() {
        let plan = RepoCleanOutputParser.parse(sample)
        let variant = plan.items.first { $0.name == "Nudge" }?.versions.first
        #expect(variant?.path == "pkgsinfo/utilities/Nudge-2.1.2.81856__1.yaml")
        #expect(variant?.willDelete == false)
    }

    @Test("parses the item metadata fields")
    func parsesItemFields() {
        let plan = RepoCleanOutputParser.parse(sample)
        let nudge = plan.items.first { $0.name == "Nudge" }
        #expect(nudge?.catalogs == ["Development", "Production", "Staging", "Testing"])
        #expect(nudge?.minimumOSVersion == "10.5.0")
        #expect(nudge?.receipts == "com.github.macadmins.Nudge")
    }

    @Test("leaves an absent optional field nil")
    func optionalFieldStaysNil() {
        let plan = RepoCleanOutputParser.parse(sample)
        let reportMate = plan.items.first { $0.name == "ReportMate" }
        #expect(reportMate?.minimumOSVersion == nil)
        #expect(reportMate?.receipts == "com.github.reportmate")
    }

    @Test("parses the closing summary")
    func parsesSummary() {
        let plan = RepoCleanOutputParser.parse(sample)
        let summary = plan.summary
        #expect(summary?.totalPkginfoItems == 1368)
        #expect(summary?.itemVariants == 1076)
        #expect(summary?.pkginfoItemsToDelete == 2)
        #expect(summary?.pkgsToDelete == 2)
        #expect(summary?.pkginfoSpaceSavings == "2.4 KB")
        #expect(summary?.pkgSpaceSavings == "76.5 MB")
    }

    @Test("reports deletions present")
    func detectsDeletions() {
        let plan = RepoCleanOutputParser.parse(sample)
        #expect(plan.hasDeletions)
        #expect(plan.itemsWithDeletions.map(\.name) == ["Nudge", "ReportMate"])
    }

    @Test("a nothing-to-delete run has no doomed versions")
    func nothingToDelete() {
        let output = """
        Analyzing manifest files...
        Analyzing pkginfo files...
        Analyzing installer items...
        Total pkginfo items:     1368
        Item variants:           1076
        pkginfo items to delete: 0
        pkgs to delete:          0
        pkginfo space savings:   0 bytes
        pkg space savings:       0 bytes
        """
        let plan = RepoCleanOutputParser.parse(output)
        #expect(plan.items.isEmpty)
        #expect(plan.hasDeletions == false)
        #expect(plan.summary?.pkginfoItemsToDelete == 0)
    }

    @Test("output with no recognisable summary yields a nil summary")
    func missingSummary() {
        let plan = RepoCleanOutputParser.parse("Analyzing manifest files...\nAnalyzing pkginfo files...")
        #expect(plan.summary == nil)
        #expect(plan.items.isEmpty)
    }
}
