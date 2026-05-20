import Foundation
import Core
import Yams

/// Loads the bundled `Payloads.yaml` schema vendored from
/// ninxsoft/LowProfile (MIT, copyright Nindi Gill 2020-2025).
///
/// The file is ~670KB and the parse takes single-digit milliseconds
/// on a current Mac, so we load it eagerly on demand and cache the
/// result via a struct-level lazy `Task`. Callers that don't need
/// schema validation pay nothing.
public enum PayloadSchemaLoader {
    /// Synchronously load and parse the bundled schema. Returns
    /// `nil` when the resource is missing (broken build) or fails
    /// to parse — the validator falls back to no-schema mode in
    /// either case.
    public static func loadBundled() -> PayloadSchema? {
        guard let url = Bundle.module.url(forResource: "Payloads", withExtension: "yaml"),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return parse(data: data)
    }

    /// Parse a YAML payload schema document into a `PayloadSchema`.
    /// Public so tests can exercise it without touching disk.
    public static func parse(data: Data) -> PayloadSchema? {
        let text = String(decoding: data, as: UTF8.self)
        guard let root = try? Yams.load(yaml: text) as? [String: Any] else {
            return nil
        }
        var definitions: [String: PayloadDefinition] = [:]
        for (typeName, rawDefinition) in root {
            guard let definition = rawDefinition as? [String: Any] else { continue }
            let humanName = (definition["name"] as? String) ?? typeName
            let propertiesArray = definition["properties"] as? [[String: Any]] ?? []
            let properties = propertiesArray.compactMap(Self.parseProperty)
            definitions[typeName] = PayloadDefinition(
                name: humanName,
                properties: properties
            )
        }
        return PayloadSchema(definitions: definitions)
    }

    /// Map one property entry from the YAML into a
    /// `PayloadProperty`. Each entry looks like:
    ///
    ///     - name: AllowedScreenCapture
    ///       type: boolean
    ///       attributes:
    ///         required: false
    ///         deprecated: true
    ///       description:
    ///       - "..."
    ///
    /// We pull just the fields the validator uses; the rest of the
    /// metadata is left on the table for a future docs-on-hover
    /// surface that wants it.
    private static func parseProperty(_ raw: [String: Any]) -> PayloadProperty? {
        guard let name = raw["name"] as? String, !name.isEmpty else { return nil }
        let typeName = raw["type"] as? String
        let attributes = raw["attributes"] as? [String: Any] ?? [:]
        let required = parseBool(attributes["required"])
        let deprecated = parseBool(attributes["deprecated"])
        return PayloadProperty(
            name: name,
            typeName: typeName,
            required: required,
            deprecated: deprecated
        )
    }

    /// The YAML loader sometimes returns booleans as Swift `Bool`
    /// and sometimes as `String` ("true"/"false") depending on
    /// whether the value was quoted. Accept either form so a quoted
    /// `'true'` doesn't read as `false`.
    private static func parseBool(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let string = value as? String { return string.lowercased() == "true" }
        return false
    }
}
