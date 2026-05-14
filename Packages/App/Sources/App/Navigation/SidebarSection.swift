import Foundation

/// Destinations the source-list sidebar offers. We keep it intentionally
/// small — four task-oriented sections rather than one entry per domain
/// concept. Icons / Categories / Developers move into the Packages pane
/// as inspectors / filters; global search hangs off Cmd-F in each list.
enum SidebarSection: String, Hashable, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case search = "Search"
    case packages = "Packages"
    case manifests = "Manifests"
    case catalogs = "Catalogs"
    case git = "Git"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .dashboard: "rectangle.grid.2x2"
        case .search: "magnifyingglass"
        case .packages: "shippingbox"
        case .manifests: "list.bullet.rectangle"
        case .catalogs: "books.vertical"
        case .git: "arrow.triangle.branch"
        }
    }

    var title: String { rawValue }
}
