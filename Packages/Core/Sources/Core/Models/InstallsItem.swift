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
        versionComparisonKey: String? = nil
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
    }
}
