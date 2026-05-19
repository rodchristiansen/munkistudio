import Foundation
import Core

/// Read / write Pkginfo as XML plist (the original Munki on-disk format).
///
/// Decode uses `PropertyListDecoder` so Pkginfo's `CodingKeys` and tolerant
/// FlexibleString decoding stay in effect.
///
/// Encode routes through ``MunkiPlistRules/serialize(_:)`` — the same call
/// `plistutils.swift` uses on the CLI side. Going through Foundation
/// types between encode and serialize guarantees our XML bytes match
/// Munki's exactly (alphabetical key sort, tab indentation, `<true/>`
/// booleans), regardless of any future change in `PropertyListEncoder`'s
/// internal output formatter.
public enum PkginfoPlistCoder {
    public static func decode(from data: Data) throws -> Pkginfo {
        try PropertyListDecoder().decode(Pkginfo.self, from: data)
    }

    public static func encode(_ pkginfo: Pkginfo) throws -> Data {
        let codableData = try PropertyListEncoder().encode(pkginfo)
        let any = try PropertyListSerialization.propertyList(from: codableData, format: nil)
        guard let dict = any as? [String: Any] else {
            throw MunkiCodingError.malformedTopLevel
        }
        return try MunkiPlistRules.serialize(dict)
    }
}
