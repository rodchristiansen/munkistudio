import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Thin shim that hides AppKit's process / Finder / pasteboard / image
/// surface behind one App-layer namespace. Every "reveal in Finder",
/// "open in external editor", "copy to clipboard", and "load an icon
/// from disk" call routes through here so the rest of the App layer
/// doesn't need `import AppKit`.
///
/// SwiftUI has no first-class replacement for any of these on macOS —
/// `.fileImporter` covers file pickers, `.draggable`/`.dropDestination`
/// cover drag and drop, but Finder reveal, default-app lookup,
/// pasteboard, and on-disk `.icns`/`.tiff` loading still bottom out in
/// AppKit. Keep the shim small; nothing in here should grow new ideas.
enum Workspace {
    // MARK: Finder reveal

    /// Open Finder, focus the parent folder, and select `url`.
    @MainActor
    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Multi-select Finder reveal — used by the Git pane when more
    /// than one file is in the selection.
    @MainActor
    static func reveal(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    // MARK: Open with apps

    /// Open `url` with the user's default app for that type.
    @MainActor
    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// Open every URL in `urls` with the app at `appURL` (the "Open
    /// With ▸ <App>" menu actions).
    @MainActor
    static func open(_ urls: [URL], with appURL: URL) {
        NSWorkspace.shared.open(
            urls,
            withApplicationAt: appURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    /// Every installed app the system would offer in the "Open With"
    /// submenu for `url`. Sorted by LaunchServices preference.
    static func applications(toOpen url: URL) -> [URL] {
        NSWorkspace.shared.urlsForApplications(toOpen: url)
    }

    /// First installed app matching `bundleIdentifier`, or `nil` when
    /// nothing claims that bundle id.
    static func application(bundleIdentifier: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    // MARK: Pasteboard

    /// Replace the general pasteboard with `text` (plain string).
    @MainActor
    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Images

    /// Load `url` as a SwiftUI `Image`. Returns `nil` when the file
    /// can't be read or isn't a valid image (corrupted icon files are
    /// the common case here).
    static func loadImage(at url: URL) -> Image? {
        guard let nsImage = NSImage(contentsOf: url) else { return nil }
        return Image(nsImage: nsImage)
    }

    /// Decode `data` into a SwiftUI `Image`. Used when callers already
    /// hold raw bytes from disk or a SwiftPM-bundled resource.
    static func loadImage(data: Data) -> Image? {
        guard let nsImage = NSImage(data: data) else { return nil }
        return Image(nsImage: nsImage)
    }

    /// SwiftUI `Image` for the Finder icon Apple assigns to files with
    /// `extension` (e.g. "pkg" → the installer-package badge).
    @MainActor
    static func fileIcon(forExtension ext: String) -> Image {
        if let type = UTType(filenameExtension: ext) {
            return Image(nsImage: NSWorkspace.shared.icon(for: type))
        }
        return Image(nsImage: NSWorkspace.shared.icon(forFile: "/System"))
    }
}
