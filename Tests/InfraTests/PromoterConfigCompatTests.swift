import Foundation
import Testing
import Core
@testable import Infra

/// Cover the parts of munki-promoter's config that MunkiStudio has to
/// agree with. Where a behaviour looks odd, it is matching
/// `jc0b/munki-promoter` deliberately — the tab is only useful if it
/// predicts what the promoter will actually do.
@Suite("munki-promoter config compatibility")
struct PromoterConfigCompatTests {
    // MARK: Config discovery

    @Test(
        "every recognised config filename is found",
        arguments: ["promoter.yml", "promoter.yaml", "config.yml", "config.yaml"]
    )
    func findsConfigByName(name: String) throws {
        let root = try Self.makeFolder(files: [name: "promotions: {}\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(FilePromoterService.configURL(in: root)?.lastPathComponent == name)
    }

    /// The upstream default is `config.yml`. Only looking for
    /// `promoter.yml` left anyone following upstream's docs with an
    /// empty tab and no explanation.
    @Test("upstream's default config.yml is picked up")
    func findsUpstreamDefaultName() throws {
        let root = try Self.makeFolder(files: ["config.yml": Self.sampleYAML])
        defer { try? FileManager.default.removeItem(at: root) }

        let url = try #require(FilePromoterService.configURL(in: root))
        #expect(url.lastPathComponent == "config.yml")
    }

    @Test("promoter.yml wins when several config names are present")
    func precedenceIsStable() throws {
        let root = try Self.makeFolder(files: [
            "config.yml": "promotions: {}\n",
            "promoter.yml": "promotions: {}\n",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(FilePromoterService.configURL(in: root)?.lastPathComponent == "promoter.yml")
    }

    @Test("a folder with no config reports none")
    func noConfig() throws {
        let root = try Self.makeFolder(files: ["recipe_list.yaml": "[]\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(FilePromoterService.configURL(in: root) == nil)
    }

    // MARK: default_days_in_catalog

    @Test("a promotion without days_in_catalog falls back to the top-level default")
    func defaultDaysApplies() throws {
        let yaml = """
        default_days_in_catalog: 5
        promotions:
          testing to staging:
            promote_from: ["Testing"]
            promote_to: ["Testing", "Staging"]
        """
        let config = try FilePromoterService.parseConfig(yaml)
        #expect(config.defaultDaysInCatalog == 5)
        #expect(config.rules.first?.daysInCatalog == 5)
    }

    @Test("an explicit days_in_catalog beats the top-level default")
    func explicitDaysWins() throws {
        let yaml = """
        default_days_in_catalog: 5
        promotions:
          testing to staging:
            promote_from: ["Testing"]
            promote_to: ["Testing", "Staging"]
            days_in_catalog: 2
        """
        let config = try FilePromoterService.parseConfig(yaml)
        #expect(config.rules.first?.daysInCatalog == 2)
    }

    @Test("with no default at all the aging window is 1 day")
    func fallbackDays() throws {
        let yaml = """
        promotions:
          testing to staging:
            promote_to: ["Staging"]
        """
        let config = try FilePromoterService.parseConfig(yaml)
        #expect(config.rules.first?.daysInCatalog == 1)
    }

    // MARK: promote_from

    /// Upstream treats `promote_from` as optional, defaulting to the
    /// promotion's own name.
    @Test("promote_from defaults to the promotion name")
    func promoteFromDefaultsToName() throws {
        let yaml = """
        promotions:
          Testing:
            promote_to: ["Testing", "Staging"]
        """
        let config = try FilePromoterService.parseConfig(yaml)
        #expect(config.rules.first?.promoteFrom == ["Testing"])
        #expect(config.nextRule(forCatalogs: ["Testing"])?.name == "Testing")
    }

    // MARK: selection

    @Test("an exclusion list keeps everything except the named items")
    func exclusionSelection() throws {
        let config = try FilePromoterService.parseConfig("""
        selection:
          type: exclusion
          items:
            - OpenKiosk
        promotions: {}
        """)
        #expect(config.selection?.type == .exclusion)
        #expect(config.includes("Firefox"))
        #expect(!config.includes("OpenKiosk"))
    }

    @Test("an inclusion list keeps only the named items")
    func inclusionSelection() throws {
        let config = try FilePromoterService.parseConfig("""
        selection:
          type: inclusion
          items:
            - Firefox
        promotions: {}
        """)
        #expect(config.includes("Firefox"))
        #expect(!config.includes("OpenKiosk"))
    }

    @Test("type: all admits everything")
    func allSelection() throws {
        let config = try FilePromoterService.parseConfig("""
        selection:
          type: all
        promotions: {}
        """)
        #expect(config.includes("Firefox"))
        #expect(config.includes("OpenKiosk"))
    }

    @Test("no selection block admits everything")
    func absentSelection() throws {
        let config = try FilePromoterService.parseConfig("promotions: {}")
        #expect(config.selection == nil)
        #expect(config.includes("Anything"))
    }

    /// `check_selection` only filters when it finds a `type`; a block
    /// without one warns and admits everything.
    @Test("a selection block with no type is ignored")
    func selectionWithoutType() throws {
        let config = try FilePromoterService.parseConfig("""
        selection:
          items: [Firefox]
        promotions: {}
        """)
        #expect(config.selection == nil)
        #expect(config.includes("OpenKiosk"))
    }

    /// The asymmetry is upstream's: a missing inclusion list admits
    /// nothing, a missing exclusion list admits everything.
    @Test("an inclusion list with no items admits nothing")
    func emptyInclusionAdmitsNothing() throws {
        let config = try FilePromoterService.parseConfig("""
        selection:
          type: inclusion
        promotions: {}
        """)
        #expect(!config.includes("Firefox"))
    }

    @Test("an exclusion list with no items admits everything")
    func emptyExclusionAdmitsEverything() throws {
        let config = try FilePromoterService.parseConfig("""
        selection:
          type: exclusion
        promotions: {}
        """)
        #expect(config.includes("Firefox"))
    }

    @Test("selection matching is exact — it does not glob like custom_items")
    func selectionDoesNotGlob() throws {
        let config = try FilePromoterService.parseConfig("""
        selection:
          type: exclusion
          items:
            - "macOS-*"
        promotions: {}
        """)
        #expect(!config.includes("macOS-*"))
        #expect(config.includes("macOS-Sequoia"))
    }

    // MARK: Candidates honour selection

    /// The bug this guards: excluded items were listed as upcoming
    /// promotions the promoter would never actually perform.
    @Test("an excluded item is not offered as a promotion candidate")
    func excludedItemIsNotACandidate() throws {
        let now = Date(timeIntervalSince1970: 1_715_000_000)
        let twoDaysAgo = now.addingTimeInterval(-2 * 86_400)

        let config = try FilePromoterService.parseConfig("""
        selection:
          type: exclusion
          items:
            - OpenKiosk
        promotions:
          testing to staging:
            promote_from: ["Development", "Testing"]
            promote_to: ["Development", "Testing", "Staging"]
            days_in_catalog: 1
        """)

        let records = ["Firefox", "OpenKiosk"].enumerated().map { index, name -> PkginfoRecord in
            var pkginfo = Pkginfo(name: name)
            pkginfo.version = "1.0"
            pkginfo.catalogs = ["Development", "Testing"]
            pkginfo.metadata = [
                "munki-promoter_edit_date": .string(FilePromoterService.formatISO8601(twoDaysAgo))
            ]
            return PkginfoRecord(
                pkginfo: pkginfo,
                fileURL: URL(fileURLWithPath: "/tmp/\(name)-\(index).yaml"),
                format: .yaml,
                modifiedAt: now
            )
        }

        let candidates = FilePromoterService.candidates(from: records, config: config, now: now)
        #expect(candidates.map(\.pkgName) == ["Firefox"])
    }

    // MARK: Helpers

    private static let sampleYAML = """
    default_days_in_catalog: 1
    promotions:
      testing to staging:
        promote_from: ["Testing"]
        promote_to: ["Testing", "Staging"]
    """

    private static func makeFolder(files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "promoter-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, contents) in files {
            try Data(contents.utf8).write(to: root.appending(path: name))
        }
        return root
    }
}
