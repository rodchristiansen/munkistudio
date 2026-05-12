import Foundation

/// Destinations the source-list sidebar offers. `Hashable` so SwiftUI can
/// use them as `NavigationLink` values; `CaseIterable` so the sidebar can
/// render them in canonical order.
enum SidebarSection: String, Hashable, CaseIterable, Identifiable {
    case packages = "Packages"
    case manifests = "Manifests"
    case catalogs = "Catalogs"
    case icons = "Icons"
    case categories = "Categories"
    case developers = "Developers"
    case git = "Git"
    case search = "Search"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .packages: "shippingbox"
        case .manifests: "list.bullet.rectangle"
        case .catalogs: "books.vertical"
        case .icons: "photo"
        case .categories: "tag"
        case .developers: "person.2"
        case .git: "arrow.triangle.branch"
        case .search: "magnifyingglass"
        }
    }

    var title: String { rawValue }
}
