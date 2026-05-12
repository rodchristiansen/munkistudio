import Foundation
import Yams
import Core

/// YAML round-trip for `Manifest`. Mirrors ``PkginfoYamlCoder``. The
/// manifest name isn't stored in the file (it's the file's path stem) — the
/// caller supplies it via `nameUserInfoKey` when decoding.
public enum ManifestYamlCoder {
    public static func decode(from yaml: String, name: String) throws -> Manifest {
        guard let any = try Yams.load(yaml: yaml, MunkiYamlResolver.strict) else {
            throw MunkiCodingError.malformedTopLevel
        }
        guard let dict = any as? [String: Any] else {
            throw MunkiCodingError.malformedTopLevel
        }
        let data = try PropertyListSerialization.data(
            fromPropertyList: dict,
            format: .xml,
            options: 0
        )
        let decoder = PropertyListDecoder()
        decoder.userInfo[Manifest.nameUserInfoKey] = name
        return try decoder.decode(Manifest.self, from: data)
    }

    public static func encode(_ manifest: Manifest) throws -> String {
        let plistData = try PropertyListEncoder().encode(manifest)
        let any = try PropertyListSerialization.propertyList(from: plistData, format: nil)
        guard let dict = any as? [String: Any] else {
            throw MunkiCodingError.malformedTopLevel
        }
        let node = try FoundationToNode.node(from: dict, context: .manifestRoot)
        return try Yams.serialize(node: node, sortKeys: false)
    }
}
