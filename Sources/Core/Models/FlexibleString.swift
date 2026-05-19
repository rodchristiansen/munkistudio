import Foundation

/// Decoding helpers for keys that are conventionally strings in Munki
/// pkginfo / manifest files but get authored as bare numbers in many
/// real repos. `CFBundleVersion: 1234` and `version: 1` are common.
/// The model declares these fields as `String?` because that's how
/// Munki documents and uses them, but tolerant-read lets us keep
/// loading files that committed integers years ago.
public extension KeyedDecodingContainer {
    /// Decode a key that may be authored as a string, integer, or
    /// floating-point. Returns `nil` when the key is absent or its
    /// value is `null`.
    func decodeFlexibleStringIfPresent(forKey key: Key) throws -> String? {
        // `decodeNil` requires the key to exist — guard with
        // `contains` first or Codable throws `keyNotFound`.
        guard contains(key) else { return nil }
        if try decodeNil(forKey: key) { return nil }
        if let s = try? decode(String.self, forKey: key) { return s }
        if let i = try? decode(Int.self, forKey: key) { return String(i) }
        if let d = try? decode(Double.self, forKey: key) {
            // `1.0` round-trips as `1.0`, not `1` — preserves the
            // authored intent. Trailing zeros are kept by `%g`-style
            // formatting via `Double.description`.
            return String(d)
        }
        if let b = try? decode(Bool.self, forKey: key) { return b ? "true" : "false" }
        throw DecodingError.typeMismatch(
            String.self,
            DecodingError.Context(
                codingPath: codingPath + [key],
                debugDescription: "Expected String, Int, Double, or Bool for flexible-string key"
            )
        )
    }

    /// Decode an ISO-8601 timestamp key that may be present as either
    /// a `Date` (when YAML's `.timestamp` resolver runs) or a String
    /// (when the resolver is suppressed, which is our default). The
    /// String form is parsed with `ISO8601DateFormatter` covering the
    /// `withInternetDateTime` and `withFractionalSeconds` variants.
    func decodeFlexibleDateIfPresent(forKey key: Key) throws -> Date? {
        guard contains(key) else { return nil }
        if try decodeNil(forKey: key) { return nil }
        if let d = try? decode(Date.self, forKey: key) { return d }
        guard let raw = try? decode(String.self, forKey: key) else { return nil }
        let candidates: [ISO8601DateFormatter.Options] = [
            [.withInternetDateTime],
            [.withInternetDateTime, .withFractionalSeconds],
            [.withFullDate],
        ]
        for options in candidates {
            let f = ISO8601DateFormatter()
            f.formatOptions = options
            if let parsed = f.date(from: raw) { return parsed }
        }
        return nil
    }
}
