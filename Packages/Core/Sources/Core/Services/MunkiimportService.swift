import Foundation

/// Invoke Munki's `munkiimport` CLI (ships at `/usr/local/munki/munkiimport`)
/// in non-interactive mode and stream its output. We don't reimplement the
/// pkg/dmg/app inspection or the pkginfo emission ourselves — `munkiimport`
/// is the canonical tool the server admins already trust, and matching its
/// output exactly is a maintenance liability we deliberately avoid.
public protocol MunkiimportService: Sendable {
    /// Stream lines from a `munkiimport -n` run as they're emitted. The
    /// returned sequence finishes when the process exits; the final
    /// element is a ``MunkiimportOutcome``.
    func run(
        in repository: MunkiRepository,
        options: MunkiimportOptions
    ) -> AsyncThrowingStream<MunkiimportEvent, any Error>
}

/// Per-run options that map 1:1 to the flags the wizard exposes. Anything
/// the UI doesn't surface stays at munkiimport's defaults.
public struct MunkiimportOptions: Sendable {
    /// Path to the installer item (`.pkg`, `.dmg`, `.app`, `.mpkg`).
    public var installerPath: URL
    /// Subdirectory under `pkgs/` and `pkgsinfo/`. Empty means top-level.
    public var subdirectory: String
    /// Catalog names. Empty array falls back to munkiimport's default
    /// (`testing`).
    public var catalogs: [String]
    /// Override the autodetected display name.
    public var name: String?
    public var displayName: String?
    public var version: String?
    public var developer: String?
    public var category: String?
    public var description: String?
    /// Supported architectures — `arm64`, `x86_64`, or both.
    public var supportedArchitectures: [String]
    public var unattendedInstall: Bool
    public var unattendedUninstall: Bool
    public var blockingApplications: [String]
    public var minimumOSVersion: String?
    public var maximumOSVersion: String?
    public var minimumMunkiVersion: String?
    /// Script file paths. munkiimport reads each one and embeds its
    /// contents into the emitted pkginfo.
    public var preinstallScriptPath: URL?
    public var postinstallScriptPath: URL?
    public var preuninstallScriptPath: URL?
    public var postuninstallScriptPath: URL?
    public var installCheckScriptPath: URL?
    public var uninstallCheckScriptPath: URL?
    /// Emit YAML pkginfos. When `nil`, munkiimport's per-repo default
    /// (plist) wins.
    public var emitYAML: Bool
    /// Try to pull an icon out of the installer.
    public var extractIcon: Bool
    /// Explicit icon override (.icns or .png).
    public var iconPath: URL?

    public init(
        installerPath: URL,
        subdirectory: String = "",
        catalogs: [String] = [],
        name: String? = nil,
        displayName: String? = nil,
        version: String? = nil,
        developer: String? = nil,
        category: String? = nil,
        description: String? = nil,
        supportedArchitectures: [String] = [],
        unattendedInstall: Bool = false,
        unattendedUninstall: Bool = false,
        blockingApplications: [String] = [],
        minimumOSVersion: String? = nil,
        maximumOSVersion: String? = nil,
        minimumMunkiVersion: String? = nil,
        preinstallScriptPath: URL? = nil,
        postinstallScriptPath: URL? = nil,
        preuninstallScriptPath: URL? = nil,
        postuninstallScriptPath: URL? = nil,
        installCheckScriptPath: URL? = nil,
        uninstallCheckScriptPath: URL? = nil,
        emitYAML: Bool = false,
        extractIcon: Bool = false,
        iconPath: URL? = nil
    ) {
        self.installerPath = installerPath
        self.subdirectory = subdirectory
        self.catalogs = catalogs
        self.name = name
        self.displayName = displayName
        self.version = version
        self.developer = developer
        self.category = category
        self.description = description
        self.supportedArchitectures = supportedArchitectures
        self.unattendedInstall = unattendedInstall
        self.unattendedUninstall = unattendedUninstall
        self.blockingApplications = blockingApplications
        self.minimumOSVersion = minimumOSVersion
        self.maximumOSVersion = maximumOSVersion
        self.minimumMunkiVersion = minimumMunkiVersion
        self.preinstallScriptPath = preinstallScriptPath
        self.postinstallScriptPath = postinstallScriptPath
        self.preuninstallScriptPath = preuninstallScriptPath
        self.postuninstallScriptPath = postuninstallScriptPath
        self.installCheckScriptPath = installCheckScriptPath
        self.uninstallCheckScriptPath = uninstallCheckScriptPath
        self.emitYAML = emitYAML
        self.extractIcon = extractIcon
        self.iconPath = iconPath
    }
}

public enum MunkiimportEvent: Sendable {
    case line(String)
    case finished(MunkiimportOutcome)
}

public struct MunkiimportOutcome: Sendable {
    public var exitCode: Int32
    /// URL of the pkginfo munkiimport wrote, if we could parse it from
    /// stdout. `nil` on failure or when stdout was unexpected.
    public var pkginfoURL: URL?
    /// URL of the installer munkiimport copied into `pkgs/`, if parseable.
    public var installerURL: URL?
    /// Aggregated stderr (only populated on non-zero exit so the UI can
    /// surface the failure reason).
    public var errorOutput: String

    public init(
        exitCode: Int32,
        pkginfoURL: URL? = nil,
        installerURL: URL? = nil,
        errorOutput: String = ""
    ) {
        self.exitCode = exitCode
        self.pkginfoURL = pkginfoURL
        self.installerURL = installerURL
        self.errorOutput = errorOutput
    }
}
