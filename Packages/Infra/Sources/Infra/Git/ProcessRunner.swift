import Foundation
import Darwin

/// Lightweight `Process` wrapper. We use it instead of pulling in a fuller
/// async-process library so Infra stays dependency-light. The
/// non-streaming `run` variant collects all output; the streaming variant
/// hands lines to an `AsyncThrowingStream` as they arrive.
enum ProcessRunner {
    struct Output: Sendable {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    /// Run a command to completion, capturing its full stdout / stderr.
    static func run(
        _ executable: URL,
        arguments: [String],
        in workingDirectory: URL? = nil,
        environment: [String: String]? = nil
    ) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            if let workingDirectory {
                process.currentDirectoryURL = workingDirectory
            }
            if let environment {
                process.environment = environment
            }
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.terminationHandler = { proc in
                let outData = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
                let errData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
                continuation.resume(returning: Output(
                    exitCode: proc.terminationStatus,
                    stdout: String(decoding: outData, as: UTF8.self),
                    stderr: String(decoding: errData, as: UTF8.self)
                ))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Run a command and stream merged stdout+stderr lines as they arrive,
    /// finishing with the process exit code in `.terminated`.
    enum StreamEvent: Sendable {
        case line(String)
        case terminated(Int32)
    }

    static func stream(
        _ executable: URL,
        arguments: [String],
        in workingDirectory: URL? = nil,
        environment: [String: String]? = nil,
        usePTY: Bool = false
    ) -> AsyncThrowingStream<StreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            if let workingDirectory {
                process.currentDirectoryURL = workingDirectory
            }
            if let environment {
                process.environment = environment
            }

            // A PTY makes the child see a terminal on stdout, so it
            // line-buffers instead of block-buffering — output then
            // streams live instead of arriving all at once on exit.
            let readHandle: FileHandle
            let childWriteEnd: FileHandle
            if usePTY, let pty = makePTY() {
                process.standardOutput = pty.replica
                process.standardError = pty.replica
                readHandle = pty.primary
                childWriteEnd = pty.replica
            } else {
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                readHandle = pipe.fileHandleForReading
                childWriteEnd = pipe.fileHandleForWriting
            }

            do {
                try process.run()
            } catch {
                continuation.finish(throwing: error)
                return
            }
            // The parent never writes to the child's output channel —
            // close its copy so the reader sees EOF when the child ends.
            try? childWriteEnd.close()

            Task {
                do {
                    for try await line in readHandle.bytes.lines {
                        continuation.yield(.line(line.hasSuffix("\r") ? String(line.dropLast()) : line))
                    }
                } catch {
                    // A PTY primary returns EIO once the child closes its
                    // replica — that's expected end-of-output. A plain
                    // pipe only throws on a real failure, so propagate it
                    // instead of masking it as a clean finish.
                    if !usePTY {
                        continuation.finish(throwing: error)
                        return
                    }
                }
                process.waitUntilExit()
                continuation.yield(.terminated(process.terminationStatus))
                continuation.finish()
            }

            continuation.onTermination = { _ in
                if process.isRunning { process.terminate() }
            }
        }
    }

    /// Allocate a pseudo-terminal: the parent's read handle (primary) and
    /// the child's write handle (replica).
    ///
    /// The replica is handed over with default termios and window size —
    /// enough to make children line-buffer (the only reason we use a
    /// PTY), but not a full Terminal.app emulation. A child that probes
    /// the window size (`TIOCGWINSZ`) or expects raw mode won't get
    /// sensible answers; `tcsetattr` / `TIOCSWINSZ` would be needed for
    /// that. Fine for `munkipkg`; revisit if other callers opt into PTY.
    private static func makePTY() -> (primary: FileHandle, replica: FileHandle)? {
        let primaryFD = posix_openpt(O_RDWR | O_NOCTTY)
        guard primaryFD >= 0 else { return nil }
        guard grantpt(primaryFD) == 0,
              unlockpt(primaryFD) == 0,
              let namePtr = ptsname(primaryFD) else {
            close(primaryFD)
            return nil
        }
        let replicaFD = open(String(cString: namePtr), O_RDWR | O_NOCTTY)
        guard replicaFD >= 0 else {
            close(primaryFD)
            return nil
        }
        return (
            FileHandle(fileDescriptor: primaryFD, closeOnDealloc: true),
            FileHandle(fileDescriptor: replicaFD, closeOnDealloc: false)
        )
    }
}
