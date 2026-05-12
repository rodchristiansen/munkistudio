import Foundation

/// `installer_type` values understood by Munki 7. We keep an `unknown(String)`
/// case so we never lose data from third-party / future installer types when
/// round-tripping a pkginfo we don't fully recognize.
public enum InstallerType: Sendable, Hashable, Codable {
    /// Default flat `.pkg` / `.mpkg`. Munki treats an absent
    /// `installer_type` key as this case on disk.
    case pkg
    case copyFromDmg
    case nopkg
    case stageOSInstaller
    case startosinstall
    case configurationProfile
    case appleUpdateMetadata
    case unknown(String)

    public var rawValue: String {
        switch self {
        case .pkg: return "pkg"
        case .copyFromDmg: return "copy_from_dmg"
        case .nopkg: return "nopkg"
        case .stageOSInstaller: return "stage_os_installer"
        case .startosinstall: return "startosinstall"
        case .configurationProfile: return "profile"
        case .appleUpdateMetadata: return "apple_update_metadata"
        case .unknown(let value): return value
        }
    }

    public init(rawValue: String) {
        switch rawValue {
        case "pkg": self = .pkg
        case "copy_from_dmg": self = .copyFromDmg
        case "nopkg": self = .nopkg
        case "stage_os_installer": self = .stageOSInstaller
        case "startosinstall": self = .startosinstall
        case "profile": self = .configurationProfile
        case "apple_update_metadata": self = .appleUpdateMetadata
        default: self = .unknown(rawValue)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
