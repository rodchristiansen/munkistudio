import Foundation

/// FileManager helper that reads creation + modification dates in one
/// call. Used by the file coders to populate `PkginfoRecord` /
/// `ManifestRecord` timestamps at load time so the UI can show them
/// and the lists can sort by Recently Modified without re-hitting disk.
enum FileTimestamps {
    static func read(_ url: URL) -> (created: Date?, modified: Date?) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return (nil, nil)
        }
        return (attrs[.creationDate] as? Date, attrs[.modificationDate] as? Date)
    }
}
