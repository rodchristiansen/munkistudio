import Foundation

/// Serialize a ``PredicateModel`` back to an NSPredicate-compatible string
/// Munki can evaluate on the client. Output matches the canonical
/// `NSPredicate(format:)` syntax: bare keypaths on the left, quoted strings
/// on the right, modifiers in `[c]`/`[d]` brackets, parentheses around
/// compound children.
public enum PredicateSerializer {
    public static func serialize(_ model: PredicateModel) -> String {
        switch model {
        case .raw(let text):
            return text
        case .not(let inner):
            return "NOT (\(serialize(inner)))"
        case .compound(let compound):
            let joiner = " \(compound.kind.rawValue) "
            let parts = compound.children.map { "(\(serialize($0)))" }
            return parts.joined(separator: joiner)
        case .comparison(let comparison):
            return serialize(comparison)
        }
    }

    private static func serialize(_ comparison: PredicateModel.Comparison) -> String {
        var op = comparison.op.rawValue
        if !comparison.modifiers.isEmpty {
            let mods = comparison.modifiers.map(\.rawValue).joined()
            op += "[\(mods)]"
        }
        return "\(comparison.leftKey) \(op) \(format(comparison.rightValue))"
    }

    private static func format(_ value: PredicateModel.Value) -> String {
        switch value {
        case .string(let text):
            let escaped = text
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        case .number(let number):
            if number.rounded() == number && abs(number) < 1e15 {
                return String(format: "%.0f", number)
            }
            return String(number)
        case .bool(let flag):
            return flag ? "TRUE" : "FALSE"
        case .identifier(let text):
            return text
        case .list(let values):
            let inner = values.map(format).joined(separator: ", ")
            return "{ \(inner) }"
        }
    }
}
