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
}
