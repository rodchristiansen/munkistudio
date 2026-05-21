import SwiftUI

/// Integration with Mother's Ruin Software's free "Suspicious Package"
/// inspector. Lets an admin open a pkginfo's `.pkg` installer item to
/// inspect its payload, scripts and signature.
enum SuspiciousPackage {
    /// Bundle identifier of the Suspicious Package application.
    static let bundleID = "com.mothersruin.SuspiciousPackageApp"

    /// Vendor page, shown when the app isn't installed.
    static let downloadPageURL = URL(string: "https://www.mothersruin.com/software/SuspiciousPackage/")!

    /// The system icon macOS uses for `.pkg` installer files.
    @MainActor
    static var pkgFileIcon: Image {
        Workspace.fileIcon(forExtension: "pkg")
    }

    /// Location of the installed app, or `nil` when it isn't installed.
    static var applicationURL: URL? {
        Workspace.application(bundleIdentifier: bundleID)
    }

    static var isInstalled: Bool { applicationURL != nil }

    /// `true` when `url` is a flat installer package Suspicious Package
    /// can open. Restricted to `.pkg` — not `.mpkg` or `.dmg`.
    static func canInspect(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "pkg"
    }

    /// Open `fileURL` in Suspicious Package. Returns `false` when the app
    /// isn't installed — the caller should then offer the download page.
    @MainActor
    @discardableResult
    static func open(_ fileURL: URL) -> Bool {
        guard let app = applicationURL else { return false }
        Workspace.open([fileURL], with: app)
        return true
    }

    /// Open the vendor download page in the default browser.
    @MainActor
    static func openDownloadPage() {
        Workspace.open(downloadPageURL)
    }
}
