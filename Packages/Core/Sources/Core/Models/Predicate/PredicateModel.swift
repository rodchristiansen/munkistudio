import Foundation

/// A structured representation of a Munki `installable_condition` or
/// manifest `condition` — both of which are NSPredicate expression strings
/// evaluated on the client. We keep the canonical form as the source string;
/// ``PredicateModel`` is a UI-friendly projection the editor can render with
/// fields and choosers.
///
/// We deliberately don't aim for round-tripping every possible NSPredicate
/// shape. The editor surfaces what we can parse; anything else falls back to
/// the "raw expression" escape hatch and is preserved verbatim on save.
public indirect enum PredicateModel: Sendable, Hashable {
    /// `key OP value` where `OP` is one of `==`, `!=`, `<`, `<=`, `>`, `>=`,
    /// `BEGINSWITH`, `CONTAINS`, `ENDSWITH`, `LIKE`, `MATCHES`, `IN`.
    case comparison(Comparison)

    /// Compound `AND` / `OR` of children.
    case compound(Compound)

    /// `NOT child`.
    case not(PredicateModel)

    /// We couldn't recognize the shape; preserve the source.
    case raw(String)

    public struct Comparison: Sendable, Hashable {
        public var leftKey: String
        public var op: Operator
        public var rightValue: Value
        public var modifiers: [Modifier]

        public init(
            leftKey: String,
            op: Operator,
            rightValue: Value,
            modifiers: [Modifier] = []
        ) {
            self.leftKey = leftKey
            self.op = op
            self.rightValue = rightValue
            self.modifiers = modifiers
        }
    }

    public struct Compound: Sendable, Hashable {
        public var kind: Kind
        public var children: [PredicateModel]

        public enum Kind: String, Sendable, Hashable, CaseIterable {
            case and = "AND"
            case or = "OR"
        }

        public init(kind: Kind, children: [PredicateModel]) {
            self.kind = kind
            self.children = children
        }
    }

    public enum Operator: String, Sendable, Hashable, CaseIterable {
        case equal = "=="
        case notEqual = "!="
        case lessThan = "<"
        case lessThanOrEqual = "<="
        case greaterThan = ">"
        case greaterThanOrEqual = ">="
        case beginsWith = "BEGINSWITH"
        case contains = "CONTAINS"
        case endsWith = "ENDSWITH"
        case like = "LIKE"
        case matches = "MATCHES"
        case `in` = "IN"
    }

    /// Modifiers on a comparison operator — `[c]` (case-insensitive),
    /// `[d]` (diacritic-insensitive). NSPredicate uses bracketed letters.
    public enum Modifier: String, Sendable, Hashable, CaseIterable {
        case caseInsensitive = "c"
        case diacriticInsensitive = "d"
    }

    /// The right-hand side of a comparison. NSPredicate is loose with types,
    /// so we surface the textual form for the UI and let writers decide
    /// quoting / unquoting.
    public enum Value: Sendable, Hashable {
        case string(String)
        case number(Double)
        case bool(Bool)
        case list([Value])
        case identifier(String)
    }
}
