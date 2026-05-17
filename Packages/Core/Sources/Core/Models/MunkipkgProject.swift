import Foundation

/// The on-disk format of a munkipkg `build-info` file. munkipkg accepts
/// all three and `--convert`s between them.
public enum BuildInfoFormat: String, Sendable, Hashable, CaseIterable {
    case yaml, plist, json

    /// The `build-info.<ext>` filename for this format.
    public var fileName: String { "build-info.\(rawValue)" }

    public var label: String {
        switch self {
        case .yaml: "YAML"
        case .plist: "XML plist"
        case .json: "JSON"
        }
    }

    /// Resolve a format from a `build-info` file's extension.
    public init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "yaml", "yml": self = .yaml
        case "plist": self = .plist
        case "json": self = .json
        default: return nil
        }
    }
}

/// Typed view of a munkipkg `build-info` file. Mirrors the schema of the
/// Swift `munkipkg` fork — the common keys are first-class; rarer ones
/// (`compression`, `min-os-version`, …) are kept as pass-through so a
/// round-trip never drops them.
public struct BuildInfo: Sendable, Hashable, Codable {
    public var name: String
    public var identifier: String
    public var version: String
    public var installLocation: String
    public var ownership: String
    public var postinstallAction: String
    public var distributionStyle: Bool
    public var preserveXattr: Bool
    public var suppressBundleRelocation: Bool
    public var productID: String
    public var signingInfo: SigningInfo?
    public var notarizationInfo: NotarizationInfo?
    // Pass-through — preserved on save, not surfaced in the form.
    public var compression: String?
    public var minOSVersion: String?
    public var largePayload: Bool?
    public var installKbytes: Int?

    public struct SigningInfo: Sendable, Hashable, Codable {
        public var identity: String
        public var keychain: String
        public var additionalCertNames: [String]
        public var timestamp: Bool

        public init(
            identity: String = "",
            keychain: String = "",
            additionalCertNames: [String] = [],
            timestamp: Bool = true
        ) {
            self.identity = identity
            self.keychain = keychain
            self.additionalCertNames = additionalCertNames
            self.timestamp = timestamp
        }

        enum CodingKeys: String, CodingKey {
            case identity, keychain, timestamp
            case additionalCertNames = "additional_cert_names"
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            identity = try c.decodeIfPresent(String.self, forKey: .identity) ?? ""
            keychain = try c.decodeIfPresent(String.self, forKey: .keychain) ?? ""
            additionalCertNames = try c.decodeIfPresent([String].self, forKey: .additionalCertNames) ?? []
            timestamp = try c.decodeIfPresent(Bool.self, forKey: .timestamp) ?? true
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(identity, forKey: .identity)
            if !keychain.isEmpty { try c.encode(keychain, forKey: .keychain) }
            if !additionalCertNames.isEmpty { try c.encode(additionalCertNames, forKey: .additionalCertNames) }
            try c.encode(timestamp, forKey: .timestamp)
        }
    }

    public struct NotarizationInfo: Sendable, Hashable, Codable {
        public var keychainProfile: String
        public var appleID: String
        public var teamID: String
        // Pass-through — preserved on save, not surfaced in the form.
        public var password: String?
        public var ascProvider: String?
        public var stapleTimeout: Int?

        public init(
            keychainProfile: String = "",
            appleID: String = "",
            teamID: String = ""
        ) {
            self.keychainProfile = keychainProfile
            self.appleID = appleID
            self.teamID = teamID
        }

        enum CodingKeys: String, CodingKey {
            case keychainProfile = "keychain_profile"
            case appleID = "apple_id"
            case teamID = "team_id"
            case password
            case ascProvider = "asc_provider"
            case stapleTimeout = "staple_timeout"
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            keychainProfile = try c.decodeIfPresent(String.self, forKey: .keychainProfile) ?? ""
            appleID = try c.decodeIfPresent(String.self, forKey: .appleID) ?? ""
            teamID = try c.decodeIfPresent(String.self, forKey: .teamID) ?? ""
            password = try c.decodeIfPresent(String.self, forKey: .password)
            ascProvider = try c.decodeIfPresent(String.self, forKey: .ascProvider)
            stapleTimeout = try c.decodeIfPresent(Int.self, forKey: .stapleTimeout)
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            if !keychainProfile.isEmpty { try c.encode(keychainProfile, forKey: .keychainProfile) }
            if !appleID.isEmpty { try c.encode(appleID, forKey: .appleID) }
            if !teamID.isEmpty { try c.encode(teamID, forKey: .teamID) }
            try c.encodeIfPresent(password, forKey: .password)
            try c.encodeIfPresent(ascProvider, forKey: .ascProvider)
            try c.encodeIfPresent(stapleTimeout, forKey: .stapleTimeout)
        }
    }

    public init(
        name: String = "",
        identifier: String = "",
        version: String = "1.0",
        installLocation: String = "/",
        ownership: String = "recommended",
        postinstallAction: String = "none",
        distributionStyle: Bool = false,
        preserveXattr: Bool = false,
        suppressBundleRelocation: Bool = false,
        productID: String = "",
        signingInfo: SigningInfo? = nil,
        notarizationInfo: NotarizationInfo? = nil
    ) {
        self.name = name
        self.identifier = identifier
        self.version = version
        self.installLocation = installLocation
        self.ownership = ownership
        self.postinstallAction = postinstallAction
        self.distributionStyle = distributionStyle
        self.preserveXattr = preserveXattr
        self.suppressBundleRelocation = suppressBundleRelocation
        self.productID = productID
        self.signingInfo = signingInfo
        self.notarizationInfo = notarizationInfo
    }

    enum CodingKeys: String, CodingKey {
        case name, identifier, version, ownership, compression
        case installLocation = "install_location"
        case postinstallAction = "postinstall_action"
        case distributionStyle = "distribution_style"
        case preserveXattr = "preserve_xattr"
        case suppressBundleRelocation = "suppress_bundle_relocation"
        case productID = "product_id"
        case signingInfo = "signing_info"
        case notarizationInfo = "notarization_info"
        case minOSVersion = "min-os-version"
        case largePayload = "large-payload"
        case installKbytes = "install_kbytes"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        identifier = try c.decodeIfPresent(String.self, forKey: .identifier) ?? ""
        version = try Self.decodeLooseString(c, .version) ?? "1.0"
        installLocation = try c.decodeIfPresent(String.self, forKey: .installLocation) ?? "/"
        ownership = try c.decodeIfPresent(String.self, forKey: .ownership) ?? "recommended"
        postinstallAction = try c.decodeIfPresent(String.self, forKey: .postinstallAction) ?? "none"
        distributionStyle = try c.decodeIfPresent(Bool.self, forKey: .distributionStyle) ?? false
        preserveXattr = try c.decodeIfPresent(Bool.self, forKey: .preserveXattr) ?? false
        suppressBundleRelocation = try c.decodeIfPresent(Bool.self, forKey: .suppressBundleRelocation) ?? false
        productID = try c.decodeIfPresent(String.self, forKey: .productID) ?? ""
        signingInfo = try c.decodeIfPresent(SigningInfo.self, forKey: .signingInfo)
        notarizationInfo = try c.decodeIfPresent(NotarizationInfo.self, forKey: .notarizationInfo)
        compression = try c.decodeIfPresent(String.self, forKey: .compression)
        minOSVersion = try Self.decodeLooseString(c, .minOSVersion)
        largePayload = try c.decodeIfPresent(Bool.self, forKey: .largePayload)
        installKbytes = try c.decodeIfPresent(Int.self, forKey: .installKbytes)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(identifier, forKey: .identifier)
        try c.encode(version, forKey: .version)
        try c.encode(installLocation, forKey: .installLocation)
        try c.encode(ownership, forKey: .ownership)
        try c.encode(postinstallAction, forKey: .postinstallAction)
        try c.encode(distributionStyle, forKey: .distributionStyle)
        if preserveXattr { try c.encode(preserveXattr, forKey: .preserveXattr) }
        if suppressBundleRelocation { try c.encode(suppressBundleRelocation, forKey: .suppressBundleRelocation) }
        if !productID.isEmpty { try c.encode(productID, forKey: .productID) }
        try c.encodeIfPresent(signingInfo, forKey: .signingInfo)
        try c.encodeIfPresent(notarizationInfo, forKey: .notarizationInfo)
        try c.encodeIfPresent(compression, forKey: .compression)
        try c.encodeIfPresent(minOSVersion, forKey: .minOSVersion)
        try c.encodeIfPresent(largePayload, forKey: .largePayload)
        try c.encodeIfPresent(installKbytes, forKey: .installKbytes)
    }

    /// `version` is often a number in YAML/JSON (`26.3`) rather than a
    /// string — accept either.
    private static func decodeLooseString(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) throws -> String? {
        if let string = try? container.decodeIfPresent(String.self, forKey: key) {
            return string
        }
        if let double = try? container.decodeIfPresent(Double.self, forKey: key) {
            return double == double.rounded() ? String(Int(double)) : String(double)
        }
        if let int = try? container.decodeIfPresent(Int.self, forKey: key) {
            return String(int)
        }
        return nil
    }
}

/// A script slot inside a munkipkg project's `scripts/` directory.
public struct MunkipkgScript: Sendable, Hashable, Identifiable {
    public var name: String
    public var fileURL: URL

    public var id: String { fileURL.path }

    public init(name: String, fileURL: URL) {
        self.name = name
        self.fileURL = fileURL
    }
}

/// A munkipkg package-source project — a directory with a `build-info`
/// file, a `payload/` directory, and an optional `scripts/` directory.
public struct MunkipkgProject: Sendable, Hashable, Identifiable {
    public var directoryURL: URL
    public var buildInfo: BuildInfo
    public var buildInfoFormat: BuildInfoFormat
    public var scripts: [MunkipkgScript]
    public var hasPayload: Bool

    public var id: String { directoryURL.path }
    /// Project directory name — the natural display name.
    public var name: String { directoryURL.lastPathComponent }
    /// Where `munkipkg --build` writes the built package.
    public var buildDirectory: URL { directoryURL.appending(path: "build") }

    public init(
        directoryURL: URL,
        buildInfo: BuildInfo,
        buildInfoFormat: BuildInfoFormat,
        scripts: [MunkipkgScript],
        hasPayload: Bool
    ) {
        self.directoryURL = directoryURL
        self.buildInfo = buildInfo
        self.buildInfoFormat = buildInfoFormat
        self.scripts = scripts
        self.hasPayload = hasPayload
    }
}
