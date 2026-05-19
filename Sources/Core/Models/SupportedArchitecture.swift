import Foundation

/// Architectures Munki recognizes in `supported_architectures`. Like
/// ``InstallerType`` we keep an `unknown` case for forward compatibility.
public enum SupportedArchitecture: Sendable, Hashable, Codable {
    case arm64
    case x86_64
    case unknown(String)

    public var rawValue: String {
        switch self {
        case .arm64: return "arm64"
        case .x86_64: return "x86_64"
        case .unknown(let value): return value
        }
    }

    public init(rawValue: String) {
        switch rawValue {
        case "arm64": self = .arm64
        case "x86_64": self = .x86_64
        default: self = .unknown(rawValue)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
