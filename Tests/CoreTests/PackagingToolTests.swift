import Foundation
import Testing
@testable import Core

@Suite("Packaging tool differences")
struct PackagingToolTests {
    /// The difference that silently breaks builds: munkipkg needs
    /// `--build`, swiftpkg builds by default and rejects the flag.
    @Test("only munkipkg takes a --build flag")
    func buildModeArguments() {
        #expect(PackagingTool.munkipkg.buildModeArguments == ["--build"])
        #expect(PackagingTool.swiftpkg.buildModeArguments.isEmpty)
    }

    @Test("each tool reports its own install location")
    func defaultPaths() {
        #expect(PackagingTool.munkipkg.defaultExecutablePath == "/usr/local/munki/munkipkg")
        #expect(PackagingTool.swiftpkg.defaultExecutablePath == "/usr/local/bin/swiftpkg")
    }

    /// swiftpkg never prompts to import, so there is no flag to suppress
    /// and no `--env` to pass.
    @Test("import-suppression and --env are munkipkg-only")
    func capabilityFlags() {
        #expect(PackagingTool.munkipkg.supportsSkipImport)
        #expect(!PackagingTool.swiftpkg.supportsSkipImport)
        #expect(PackagingTool.munkipkg.supportsEnvFile)
        #expect(!PackagingTool.swiftpkg.supportsEnvFile)
    }

    @Test("swiftpkg is preferred when nothing is configured")
    func detectionOrder() {
        #expect(PackagingTool.detectionOrder.first == .swiftpkg)
        #expect(PackagingTool.detectionOrder.contains(.munkipkg))
    }

    @Test(
        "the tool is identified from its executable filename",
        arguments: [
            ("/usr/local/bin/swiftpkg", PackagingTool.swiftpkg),
            ("/opt/homebrew/bin/swiftpkg", PackagingTool.swiftpkg),
            ("/usr/local/munki/munkipkg", PackagingTool.munkipkg),
            ("/Users/someone/bin/munkipkg", PackagingTool.munkipkg),
        ]
    )
    func inferredFromPath(path: String, expected: PackagingTool) {
        #expect(PackagingTool.inferred(fromExecutablePath: path) == expected)
    }

    @Test("an unrecognised filename infers nothing")
    func inferredFromUnknownPath() {
        #expect(PackagingTool.inferred(fromExecutablePath: "/usr/local/bin/pkgbuild") == nil)
    }

    // MARK: Build options

    @Test("shared flags are emitted for both tools")
    func sharedFlags() {
        let options = MunkipkgBuildOptions(
            exportBomInfo: true,
            skipNotarization: true,
            skipStapling: true,
            quiet: true
        )
        for tool in PackagingTool.allCases {
            let args = options.arguments(for: tool)
            #expect(args.contains("--export-bom-info"))
            #expect(args.contains("--skip-notarization"))
            #expect(args.contains("--skip-stapling"))
            #expect(args.contains("--quiet"))
        }
    }

    /// Passing `--env` to swiftpkg makes it print usage and exit
    /// non-zero, so it must be dropped rather than passed through.
    @Test("--env goes to munkipkg only")
    func envFlagIsMunkipkgOnly() {
        let options = MunkipkgBuildOptions(envPath: "/tmp/.env")
        #expect(options.arguments(for: .munkipkg) == ["--env", "/tmp/.env"])
        #expect(options.arguments(for: .swiftpkg).isEmpty)
    }

    @Test("a blank env path adds nothing for either tool")
    func blankEnvPath() {
        let options = MunkipkgBuildOptions(envPath: "   ")
        #expect(options.arguments(for: .munkipkg).isEmpty)
        #expect(options.arguments(for: .swiftpkg).isEmpty)
    }

    @Test("the legacy `arguments` property still speaks munkipkg")
    func legacyArgumentsUnchanged() {
        let options = MunkipkgBuildOptions(exportBomInfo: true, envPath: "/tmp/.env")
        #expect(options.arguments == options.arguments(for: .munkipkg))
    }

    // MARK: Status label

    @Test("a bare version string is prefixed with the tool name")
    func displayLabelAddsToolName() {
        let installed = InstalledPackagingTool(
            tool: .swiftpkg,
            version: "0.3.1",
            executablePath: "/usr/local/bin/swiftpkg"
        )
        #expect(installed.displayLabel == "swiftpkg 0.3.1")
    }

    /// Both tools print their own name in `--version`, so the label must
    /// not double it up into "swiftpkg swiftpkg 0.3.1".
    @Test("a version string that already names the tool is left alone")
    func displayLabelAvoidsDuplication() {
        let installed = InstalledPackagingTool(
            tool: .swiftpkg,
            version: "swiftpkg 0.3.1",
            executablePath: "/usr/local/bin/swiftpkg"
        )
        #expect(installed.displayLabel == "swiftpkg 0.3.1")
    }
}
