import Foundation

/// Entry in `installs[]` — describes a single artifact on disk Munki uses to
/// detect whether the package is already installed. `path` is required; the
/// other keys vary by `type`.
public struct InstallsItem: Sendable, Hashable, Codable {
    public var type: String?
    public var path: String
    public var md5checksum: String?
    public var sha256checksum: String?

    public var cfBundleIdentifier: String?
    public var cfBundleName: String?
    public var cfBundleShortVersionString: String?
    public var cfBundleVersion: String?

    public var minosversion: String?
    public var versionComparisonKey: String?
    public var minimumUpdateVersion: String?

    public init(
        type: String? = nil,
        path: String,
        md5checksum: String? = nil,
        sha256checksum: String? = nil,
        cfBundleIdentifier: String? = nil,
        cfBundleName: String? = nil,
        cfBundleShortVersionString: String? = nil,
        cfBundleVersion: String? = nil,
        minosversion: String? = nil,
        versionComparisonKey: String? = nil,
        minimumUpdateVersion: String? = nil
    ) {
        self.type = type
        self.path = path
        self.md5checksum = md5checksum
        self.sha256checksum = sha256checksum
        self.cfBundleIdentifier = cfBundleIdentifier
        self.cfBundleName = cfBundleName
        self.cfBundleShortVersionString = cfBundleShortVersionString
        self.cfBundleVersion = cfBundleVersion
        self.minosversion = minosversion
        self.versionComparisonKey = versionComparisonKey
        self.minimumUpdateVersion = minimumUpdateVersion
    }

    enum CodingKeys: String, CodingKey {
        case type
        case path
        case md5checksum
        case sha256checksum
        case cfBundleIdentifier = "CFBundleIdentifier"
        case cfBundleName = "CFBundleName"
        case cfBundleShortVersionString = "CFBundleShortVersionString"
        case cfBundleVersion = "CFBundleVersion"
        case minosversion
        case versionComparisonKey = "version_comparison_key"
        case minimumUpdateVersion = "minimum_update_version"
    }

    /// Tolerant-read decoder: version-like keys are conventionally
    /// strings but countless real Munki repos commit them as bare
    /// integers (`CFBundleVersion: 1234`, `minosversion: 12`). We
    /// accept both forms — see `decodeFlexibleStringIfPresent` for the
    /// coercion rules.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try c.decodeFlexibleStringIfPresent(forKey: .type)
        self.path = try c.decode(String.self, forKey: .path)
        self.md5checksum = try c.decodeIfPresent(String.self, forKey: .md5checksum)
        self.sha256checksum = try c.decodeIfPresent(String.self, forKey: .sha256checksum)
        self.cfBundleIdentifier = try c.decodeFlexibleStringIfPresent(forKey: .cfBundleIdentifier)
        self.cfBundleName = try c.decodeFlexibleStringIfPresent(forKey: .cfBundleName)
        self.cfBundleShortVersionString = try c.decodeFlexibleStringIfPresent(forKey: .cfBundleShortVersionString)
        self.cfBundleVersion = try c.decodeFlexibleStringIfPresent(forKey: .cfBundleVersion)
        self.minosversion = try c.decodeFlexibleStringIfPresent(forKey: .minosversion)
        self.versionComparisonKey = try c.decodeFlexibleStringIfPresent(forKey: .versionComparisonKey)
        self.minimumUpdateVersion = try c.decodeFlexibleStringIfPresent(forKey: .minimumUpdateVersion)
    }
}
