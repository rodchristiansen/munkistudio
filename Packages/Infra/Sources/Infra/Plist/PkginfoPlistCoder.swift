import Foundation
import Core

/// Read / write Pkginfo as XML plist (the original Munki on-disk format).
/// Uses `PropertyListEncoder/Decoder` which respects Pkginfo's `CodingKeys`.
public enum PkginfoPlistCoder {
    public static func decode(from data: Data) throws -> Pkginfo {
        try PropertyListDecoder().decode(Pkginfo.self, from: data)
    }

    public static func encode(_ pkginfo: Pkginfo) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        return try encoder.encode(pkginfo)
    }
}
