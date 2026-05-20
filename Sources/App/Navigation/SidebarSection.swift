import Foundation

/// Destinations the source-list sidebar offers. We keep it intentionally
/// small — four task-oriented sections rather than one entry per domain
/// concept. Icons / Categories / Developers move into the Packages pane
/// as inspectors / filters; global search hangs off Cmd-F in each list.
enum SidebarSection: String, Hashable, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case packages = "Packages"
    case manifests = "Manifests"
    case profiles = "Profiles"
    case catalogs = "Catalogs"
    case dependencies = "Dependencies"
    case build = "Build"
    case importer = "Import"
    case clean = "Clean"
    case git = "Git"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .dashboard: "rectangle.grid.2x2"
        case .packages: "shippingbox"
        case .manifests: "list.bullet.rectangle"
        case .profiles: "doc.text"
        case .catalogs: "books.vertical"
        case .dependencies: "point.3.connected.trianglepath.dotted"
        case .build: "hammer"
        case .importer: "square.and.arrow.down"
        case .clean: "sparkles"
        case .git: "arrow.triangle.branch"
        }
    }

    var title: String { rawValue }

    /// Sections that own the whole detail area — no separate list / detail
    /// columns. These get a single full-width pane next to the sidebar.
    var prefersFullWidth: Bool {
        switch self {
        case .dashboard, .git, .importer, .dependencies, .build, .clean: true
        case .packages, .manifests, .profiles, .catalogs: false
        }
    }
}
