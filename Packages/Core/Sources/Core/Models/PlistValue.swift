import Foundation

/// A type-erased value matching the set of scalars that can appear in an
/// Apple plist (or, equivalently, the YAML node types Munki uses). We need
/// this for two reasons:
///
/// 1. `_metadata` is an open dictionary maintained by tools (MunkiAdmin,
///    AutoPkg, etc.) — we don't want to model every key those tools invent.
/// 2. Unknown / third-party pkginfo keys should round-trip without loss.
///
/// `PlistValue` is `Sendable` and value-typed so it composes with the rest
/// of Core's data model.
public indirect enum PlistValue: Sendable, Hashable {
    case string(String)
    case integer(Int)
    case double(Double)
    case bool(Bool)
    case date(Date)
    case data(Data)
    case array([PlistValue])
    case dictionary([String: PlistValue])
}

extension PlistValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            // Plists don't have a null type; represent it as an empty string.
            self = .string("")
            return
        }
        if let value = try? container.decode(Bool.self) {
            self = .bool(value); return
        }
        if let value = try? container.decode(Int.self) {
            self = .integer(value); return
        }
        if let value = try? container.decode(Double.self) {
            self = .double(value); return
        }
        if let value = try? container.decode(Data.self) {
            self = .data(value); return
        }
        if let value = try? container.decode(Date.self) {
            self = .date(value); return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value); return
        }
        if let value = try? container.decode([PlistValue].self) {
            self = .array(value); return
        }
        if let value = try? container.decode([String: PlistValue].self) {
            self = .dictionary(value); return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Unsupported PlistValue payload"
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .date(let value): try container.encode(value)
        case .data(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .dictionary(let value): try container.encode(value)
        }
    }
}

/// A `CodingKey` whose `stringValue` is whatever you give it. Used to read /
/// write arbitrary keys when capturing unknown pkginfo entries.
struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        nil
    }
}
