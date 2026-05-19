import Foundation

/// Top-level value type describing one open Munki repo. Holds the root URL,
/// the standard subdirectory layout, and the format the UI should default to
/// when creating *new* pkginfo / manifest files (computed from the majority
/// of existing files at open time).
public struct MunkiRepository: Sendable, Hashable, Identifiable {
    public var id: URL { rootURL }

    public var rootURL: URL
    public var displayName: String
    public var defaultFormat: RepoFormat

    public init(
        rootURL: URL,
        displayName: String? = nil,
        defaultFormat: RepoFormat = .plist
    ) {
        self.rootURL = rootURL
        self.displayName = displayName ?? rootURL.lastPathComponent
        self.defaultFormat = defaultFormat
    }

    public var pkgsinfoURL: URL { rootURL.appending(path: "pkgsinfo") }
    public var manifestsURL: URL { rootURL.appending(path: "manifests") }
    public var catalogsURL: URL { rootURL.appending(path: "catalogs") }
    public var pkgsURL: URL { rootURL.appending(path: "pkgs") }
    public var iconsURL: URL { rootURL.appending(path: "icons") }
    public var clientResourcesURL: URL { rootURL.appending(path: "client_resources") }
}
