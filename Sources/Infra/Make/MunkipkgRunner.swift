import Foundation
import Core

/// Concrete ``MunkipkgService`` that shells out to the `munkipkg` binary
/// Munki ships under `/usr/local/munki/`. Project discovery, build-info
/// parsing, and script I/O are plain file operations; `build` streams
/// `munkipkg --build` output through ``ProcessRunner``.
public final class MunkipkgRunner: MunkipkgService {
    /// The standard munkipkg install location. Kept for callers that
    /// reference it directly; resolution now goes through
    /// ``PackagingTool``.
    public static let defaultExecutablePath = PackagingTool.munkipkg.defaultExecutablePath

    public init() {}

    /// The executable path configured in Settings, or `nil` when blank.
    private var configuredExecutablePath: String? {
        let stored = UserDefaults.standard
            .string(forKey: MunkipkgDefaults.executablePathKey)?
            .trimmingCharacters(in: .whitespaces)
        guard let stored, !stored.isEmpty else { return nil }
        return (stored as NSString).expandingTildeInPath
    }

    /// Which tool to run, and where.
    ///
    /// An explicit Settings path always wins — including its tool kind,
    /// inferred from the binary's name, so pointing at a `swiftpkg`
    /// build doesn't get driven with munkipkg's `--build` flag. With no
    /// path set, the first tool in ``PackagingTool/detectionOrder`` that
    /// exists on disk is used. Read per-call so a Settings change takes
    /// effect without relaunching.
    var resolved: (tool: PackagingTool, url: URL) {
        if let configured = configuredExecutablePath {
            // An unrecognised filename is assumed to be munkipkg — that
            // was the only supported tool before swiftpkg, so it is the
            // back-compatible reading of a hand-set path.
            let tool = PackagingTool.inferred(fromExecutablePath: configured) ?? .munkipkg
            return (tool, URL(fileURLWithPath: configured))
        }
        for candidate in PackagingTool.detectionOrder
        where FileManager.default.isExecutableFile(atPath: candidate.defaultExecutablePath) {
            return (candidate, URL(fileURLWithPath: candidate.defaultExecutablePath))
        }
        // Nothing installed — report the default so error messages name
        // a concrete path rather than nothing at all.
        return (.munkipkg, URL(fileURLWithPath: PackagingTool.munkipkg.defaultExecutablePath))
    }

    private var executableURL: URL { resolved.url }

    public func projects(in folder: URL) async throws -> [MunkipkgProject] {
        let fileManager = FileManager.default
        // Let a missing or unreadable projects folder propagate so the
        // UI can show "Couldn't read projects". A single malformed
        // project, by contrast, is skipped — one bad build-info
        // shouldn't blank the whole sidebar.
        let entries = try fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var projects: [MunkipkgProject] = []
        for entry in entries {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  buildInfoFile(in: entry) != nil else { continue }
            if let project = try? await loadProject(at: entry) {
                projects.append(project)
            }
        }
        return projects.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    public func loadProject(at directory: URL) async throws -> MunkipkgProject {
        guard let (infoURL, format) = buildInfoFile(in: directory) else {
            throw RepositoryError.fileNotFound(directory)
        }
        let data = try Data(contentsOf: infoURL)
        let buildInfo: BuildInfo
        do {
            buildInfo = try BuildInfoCoder.decode(data: data, format: format)
        } catch {
            throw RepositoryError.parse(file: infoURL, message: error.localizedDescription)
        }

        let scriptsDirectory = directory.appending(path: "scripts")
        var scripts: [MunkipkgScript] = []
        if let names = try? FileManager.default.contentsOfDirectory(atPath: scriptsDirectory.path) {
            for name in names.sorted() where !name.hasPrefix(".") {
                scripts.append(MunkipkgScript(
                    name: name,
                    fileURL: scriptsDirectory.appending(path: name)
                ))
            }
        }
        let hasPayload = FileManager.default.fileExists(
            atPath: directory.appending(path: "payload").path
        )

        return MunkipkgProject(
            directoryURL: directory,
            buildInfo: buildInfo,
            buildInfoFormat: format,
            scripts: scripts,
            hasPayload: hasPayload
        )
    }

    public func saveBuildInfo(
        _ buildInfo: BuildInfo,
        to project: MunkipkgProject,
        format: BuildInfoFormat
    ) async throws {
        let url = project.directoryURL.appending(path: format.fileName)
        do {
            let data = try BuildInfoCoder.encode(buildInfo, format: format)
            try data.write(to: url, options: .atomic)
        } catch {
            throw RepositoryError.write(file: url, message: error.localizedDescription)
        }
        // Keep exactly one build-info file — drop any in another format.
        let others = ["build-info.plist", "build-info.yaml", "build-info.yml", "build-info.json"]
        for name in others {
            let candidate = project.directoryURL.appending(path: name)
            if candidate != url {
                try? FileManager.default.removeItem(at: candidate)
            }
        }
    }

    public func readScript(_ script: MunkipkgScript) async throws -> String {
        let data = try Data(contentsOf: script.fileURL)
        return String(decoding: data, as: UTF8.self)
    }

    public func writeScript(_ script: MunkipkgScript, contents: String) async throws {
        try contents.write(to: script.fileURL, atomically: true, encoding: .utf8)
        // munkipkg only runs scripts that are executable — keep the bit.
        let fileManager = FileManager.default
        if let attributes = try? fileManager.attributesOfItem(atPath: script.fileURL.path),
           let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue {
            try? fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: permissions | 0o111)],
                ofItemAtPath: script.fileURL.path
            )
        }
    }

    public func build(
        _ project: MunkipkgProject,
        options: MunkipkgBuildOptions
    ) -> AsyncThrowingStream<MunkipkgEvent, any Error> {
        let (tool, executable) = resolved
        let projectDirectory = project.directoryURL
        // munkipkg writes the package to `build/<name>.pkg` — the fork
        // appends `.pkg` to `name` itself when it isn't already there.
        let name = project.buildInfo.name
        let packageFileName = name.hasSuffix(".pkg") ? name : name + ".pkg"
        let productURL = project.buildDirectory.appending(path: packageFileName)
        let baseArguments = options.arguments(for: tool)
        // swiftpkg has no post-build import prompt, so there is no flag
        // to suppress — probing its `--help` for one and appending a
        // munkipkg spelling would just make it print usage and fail.
        let wantsSkipImport = options.skipImport && tool.supportsSkipImport

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var arguments = tool.buildModeArguments + baseArguments
                    if wantsSkipImport,
                       let flag = await Self.resolveSkipImportFlag(executable: executable) {
                        arguments.append(flag)
                    }
                    arguments.append(projectDirectory.path)
                    for try await event in ProcessRunner.stream(
                        executable,
                        arguments: arguments,
                        in: projectDirectory,
                        usePTY: true
                    ) {
                        switch event {
                        case .line(let line):
                            continuation.yield(.line(line))
                        case .terminated(let exitCode):
                            let built = exitCode == 0
                                && FileManager.default.fileExists(atPath: productURL.path)
                            continuation.yield(.finished(
                                exitCode: exitCode,
                                productURL: built ? productURL : nil
                            ))
                            continuation.finish()
                        }
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // Cancelling the consumer (e.g. navigating away mid-build)
            // tears down the inner task, which drops the `ProcessRunner`
            // stream and terminates the `munkipkg` child.
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Cache of the flag spelling this `munkipkg` accepts for
    /// suppressing the post-build import prompt. Per-executable so a
    /// Settings change re-detects. `nil` value means "no flag works —
    /// run without it" so we don't probe again.
    private static let importFlagCache = ImportFlagCache()

    private actor ImportFlagCache {
        private var values: [String: String?] = [:]
        func value(for path: String) -> (cached: Bool, value: String?) {
            if let entry = values[path] { return (true, entry) }
            return (false, nil)
        }
        func set(_ value: String?, for path: String) { values[path] = value }
    }

    /// The flag name (`--skip-import` or `--no-import`) the installed
    /// `munkipkg` advertises in `--help`, or `nil` if neither is present.
    /// Callers should omit the flag when this returns `nil` rather than
    /// blocking the build.
    private static func resolveSkipImportFlag(executable: URL) async -> String? {
        let path = executable.path
        let lookup = await importFlagCache.value(for: path)
        if lookup.cached { return lookup.value }
        guard FileManager.default.isExecutableFile(atPath: path),
              let output = try? await ProcessRunner.run(executable, arguments: ["--help"])
        else {
            await importFlagCache.set(nil, for: path)
            return nil
        }
        let help = output.stdout + "\n" + output.stderr
        let resolved: String?
        if help.contains("--skip-import") {
            resolved = "--skip-import"
        } else if help.contains("--no-import") {
            resolved = "--no-import"
        } else {
            resolved = nil
        }
        await importFlagCache.set(resolved, for: path)
        return resolved
    }

    public func version() async -> String? {
        let executable = executableURL
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        guard let output = try? await ProcessRunner.run(executable, arguments: ["--version"]),
              output.exitCode == 0 else { return nil }
        let text = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    public func installedTool() async -> InstalledPackagingTool? {
        let (tool, url) = resolved
        guard let version = await version() else { return nil }
        return InstalledPackagingTool(
            tool: tool,
            version: version,
            executablePath: url.path
        )
    }

    /// Latest-release endpoints. munkipkg attaches a bare binary;
    /// swiftpkg ships installer packages.
    private static func releaseAPI(for tool: PackagingTool) -> URL {
        switch tool {
        case .munkipkg:
            URL(string: "https://api.github.com/repos/rodchristiansen/munki-pkg/releases/latest")!
        case .swiftpkg:
            URL(string: "https://api.github.com/repos/codecarton/swiftpkg/releases/latest")!
        }
    }

    public func installLatest(_ tool: PackagingTool) async throws {
        switch tool {
        case .munkipkg: try await installMunkipkg()
        case .swiftpkg: try await installSwiftpkg()
        }
    }

    private func installMunkipkg() async throws {
        let staged = try await downloadLatestRelease()
        defer { try? FileManager.default.removeItem(at: staged) }
        // Clear the download quarantine flag (best effort) before the
        // privileged copy, so the installed binary isn't quarantined.
        _ = try? await ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/xattr"),
            arguments: ["-d", "com.apple.quarantine", staged.path]
        )
        try await installBinary(at: staged)
    }

    /// swiftpkg publishes signed installer packages rather than a bare
    /// binary, so this downloads the CLI package and hands it to
    /// `installer`, which puts the tool at its own chosen location.
    private func installSwiftpkg() async throws {
        let release = try await fetchRelease(for: .swiftpkg)
        guard let asset = Self.swiftpkgCLIAsset(in: release) else {
            throw MunkipkgError(
                "The latest swiftpkg release has no CLI installer package. "
                + "Expected an asset named like \"swiftpkg-<version>-cli.pkg\"."
            )
        }
        let (downloaded, _) = try await URLSession.shared.download(from: asset.browserDownloadURL)
        let staged = FileManager.default.temporaryDirectory
            .appending(path: "swiftpkg-\(UUID().uuidString).pkg")
        try FileManager.default.moveItem(at: downloaded, to: staged)
        defer { try? FileManager.default.removeItem(at: staged) }
        _ = try? await ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/xattr"),
            arguments: ["-d", "com.apple.quarantine", staged.path]
        )
        try await runInstaller(package: staged)
    }

    /// Pick the CLI-only package.
    ///
    /// The release also carries a "combined" package that bundles the
    /// Swiftpkgr desktop app, a tarball, and a checksums file. Matching
    /// the CLI package explicitly avoids installing a GUI app nobody
    /// asked for — and avoids running whatever else happens to be
    /// attached.
    static func swiftpkgCLIAsset(in release: GitHubRelease) -> GitHubRelease.Asset? {
        release.assets.first {
            let name = $0.name.lowercased()
            return name.hasPrefix("swiftpkg-") && name.hasSuffix("-cli.pkg")
        }
    }

    /// Install a `.pkg` system-wide, prompting for administrator rights.
    private func runInstaller(package: URL) async throws {
        let shell = "/usr/sbin/installer -pkg \"\(package.path)\" -target /"
        let escaped = shell
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script \"\(escaped)\" with administrator privileges"
        let output = try await ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: ["-e", appleScript]
        )
        guard output.exitCode == 0 else {
            let detail = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.contains("User canceled") || detail.contains("-128") {
                throw MunkipkgError("Installation cancelled.")
            }
            throw MunkipkgError(detail.isEmpty ? "Installation failed." : detail)
        }
    }

    private func fetchRelease(for tool: PackagingTool) async throws -> GitHubRelease {
        var request = URLRequest(url: Self.releaseAPI(for: tool))
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MunkipkgError("Couldn't reach GitHub.")
        }
        guard http.statusCode == 200 else {
            throw MunkipkgError("No published \(tool.displayName) release found.")
        }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    /// Resolve the fork's latest release, download its `munkipkg` asset
    /// to a temp file, and return that file.
    private func downloadLatestRelease() async throws -> URL {
        var request = URLRequest(url: Self.releaseAPI(for: .munkipkg))
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MunkipkgError("Couldn't reach GitHub.")
        }
        guard http.statusCode == 200 else {
            throw MunkipkgError(
                "No published munkipkg release found at github.com/rodchristiansen/munki-pkg. "
                + "Publish a release with the munkipkg binary attached."
            )
        }
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        // Only ever install an asset literally named `munkipkg` — never
        // fall back to whatever happens to be attached (a tarball, a
        // dSYM, release notes) and run it as the binary.
        guard let asset = release.assets.first(where: { $0.name == "munkipkg" }) else {
            throw MunkipkgError(
                "The latest munkipkg release has no asset named \"munkipkg\". "
                + "Attach the built binary to the release."
            )
        }
        let (downloaded, _) = try await URLSession.shared.download(from: asset.browserDownloadURL)
        let staged = FileManager.default.temporaryDirectory
            .appending(path: "munkipkg-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: downloaded, to: staged)
        return staged
    }

    /// Copy `binary` to `/usr/local/munki/munkipkg` with administrator
    /// rights — the destination directory is root-owned.
    private func installBinary(at binary: URL) async throws {
        let destination = Self.defaultExecutablePath
        let destinationDirectory = (destination as NSString).deletingLastPathComponent
        // Copying into /usr/local/munki needs root — run it through
        // osascript so macOS shows its own administrator prompt.
        let shell = "mkdir -p \"\(destinationDirectory)\" "
            + "&& /bin/cp \"\(binary.path)\" \"\(destination)\" "
            + "&& /bin/chmod 755 \"\(destination)\""
        let escaped = shell
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script \"\(escaped)\" with administrator privileges"
        let output = try await ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: ["-e", appleScript]
        )
        guard output.exitCode == 0 else {
            let detail = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.contains("User canceled") || detail.contains("-128") {
                throw MunkipkgError("Installation cancelled.")
            }
            throw MunkipkgError(detail.isEmpty ? "Installation failed." : detail)
        }
    }

    /// The `build-info` file in `directory`, with its format. Resolution
    /// order matches munkipkg's own: plist, then yaml, then json.
    private func buildInfoFile(in directory: URL) -> (URL, BuildInfoFormat)? {
        let candidates: [(String, BuildInfoFormat)] = [
            ("build-info.plist", .plist),
            ("build-info.yaml", .yaml),
            ("build-info.yml", .yaml),
            ("build-info.json", .json),
        ]
        for (name, format) in candidates {
            let url = directory.appending(path: name)
            if FileManager.default.fileExists(atPath: url.path) {
                return (url, format)
            }
        }
        return nil
    }
}

/// The slice of a GitHub release JSON payload the installer needs.
struct GitHubRelease: Decodable {
    let assets: [Asset]

    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }
}
