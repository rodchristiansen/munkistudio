import Foundation

/// Parsed representation of a `promoter.yml` configuration file — the
/// rules the AutoPkg promoter uses to move pkginfo records between
/// catalogs as items age.
///
/// One rule per promotion path (e.g. "testing to staging"). The path
/// name is human-prose and used only as a label; the actual catalog
/// movement is defined by `promoteFrom` → `promoteTo`.
public struct PromoterConfig: Sendable, Hashable {
    public var rules: [PromotionRule]

    /// Top-level `default_days_in_catalog`, used by any promotion that
    /// doesn't set its own `days_in_catalog`.
    public var defaultDaysInCatalog: Int?

    /// Top-level `selection` block, gating which items are eligible for
    /// promotion at all.
    public var selection: SelectionRule?

    public init(
        rules: [PromotionRule],
        defaultDaysInCatalog: Int? = nil,
        selection: SelectionRule? = nil
    ) {
        self.rules = rules
        self.defaultDaysInCatalog = defaultDaysInCatalog
        self.selection = selection
    }

    /// Whether `name` is eligible for promotion under the `selection`
    /// block.
    ///
    /// Mirrors munki-promoter's `check_selection`, including its edge
    /// cases: an inclusion list that is missing or malformed admits
    /// *nothing*, while a malformed exclusion list admits *everything*.
    /// Matching is exact — the promoter does no globbing here, unlike
    /// `custom_items`.
    public func includes(_ name: String) -> Bool {
        guard let selection else { return true }
        switch selection.type {
        case .inclusion: return selection.items.contains(name)
        case .exclusion: return !selection.items.contains(name)
        case .all: return true
        }
    }

    /// The `selection` block: an allow-list, a deny-list, or everything.
    public struct SelectionRule: Sendable, Hashable {
        public enum Kind: String, Sendable, Hashable, CaseIterable {
            case inclusion, exclusion, all
        }

        public var type: Kind
        public var items: [String]

        public init(type: Kind, items: [String]) {
            self.type = type
            self.items = items
        }
    }

    /// Look up the per-item override for a package name, if any. The
    /// match is a simple glob: trailing `*` means prefix-match, otherwise
    /// exact-match on `name`.
    public func ruleOverride(for name: String, in rule: PromotionRule) -> PromotionRule.ItemOverride? {
        for (pattern, override) in rule.customItems {
            if pattern.hasSuffix("*") {
                let prefix = String(pattern.dropLast())
                if name.hasPrefix(prefix) { return override }
            } else if name == pattern {
                return override
            }
        }
        return nil
    }

    /// Find the first rule whose `promoteFrom` matches the pkginfo's
    /// current catalogs (set equality) — that's the rule that would
    /// promote it next. Returns `nil` if no rule applies.
    public func nextRule(forCatalogs catalogs: [String]) -> PromotionRule? {
        let normalized = Set(catalogs)
        return rules.first { Set($0.promoteFrom) == normalized }
    }
}

/// One promotion path: a set of source catalogs, a set of destination
/// catalogs, an aging window, and optional per-item overrides.
public struct PromotionRule: Sendable, Hashable, Identifiable {
    public var name: String
    public var promoteFrom: [String]
    public var promoteTo: [String]
    public var daysInCatalog: Int
    public var customItems: [String: ItemOverride]

    public var id: String { name }

    public init(
        name: String,
        promoteFrom: [String],
        promoteTo: [String],
        daysInCatalog: Int,
        customItems: [String: ItemOverride] = [:]
    ) {
        self.name = name
        self.promoteFrom = promoteFrom
        self.promoteTo = promoteTo
        self.daysInCatalog = daysInCatalog
        self.customItems = customItems
    }

    /// Per-item override for the aging window. Keyed by name pattern in
    /// the parent rule's `customItems`.
    public struct ItemOverride: Sendable, Hashable {
        public var daysInCatalog: Int

        public init(daysInCatalog: Int) {
            self.daysInCatalog = daysInCatalog
        }
    }

    /// Effective aging window for a given package name, honouring any
    /// per-item override.
    public func daysInCatalog(for name: String) -> Int {
        for (pattern, override) in customItems {
            if pattern.hasSuffix("*") {
                let prefix = String(pattern.dropLast())
                if name.hasPrefix(prefix) { return override.daysInCatalog }
            } else if name == pattern {
                return override.daysInCatalog
            }
        }
        return daysInCatalog
    }
}
