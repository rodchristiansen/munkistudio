import Foundation

/// A single entry in a manifest's `conditional_items[]`. The `condition`
/// string is an NSPredicate expression evaluated by Munki at run time on the
/// client; if it resolves to true, the nested arrays are merged into the
/// active install lists. The structured form lives in
/// ``PredicateModel`` and is parsed on demand by the UI.
public struct ConditionalItem: Sendable, Hashable, Codable {
    public var condition: String
    public var managedInstalls: [String]?
    public var managedUninstalls: [String]?
    public var managedUpdates: [String]?
    public var optionalInstalls: [String]?
    public var featuredItems: [String]?
    public var includedManifests: [String]?
    public var conditionalItems: [ConditionalItem]?

    public init(
        condition: String,
        managedInstalls: [String]? = nil,
        managedUninstalls: [String]? = nil,
        managedUpdates: [String]? = nil,
        optionalInstalls: [String]? = nil,
        featuredItems: [String]? = nil,
        includedManifests: [String]? = nil,
        conditionalItems: [ConditionalItem]? = nil
    ) {
        self.condition = condition
        self.managedInstalls = managedInstalls
        self.managedUninstalls = managedUninstalls
        self.managedUpdates = managedUpdates
        self.optionalInstalls = optionalInstalls
        self.featuredItems = featuredItems
        self.includedManifests = includedManifests
        self.conditionalItems = conditionalItems
    }

    enum CodingKeys: String, CodingKey {
        case condition
        case managedInstalls = "managed_installs"
        case managedUninstalls = "managed_uninstalls"
        case managedUpdates = "managed_updates"
        case optionalInstalls = "optional_installs"
        case featuredItems = "featured_items"
        case includedManifests = "included_manifests"
        case conditionalItems = "conditional_items"
    }
}
