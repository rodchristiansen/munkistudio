import Foundation
import Testing
import Core
@testable import Infra

/// CLI-parity tests for MunkiStudio's YAML/plist emitters.
///
/// Stronger than the round-trip sweep in `RoundTripSweepTests`. Those tests
/// only prove our output is *self-stable* (emit → parse → emit produces the
/// same bytes the second time around). These tests prove our output is also
/// *byte-compatible with the Munki CLI*: a file authored by the CLI should
/// pass through MunkiStudio without changing.
///
/// Mechanism: hand-written fixtures whose contents are exactly what Munki
/// PR #1261's `yamlutils.swift` / `plistutils.swift` would emit. We decode
/// each fixture and re-encode it, then assert byte-equality. Any drift in
/// our emission rules will break these tests with a clear diff.
@Suite("CLI parity (yamlutils.swift / plistutils.swift)")
struct MunkiParityTests {

    // MARK: YAML pkginfo

    @Test("pkginfo YAML matches Munki canonical form")
    func canonicalPkginfoYaml() throws {
        let expected = try fixture("munki-canonical-pkginfo", extension: "yaml")
        let original = try String(contentsOf: expected, encoding: .utf8)
        let pkginfo = try PkginfoYamlCoder.decode(from: original)
        let reemitted = try PkginfoYamlCoder.encode(pkginfo)
        #expect(
            reemitted == original,
            "MunkiStudio emission diverged from Munki canonical form.\n--- expected ---\n\(original)\n--- got ---\n\(reemitted)"
        )
    }

    // MARK: YAML manifest

    @Test("manifest YAML matches Munki canonical form")
    func canonicalManifestYaml() throws {
        let expected = try fixture("munki-canonical-manifest", extension: "yaml")
        let original = try String(contentsOf: expected, encoding: .utf8)
        let manifest = try ManifestYamlCoder.decode(from: original, name: "lab-imac")
        let reemitted = try ManifestYamlCoder.encode(manifest)
        #expect(
            reemitted == original,
            "MunkiStudio manifest emission diverged from Munki canonical form.\n--- expected ---\n\(original)\n--- got ---\n\(reemitted)"
        )
    }

    // MARK: Targeted emission rules
    //
    // The two fixture tests above prove byte-identity for a comprehensive
    // example. The tests below are focused regression guards on individual
    // emission rules — if a fixture test breaks, these usually pinpoint why.

    @Test("empty strings round-trip as quoted scalars, not null")
    func emptyStringsAreSingleQuoted() throws {
        // Regression: yamlutils.swift emits empty strings as `''` so they
        // re-read as "" instead of null. The previous MunkiStudio code
        // emitted a bare empty scalar that re-read as null and dropped the
        // key entirely on the way through Codable.
        var pkginfo = Pkginfo(name: "EmptyApp")
        pkginfo.version = "1.0"
        pkginfo.uninstallMethod = ""
        pkginfo.description = ""

        let yaml = try PkginfoYamlCoder.encode(pkginfo)
        #expect(
            yaml.contains("uninstall_method: ''"),
            "Empty string uninstall_method must emit as `''`. Got:\n\(yaml)"
        )
        #expect(
            yaml.contains("description: ''"),
            "Empty string description must emit as `''`. Got:\n\(yaml)"
        )

        let decoded = try PkginfoYamlCoder.decode(from: yaml)
        #expect(decoded.uninstallMethod == "", "Empty string did not round-trip")
        #expect(decoded.description == "", "Empty string did not round-trip")
    }

    @Test("receipts emit with Munki key order: packageid, name, filename, installed_size, version, optional")
    func receiptKeyOrder() throws {
        var pkginfo = Pkginfo(name: "ReceiptApp")
        pkginfo.version = "1.0"
        pkginfo.receipts = [
            Receipt(
                packageid: "com.example.app",
                name: "ReceiptApp",
                filename: "ReceiptApp.pkg",
                version: "1.0",
                installedSize: 1024,
                optional: false
            )
        ]
        let yaml = try PkginfoYamlCoder.encode(pkginfo)

        // Scan only the receipt sub-block — `version:` also appears at the
        // pkginfo top level and would otherwise alias to the wrong position.
        guard let receiptsRange = yaml.range(of: "receipts:") else {
            Issue.record("No receipts: block in YAML:\n\(yaml)")
            return
        }
        let subBlock = String(yaml[receiptsRange.lowerBound...])
        let expectedOrder = ["packageid", "name", "filename", "installed_size", "version", "optional"]
        let positions = expectedOrder.compactMap { key -> Int? in
            subBlock.range(of: "\(key):")?.lowerBound.utf16Offset(in: subBlock)
        }
        #expect(
            positions.count == expectedOrder.count,
            "Missing receipt keys. Found \(positions.count) of \(expectedOrder.count). YAML:\n\(yaml)"
        )
        #expect(
            positions == positions.sorted(),
            "Receipt keys emitted in wrong order. Found positions \(positions) for \(expectedOrder). YAML:\n\(yaml)"
        )
    }

    @Test("conditional_items emit with condition first, then managed_* in semantic order")
    func conditionalItemKeyOrder() throws {
        var manifest = Manifest(manifestName: "test")
        manifest.catalogs = ["production"]
        manifest.conditionalItems = [
            ConditionalItem(
                condition: "arch == \"arm64\"",
                managedInstalls: ["A"],
                managedUninstalls: ["B"],
                managedUpdates: ["C"],
                optionalInstalls: ["D"]
            )
        ]
        let yaml = try ManifestYamlCoder.encode(manifest)

        // Strict order per yamlutils.swift's conditionalItemKeyOrder.
        let expectedOrder = ["condition", "managed_installs", "managed_uninstalls", "managed_updates", "optional_installs"]
        let positions = expectedOrder.compactMap { key -> Int? in
            yaml.range(of: "\(key):")?.lowerBound.utf16Offset(in: yaml)
        }
        #expect(
            positions == positions.sorted(),
            "conditional_items keys emitted in wrong order. Found \(positions) for \(expectedOrder). YAML:\n\(yaml)"
        )
    }

    @Test("multi-line description emits as folded block scalar")
    func proseFolded() throws {
        var pkginfo = Pkginfo(name: "ProseApp")
        pkginfo.version = "1.0"
        pkginfo.description = "First sentence.\nSecond sentence."

        let yaml = try PkginfoYamlCoder.encode(pkginfo)
        // `>` introduces a folded scalar block. The previous MunkiStudio
        // code left this at `.any` and Yams sometimes picked literal,
        // producing a noisy diff against CLI-written files.
        #expect(
            yaml.contains("description: >"),
            "Multi-line description must emit as folded block (`>`). Got:\n\(yaml)"
        )
    }

    @Test("version_script and embedded_script keys emit as literal block")
    func extraScriptKeysAreLiteral() throws {
        // Regression: the older MunkiStudio rules omitted version_script
        // and embedded_script from scriptFieldKeys. yamlutils.swift includes
        // both — any pkginfo using them was producing a diff.
        var pkginfo = Pkginfo(name: "VersionedApp")
        pkginfo.version = "1.0"
        pkginfo.versionScript = "#!/bin/sh\nsw_vers -productVersion\n"
        pkginfo.unknownKeys = [
            "embedded_script": .string("#!/bin/sh\necho embedded\n"),
        ]

        let yaml = try PkginfoYamlCoder.encode(pkginfo)
        #expect(yaml.contains("version_script: |"), "version_script must emit as `|`. Got:\n\(yaml)")
        #expect(yaml.contains("embedded_script: |"), "embedded_script must emit as `|`. Got:\n\(yaml)")
    }

    // MARK: Plist parity

    @Test("plist encode produces alphabetically-sorted XML matching PropertyListSerialization output")
    func plistAlphabeticOrder() throws {
        var pkginfo = Pkginfo(name: "PlistApp")
        pkginfo.version = "1.0"
        pkginfo.catalogs = ["production"]
        pkginfo.developer = "Acme"
        pkginfo.unattendedInstall = true

        let data = try PkginfoPlistCoder.encode(pkginfo)

        // Drive the same dict through PropertyListSerialization directly. If
        // our encode() path diverges from the canonical Apple emission, the
        // bytes will differ. This is the CLI-parity guarantee.
        let any = try PropertyListSerialization.propertyList(from: data, format: nil)
        let direct = try PropertyListSerialization.data(
            fromPropertyList: any,
            format: .xml,
            options: 0
        )
        #expect(
            data == direct,
            "PkginfoPlistCoder.encode() output diverged from PropertyListSerialization canonical bytes."
        )
    }

    @Test("plist round-trips byte-identically")
    func plistByteIdempotent() throws {
        var manifest = Manifest(manifestName: "lab")
        manifest.displayName = "Lab"
        manifest.catalogs = ["production"]
        manifest.managedInstalls = ["AppA", "AppB"]
        manifest.conditionalItems = [
            ConditionalItem(
                condition: "arch == \"arm64\"",
                managedInstalls: ["SiliconOnly"]
            )
        ]

        let first = try ManifestPlistCoder.encode(manifest)
        let decoded = try ManifestPlistCoder.decode(from: first, name: "lab")
        let second = try ManifestPlistCoder.encode(decoded)
        #expect(first == second, "Plist encode is not byte-idempotent")
    }

    private func fixture(_ name: String, extension ext: String) throws -> URL {
        try #require(
            Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
        )
    }
}
