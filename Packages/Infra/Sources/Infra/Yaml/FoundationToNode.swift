import Foundation
import Yams

/// Convert a Foundation-typed property-list graph (the kind
/// `PropertyListSerialization.propertyList(from:options:format:)` returns)
/// into a Yams `Node`, applying the Munki key-ordering and script
/// literal-block rules along the way.
///
/// We go through Foundation rather than emitting Node directly from the
/// Swift model so the encoder doesn't have to know about every CodingKey
/// in `Pkginfo` / `Manifest`. The Codable conformance keeps that mapping;
/// this file is only about emitting the resulting dictionary in Munki's
/// canonical YAML form.
public enum FoundationToNode {
    public static func node(
        from value: Any,
        context: KeyOrderingContext = .other,
        forceLiteralBlock: Bool = false
    ) throws -> Node {
        switch value {
        case let dict as [String: Any]:
            return try mappingNode(from: dict, context: context)
        case let array as [Any]:
            return try sequenceNode(from: array, context: context)
        case let string as String:
            return stringNode(string, forceLiteralBlock: forceLiteralBlock)
        case let date as Date:
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return Node.scalar(Node.Scalar(formatter.string(from: date), Tag(.timestamp)))
        case let data as Data:
            return Node.scalar(Node.Scalar(data.base64EncodedString(), Tag(.binary)))
        case let number as NSNumber:
            return numberNode(number)
        default:
            throw MunkiCodingError.unsupportedValue(String(describing: type(of: value)))
        }
    }

    // MARK: Mapping

    private static func mappingNode(
        from dict: [String: Any],
        context: KeyOrderingContext
    ) throws -> Node {
        let orderedKeys = orderKeys(dict.keys, in: context)
        let pairs: [(Node, Node)] = try orderedKeys.map { key in
            let value = dict[key]!
            let childContext = childContext(of: context, forKey: key)
            let forceLiteral = CanonicalKeyOrder.scriptKeys.contains(key)
            let valueNode = try node(from: value, context: childContext, forceLiteralBlock: forceLiteral)
            return (Node.scalar(Node.Scalar(key)), valueNode)
        }
        return Node.mapping(Node.Mapping(pairs))
    }

    private static func sequenceNode(
        from array: [Any],
        context: KeyOrderingContext
    ) throws -> Node {
        let nodes = try array.map { try node(from: $0, context: context) }
        return Node.sequence(Node.Sequence(nodes))
    }

    // MARK: Scalars

    private static func stringNode(_ string: String, forceLiteralBlock: Bool) -> Node {
        if forceLiteralBlock {
            return Node.scalar(Node.Scalar(string, .implicit, .literal))
        }
        // Force quoting for strings that look numeric so cross-tool readers
        // (or a future restoration of the float resolver) don't coerce them
        // into Double / Int and lose data.
        if looksNumeric(string) {
            return Node.scalar(Node.Scalar(string, .implicit, .singleQuoted))
        }
        return Node.scalar(Node.Scalar(string))
    }

    private static func numberNode(_ number: NSNumber) -> Node {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return Node.scalar(Node.Scalar(number.boolValue ? "true" : "false", Tag(.bool)))
        }
        let objcType = String(cString: number.objCType)
        // Per Apple's docs, integer NSNumbers encode their type as one of
        // c, i, s, l, q (signed) or C, I, S, L, Q (unsigned); floating
        // values use f or d.
        if objcType == "f" || objcType == "d" {
            return Node.scalar(Node.Scalar(number.stringValue, Tag(.float)))
        }
        return Node.scalar(Node.Scalar(number.stringValue, Tag(.int)))
    }

    // MARK: Context plumbing

    private static func orderKeys(_ keys: some Sequence<String>, in context: KeyOrderingContext) -> [String] {
        switch context {
        case .pkginfoRoot:
            CanonicalKeyOrder.order(keys, priority: CanonicalKeyOrder.pkginfoPriority, trailing: CanonicalKeyOrder.pkginfoTrailing)
        case .manifestRoot:
            CanonicalKeyOrder.order(keys, priority: CanonicalKeyOrder.manifestPriority, trailing: CanonicalKeyOrder.manifestTrailing)
        case .installsItem:
            CanonicalKeyOrder.order(keys, priority: CanonicalKeyOrder.installsItemPriority, trailing: [])
        case .receipt:
            CanonicalKeyOrder.order(keys, priority: CanonicalKeyOrder.receiptPriority, trailing: [])
        case .conditionalItem:
            CanonicalKeyOrder.order(keys, priority: CanonicalKeyOrder.conditionalItemPriority, trailing: [])
        case .itemToCopy:
            CanonicalKeyOrder.order(keys, priority: CanonicalKeyOrder.itemsToCopyPriority, trailing: [])
        case .other:
            CanonicalKeyOrder.order(keys, priority: [], trailing: [])
        }
    }

    private static func childContext(of parent: KeyOrderingContext, forKey key: String) -> KeyOrderingContext {
        switch (parent, key) {
        case (.pkginfoRoot, "installs"): .installsItem
        case (.pkginfoRoot, "receipts"): .receipt
        case (.pkginfoRoot, "items_to_copy"): .itemToCopy
        case (.pkginfoRoot, "conditional_items"): .conditionalItem
        case (.manifestRoot, "conditional_items"): .conditionalItem
        case (.conditionalItem, "conditional_items"): .conditionalItem
        default: .other
        }
    }

    // MARK: Helpers

    private static func looksNumeric(_ string: String) -> Bool {
        guard !string.isEmpty else { return false }
        // Plain decimals or version-like dotted numerics. Avoid matching
        // arbitrary strings that happen to contain digits.
        let pattern = #"^-?\d+(\.\d+)+$|^-?\d+\.\d+$|^-?\d+$"#
        return string.range(of: pattern, options: .regularExpression) != nil
    }
}

public enum MunkiCodingError: Error, Sendable, LocalizedError {
    case unsupportedValue(String)
    case malformedTopLevel
    case missingRequiredKey(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedValue(let kind):
            "YAML/plist coder can't represent value of type \(kind)."
        case .malformedTopLevel:
            "Expected a mapping at the top level."
        case .missingRequiredKey(let key):
            "Required key '\(key)' is missing."
        }
    }
}
