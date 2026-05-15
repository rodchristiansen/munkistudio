import Foundation
import AppKit

/// Light-weight facts we sniff from an installer before the user reaches
/// Step 2 of the import wizard. We deliberately keep this thin —
/// `munkiimport -n` is the source of truth and will overwrite anything we
/// leave blank from its own inspection of the file. The extractor exists
/// purely so the Review step has something to show and so the Edit step
/// has sensible defaults the user can refine.
///
/// For `.app` bundles we read the Info.plist directly (cheap, no shell
/// out). For `.pkg`, `.dmg`, `.mpkg`, and anything else, we fall back to
/// parsing the filename — `Firefox-123.0.dmg` → name=Firefox, version=123.0
/// — which is good enough for the wizard's preview.
struct InstallerMetadata: Sendable, Equatable {
    var name: String
    var version: String
    var developer: String
    var category: String
    var displayName: String
    var description: String
    var bundleIdentifier: String?
    var supportedArchitectures: [String]
    var installerKindHint: InstallerKindHint
}

enum InstallerKindHint: String, Sendable, Hashable {
    case app
    case pkg
    case mpkg
    case dmg
    case unknown

    static func from(url: URL) -> InstallerKindHint {
        switch url.pathExtension.lowercased() {
        case "app": .app
        case "pkg": .pkg
        case "mpkg": .mpkg
        case "dmg", "iso": .dmg
        default: .unknown
        }
    }

    var label: String {
        switch self {
        case .app: "Application bundle"
        case .pkg: "Installer package"
        case .mpkg: "Bundle installer"
        case .dmg: "Disk image"
        case .unknown: "Installer"
        }
    }
}

enum InstallerMetadataExtractor {
    /// Best-effort extraction. Never throws — on any failure we fall back
    /// to filename parsing so the wizard always has something to show.
    static func extract(from installerURL: URL) -> InstallerMetadata {
        let hint = InstallerKindHint.from(url: installerURL)
        var meta = InstallerMetadata(
            name: "",
            version: "",
            developer: "",
            category: "",
            displayName: "",
            description: "",
            bundleIdentifier: nil,
            supportedArchitectures: [],
            installerKindHint: hint
        )

        if hint == .app, let info = readAppInfoPlist(at: installerURL) {
            meta.name = info["CFBundleName"] as? String
                ?? (installerURL.deletingPathExtension().lastPathComponent)
            meta.displayName = info["CFBundleDisplayName"] as? String ?? meta.name
            meta.version = (info["CFBundleShortVersionString"] as? String)
                ?? (info["CFBundleVersion"] as? String)
                ?? ""
            meta.bundleIdentifier = info["CFBundleIdentifier"] as? String
            // Apple's plists carry the localized developer in
            // NSHumanReadableCopyright as a string like "© 2025 Mozilla";
            // we just expose it as-is and let the user trim it in Step 2.
            if let copyright = info["NSHumanReadableCopyright"] as? String {
                meta.developer = copyright
            }
        }

        // Filename-based fallback. Even when Info.plist filled the name in,
        // we still derive a version from the filename if the plist didn't
        // have one — most app bundles carry a version but a handful don't.
        let parsed = parseFilename(installerURL.lastPathComponent)
        if meta.name.isEmpty { meta.name = parsed.name }
        if meta.version.isEmpty { meta.version = parsed.version }
        if meta.displayName.isEmpty { meta.displayName = meta.name }
        if let archFromName = detectArchitecture(in: installerURL.lastPathComponent) {
            meta.supportedArchitectures = [archFromName]
        }
        return meta
    }

    /// Reads Info.plist either from a .app bundle directly or from the
    /// equivalent location inside an installer payload. Returns nil for
    /// anything we can't parse — extractor swallows the error so the
    /// wizard falls back to the filename heuristic.
    private static func readAppInfoPlist(at url: URL) -> [String: Any]? {
        let infoURL = url.appending(path: "Contents/Info.plist")
        guard FileManager.default.fileExists(atPath: infoURL.path) else { return nil }
        guard let data = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist
    }

    /// Splits `Firefox-123.0.dmg` into (`Firefox`, `123.0`). Falls back to
    /// the whole basename when no version is detectable.
    private static func parseFilename(_ filename: String) -> (name: String, version: String) {
        let base = (filename as NSString).deletingPathExtension
        // Match the *last* dash-separated chunk that looks like a version
        // number; that's the convention the rest of the toolchain
        // uses (and matches what makepkginfo's auto-namer produces).
        let pattern = #"^(.+?)[-_ ]+([0-9][0-9A-Za-z.\-]*)$"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: base, range: NSRange(base.startIndex..., in: base)),
           let nameRange = Range(match.range(at: 1), in: base),
           let versionRange = Range(match.range(at: 2), in: base) {
            return (String(base[nameRange]), String(base[versionRange]))
        }
        return (base, "")
    }

    private static func detectArchitecture(in filename: String) -> String? {
        let lower = filename.lowercased()
        if lower.contains("arm64") || lower.contains("aarch64") || lower.contains("apple-silicon") {
            return "arm64"
        }
        if lower.contains("x86_64") || lower.contains("x64") || lower.contains("intel") || lower.contains("amd64") {
            return "x86_64"
        }
        return nil
    }
}

extension InstallerMetadata {
    static var empty: InstallerMetadata {
        InstallerMetadata(
            name: "",
            version: "",
            developer: "",
            category: "",
            displayName: "",
            description: "",
            bundleIdentifier: nil,
            supportedArchitectures: [],
            installerKindHint: .unknown
        )
    }
}
