import Foundation
import Yams
import Core

/// YAML round-trip for `Pkginfo`. We route through Foundation property-list
/// types on both sides so we don't have to reimplement key mapping that
/// Pkginfo's `Codable` already does. The interesting work is in
/// ``FoundationToNode`` (emit) and Yams' custom resolver (read).
public enum PkginfoYamlCoder {
    public static func decode(from yaml: String) throws -> Pkginfo {
        guard let any = try Yams.load(yaml: yaml, MunkiYamlResolver.strict) else {
            throw MunkiCodingError.malformedTopLevel
        }
        guard let dict = YamlSanitizer.sanitize(any) as? [String: Any] else {
            throw MunkiCodingError.malformedTopLevel
        }
        let data = try PropertyListSerialization.data(
            fromPropertyList: dict,
            format: .xml,
            options: 0
        )
        return try PropertyListDecoder().decode(Pkginfo.self, from: data)
    }

    public static func encode(_ pkginfo: Pkginfo) throws -> String {
        let plistData = try PropertyListEncoder().encode(pkginfo)
        let any = try PropertyListSerialization.propertyList(from: plistData, format: nil)
        guard let dict = any as? [String: Any] else {
            throw MunkiCodingError.malformedTopLevel
        }
        let node = try FoundationToNode.node(from: dict, context: .pkginfoRoot)
        // `allowUnicode: true` keeps non-ASCII characters as themselves
        // in the output (`Ω`, `é`, `日本語`) instead of escaping them
        // to `\uXXXX` sequences. Round-trip diffs on files that
        // legitimately contain unicode (e.g. manifest names with
        // greek-letter prefixes) were unreadable without this.
        return try Yams.serialize(node: node, allowUnicode: true, sortKeys: false)
    }
}
