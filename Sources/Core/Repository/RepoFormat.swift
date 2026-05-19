import Foundation

/// The on-disk serialization format for a pkginfo or manifest file. Munki 7
/// (per [PR #1261](https://github.com/munki/munki/pull/1261)) detects format
/// strictly by extension: `.yaml` / `.yml` → YAML, everything else → plist.
public enum RepoFormat: Sendable, Hashable, CaseIterable {
    case plist
    case yaml

    /// The file extension we write for a new file in this format. We pick
    /// `yaml` over `yml` because the Munki PR's defaults and existing
    /// fixtures use it.
    public var preferredExtension: String {
        switch self {
        case .plist: "plist"
        case .yaml: "yaml"
        }
    }

    /// Map an arbitrary path extension to a format. Returns nil if the
    /// extension is unrecognized so callers can skip non-pkginfo files.
    public static func fromPathExtension(_ ext: String) -> RepoFormat? {
        switch ext.lowercased() {
        case "plist": .plist
        case "yaml", "yml": .yaml
        default: nil
        }
    }
}
