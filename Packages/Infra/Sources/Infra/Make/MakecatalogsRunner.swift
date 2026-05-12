import Foundation
import Core

/// Concrete ``MakecatalogsService`` that shells out to the official
/// `makecatalogs` binary Munki ships under `/usr/local/munki/`. Output is
/// surfaced as a stream of lines plus a terminal outcome.
public final class MakecatalogsRunner: MakecatalogsService {
    private let executableURL: URL

    public init(executableURL: URL = URL(fileURLWithPath: "/usr/local/munki/makecatalogs")) {
        self.executableURL = executableURL
    }

    public func run(
        in repository: MunkiRepository,
        options: MakecatalogsOptions
    ) -> AsyncThrowingStream<MakecatalogsEvent, any Error> {
        let executable = executableURL
        let repoPath = repository.rootURL.path

        var args: [String] = []
        if options.force { args.append("--force") }
        if options.skipPkgcheck { args.append("--skip-pkg-check") }
        if let outputFormat = options.outputFormat {
            args.append("--output-format")
            args.append(outputFormat.preferredExtension)
        }
        args.append(repoPath)

        return AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            let collector = LineCollector()

            process.terminationHandler = { proc in
                Task {
                    let warnings = await collector.sawWarnings
                    continuation.yield(.finished(MakecatalogsOutcome(
                        exitCode: proc.terminationStatus,
                        hadWarnings: warnings
                    )))
                    continuation.finish()
                }
            }

            do {
                try process.run()
            } catch {
                continuation.finish(throwing: error)
                return
            }

            // Stream stdout/stderr lines as they arrive.
            Task {
                let handle = pipe.fileHandleForReading
                do {
                    for try await line in handle.bytes.lines {
                        await collector.note(line: line)
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
}

private actor LineCollector {
    private(set) var sawWarnings = false

    func note(line: String) {
        if line.localizedCaseInsensitiveContains("warning") {
            sawWarnings = true
        }
    }
}
