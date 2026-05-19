import Foundation
import Core

/// Read / write Manifest as XML plist. The manifest's name comes from the
/// file path, not the file contents, so callers pass it via `name:` here
/// and we inject it through the decoder's `userInfo`.
///
/// Encode routes through ``MunkiPlistRules/serialize(_:)`` for byte-for-byte
/// parity with the Munki CLI. See ``PkginfoPlistCoder`` for the rationale.
public enum ManifestPlistCoder {
    public static func decode(from data: Data, name: String) throws -> Manifest {
        let decoder = PropertyListDecoder()
        decoder.userInfo[Manifest.nameUserInfoKey] = name
        return try decoder.decode(Manifest.self, from: data)
    }

    public static func encode(_ manifest: Manifest) throws -> Data {
        let codableData = try PropertyListEncoder().encode(manifest)
        let any = try PropertyListSerialization.propertyList(from: codableData, format: nil)
        guard let dict = any as? [String: Any] else {
            throw MunkiCodingError.malformedTopLevel
        }
        return try MunkiPlistRules.serialize(dict)
    }
}
