import Foundation

/// Wrapper around `Data.write(to:options:)` that guarantees the destination
/// either contains the new bytes or the old bytes — never a partially
/// written file. We rely on `.atomic` which uses rename(2) under the hood.
public enum AtomicWrite {
    public static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: [.atomic])
    }
}
