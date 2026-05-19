import Foundation

/// A `blocking_applications[]` entry is just a string in Munki — usually an
/// app bundle identifier or app name — but we wrap it in a value type so the
/// UI can attach derived state (running? installed?) without polluting the
/// on-disk schema.
public struct BlockingApplication: Sendable, Hashable, Codable, RawRepresentable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
