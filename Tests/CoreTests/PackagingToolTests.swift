import Foundation
import Testing
@testable import Core

private extension PackagingToolCapabilities {
    /// munkipkg, and swiftpkg once `next` ships.
    static let munkipkgStyle = PackagingToolCapabilities(
        skipImportFlag: "--skip-import",
        envFileFlag: "--env"
    )

    /// swiftpkg on `next`: different env spelling, same import flag.
    static let swiftpkgNext = PackagingToolCapabilities(
        skipImportFlag: "--skip-import",
        envFileFlag: "--env-file"
    )
}

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

    /// swiftpkg's README recommends Homebrew, which on Apple Silicon
    /// installs to `/opt/homebrew/bin`. Probing only the installer
    /// package's `/usr/local/bin` made a brew install invisible.
    @Test("the Homebrew location is probed for both tools")
    func homebrewPathsAreProbed() {
        #expect(PackagingTool.swiftpkg.candidateExecutablePaths.contains("/opt/homebrew/bin/swiftpkg"))
        #expect(PackagingTool.munkipkg.candidateExecutablePaths.contains("/opt/homebrew/bin/munkipkg"))
    }

    /// Intel Homebrew and hand-built installs land in `/usr/local/bin`.
    @Test("/usr/local/bin is probed for both tools")
    func usrLocalBinIsProbed() {
        #expect(PackagingTool.swiftpkg.candidateExecutablePaths.contains("/usr/local/bin/swiftpkg"))
        #expect(PackagingTool.munkipkg.candidateExecutablePaths.contains("/usr/local/bin/munkipkg"))
    }

    @Test("Munki's own location is probed first for munkipkg")
    func munkiPathIsPreferred() {
        #expect(PackagingTool.munkipkg.candidateExecutablePaths.first == "/usr/local/munki/munkipkg")
    }

    /// The install button reports where it put the binary, so the
    /// default has to be a path the tool's installer actually uses.
    @Test("the default path is the first probed candidate")
    func defaultIsFirstCandidate() {
        for tool in PackagingTool.allCases {
            #expect(tool.defaultExecutablePath == tool.candidateExecutablePaths.first)
        }
    }

    @Test("every candidate path ends in the tool's own binary name")
    func candidatesNameTheTool() {
        for tool in PackagingTool.allCases {
            for path in tool.candidateExecutablePaths {
                #expect((path as NSString).lastPathComponent == tool.rawValue)
                // A candidate must also infer back to its own tool, or
                // resolution would pick the wrong CLI for it.
                #expect(PackagingTool.inferred(fromExecutablePath: path) == tool)
            }
        }
    }

    @Test("no candidate path is listed twice")
    func candidatesAreUnique() {
        for tool in PackagingTool.allCases {
            let paths = tool.candidateExecutablePaths
            #expect(Set(paths).count == paths.count)
        }
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

    @Test("shared flags are emitted whatever the binary supports")
    func sharedFlags() {
        let options = MunkipkgBuildOptions(
            exportBomInfo: true,
            skipNotarization: true,
            skipStapling: true,
            quiet: true
        )
        for capabilities in [PackagingToolCapabilities.none, .munkipkgStyle, .swiftpkgNext] {
            let args = options.arguments(capabilities: capabilities)
            #expect(args.contains("--export-bom-info"))
            #expect(args.contains("--skip-notarization"))
            #expect(args.contains("--skip-stapling"))
            #expect(args.contains("--quiet"))
        }
    }

    /// The env flag is spelled differently by each tool, and older
    /// swiftpkg has none at all. swift-argument-parser treats an unknown
    /// flag as a hard failure, so an unsupported one must be dropped.
    @Test("the env flag uses whatever spelling the binary advertises")
    func envFlagFollowsCapabilities() {
        let options = MunkipkgBuildOptions(envPath: "/tmp/.env")
        #expect(options.arguments(capabilities: .munkipkgStyle) == ["--env", "/tmp/.env"])
        #expect(options.arguments(capabilities: .swiftpkgNext) == ["--env-file", "/tmp/.env"])
        #expect(options.arguments(capabilities: .none).isEmpty)
    }

    @Test("a blank env path adds nothing even when supported")
    func blankEnvPath() {
        let options = MunkipkgBuildOptions(envPath: "   ")
        #expect(options.arguments(capabilities: .munkipkgStyle).isEmpty)
        #expect(options.arguments(capabilities: .swiftpkgNext).isEmpty)
    }

    // MARK: Capability detection

    /// munkipkg's own help, as printed by the installed fork.
    @Test("munkipkg's help yields --env and --skip-import")
    func detectsMunkipkgCapabilities() {
        let help = "--build --create --env --export-bom-info --skip-import --skip-stapling"
        let detected = PackagingToolCapabilities.detected(fromHelp: help)
        #expect(detected.envFileFlag == "--env")
        #expect(detected.skipImportFlag == "--skip-import")
    }

    /// The shipped 0.3.1 CLI has neither, and rejects both.
    @Test("swiftpkg 0.3.1's help yields no optional flags")
    func detectsShippedSwiftpkgCapabilities() {
        let help = """
        --create --import PKG --json --yaml --export-bom-info --sync
        --quiet --force --skip-signing --skip-notarization --skip-stapling
        """
        #expect(PackagingToolCapabilities.detected(fromHelp: help) == .none)
    }

    /// The `next` branch adds `--env-file` and accepts `--skip-import`
    /// for munki-pkg compatibility.
    @Test("swiftpkg next's help yields --env-file and --skip-import")
    func detectsNextSwiftpkgCapabilities() {
        let help = """
        --lint --quiet --skip-signing --skip-notarization --skip-stapling
        --env-file PATH --strict-env --no-inherit-env --provenance --verify
        --output-format FORMAT --skip-import --pkg-version VERSION --output-dir DIR
        """
        let detected = PackagingToolCapabilities.detected(fromHelp: help)
        #expect(detected.envFileFlag == "--env-file")
        #expect(detected.skipImportFlag == "--skip-import")
    }

    /// `--env-file` contains `--env`. Checking the shorter spelling
    /// first would hand munkipkg's flag to a binary that only takes the
    /// longer one.
    @Test("--env-file is preferred over the shorter --env")
    func longerEnvSpellingWins() {
        #expect(PackagingToolCapabilities.detected(fromHelp: "--env-file PATH").envFileFlag == "--env-file")
    }

    @Test("the older --no-import spelling is still recognised")
    func detectsNoImportSpelling() {
        #expect(PackagingToolCapabilities.detected(fromHelp: "--no-import").skipImportFlag == "--no-import")
    }

    @Test("empty help yields no capabilities")
    func detectsNothingFromEmptyHelp() {
        #expect(PackagingToolCapabilities.detected(fromHelp: "") == .none)
    }

    @Test("the legacy `arguments` property still speaks munkipkg")
    func legacyArgumentsUnchanged() {
        let options = MunkipkgBuildOptions(exportBomInfo: true, envPath: "/tmp/.env")
        #expect(options.arguments == options.arguments(capabilities: .munkipkgStyle))
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
