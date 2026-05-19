import Foundation
import Core

/// Concrete ``IconImporterService`` that shells out to the official
/// `iconimporter` binary Munki ships under `/usr/local/munki/`.
public actor IconImporterRunner: IconImporterService {
    private let executableURL: URL

    public init(executableURL: URL = URL(fileURLWithPath: "/usr/local/munki/iconimporter")) {
        self.executableURL = executableURL
    }

    public func generateIcon(
        forItem itemName: String,
        force: Bool,
        in repository: MunkiRepository
    ) async throws -> [String] {
        var args: [String] = []
        if force { args.append("--force") }
        args.append(contentsOf: ["--item", itemName])
        args.append(repository.rootURL.path)

        let process = Process()
        process.executableURL = executableURL
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        // iconimporter for a single item emits only a few lines, well
        // under the pipe buffer — safe to drain after the process exits.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)

        guard process.terminationStatus == 0 else {
            throw RepositoryError.process(
                name: "iconimporter",
                exitCode: process.terminationStatus,
                output: output
            )
        }
        return Self.writtenIconNames(from: output)
    }

    /// Parse the `Wrote: icons/<file>` lines `iconimporter` prints into
    /// the bare icon filenames it created.
    static func writtenIconNames(from output: String) -> [String] {
        var names: [String] = []
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("Wrote:") else { continue }
            let path = trimmed.dropFirst("Wrote:".count).trimmingCharacters(in: .whitespaces)
            let name = (path as NSString).lastPathComponent
            if !name.isEmpty { names.append(name) }
        }
        return names
    }
}
