import Foundation

/// Entry in `receipts[]` — used by Munki to detect installation when
/// `installs[]` isn't present and the installer is a `.pkg`.
public struct Receipt: Sendable, Hashable, Codable {
    public var packageid: String?
    /// Human-readable name. Appears in `receipts[]` per Munki's schema and
    /// in the CLI's `receiptKeyOrder`; preserving it round-trips diff-clean
    /// against `pkginfos` authored by `makepkginfo`.
    public var name: String?
    /// Original installer filename (e.g. `ExampleApp.pkg`). Part of Munki's
    /// receipt schema alongside `packageid` / `version`.
    public var filename: String?
    public var version: String?
    public var installedSize: Int?

    public var optional: Bool?
    public var noUnattendedUninstall: Bool?

    public init(
        packageid: String? = nil,
        name: String? = nil,
        filename: String? = nil,
        version: String? = nil,
        installedSize: Int? = nil,
        optional: Bool? = nil,
        noUnattendedUninstall: Bool? = nil
    ) {
        self.packageid = packageid
        self.name = name
        self.filename = filename
        self.version = version
        self.installedSize = installedSize
        self.optional = optional
        self.noUnattendedUninstall = noUnattendedUninstall
    }

    enum CodingKeys: String, CodingKey {
        case packageid
        case name
        case filename
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
        self.name = try c.decodeIfPresent(String.self, forKey: .name)
        self.filename = try c.decodeIfPresent(String.self, forKey: .filename)
        self.version = try c.decodeFlexibleStringIfPresent(forKey: .version)
        self.installedSize = try c.decodeIfPresent(Int.self, forKey: .installedSize)
        self.optional = try c.decodeIfPresent(Bool.self, forKey: .optional)
        self.noUnattendedUninstall = try c.decodeIfPresent(Bool.self, forKey: .noUnattendedUninstall)
    }
}
