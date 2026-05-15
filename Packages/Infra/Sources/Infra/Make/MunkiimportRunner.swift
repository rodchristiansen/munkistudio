import Foundation
import Core

/// Concrete ``MunkiimportService`` that shells out to the official
/// `munkiimport` binary Munki ships under `/usr/local/munki/`. We always
/// pass `-n` (nointeractive) — the wizard collects every value the CLI
/// would otherwise prompt for, so there's nothing to wait on.
///
/// We parse two paths out of stdout when the run succeeds: the pkginfo
/// file munkiimport just wrote, and the installer it copied into
/// `pkgs/`. The wizard uses those to refresh the package list and pre-
/// stage the git commit hand-off, exactly the way CimianStudio's import
/// page does after its own native write.
public final class MunkiimportRunner: MunkiimportService {
    private let executableURL: URL

    public init(executableURL: URL = URL(fileURLWithPath: "/usr/local/munki/munkiimport")) {
        self.executableURL = executableURL
    }

    public func run(
        in repository: MunkiRepository,
        options: MunkiimportOptions
    ) -> AsyncThrowingStream<MunkiimportEvent, any Error> {
        let executable = executableURL
        let arguments = Self.buildArguments(repository: repository, options: options)

        return AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let collector = OutputCollector()

            process.terminationHandler = { proc in
                Task {
                    let stdout = await collector.stdout
                    let stderr = await collector.stderr
                    let outcome = MunkiimportOutcome(
                        exitCode: proc.terminationStatus,
                        pkginfoURL: Self.parsePkginfoPath(from: stdout, repository: repository),
                        installerURL: Self.parseInstallerPath(from: stdout, repository: repository),
                        errorOutput: proc.terminationStatus == 0 ? "" : stderr
                    )
                    continuation.yield(.finished(outcome))
                    continuation.finish()
                }
            }

            do {
                try process.run()
            } catch {
                continuation.finish(throwing: error)
                return
            }

            // Stream stdout and stderr together so the UI sees everything
            // in arrival order. Each handle gets its own task because
            // FileHandle.bytes is a single-pass async sequence.
            Task {
                do {
                    for try await line in stdoutPipe.fileHandleForReading.bytes.lines {
                        await collector.append(stdout: line)
                        continuation.yield(.line(line))
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            Task {
                do {
                    for try await line in stderrPipe.fileHandleForReading.bytes.lines {
                        await collector.append(stderr: line)
                        continuation.yield(.line(line))
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                if process.isRunning { process.terminate() }
            }
        }
    }

    /// Translate an ``MunkiimportOptions`` into the flag set the CLI
    /// expects. Order doesn't matter to munkiimport but we group flags
    /// so the printed command-line is readable when the wizard echoes
    /// it back to the user.
    static func buildArguments(repository: MunkiRepository, options: MunkiimportOptions) -> [String] {
        var args: [String] = ["-n"]

        args.append("--repo-url")
        args.append("file://\(repository.rootURL.path)")

        if !options.subdirectory.isEmpty {
            args.append("--subdirectory")
            args.append(options.subdirectory)
        }
        for catalog in options.catalogs where !catalog.isEmpty {
            args.append("--catalog")
            args.append(catalog)
        }
        if let name = options.name, !name.isEmpty {
            args.append("--name")
            args.append(name)
        }
        if let displayName = options.displayName, !displayName.isEmpty {
            args.append("--displayname")
            args.append(displayName)
        }
        if let version = options.version, !version.isEmpty {
            args.append("--pkgvers")
            args.append(version)
        }
        if let developer = options.developer, !developer.isEmpty {
            args.append("--developer")
            args.append(developer)
        }
        if let category = options.category, !category.isEmpty {
            args.append("--category")
            args.append(category)
        }
        if let description = options.description, !description.isEmpty {
            args.append("--description")
            args.append(description)
        }
        for arch in options.supportedArchitectures where !arch.isEmpty {
            args.append("--arch")
            args.append(arch)
        }
        if options.unattendedInstall {
            args.append("--unattended-install")
        }
        if options.unattendedUninstall {
            args.append("--unattended-uninstall")
        }
        for blocking in options.blockingApplications where !blocking.isEmpty {
            args.append("--blocking-application")
            args.append(blocking)
        }
        if let minOS = options.minimumOSVersion, !minOS.isEmpty {
            args.append("--minimum-os-version")
            args.append(minOS)
        }
        if let maxOS = options.maximumOSVersion, !maxOS.isEmpty {
            args.append("--maximum-os-version")
            args.append(maxOS)
        }
        if let minMunki = options.minimumMunkiVersion, !minMunki.isEmpty {
            args.append("--minimum-munki-version")
            args.append(minMunki)
        }
        if let pre = options.preinstallScriptPath {
            args.append("--preinstall-script")
            args.append(pre.path)
        }
        if let post = options.postinstallScriptPath {
            args.append("--postinstall-script")
            args.append(post.path)
        }
        if let preU = options.preuninstallScriptPath {
            args.append("--preuninstall-script")
            args.append(preU.path)
        }
        if let postU = options.postuninstallScriptPath {
            args.append("--postuninstall-script")
            args.append(postU.path)
        }
        if let ic = options.installCheckScriptPath {
            args.append("--installcheck-script")
            args.append(ic.path)
        }
        if let uc = options.uninstallCheckScriptPath {
            args.append("--uninstallcheck-script")
            args.append(uc.path)
        }
        if options.emitYAML {
            args.append("--yaml")
        }
        if options.extractIcon {
            args.append("--extract-icon")
        }
        if let icon = options.iconPath {
            args.append("--icon-path")
            args.append(icon.path)
        }

        args.append(options.installerPath.path)
        return args
    }

    /// munkiimport prints lines like
    /// `Saved pkginfo to pkgsinfo/apps/Firefox-123.0.plist` (and the YAML
    /// variant uses the same prefix). Pull the relative path out and
    /// resolve it against the repo root so the caller can navigate to it.
    static func parsePkginfoPath(from stdout: String, repository: MunkiRepository) -> URL? {
        let needles = ["Saved pkginfo to ", "Wrote pkginfo to ", "Saved pkgsinfo to ", "Created pkginfo at "]
        for line in stdout.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            for needle in needles where trimmed.hasPrefix(needle) {
                let path = String(trimmed.dropFirst(needle.count))
                return resolved(path: path, against: repository)
            }
        }
        // Fall back to scanning every line for a "pkgsinfo/" reference —
        // munki minor versions sometimes change the prefix wording.
        for line in stdout.split(whereSeparator: \.isNewline) {
            if let range = line.range(of: "pkgsinfo/") {
                let tail = String(line[range.lowerBound...])
                let cleaned = tail.trimmingCharacters(in: CharacterSet(charactersIn: "'\"`.,"))
                return resolved(path: cleaned, against: repository)
            }
        }
        return nil
    }

    static func parseInstallerPath(from stdout: String, repository: MunkiRepository) -> URL? {
        let needles = ["Copying ", "Uploaded ", "Copied "]
        for line in stdout.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            for needle in needles where trimmed.hasPrefix(needle) {
                let rest = trimmed.dropFirst(needle.count)
                // Either "Copying X to Y" or just a single path; prefer
                // the destination when "to" is present.
                if let toRange = rest.range(of: " to ") {
                    let path = String(rest[toRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                    return resolved(path: path, against: repository)
                }
            }
            if let range = line.range(of: "pkgs/") {
                let tail = String(line[range.lowerBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "'\"`.,"))
                if !tail.contains("pkgsinfo/") {
                    return resolved(path: tail, against: repository)
                }
            }
        }
        return nil
    }

    private static func resolved(path: String, against repository: MunkiRepository) -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed)
        }
        return repository.rootURL.appending(path: trimmed)
    }
}

private actor OutputCollector {
    private(set) var stdout = ""
    private(set) var stderr = ""

    func append(stdout line: String) { stdout.append(line); stdout.append("\n") }
    func append(stderr line: String) { stderr.append(line); stderr.append("\n") }
}
