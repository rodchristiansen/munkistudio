import Foundation
import Yams

/// Convert a Foundation-typed property-list graph (the kind
/// `PropertyListSerialization.propertyList(from:options:format:)` returns)
/// into a Yams `Node`, applying the Munki key-ordering and scalar-style
/// rules from ``MunkiYamlRules``.
///
/// We go through Foundation rather than emitting Node directly from the
/// Swift model so the encoder doesn't have to know about every CodingKey
/// in `Pkginfo` / `Manifest`. The Codable conformance keeps that mapping;
/// this file is only about emitting the resulting dictionary in Munki's
/// canonical YAML form.
///
/// Detection is content-based (per dict shape) to match yamlutils.swift's
/// `toNode` — no caller-supplied context. See ``MunkiYamlRules/sortKeysForDict(_:)``.
public enum FoundationToNode {
    /// Emit a Yams `Node` for the given Foundation graph.
    public static func node(from value: Any) throws -> Node {
        try toNode(value, forKey: nil)
    }

    /// Recursive emitter. `forKey` is the parent dict key — used by
    /// ``MunkiYamlRules/scalarStyle(forKey:value:)`` to pick a block style for
    /// script/prose fields. Array elements pass `nil`.
    private static func toNode(_ value: Any, forKey key: String?) throws -> Node {
        switch value {
        case is NSNull:
            return Node("")
        case let string as String:
            return stringNode(string, forKey: key)
        case let dict as [String: Any]:
            return try mappingNode(from: dict)
        case let array as [Any]:
            return try sequenceNode(from: array)
        case let date as Date:
            // Plain ISO-8601 string. Our resolver drops `.timestamp`, so this
            // round-trips back as a String — keeps git diffs clean against
            // hand-authored quoted dates.
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return Node(formatter.string(from: date))
        case let data as Data:
            return Node(data.base64EncodedString(), Tag(.binary))
        case let number as NSNumber:
            return numberNode(number)
        default:
            throw MunkiCodingError.unsupportedValue(String(describing: type(of: value)))
        }
    }

    // MARK: Mapping

    private static func mappingNode(from dict: [String: Any]) throws -> Node {
        let sortedKeys = MunkiYamlRules.sortKeysForDict(dict)
        var pairs: [(Node, Node)] = []
        pairs.reserveCapacity(sortedKeys.count)
        for key in sortedKeys {
            guard let value = dict[key] else { continue }
            pairs.append((Node(key), try toNode(value, forKey: key)))
        }
        return Node(pairs, .implicit, .block)
    }

    // MARK: Sequence

    private static func sequenceNode(from array: [Any]) throws -> Node {
        // Array elements don't carry a key context — they're indexed.
        let nodes = try array.map { try toNode($0, forKey: nil) }
        return Node(nodes, .implicit, .block)
    }

    // MARK: Scalars

    private static func stringNode(_ string: String, forKey key: String?) -> Node {
        // Empty strings must be emitted explicitly as quoted scalars so they
        // survive a write+read round-trip. An unquoted empty scalar resolves
        // to null under Yams' core resolver, which would either drop the key
        // entirely or fail a downstream non-optional decode. Matches
        // yamlutils.swift's `Node("", Tag(.str), .singleQuoted)`.
        if string.isEmpty {
            return Node("", Tag(.str), .singleQuoted)
        }
        let style = MunkiYamlRules.scalarStyle(forKey: key ?? "", value: string)
        return Node(string, .implicit, style)
    }

    private static func numberNode(_ number: NSNumber) -> Node {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return Node(number.boolValue ? "true" : "false", Tag(.bool))
        }
        // yamlutils.swift emits ints and doubles as plain untagged scalars.
        // For ints we keep the `.int` tag so size-like keys round-trip as
        // numeric (`installer_item_size: 1024`). For doubles we emit
        // untagged — combined with our resolver's `.float` removal, that
        // makes `26.2` re-read as a String, which is what we want for
        // version-like values that survive a round-trip.
        let objcType = String(cString: number.objCType)
        if objcType == "f" || objcType == "d" {
            return Node(number.stringValue)
        }
        return Node(number.stringValue, Tag(.int))
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
