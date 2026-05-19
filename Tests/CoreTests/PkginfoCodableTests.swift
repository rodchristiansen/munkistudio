import Foundation
import Testing
@testable import Core

@Suite("Pkginfo Codable round-trip")
struct PkginfoCodableTests {
    @Test("decodes a representative Firefox pkginfo plist")
    func decodesFirefoxFixture() throws {
        let url = try #require(
            Bundle.module.url(forResource: "firefox-126", withExtension: "plist", subdirectory: "Fixtures")
        )
        let data = try Data(contentsOf: url)
        let decoder = PropertyListDecoder()
        let pkginfo = try decoder.decode(Pkginfo.self, from: data)

        #expect(pkginfo.name == "Firefox")
        #expect(pkginfo.version == "126.0")
        #expect(pkginfo.minimumOSVersion == "10.15")
        #expect(pkginfo.installerType == .copyFromDmg)
        #expect(pkginfo.catalogs == ["testing"])
        #expect(pkginfo.supportedArchitectures == [.arm64, .x86_64])
        #expect(pkginfo.installs?.first?.cfBundleIdentifier == "org.mozilla.firefox")
        #expect(pkginfo.itemsToCopy?.first?.sourceItem == "Firefox.app")
        #expect(pkginfo.unattendedInstall == true)
        #expect(pkginfo.autoremove == false)
        #expect(pkginfo.unknownKeys == nil)
    }

    @Test("round-trips through plist without losing known keys")
    func roundTripsThroughPlist() throws {
        let url = try #require(
            Bundle.module.url(forResource: "firefox-126", withExtension: "plist", subdirectory: "Fixtures")
        )
        let data = try Data(contentsOf: url)
        let decoder = PropertyListDecoder()
        let pkginfo = try decoder.decode(Pkginfo.self, from: data)

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let reEncoded = try encoder.encode(pkginfo)

        let decodedAgain = try decoder.decode(Pkginfo.self, from: reEncoded)
        #expect(decodedAgain == pkginfo)
    }

    @Test("unknown keys round-trip through encode")
    func preservesUnknownKeys() throws {
        var pkginfo = Pkginfo(name: "Sample")
        pkginfo.version = "1.0"
        pkginfo.unknownKeys = ["totally_custom_key": .string("hello")]

        let encoder = PropertyListEncoder()
        let data = try encoder.encode(pkginfo)

        let decoder = PropertyListDecoder()
        let decoded = try decoder.decode(Pkginfo.self, from: data)
        #expect(decoded.unknownKeys?["totally_custom_key"] == .string("hello"))
    }
}
