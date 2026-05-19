import Foundation

/// A single row in a pkginfo smart-filter — `attribute` `op` `value`.
/// Mirrors ``ManifestCriterion`` but typed over the pkginfo schema.
public struct PackageCriterion: Sendable, Hashable, Identifiable, Codable {
    public var id: UUID
    public var attribute: PackageAttribute
    public var op: CriterionOperator
    public var value: String

    public init(
        id: UUID = UUID(),
        attribute: PackageAttribute,
        op: CriterionOperator,
        value: String = ""
    ) {
        self.id = id
        self.attribute = attribute
        self.op = op
        self.value = value
    }
}

public struct PackageCriteriaGroup: Sendable, Hashable, Codable {
    public typealias Quantifier = ManifestCriteriaGroup.Quantifier

    public var quantifier: Quantifier
    public var criteria: [PackageCriterion]

    public init(quantifier: Quantifier = .all, criteria: [PackageCriterion] = []) {
        self.quantifier = quantifier
        self.criteria = criteria
    }

    public func matches(_ ctx: PackageRecordContext) -> Bool {
        guard !criteria.isEmpty else { return true }
        switch quantifier {
        case .all: return criteria.allSatisfy { $0.matches(ctx) }
        case .any: return criteria.contains { $0.matches(ctx) }
        }
    }
}

public enum PackageAttribute: String, Sendable, Hashable, CaseIterable, Identifiable, Codable {
    case name
    case displayName
    case description
    case category
    case developer
    case version
    case notes
    case installerType
    case minimumOSVersion
    case catalogsCount
    case requiresCount
    case updateForCount
    case anyCatalog
    case anyRequires
    case anyUpdateFor
    case anySupportedArchitecture

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .name: "Name"
        case .displayName: "Display name"
        case .description: "Description"
        case .category: "Category"
        case .developer: "Developer"
        case .version: "Version"
        case .notes: "Notes"
        case .installerType: "Installer type"
        case .minimumOSVersion: "Minimum OS version"
        case .catalogsCount: "Number of catalogs"
        case .requiresCount: "Number of requires"
        case .updateForCount: "Number of update-for"
        case .anyCatalog: "Any catalog"
        case .anyRequires: "Any requires item"
        case .anyUpdateFor: "Any update-for item"
        case .anySupportedArchitecture: "Any supported architecture"
        }
    }

    public enum Kind: Sendable { case string, count, arrayMembership }

    public var kind: Kind {
        switch self {
        case .name, .displayName, .description, .category, .developer,
                .version, .notes, .installerType, .minimumOSVersion:
            .string
        case .catalogsCount, .requiresCount, .updateForCount:
            .count
        case .anyCatalog, .anyRequires, .anyUpdateFor, .anySupportedArchitecture:
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

public struct PackageRecordContext: Sendable {
    public let pkginfo: Pkginfo
    public let filename: String

    public init(pkginfo: Pkginfo, filename: String) {
        self.pkginfo = pkginfo
        self.filename = filename
    }
}

public extension PackageCriterion {
    func matches(_ ctx: PackageRecordContext) -> Bool {
        switch attribute.kind {
        case .string: matchString(stringValue(in: ctx))
        case .count: matchCount(countValue(in: ctx))
        case .arrayMembership: matchArray(arrayValue(in: ctx))
        }
    }

    private func stringValue(in ctx: PackageRecordContext) -> String {
        switch attribute {
        case .name: ctx.pkginfo.name
        case .displayName: ctx.pkginfo.displayName ?? ""
        case .description: ctx.pkginfo.description ?? ""
        case .category: ctx.pkginfo.category ?? ""
        case .developer: ctx.pkginfo.developer ?? ""
        case .version: ctx.pkginfo.version ?? ""
        case .notes: ctx.pkginfo.notes ?? ""
        case .installerType: ctx.pkginfo.installerType?.rawValue ?? ""
        case .minimumOSVersion: ctx.pkginfo.minimumOSVersion ?? ""
        default: ""
        }
    }

    private func countValue(in ctx: PackageRecordContext) -> Int {
        switch attribute {
        case .catalogsCount: ctx.pkginfo.catalogs?.count ?? 0
        case .requiresCount: ctx.pkginfo.requires?.count ?? 0
        case .updateForCount: ctx.pkginfo.updateFor?.count ?? 0
        default: 0
        }
    }

    private func arrayValue(in ctx: PackageRecordContext) -> [String] {
        switch attribute {
        case .anyCatalog: ctx.pkginfo.catalogs ?? []
        case .anyRequires: ctx.pkginfo.requires ?? []
        case .anyUpdateFor: ctx.pkginfo.updateFor ?? []
        case .anySupportedArchitecture: (ctx.pkginfo.supportedArchitectures ?? []).map(\.rawValue)
        default: []
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
