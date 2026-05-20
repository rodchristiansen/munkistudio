import Foundation

/// Lightweight model of Apple's `.mobileconfig` payload schema as
/// curated by ninxsoft/LowProfile (MIT). Used by the validator to
/// surface schema-aware warnings — "this key is deprecated for the
/// X payload" or "this key isn't defined for X" — without forcing
/// the user to memorise the per-payload key catalog.
///
/// Loading lives in Infra (it shells through Yams to parse the
/// bundled `Payloads.yaml`); this type only describes the parsed
/// shape so Core can stay dependency-free and the model stays
/// equally available to Core tests.
public struct PayloadSchema: Sendable, Hashable {
    /// Map of `PayloadType` string → definition. The key matches
    /// what appears in `<key>PayloadType</key><string>…</string>`
    /// inside a profile (e.g. `com.apple.screensaver`).
    public var definitions: [String: PayloadDefinition]

    public init(definitions: [String: PayloadDefinition]) {
        self.definitions = definitions
    }

    /// Look up the schema entry for a `PayloadType`. Returns `nil`
    /// when the type isn't catalogued — common for vendor-specific
    /// or beta payloads. Callers should degrade gracefully (no
    /// warning) rather than treating an unknown type as an error.
    public func definition(for payloadType: String) -> PayloadDefinition? {
        definitions[payloadType]
    }

    public static let empty = PayloadSchema(definitions: [:])
}

/// One catalogued PayloadType. Captures just the fields the
/// validator currently uses; the upstream YAML carries lots more
/// (example XML, discussion text, per-platform availability) that
/// can be folded in later for a docs-on-hover surface.
public struct PayloadDefinition: Sendable, Hashable {
    public var name: String
    public var properties: [PayloadProperty]

    public init(name: String, properties: [PayloadProperty]) {
        self.name = name
        self.properties = properties
    }

    /// Index `properties` by name for O(1) lookup from the
    /// validator's hot loop. The upstream YAML occasionally lists
    /// the same property twice (different platforms / availability
    /// blocks) — keep the later definition so deprecation flags from
    /// the newest entry win, and never trap on collision.
    public var propertyIndex: [String: PayloadProperty] {
        Dictionary(properties.map { ($0.name, $0) }, uniquingKeysWith: { _, new in new })
    }
}

/// One catalogued property on a payload type. `deprecated` is the
/// only attribute the validator currently acts on, but the rest
/// are kept so future passes (form editor, autocomplete) can use
/// them without re-parsing the YAML.
public struct PayloadProperty: Sendable, Hashable {
    public var name: String
    /// `boolean` / `string` / `number` / `array` / `dictionary` /
    /// `data` / `date` etc. as labeled in `Payloads.yaml`.
    public var typeName: String?
    public var required: Bool
    public var deprecated: Bool

    public init(
        name: String,
        typeName: String? = nil,
        required: Bool = false,
        deprecated: Bool = false
    ) {
        self.name = name
        self.typeName = typeName
        self.required = required
        self.deprecated = deprecated
    }
}
