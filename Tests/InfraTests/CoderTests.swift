import Foundation
import Testing
import Core
@testable import Infra

@Suite("Pkginfo plist + YAML coders")
struct PkginfoCoderTests {
    @Test("decodes Firefox YAML fixture")
    func decodesYamlFixture() throws {
        let url = try fixture("firefox-126", extension: "yaml")
        let yaml = try String(contentsOf: url, encoding: .utf8)
        let pkginfo = try PkginfoYamlCoder.decode(from: yaml)

        #expect(pkginfo.name == "Firefox")
        #expect(pkginfo.version == "126.0")
        #expect(pkginfo.minimumOSVersion == "10.15")
        #expect(pkginfo.installerType == .copyFromDmg)
        #expect(pkginfo.supportedArchitectures == [.arm64, .x86_64])
        #expect(pkginfo.postinstallScript?.contains("#!/bin/bash") == true)
        #expect(pkginfo.unknownKeys == nil)
        #expect(pkginfo.metadata?["created_by"] == .string("autopkg"))
    }

    @Test("YAML encode puts priority keys first then alpha then _metadata")
    func priorityKeyOrderingOnEncode() throws {
        var pkginfo = Pkginfo(name: "TestApp")
        pkginfo.displayName = "Test App"
        pkginfo.version = "2.5"
        pkginfo.category = "Utilities"
        pkginfo.developer = "Acme"
        pkginfo.catalogs = ["production"]
        pkginfo.metadata = ["created_by": .string("rod")]

        let yaml = try PkginfoYamlCoder.encode(pkginfo)
        let lines = yaml.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let topLevelKeyLines = lines.filter { !$0.hasPrefix(" ") && $0.contains(":") }
        let topKeys = topLevelKeyLines.map { String($0.prefix { $0 != ":" }) }

        // name / display_name / version first.
        #expect(topKeys.first == "name")
        #expect(topKeys.dropFirst().first == "display_name")
        #expect(topKeys.dropFirst(2).first == "version")
        // _metadata last.
        #expect(topKeys.last == "_metadata")
        // Middle keys alphabetical.
        let middle = Array(topKeys.dropFirst(3).dropLast())
        #expect(middle == middle.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    }

    @Test("scripts emit as literal block scalars")
    func scriptKeysUseLiteralBlock() throws {
        var pkginfo = Pkginfo(name: "ScriptedApp")
        pkginfo.version = "1.0"
        pkginfo.postinstallScript = "#!/bin/bash\necho hello\nexit 0\n"

        let yaml = try PkginfoYamlCoder.encode(pkginfo)
        // `|` introduces the literal block; trailing newline preserved.
        #expect(yaml.contains("postinstall_script: |"))
    }

    @Test("version strings round-trip without numeric coercion")
    func versionStringsRoundTrip() throws {
        var pkginfo = Pkginfo(name: "VersionApp")
        pkginfo.version = "1.0"
        pkginfo.minimumOSVersion = "10.13"

        let yaml = try PkginfoYamlCoder.encode(pkginfo)
        let decoded = try PkginfoYamlCoder.decode(from: yaml)
        #expect(decoded.version == "1.0")
        #expect(decoded.minimumOSVersion == "10.13")
    }

    @Test("plist coder round-trips")
    func plistRoundTrip() throws {
        var pkginfo = Pkginfo(name: "PlistApp")
        pkginfo.version = "3.1"
        pkginfo.installerType = .pkg
        pkginfo.catalogs = ["testing", "production"]
        let data = try PkginfoPlistCoder.encode(pkginfo)
        let decoded = try PkginfoPlistCoder.decode(from: data)
        #expect(decoded == pkginfo)
    }

    private func fixture(_ name: String, extension ext: String) throws -> URL {
        try #require(
            Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
        )
    }
}

@Suite("Manifest plist + YAML coders")
struct ManifestCoderTests {
    @Test("decodes lab-imac plist manifest")
    func decodesPlistManifest() throws {
        let url = try #require(
            Bundle.module.url(forResource: "lab-imac", withExtension: "plist", subdirectory: "Fixtures")
        )
        let data = try Data(contentsOf: url)
        let manifest = try ManifestPlistCoder.decode(from: data, name: "lab-imac")
        #expect(manifest.manifestName == "lab-imac")
        #expect(manifest.catalogs == ["production"])
        #expect(manifest.managedInstalls == ["Firefox", "Slack"])
        #expect(manifest.includedManifests == ["site_default"])
        #expect(manifest.conditionalItems?.count == 1)
        #expect(manifest.conditionalItems?.first?.condition == "arch == \"arm64\"")
    }

    @Test("manifest YAML round-trip preserves conditional_items")
    func manifestYamlRoundTrip() throws {
        var manifest = Manifest(manifestName: "lab")
        manifest.catalogs = ["production"]
        manifest.managedInstalls = ["AppA", "AppB"]
        manifest.conditionalItems = [
            ConditionalItem(
                condition: "arch == \"arm64\"",
                managedInstalls: ["AppleSiliconOnly"]
            )
        ]
        let yaml = try ManifestYamlCoder.encode(manifest)
        let decoded = try ManifestYamlCoder.decode(from: yaml, name: "lab")
        #expect(decoded.catalogs == manifest.catalogs)
        #expect(decoded.managedInstalls == manifest.managedInstalls)
        #expect(decoded.conditionalItems?.count == 1)
        #expect(decoded.conditionalItems?.first?.condition == "arch == \"arm64\"")
    }
}

@Suite("Format router")
struct FileCoderTests {
    @Test("PkginfoFileCoder reads YAML by extension")
    func pkginfoYamlByExtension() throws {
        let url = try #require(
            Bundle.module.url(forResource: "firefox-126", withExtension: "yaml", subdirectory: "Fixtures")
        )
        let record = try PkginfoFileCoder.read(from: url)
        #expect(record.format == .yaml)
        #expect(record.pkginfo.name == "Firefox")
    }

    @Test("write preserves original format")
    func writePreservesFormat() throws {
        var pkginfo = Pkginfo(name: "TmpApp")
        pkginfo.version = "1.0"
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "munki-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let yamlURL = tmp.appending(path: "TmpApp.yaml")
        try PkginfoFileCoder.write(
            PkginfoRecord(pkginfo: pkginfo, fileURL: yamlURL, format: .yaml)
        )
        let yamlData = try Data(contentsOf: yamlURL)
        #expect(String(decoding: yamlData, as: UTF8.self).hasPrefix("name: TmpApp"))

        let plistURL = tmp.appending(path: "TmpApp.plist")
        try PkginfoFileCoder.write(
            PkginfoRecord(pkginfo: pkginfo, fileURL: plistURL, format: .plist)
        )
        let plistData = try Data(contentsOf: plistURL)
        #expect(String(decoding: plistData, as: UTF8.self).contains("<plist"))
    }
}
