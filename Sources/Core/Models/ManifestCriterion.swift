import Foundation

/// A single row in a manifest smart-filter — `attribute` `op` `value`.
/// Lists of these are combined under a ``CriteriaGroup`` quantifier
/// (`all` / `any`).
public struct ManifestCriterion: Sendable, Hashable, Identifiable, Codable {
    public var id: UUID
    public var attribute: ManifestAttribute
    public var op: CriterionOperator
    public var value: String

    public init(
        id: UUID = UUID(),
        attribute: ManifestAttribute,
        op: CriterionOperator,
        value: String = ""
    ) {
        self.id = id
        self.attribute = attribute
        self.op = op
        self.value = value
    }
}

/// Quantifier wrapping a list of criteria. Implements the "All/Any of
/// the following are true" pattern that admins expect from a predicate
/// editor.
public struct ManifestCriteriaGroup: Sendable, Hashable, Codable {
    public enum Quantifier: String, Sendable, Hashable, CaseIterable, Codable {
        case all, any
        public var label: String { self == .all ? "All" : "Any" }
    }

    public var quantifier: Quantifier
    public var criteria: [ManifestCriterion]

    public init(quantifier: Quantifier = .all, criteria: [ManifestCriterion] = []) {
        self.quantifier = quantifier
        self.criteria = criteria
    }

    /// Returns `true` when this group matches a manifest, taking the
    /// quantifier into account. An empty criteria list always matches
    /// (so the group reads as "no constraint").
    public func matches(_ record: ManifestRecordContext) -> Bool {
        guard !criteria.isEmpty else { return true }
        switch quantifier {
        case .all: return criteria.allSatisfy { $0.matches(record) }
        case .any: return criteria.contains { $0.matches(record) }
        }
    }
}

/// Closed set of manifest attributes the criteria builder can filter
/// on. Each case has a kind (`string` / `count` / `arrayMembership`)
/// which constrains the operators allowed for it.
public enum ManifestAttribute: String, Sendable, Hashable, CaseIterable, Identifiable, Codable {
    case name
    case filename
    case username
    case displayName
    case notes
    case managedInstallsCount
    case managedUninstallsCount
    case managedUpdatesCount
    case optionalInstallsCount
    case defaultInstallsCount
    case featuredItemsCount
    case includedManifestsCount
    case referencingManifestsCount
    case conditionsCount
    case anyInstallsItem
    case anyCatalog
    case anyManagedInstallsItem
    case anyManagedUninstallsItem
    case anyManagedUpdatesItem
    case anyOptionalInstallsItem
    case anyDefaultInstallsItem
    case anyFeaturedItem
    case anyIncludedManifest
    case anyReferencingManifest
    case anyConditionPredicateString

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .name: "Name"
        case .filename: "Filename"
        case .username: "Username"
        case .displayName: "Display name"
        case .notes: "Notes"
        case .managedInstallsCount: "Number of managed installs"
        case .managedUninstallsCount: "Number of managed uninstalls"
        case .managedUpdatesCount: "Number of managed updates"
        case .optionalInstallsCount: "Number of optional installs"
        case .defaultInstallsCount: "Number of default installs"
        case .featuredItemsCount: "Number of featured items"
        case .includedManifestsCount: "Number of included manifests"
        case .referencingManifestsCount: "Number of referencing manifests"
        case .conditionsCount: "Number of conditions"
        case .anyInstallsItem: "Any installs item"
        case .anyCatalog: "Any catalog"
        case .anyManagedInstallsItem: "Any managed installs item"
        case .anyManagedUninstallsItem: "Any managed uninstalls item"
        case .anyManagedUpdatesItem: "Any managed updates item"
        case .anyOptionalInstallsItem: "Any optional installs item"
        case .anyDefaultInstallsItem: "Any default installs item"
        case .anyFeaturedItem: "Any featured item"
        case .anyIncludedManifest: "Any included manifest"
        case .anyReferencingManifest: "Any referencing manifest"
        case .anyConditionPredicateString: "Any condition predicate string"
        }
    }

    public enum Kind: Sendable {
        case string
        case count
        case arrayMembership
    }

    public var kind: Kind {
        switch self {
        case .name, .filename, .username, .displayName, .notes:
            .string
        case .managedInstallsCount, .managedUninstallsCount, .managedUpdatesCount,
                .optionalInstallsCount, .defaultInstallsCount, .featuredItemsCount,
                .includedManifestsCount, .referencingManifestsCount, .conditionsCount:
            .count
        case .anyInstallsItem, .anyCatalog, .anyManagedInstallsItem,
                .anyManagedUninstallsItem, .anyManagedUpdatesItem,
                .anyOptionalInstallsItem, .anyDefaultInstallsItem, .anyFeaturedItem,
                .anyIncludedManifest, .anyReferencingManifest,
                .anyConditionPredicateString:
            .arrayMembership
        }
    }

    public var allowedOperators: [CriterionOperator] {
        switch kind {
        case .string: [.contains, .doesNotContain, .equals, .notEquals, .beginsWith, .endsWith, .matchesRegex]
        case .count: [.equalsNumber, .notEqualsNumber, .greaterThan, .lessThan, .greaterOrEqual, .lessOrEqual]
        case .arrayMembership: [.contains, .doesNotContain, .equals]
        }
    }
}

public enum CriterionOperator: String, Sendable, Hashable, CaseIterable, Identifiable, Codable {
    case contains
    case doesNotContain
    case equals
    case notEquals
    case beginsWith
    case endsWith
    case matchesRegex
    case equalsNumber
    case notEqualsNumber
    case greaterThan
    case lessThan
    case greaterOrEqual
    case lessOrEqual

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .contains: "contains"
        case .doesNotContain: "does not contain"
        case .equals: "equals"
        case .notEquals: "does not equal"
        case .beginsWith: "begins with"
        case .endsWith: "ends with"
        case .matchesRegex: "matches regex"
        case .equalsNumber: "="
        case .notEqualsNumber: "≠"
        case .greaterThan: ">"
        case .lessThan: "<"
        case .greaterOrEqual: "≥"
        case .lessOrEqual: "≤"
        }
    }
}

/// Pre-computed view of a manifest plus the cross-references the
/// criteria need (referenced-by counts, filename). Decoupled from
/// ``ManifestRecord`` so Core can evaluate criteria without depending
/// on file-system metadata.
public struct ManifestRecordContext: Sendable {
    public let manifest: Manifest
    public let filename: String
    public let referencingManifests: [String]

    public init(manifest: Manifest, filename: String, referencingManifests: [String]) {
        self.manifest = manifest
        self.filename = filename
        self.referencingManifests = referencingManifests
    }
}

public extension ManifestCriterion {
    func matches(_ ctx: ManifestRecordContext) -> Bool {
        switch attribute.kind {
        case .string:
            return matchString(stringValue(in: ctx))
        case .count:
            return matchCount(countValue(in: ctx))
        case .arrayMembership:
            return matchArray(arrayValue(in: ctx))
        }
    }

    private func stringValue(in ctx: ManifestRecordContext) -> String {
        switch attribute {
        case .name: ctx.manifest.manifestName
        case .filename: ctx.filename
        case .username: ctx.manifest.user ?? ""
        case .displayName: ctx.manifest.displayName ?? ""
        case .notes: ctx.manifest.notes ?? ""
        default: ""
        }
    }

    private func countValue(in ctx: ManifestRecordContext) -> Int {
        switch attribute {
        case .managedInstallsCount: ctx.manifest.managedInstalls?.count ?? 0
        case .managedUninstallsCount: ctx.manifest.managedUninstalls?.count ?? 0
        case .managedUpdatesCount: ctx.manifest.managedUpdates?.count ?? 0
        case .optionalInstallsCount: ctx.manifest.optionalInstalls?.count ?? 0
        case .defaultInstallsCount: ctx.manifest.defaultInstalls?.count ?? 0
        case .featuredItemsCount: ctx.manifest.featuredItems?.count ?? 0
        case .includedManifestsCount: ctx.manifest.includedManifests?.count ?? 0
        case .referencingManifestsCount: ctx.referencingManifests.count
        case .conditionsCount: ctx.manifest.conditionalItems?.count ?? 0
        default: 0
        }
    }

    private func arrayValue(in ctx: ManifestRecordContext) -> [String] {
        switch attribute {
        case .anyInstallsItem:
            var items: [String] = ctx.manifest.managedInstalls ?? []
            items += ctx.manifest.managedUninstalls ?? []
            items += ctx.manifest.managedUpdates ?? []
            items += ctx.manifest.optionalInstalls ?? []
            items += ctx.manifest.defaultInstalls ?? []
            items += ctx.manifest.featuredItems ?? []
            return items
        case .anyCatalog: return ctx.manifest.catalogs ?? []
        case .anyManagedInstallsItem: return ctx.manifest.managedInstalls ?? []
        case .anyManagedUninstallsItem: return ctx.manifest.managedUninstalls ?? []
        case .anyManagedUpdatesItem: return ctx.manifest.managedUpdates ?? []
        case .anyOptionalInstallsItem: return ctx.manifest.optionalInstalls ?? []
        case .anyDefaultInstallsItem: return ctx.manifest.defaultInstalls ?? []
        case .anyFeaturedItem: return ctx.manifest.featuredItems ?? []
        case .anyIncludedManifest: return ctx.manifest.includedManifests ?? []
        case .anyReferencingManifest: return ctx.referencingManifests
        case .anyConditionPredicateString:
            return (ctx.manifest.conditionalItems ?? []).map(\.condition)
        default: return []
        }
    }

    private func matchString(_ lhs: String) -> Bool {
        let l = lhs.lowercased()
        let r = value.lowercased()
        switch op {
        case .contains: return l.contains(r)
        case .doesNotContain: return !l.contains(r)
        case .equals: return l == r
        case .notEquals: return l != r
        case .beginsWith: return l.hasPrefix(r)
        case .endsWith: return l.hasSuffix(r)
        case .matchesRegex:
            guard let regex = try? NSRegularExpression(pattern: value, options: [.caseInsensitive]) else { return false }
            let range = NSRange(lhs.startIndex..., in: lhs)
            return regex.firstMatch(in: lhs, range: range) != nil
        default: return false
        }
    }

    private func matchCount(_ lhs: Int) -> Bool {
        guard let rhs = Int(value) else { return false }
        switch op {
        case .equalsNumber: return lhs == rhs
        case .notEqualsNumber: return lhs != rhs
        case .greaterThan: return lhs > rhs
        case .lessThan: return lhs < rhs
        case .greaterOrEqual: return lhs >= rhs
        case .lessOrEqual: return lhs <= rhs
        default: return false
        }
    }

    private func matchArray(_ items: [String]) -> Bool {
        let needle = value.lowercased()
        let lower = items.map { $0.lowercased() }
        switch op {
        case .contains: return lower.contains { $0.contains(needle) }
        case .doesNotContain: return !lower.contains { $0.contains(needle) }
        case .equals: return lower.contains(needle)
        default: return false
        }
    }
}
