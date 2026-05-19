import Foundation
import Core

/// Concrete ``RepoCleanService`` that shells out to the official
/// `repoclean` binary Munki ships under `/usr/local/munki/`. Output is
/// surfaced as a stream of lines plus a terminal outcome.
public final class RepoCleanRunner: RepoCleanService {
    private let executableURL: URL

    public init(executableURL: URL = URL(fileURLWithPath: "/usr/local/munki/repoclean")) {
        self.executableURL = executableURL
    }

    public func run(
        in repository: MunkiRepository,
        options: RepoCleanOptions
    ) -> AsyncThrowingStream<RepoCleanEvent, any Error> {
        let executable = executableURL
        let repoPath = repository.rootURL.path
        let apply = options.apply

        var args = ["--keep", String(max(1, options.keep))]
        if options.showAll { args.append("--show-all") }
        // --auto deletes without prompting. A preview run omits it and
        // instead answers "no" to the prompt (see below).
        if apply { args.append("--auto") }
        args.append(repoPath)

        return AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = args
            let outPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = outPipe

            // A preview must not delete anything. `repoclean` prints a
            // "[y/N]" prompt before deleting; feed it "n" so the prompt
            // resolves to No. An apply run uses --auto and never reads
            // stdin, but we still wire a closed pipe so it can't block.
            let inPipe = Pipe()
            process.standardInput = inPipe

            process.terminationHandler = { proc in
                continuation.yield(.finished(RepoCleanOutcome(
                    exitCode: proc.terminationStatus,
                    applied: apply && proc.terminationStatus == 0
                )))
                continuation.finish()
            }

            do {
                try process.run()
            } catch {
                continuation.finish(throwing: error)
                return
            }

            let stdin = inPipe.fileHandleForWriting
            if apply {
                try? stdin.close()
            } else {
                try? stdin.write(contentsOf: Data("n\n".utf8))
                try? stdin.close()
            }

            Task {
                let handle = outPipe.fileHandleForReading
                do {
                    for try await line in handle.bytes.lines {
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
