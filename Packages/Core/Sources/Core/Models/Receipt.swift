import Foundation

/// Entry in `receipts[]` — used by Munki to detect installation when
/// `installs[]` isn't present and the installer is a `.pkg`.
public struct Receipt: Sendable, Hashable, Codable {
    public var packageid: String?
    public var version: String?
    public var installedSize: Int?

    public var optional: Bool?
    public var noUnattendedUninstall: Bool?

    public init(
        packageid: String? = nil,
        version: String? = nil,
        installedSize: Int? = nil,
        optional: Bool? = nil,
        noUnattendedUninstall: Bool? = nil
    ) {
        self.packageid = packageid
        self.version = version
        self.installedSize = installedSize
        self.optional = optional
        self.noUnattendedUninstall = noUnattendedUninstall
    }

    enum CodingKeys: String, CodingKey {
        case packageid
        case version
        case installedSize = "installed_size"
        case optional
        case noUnattendedUninstall = "no_unattended_uninstall"
    }

    /// Tolerant-read: `packageid` and `version` are conventionally
    /// strings but YAML happily resolves digits-only values as Int.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.packageid = try c.decodeFlexibleStringIfPresent(forKey: .packageid)
        self.version = try c.decodeFlexibleStringIfPresent(forKey: .version)
        self.installedSize = try c.decodeIfPresent(Int.self, forKey: .installedSize)
        self.optional = try c.decodeIfPresent(Bool.self, forKey: .optional)
        self.noUnattendedUninstall = try c.decodeIfPresent(Bool.self, forKey: .noUnattendedUninstall)
    }
}
