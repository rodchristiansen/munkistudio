import Foundation

/// A single manifest file. A manifest is a plist or YAML document under
/// `manifests/` that names lists of pkginfo items a client should install,
/// uninstall, or be offered. Manifests may include other manifests, and may
/// gate items behind ``ConditionalItem`` predicates evaluated on the client.
public struct Manifest: Sendable, Hashable, Codable, Identifiable {
    /// Manifest filename (relative to `manifests/` root). Acts as the
    /// identifier — Munki references manifests by name.
    public var manifestName: String

    public var catalogs: [String]?
    public var includedManifests: [String]?

    public var managedInstalls: [String]?
    public var managedUninstalls: [String]?
    public var managedUpdates: [String]?
    public var optionalInstalls: [String]?
    public var featuredItems: [String]?
    /// Names of `optional_installs` items that should be pre-checked
    /// in Managed Software Center on first run. Munki 6.1+ feature.
    public var defaultInstalls: [String]?

    public var conditionalItems: [ConditionalItem]?

    public var displayName: String?
    public var user: String?
    public var notes: String?
    public var defaultInstallerChoicesXML: [String: PlistValue]?

    public var metadata: [String: PlistValue]?
    public var unknownKeys: [String: PlistValue]?

    public var id: String { manifestName }

    public init(manifestName: String) {
        self.manifestName = manifestName
    }

    /// Returns a human-readable reason `name` is unfit for a manifest
    /// filename, or `nil` when it is valid. Slashes are allowed — they
    /// nest the file under `manifests/` — but path traversal (`..`),
    /// absolute paths and empty segments are rejected so a name can't
    /// escape the `manifests/` directory.
    public static func nameRejectionReason(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Enter a name." }
        if trimmed.hasPrefix("/") { return "A name can't start with a slash." }
        if trimmed.hasPrefix("~") { return "A name can't start with \u{201c}~\u{201d}." }
        let segments = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for segment in segments {
            if segment.isEmpty { return "A name can't contain an empty path segment." }
            if segment == "." || segment == ".." {
                return "A name can't contain \u{201c}.\u{201d} or \u{201c}..\u{201d} segments."
            }
        }
        return nil
    }

    private enum FixedKey: String, CodingKey {
        case catalogs
        case includedManifests = "included_manifests"
        case managedInstalls = "managed_installs"
        case managedUninstalls = "managed_uninstalls"
        case managedUpdates = "managed_updates"
        case optionalInstalls = "optional_installs"
        case featuredItems = "featured_items"
        case defaultInstalls = "default_installs"
        case conditionalItems = "conditional_items"
        case displayName = "display_name"
        case user
        case notes
        case defaultInstallerChoicesXML = "default_installer_choices_xml"
        case metadata = "_metadata"
    }

    /// Manifests don't carry their own name on disk (it's derived from the
    /// filename). Decoding only populates the body keys.
    public init(from decoder: any Decoder) throws {
        self.manifestName = (decoder.userInfo[Manifest.nameUserInfoKey] as? String) ?? ""
        let container = try decoder.container(keyedBy: FixedKey.self)
        self.catalogs = try container.decodeIfPresent([String].self, forKey: .catalogs)
        self.includedManifests = try container.decodeIfPresent([String].self, forKey: .includedManifests)
        self.managedInstalls = try container.decodeIfPresent([String].self, forKey: .managedInstalls)
        self.managedUninstalls = try container.decodeIfPresent([String].self, forKey: .managedUninstalls)
        self.managedUpdates = try container.decodeIfPresent([String].self, forKey: .managedUpdates)
        self.optionalInstalls = try container.decodeIfPresent([String].self, forKey: .optionalInstalls)
        self.featuredItems = try container.decodeIfPresent([String].self, forKey: .featuredItems)
        self.defaultInstalls = try container.decodeIfPresent([String].self, forKey: .defaultInstalls)
        self.conditionalItems = try container.decodeIfPresent([ConditionalItem].self, forKey: .conditionalItems)
        self.displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        self.user = try container.decodeIfPresent(String.self, forKey: .user)
        self.notes = try container.decodeIfPresent(String.self, forKey: .notes)
        self.defaultInstallerChoicesXML = try container.decodeIfPresent(
            [String: PlistValue].self,
            forKey: .defaultInstallerChoicesXML
        )
        self.metadata = try container.decodeIfPresent([String: PlistValue].self, forKey: .metadata)

        let dynamic = try decoder.container(keyedBy: DynamicKey.self)
        let known: Set<String> = [
            "catalogs", "included_manifests", "managed_installs",
            "managed_uninstalls", "managed_updates", "optional_installs",
            "featured_items", "default_installs", "conditional_items",
            "display_name", "user", "notes",
            "default_installer_choices_xml", "_metadata",
        ]
        var leftovers: [String: PlistValue] = [:]
        for key in dynamic.allKeys where !known.contains(key.stringValue) {
            leftovers[key.stringValue] = try dynamic.decode(PlistValue.self, forKey: key)
        }
        self.unknownKeys = leftovers.isEmpty ? nil : leftovers
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: FixedKey.self)
        try container.encodeIfPresent(catalogs, forKey: .catalogs)
        try container.encodeIfPresent(includedManifests, forKey: .includedManifests)
        try container.encodeIfPresent(managedInstalls, forKey: .managedInstalls)
        try container.encodeIfPresent(managedUninstalls, forKey: .managedUninstalls)
        try container.encodeIfPresent(managedUpdates, forKey: .managedUpdates)
        try container.encodeIfPresent(optionalInstalls, forKey: .optionalInstalls)
        try container.encodeIfPresent(featuredItems, forKey: .featuredItems)
        try container.encodeIfPresent(defaultInstalls, forKey: .defaultInstalls)
        try container.encodeIfPresent(conditionalItems, forKey: .conditionalItems)
        try container.encodeIfPresent(displayName, forKey: .displayName)
        try container.encodeIfPresent(user, forKey: .user)
        try container.encodeIfPresent(notes, forKey: .notes)
        try container.encodeIfPresent(defaultInstallerChoicesXML, forKey: .defaultInstallerChoicesXML)
        try container.encodeIfPresent(metadata, forKey: .metadata)

        if let unknownKeys, !unknownKeys.isEmpty {
            var dynamic = encoder.container(keyedBy: DynamicKey.self)
            for (key, value) in unknownKeys {
                try dynamic.encode(value, forKey: DynamicKey(stringValue: key))
            }
        }
    }

    /// Coders set this on `Decoder.userInfo` so the manifest knows its
    /// filename-derived name. Filled in by the Infra-layer repository
    /// importer; tests can stub it.
    public static let nameUserInfoKey = CodingUserInfoKey(rawValue: "manifest.name")!
}
