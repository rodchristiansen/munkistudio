import AppKit
import Foundation

/// `.git/index.lock` left behind by a crashed or concurrent git process
/// is the single most common reason a stage / unstage / commit fails
/// out of nowhere. macOS git's own error message is "Another git
/// process seems to be running in this repository, e.g. an editor
/// opened by 'git commit'…" — accurate but not actionable from inside
/// the app.
///
/// This helper detects that specific failure and surfaces a modal with
/// two recovery actions: probe `lsof` to identify the process still
/// holding the lock (so the user can kill it the right way) or delete
/// the lock outright (safe when no other git process is actually
/// running).
enum IndexLockRecovery {
    /// Returns `true` if the error looks like an index-lock conflict.
    /// Used by callers to decide whether to swap their generic error
    /// message for the recovery flow.
    static func matches(_ error: Error) -> Bool {
        matches(message: error.localizedDescription)
    }

    static func matches(message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("index.lock") || lower.contains("another git process")
    }

    /// Present the recovery alert. Synchronous (NSAlert.runModal) so
    /// callers don't have to manage a separate sheet state — the alert
    /// blocks the main thread for the few seconds it's visible and
    /// then returns.
    @MainActor
    static func present(workTreeRoot: URL, message: String) -> Outcome {
        let lockURL = workTreeRoot.appending(path: ".git/index.lock")
        let alert = NSAlert()
        alert.messageText = "Git index is locked"
        alert.informativeText = """
            \(message)

            Lock file: \(lockURL.path)
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Show holder…")
        alert.addButton(withTitle: "Delete lock file")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return inspectHolder(lockURL: lockURL)
        case .alertSecondButtonReturn:
            return deleteLock(lockURL: lockURL)
        default:
            return .cancelled
        }
    }

    enum Outcome {
        case deleted
        case cancelled
        case failed(String)
    }

    /// Run `lsof` against the lock file to find which PID still holds
    /// it. macOS's lsof prints a process name and PID per row; if the
    /// output is empty, no process actually has the file open and the
    /// lock is safe to delete (likely a crashed git left it behind).
    @MainActor
    private static func inspectHolder(lockURL: URL) -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = [lockURL.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        var lsofOutput = ""
        do {
            try process.run()
            process.waitUntilExit()
            let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
            lsofOutput = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            // lsof itself blew up — surface the error and bail out
            // before pretending we know who holds the lock.
            return .failed("lsof failed: \(error.localizedDescription)")
        }

        let alert = NSAlert()
        alert.messageText = "Lock holder"
        if lsofOutput.isEmpty {
            alert.informativeText = """
                No process currently has \(lockURL.lastPathComponent) open.

                The lock was likely left behind by a crashed git command. Safe to delete.
                """
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Delete lock file")
            alert.addButton(withTitle: "Cancel")
        } else {
            alert.informativeText = """
                lsof reports:

                \(lsofOutput)

                Quit that process before deleting the lock, or delete it now if you know it's safe.
                """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Delete lock file")
            alert.addButton(withTitle: "Cancel")
        }
        return alert.runModal() == .alertFirstButtonReturn
            ? deleteLock(lockURL: lockURL)
            : .cancelled
    }

    @MainActor
    private static func deleteLock(lockURL: URL) -> Outcome {
        do {
            try FileManager.default.removeItem(at: lockURL)
            return .deleted
        } catch CocoaError.fileNoSuchFile {
            // Already gone — count that as success; whatever the user
            // was trying to do can be retried immediately.
            return .deleted
        } catch {
            return .failed("Couldn't delete lock: \(error.localizedDescription)")
        }
    }
}
