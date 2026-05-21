import Foundation

/// `.git/index.lock` left behind by a crashed or concurrent git process
/// is the single most common reason a stage / unstage / commit fails
/// out of nowhere. macOS git's own error message is "Another git
/// process seems to be running in this repository, e.g. an editor
/// opened by 'git commit'…" — accurate but not actionable from inside
/// the app.
///
/// This helper is now pure: it detects the failure (``matches``) and
/// performs the two recovery operations (``inspectHolder``,
/// ``deleteLock``). UI used to live here as a synchronous `NSAlert.runModal`
/// flow — it now sits on `GitView` as a SwiftUI `.alert` so the app
/// no longer needs AppKit for this surface.
enum IndexLockRecovery {
    /// Returns `true` if the error looks like an index-lock conflict.
    /// Used by callers to decide whether to swap their generic error
    /// message for the recovery flow.
    static func matches(_ error: any Error) -> Bool {
        matches(message: error.localizedDescription)
    }

    static func matches(message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("index.lock") || lower.contains("another git process")
    }

    /// The conventional location of the index lock for a working tree.
    static func lockURL(in workTreeRoot: URL) -> URL {
        workTreeRoot.appending(path: ".git/index.lock")
    }

    /// Run `lsof` against the lock file to find which PID still holds
    /// it. macOS's lsof prints a process name + PID per row; empty
    /// output means nothing has the file open and the lock is safe to
    /// delete (likely a crashed git left it behind).
    static func inspectHolder(lockURL: URL) async -> HolderResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = [lockURL.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return .lookupFailed("lsof failed: \(error.localizedDescription)")
        }
        process.waitUntilExit()
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        let output = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .ok(output)
    }

    enum HolderResult {
        /// `output` is the trimmed lsof report — empty when nothing
        /// holds the lock.
        case ok(String)
        case lookupFailed(String)
    }

    /// Remove the lock file. Treats "already gone" as success so the
    /// caller's retry can run immediately.
    static func deleteLock(lockURL: URL) -> Outcome {
        do {
            try FileManager.default.removeItem(at: lockURL)
            return .deleted
        } catch CocoaError.fileNoSuchFile {
            return .deleted
        } catch {
            return .failed("Couldn't delete lock: \(error.localizedDescription)")
        }
    }

    enum Outcome {
        case deleted
        case failed(String)
    }
}
