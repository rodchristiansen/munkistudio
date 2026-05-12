import Foundation

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
        environment: [String: String]? = nil
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
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            process.terminationHandler = { proc in
                continuation.yield(.terminated(proc.terminationStatus))
                continuation.finish()
            }

            do {
                try process.run()
            } catch {
                continuation.finish(throwing: error)
                return
            }

            Task {
                do {
                    for try await line in pipe.fileHandleForReading.bytes.lines {
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
