import Foundation
import Core

/// Shared helpers for walking the Munki repo directories. Pure functions —
/// no I/O state, no error swallowing.
enum RepoWalker {
    /// All pkginfo / manifest URLs under `directory`, restricted to the
    /// recognized extensions. Hidden files are skipped.
    static func documentURLs(
        under directory: URL,
        allowEmptyExtension: Bool = false
    ) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var urls: [URL] = []
        for case let url as URL in enumerator {
            let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            guard isRegular else { continue }
            let ext = url.pathExtension.lowercased()
            if RepoFormat.fromPathExtension(ext) != nil {
                urls.append(url)
            } else if allowEmptyExtension && ext.isEmpty {
                urls.append(url)
            }
        }
        return urls
    }
}
