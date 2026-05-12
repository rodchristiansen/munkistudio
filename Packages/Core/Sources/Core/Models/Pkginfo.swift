import Foundation

/// A single pkginfo record — the canonical Munki description of one
/// installable item. Mirrors the [Supported Pkginfo Keys] wiki page for
/// Munki 7, plus a tolerated set of legacy keys we round-trip without
/// editing in the UI.
///
/// [Supported Pkginfo Keys]: https://github.com/munki/munki/wiki/Supported-Pkginfo-Keys
///
/// Notes for maintainers:
/// - All non-required fields are `Optional`. Absence vs. `false` matters in
///   the on-disk plist, and we want round-trip cleanliness.
/// - Version-ish fields (`version`, `minimum_os_version`, `maximum_os_version`)
///   are `String`, not numeric, to preserve `"10.13"` ≠ `10.13`.
/// - `installerType` defaults to ``InstallerType/pkg`` on the client side
///   only — we keep the on-disk key optional so we never write `pkg` into a
///   file that didn't have the key originally.
/// - `RestartAction` and `OnDemand` keep their PascalCase on-disk names via
///   ``CodingKeys``.
public struct Pkginfo: Sendable, Hashable, Codable, Identifiable {
    // MARK: Identity

    public var name: String
    public var displayName: String?
    public var description: String?
    public var version: String?
    public var category: String?
    public var developer: String?
    public var notes: String?

    // MARK: Installer location & type

    public var installerType: InstallerType?
    public var installerItemLocation: String?
    public var installerItemHash: String?
    public var installerItemSize: Int?
    public var packagePath: String?
    public var uninstallerItemLocation: String?
    public var uninstallerItemHash: String?
    public var uninstallerItemSize: Int?
    public var allowUntrusted: Bool?
    public var precache: Bool?
    public var installerEnvironment: [String: String]?
    public var installerChoicesXml: [PlistValue]?

    // MARK: Install detection

    public var installs: [InstallsItem]?
    public var receipts: [Receipt]?
    public var itemsToCopy: [ItemToCopy]?
    public var installcheckScript: String?
    public var uninstallcheckScript: String?

    // MARK: Lifecycle scripts

    public var preinstallScript: String?
    public var postinstallScript: String?
    public var preuninstallScript: String?
    public var postuninstallScript: String?
    public var uninstallScript: String?
    public var uninstallMethod: String?
    public var uninstallable: Bool?
    public var versionScript: String?

    // MARK: User-facing alerts

    public var preinstallAlert: PreinstallAlert?
    public var preuninstallAlert: PreinstallAlert?
    public var preupgradeAlert: PreinstallAlert?

    // MARK: Conditions & targeting

    public var catalogs: [String]?
    public var requires: [String]?
    public var updateFor: [String]?
    public var supportedArchitectures: [SupportedArchitecture]?
    public var minimumOSVersion: String?
    public var maximumOSVersion: String?
    public var minimumMunkiVersion: String?
    public var installableCondition: String?
    public var blockingApplications: [BlockingApplication]?

    // MARK: Behavior & scheduling

    public var unattendedInstall: Bool?
    public var unattendedUninstall: Bool?
    public var forceInstallAfterDate: Date?
    public var restartAction: RestartAction?
    public var onDemand: Bool?
    public var autoremove: Bool?
    public var featured: Bool?
    public var suppressBundleRelocation: Bool?
    public var defaultInstalls: Bool?

    // MARK: Icons & artwork

    public var iconName: String?
    public var iconHash: String?

    // MARK: Staged OS installer / localization / Apple updates

    public var displayNameStaged: String?
    public var descriptionStaged: String?
    public var appleItem: Bool?
    public var localizedStrings: [String: PlistValue]?
    public var payloadIdentifier: String?

    // MARK: Munki Admin / tool metadata

    public var metadata: [String: PlistValue]?

    // MARK: Tolerated unknown keys

    /// Any pkginfo keys we don't model explicitly. Preserved verbatim on
    /// save so legacy or third-party tooling doesn't lose data when the file
    /// is round-tripped through the editor.
    public var unknownKeys: [String: PlistValue]?

    public var id: String { name }

    public init(name: String) {
        self.name = name
    }

    // MARK: Codable

    private enum FixedKey: String, CodingKey {
        case name
        case displayName = "display_name"
        case description
        case version
        case category
        case developer
        case notes

        case installerType = "installer_type"
        case installerItemLocation = "installer_item_location"
        case installerItemHash = "installer_item_hash"
        case installerItemSize = "installer_item_size"
        case packagePath = "package_path"
        case uninstallerItemLocation = "uninstaller_item_location"
        case uninstallerItemHash = "uninstaller_item_hash"
        case uninstallerItemSize = "uninstaller_item_size"
        case allowUntrusted = "allow_untrusted"
        case precache
        case installerEnvironment = "installer_environment"
        case installerChoicesXml = "installer_choices_xml"

        case installs
        case receipts
        case itemsToCopy = "items_to_copy"
        case installcheckScript = "installcheck_script"
        case uninstallcheckScript = "uninstallcheck_script"

        case preinstallScript = "preinstall_script"
        case postinstallScript = "postinstall_script"
        case preuninstallScript = "preuninstall_script"
        case postuninstallScript = "postuninstall_script"
        case uninstallScript = "uninstall_script"
        case uninstallMethod = "uninstall_method"
        case uninstallable
        case versionScript = "version_script"

        case preinstallAlert = "preinstall_alert"
        case preuninstallAlert = "preuninstall_alert"
        case preupgradeAlert = "preupgrade_alert"

        case catalogs
        case requires
        case updateFor = "update_for"
        case supportedArchitectures = "supported_architectures"
        case minimumOSVersion = "minimum_os_version"
        case maximumOSVersion = "maximum_os_version"
        case minimumMunkiVersion = "minimum_munki_version"
        case installableCondition = "installable_condition"
        case blockingApplications = "blocking_applications"

        case unattendedInstall = "unattended_install"
        case unattendedUninstall = "unattended_uninstall"
        case forceInstallAfterDate = "force_install_after_date"
        case restartAction = "RestartAction"
        case onDemand = "OnDemand"
        case autoremove
        case featured
        case suppressBundleRelocation = "suppress_bundle_relocation"
        case defaultInstalls = "default_installs"

        case iconName = "icon_name"
        case iconHash = "icon_hash"

        case displayNameStaged = "display_name_staged"
        case descriptionStaged = "description_staged"
        case appleItem = "apple_item"
        case localizedStrings = "localized_strings"
        case payloadIdentifier = "PayloadIdentifier"

        case metadata = "_metadata"
    }

    /// Every fixed key we know about. Anything outside this set lands in
    /// ``unknownKeys`` on decode and is re-emitted on encode.
    static let knownKeyStrings: Set<String> = [
        "name", "display_name", "description", "version", "category",
        "developer", "notes",
        "installer_type", "installer_item_location", "installer_item_hash",
        "installer_item_size", "package_path", "uninstaller_item_location",
        "uninstaller_item_hash", "uninstaller_item_size",
        "allow_untrusted", "precache", "installer_environment",
        "installer_choices_xml",
        "installs", "receipts", "items_to_copy",
        "installcheck_script", "uninstallcheck_script",
        "preinstall_script", "postinstall_script", "preuninstall_script",
        "postuninstall_script", "uninstall_script", "uninstall_method",
        "uninstallable", "version_script",
        "preinstall_alert", "preuninstall_alert", "preupgrade_alert",
        "catalogs", "requires", "update_for", "supported_architectures",
        "minimum_os_version", "maximum_os_version", "minimum_munki_version",
        "installable_condition", "blocking_applications",
        "unattended_install", "unattended_uninstall", "force_install_after_date",
        "RestartAction", "OnDemand", "autoremove", "featured",
        "suppress_bundle_relocation", "default_installs",
        "icon_name", "icon_hash",
        "display_name_staged", "description_staged", "apple_item",
        "localized_strings", "PayloadIdentifier",
        "_metadata",
    ]

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: FixedKey.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        self.description = try container.decodeIfPresent(String.self, forKey: .description)
        self.version = try container.decodeIfPresent(String.self, forKey: .version)
        self.category = try container.decodeIfPresent(String.self, forKey: .category)
        self.developer = try container.decodeIfPresent(String.self, forKey: .developer)
        self.notes = try container.decodeIfPresent(String.self, forKey: .notes)

        self.installerType = try container.decodeIfPresent(InstallerType.self, forKey: .installerType)
        self.installerItemLocation = try container.decodeIfPresent(String.self, forKey: .installerItemLocation)
        self.installerItemHash = try container.decodeIfPresent(String.self, forKey: .installerItemHash)
        self.installerItemSize = try container.decodeIfPresent(Int.self, forKey: .installerItemSize)
        self.packagePath = try container.decodeIfPresent(String.self, forKey: .packagePath)
        self.uninstallerItemLocation = try container.decodeIfPresent(String.self, forKey: .uninstallerItemLocation)
        self.uninstallerItemHash = try container.decodeIfPresent(String.self, forKey: .uninstallerItemHash)
        self.uninstallerItemSize = try container.decodeIfPresent(Int.self, forKey: .uninstallerItemSize)
        self.allowUntrusted = try container.decodeIfPresent(Bool.self, forKey: .allowUntrusted)
        self.precache = try container.decodeIfPresent(Bool.self, forKey: .precache)
        self.installerEnvironment = try container.decodeIfPresent([String: String].self, forKey: .installerEnvironment)
        self.installerChoicesXml = try container.decodeIfPresent([PlistValue].self, forKey: .installerChoicesXml)

        self.installs = try container.decodeIfPresent([InstallsItem].self, forKey: .installs)
        self.receipts = try container.decodeIfPresent([Receipt].self, forKey: .receipts)
        self.itemsToCopy = try container.decodeIfPresent([ItemToCopy].self, forKey: .itemsToCopy)
        self.installcheckScript = try container.decodeIfPresent(String.self, forKey: .installcheckScript)
        self.uninstallcheckScript = try container.decodeIfPresent(String.self, forKey: .uninstallcheckScript)

        self.preinstallScript = try container.decodeIfPresent(String.self, forKey: .preinstallScript)
        self.postinstallScript = try container.decodeIfPresent(String.self, forKey: .postinstallScript)
        self.preuninstallScript = try container.decodeIfPresent(String.self, forKey: .preuninstallScript)
        self.postuninstallScript = try container.decodeIfPresent(String.self, forKey: .postuninstallScript)
        self.uninstallScript = try container.decodeIfPresent(String.self, forKey: .uninstallScript)
        self.uninstallMethod = try container.decodeIfPresent(String.self, forKey: .uninstallMethod)
        self.uninstallable = try container.decodeIfPresent(Bool.self, forKey: .uninstallable)
        self.versionScript = try container.decodeIfPresent(String.self, forKey: .versionScript)

        self.preinstallAlert = try container.decodeIfPresent(PreinstallAlert.self, forKey: .preinstallAlert)
        self.preuninstallAlert = try container.decodeIfPresent(PreinstallAlert.self, forKey: .preuninstallAlert)
        self.preupgradeAlert = try container.decodeIfPresent(PreinstallAlert.self, forKey: .preupgradeAlert)

        self.catalogs = try container.decodeIfPresent([String].self, forKey: .catalogs)
        self.requires = try container.decodeIfPresent([String].self, forKey: .requires)
        self.updateFor = try container.decodeIfPresent([String].self, forKey: .updateFor)
        self.supportedArchitectures = try container.decodeIfPresent([SupportedArchitecture].self, forKey: .supportedArchitectures)
        self.minimumOSVersion = try container.decodeIfPresent(String.self, forKey: .minimumOSVersion)
        self.maximumOSVersion = try container.decodeIfPresent(String.self, forKey: .maximumOSVersion)
        self.minimumMunkiVersion = try container.decodeIfPresent(String.self, forKey: .minimumMunkiVersion)
        self.installableCondition = try container.decodeIfPresent(String.self, forKey: .installableCondition)
        self.blockingApplications = try container.decodeIfPresent([BlockingApplication].self, forKey: .blockingApplications)

        self.unattendedInstall = try container.decodeIfPresent(Bool.self, forKey: .unattendedInstall)
        self.unattendedUninstall = try container.decodeIfPresent(Bool.self, forKey: .unattendedUninstall)
        self.forceInstallAfterDate = try container.decodeIfPresent(Date.self, forKey: .forceInstallAfterDate)
        self.restartAction = try container.decodeIfPresent(RestartAction.self, forKey: .restartAction)
        self.onDemand = try container.decodeIfPresent(Bool.self, forKey: .onDemand)
        self.autoremove = try container.decodeIfPresent(Bool.self, forKey: .autoremove)
        self.featured = try container.decodeIfPresent(Bool.self, forKey: .featured)
        self.suppressBundleRelocation = try container.decodeIfPresent(Bool.self, forKey: .suppressBundleRelocation)
        self.defaultInstalls = try container.decodeIfPresent(Bool.self, forKey: .defaultInstalls)

        self.iconName = try container.decodeIfPresent(String.self, forKey: .iconName)
        self.iconHash = try container.decodeIfPresent(String.self, forKey: .iconHash)

        self.displayNameStaged = try container.decodeIfPresent(String.self, forKey: .displayNameStaged)
        self.descriptionStaged = try container.decodeIfPresent(String.self, forKey: .descriptionStaged)
        self.appleItem = try container.decodeIfPresent(Bool.self, forKey: .appleItem)
        self.localizedStrings = try container.decodeIfPresent([String: PlistValue].self, forKey: .localizedStrings)
        self.payloadIdentifier = try container.decodeIfPresent(String.self, forKey: .payloadIdentifier)

        self.metadata = try container.decodeIfPresent([String: PlistValue].self, forKey: .metadata)

        // Capture any keys we don't recognize so we can round-trip them.
        let dynamic = try decoder.container(keyedBy: DynamicKey.self)
        var leftovers: [String: PlistValue] = [:]
        for key in dynamic.allKeys where !Pkginfo.knownKeyStrings.contains(key.stringValue) {
            leftovers[key.stringValue] = try dynamic.decode(PlistValue.self, forKey: key)
        }
        self.unknownKeys = leftovers.isEmpty ? nil : leftovers
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: FixedKey.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(displayName, forKey: .displayName)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(version, forKey: .version)
        try container.encodeIfPresent(category, forKey: .category)
        try container.encodeIfPresent(developer, forKey: .developer)
        try container.encodeIfPresent(notes, forKey: .notes)

        try container.encodeIfPresent(installerType, forKey: .installerType)
        try container.encodeIfPresent(installerItemLocation, forKey: .installerItemLocation)
        try container.encodeIfPresent(installerItemHash, forKey: .installerItemHash)
        try container.encodeIfPresent(installerItemSize, forKey: .installerItemSize)
        try container.encodeIfPresent(packagePath, forKey: .packagePath)
        try container.encodeIfPresent(uninstallerItemLocation, forKey: .uninstallerItemLocation)
        try container.encodeIfPresent(uninstallerItemHash, forKey: .uninstallerItemHash)
        try container.encodeIfPresent(uninstallerItemSize, forKey: .uninstallerItemSize)
        try container.encodeIfPresent(allowUntrusted, forKey: .allowUntrusted)
        try container.encodeIfPresent(precache, forKey: .precache)
        try container.encodeIfPresent(installerEnvironment, forKey: .installerEnvironment)
        try container.encodeIfPresent(installerChoicesXml, forKey: .installerChoicesXml)

        try container.encodeIfPresent(installs, forKey: .installs)
        try container.encodeIfPresent(receipts, forKey: .receipts)
        try container.encodeIfPresent(itemsToCopy, forKey: .itemsToCopy)
        try container.encodeIfPresent(installcheckScript, forKey: .installcheckScript)
        try container.encodeIfPresent(uninstallcheckScript, forKey: .uninstallcheckScript)

        try container.encodeIfPresent(preinstallScript, forKey: .preinstallScript)
        try container.encodeIfPresent(postinstallScript, forKey: .postinstallScript)
        try container.encodeIfPresent(preuninstallScript, forKey: .preuninstallScript)
        try container.encodeIfPresent(postuninstallScript, forKey: .postuninstallScript)
        try container.encodeIfPresent(uninstallScript, forKey: .uninstallScript)
        try container.encodeIfPresent(uninstallMethod, forKey: .uninstallMethod)
        try container.encodeIfPresent(uninstallable, forKey: .uninstallable)
        try container.encodeIfPresent(versionScript, forKey: .versionScript)

        try container.encodeIfPresent(preinstallAlert, forKey: .preinstallAlert)
        try container.encodeIfPresent(preuninstallAlert, forKey: .preuninstallAlert)
        try container.encodeIfPresent(preupgradeAlert, forKey: .preupgradeAlert)

        try container.encodeIfPresent(catalogs, forKey: .catalogs)
        try container.encodeIfPresent(requires, forKey: .requires)
        try container.encodeIfPresent(updateFor, forKey: .updateFor)
        try container.encodeIfPresent(supportedArchitectures, forKey: .supportedArchitectures)
        try container.encodeIfPresent(minimumOSVersion, forKey: .minimumOSVersion)
        try container.encodeIfPresent(maximumOSVersion, forKey: .maximumOSVersion)
        try container.encodeIfPresent(minimumMunkiVersion, forKey: .minimumMunkiVersion)
        try container.encodeIfPresent(installableCondition, forKey: .installableCondition)
        try container.encodeIfPresent(blockingApplications, forKey: .blockingApplications)

        try container.encodeIfPresent(unattendedInstall, forKey: .unattendedInstall)
        try container.encodeIfPresent(unattendedUninstall, forKey: .unattendedUninstall)
        try container.encodeIfPresent(forceInstallAfterDate, forKey: .forceInstallAfterDate)
        try container.encodeIfPresent(restartAction, forKey: .restartAction)
        try container.encodeIfPresent(onDemand, forKey: .onDemand)
        try container.encodeIfPresent(autoremove, forKey: .autoremove)
        try container.encodeIfPresent(featured, forKey: .featured)
        try container.encodeIfPresent(suppressBundleRelocation, forKey: .suppressBundleRelocation)
        try container.encodeIfPresent(defaultInstalls, forKey: .defaultInstalls)

        try container.encodeIfPresent(iconName, forKey: .iconName)
        try container.encodeIfPresent(iconHash, forKey: .iconHash)

        try container.encodeIfPresent(displayNameStaged, forKey: .displayNameStaged)
        try container.encodeIfPresent(descriptionStaged, forKey: .descriptionStaged)
        try container.encodeIfPresent(appleItem, forKey: .appleItem)
        try container.encodeIfPresent(localizedStrings, forKey: .localizedStrings)
        try container.encodeIfPresent(payloadIdentifier, forKey: .payloadIdentifier)

        try container.encodeIfPresent(metadata, forKey: .metadata)

        if let unknownKeys, !unknownKeys.isEmpty {
            var dynamic = encoder.container(keyedBy: DynamicKey.self)
            for (key, value) in unknownKeys {
                try dynamic.encode(value, forKey: DynamicKey(stringValue: key))
            }
        }
    }
}

