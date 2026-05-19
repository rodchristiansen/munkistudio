import Foundation
import Yams

/// 1:1 port of Munki PR #1261's `yamlutils.swift` emission rules.
///
/// **Source of truth:** `rodchristiansen/munki@add-yaml-support`,
/// `code/cli/munki/shared/utils/yamlutils.swift`.
///
/// MunkiStudio writes YAML that must be byte-compatible with the Munki CLI's
/// output: same key ordering, same scalar styles, same empty-string handling.
/// Any divergence shows up as a noisy diff every time the user saves a file
/// originally authored by the CLI. To keep us aligned, this file mirrors
/// yamlutils.swift section-by-section and declaration-by-declaration. When
/// the upstream file changes, diff the two and port the delta — don't
/// evolve these rules independently.
///
/// Sections below match the `// MARK:` headers in yamlutils.swift.
public enum MunkiYamlRules {

    // MARK: - Custom Key Ordering for pkginfo YAML output

    /// Keys that should appear first in pkginfo YAML output, in this order.
    public static let priorityKeys = ["name", "display_name", "version"]

    /// Keys that should appear last in pkginfo YAML output.
    public static let lastKeys = ["_metadata"]

    /// Keys that indicate a receipt entry dictionary.
    public static let receiptKeys: Set<String> = [
        "packageid", "installed_size", "version", "filename", "name", "optional",
    ]

    /// Preferred key order for receipt entries — `packageid` first for readability.
    public static let receiptKeyOrder = [
        "packageid", "name", "filename", "installed_size", "version", "optional",
    ]

    /// Keys that indicate an installs item dictionary.
    public static let installsKeys: Set<String> = [
        "path", "type",
        "CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion",
        "md5checksum",
    ]

    /// Preferred key order for installs items — `path` first for readability.
    public static let installsKeyOrder = [
        "path", "type",
        "CFBundleIdentifier", "CFBundleName",
        "CFBundleShortVersionString", "CFBundleVersion",
        "md5checksum", "minosversion",
    ]

    /// Keys that indicate a conditional_items entry dictionary.
    public static let conditionalItemKeys: Set<String> = [
        "condition",
        "managed_installs", "managed_uninstalls", "managed_updates",
        "optional_installs",
        "included_manifests", "conditional_items",
    ]

    /// Preferred key order for conditional_items — `condition` MUST be first.
    public static let conditionalItemKeyOrder = [
        "condition",
        "managed_installs", "managed_uninstalls", "managed_updates",
        "optional_installs", "default_installs",
        "featured_items",
        "included_manifests", "conditional_items",
    ]

    // MARK: - Block Scalar Handling for Multi-line Strings

    /// Script field keys that should use YAML literal block scalar style (`|`).
    /// These fields contain executable scripts and must preserve exact newlines
    /// and formatting. Keep in sync with `ScriptOptions` in Munki's
    /// `pkginfoOptions.swift`.
    public static let scriptFieldKeys: Set<String> = [
        "preinstall_script",
        "postinstall_script",
        "installcheck_script",
        "uninstallcheck_script",
        "postuninstall_script",
        "uninstall_script",
        "preuninstall_script",
        "version_script",
        "embedded_script",
    ]

    /// Prose field keys that should use YAML folded block scalar style (`>`)
    /// when multi-line. Line wrapping is acceptable for human-readable text.
    public static let proseFieldKeys: Set<String> = [
        "description",
        "notes",
    ]

    /// Minimum length for an unknown-key multi-line string to be treated as a
    /// script. Below this, folded style wins (readable prose) over literal.
    /// 80 chars ≈ one terminal line — shorter content is almost certainly not a script.
    public static let scriptContentMinLength = 80

    /// Pick the appropriate YAML scalar style for a string value based on its key
    /// and content. Policy mirrors yamlutils.swift's `scalarStyleForString`:
    ///
    /// 1. Known script field key → literal block (`|`), regardless of content.
    /// 2. Single-line string → `.any` (let Yams pick plain/quoted).
    /// 3. Known prose field, multi-line → folded block (`>`).
    /// 4. Unknown key, multi-line → literal only if shebang OR ≥ `scriptContentMinLength`.
    ///    Otherwise folded.
    public static func scalarStyle(forKey key: String, value: String) -> Node.Scalar.Style {
        if scriptFieldKeys.contains(key) {
            return .literal
        }
        if !value.contains("\n") {
            return .any
        }
        if proseFieldKeys.contains(key) {
            return .folded
        }
        let hasShebang = value.hasPrefix("#!")
        let isLong = value.count >= scriptContentMinLength
        if hasShebang || isLong {
            return .literal
        }
        return .folded
    }

    // MARK: - Dictionary shape detection

    /// True if the dict looks like a receipt entry (must have `packageid`).
    public static func isReceiptDict(_ dict: [String: Any]) -> Bool {
        dict.keys.contains("packageid")
    }

    /// True if the dict looks like an installs item (must have `path` AND `type`).
    public static func isInstallsDict(_ dict: [String: Any]) -> Bool {
        dict.keys.contains("path") && dict.keys.contains("type")
    }

    /// True if the dict looks like a conditional_items entry.
    ///
    /// Top-level manifests share most keys with conditional blocks
    /// (`managed_installs`, `included_manifests`, etc.). `catalogs` is the
    /// disambiguator: conditional blocks never carry it. Without this check, a
    /// top-level manifest with `included_manifests` would route through the
    /// conditional sort and emit keys in the conditional layout instead of
    /// the manifest's alphabetical layout.
    public static func isConditionalItemDict(_ dict: [String: Any]) -> Bool {
        if dict.keys.contains("catalogs") {
            return false
        }
        if dict.keys.contains("condition") {
            return true
        }
        // Unconditional blocks inside a `conditional_items:` array have manifest-list
        // keys but no pkginfo-identity keys.
        let hasManifestKeys = dict.keys.contains { conditionalItemKeys.contains($0) }
        let hasPkginfoKeys =
            dict.keys.contains("name") ||
            dict.keys.contains("version") ||
            dict.keys.contains("installer_item_location")
        return hasManifestKeys && !hasPkginfoKeys
    }

    // MARK: - Sort functions

    /// Sort keys of an apparent conditional_items entry: `condition` first,
    /// then the `managed_*` block in semantic order, then anything else
    /// alphabetically.
    public static func sortConditionalItemKeys(_ keys: [String]) -> [String] {
        sort(keys, byOrder: conditionalItemKeyOrder)
    }

    /// Sort keys of an apparent receipt entry: `packageid` first, then the rest
    /// per `receiptKeyOrder`, then anything else alphabetically.
    public static func sortReceiptKeys(_ keys: [String]) -> [String] {
        sort(keys, byOrder: receiptKeyOrder)
    }

    /// Sort keys of an apparent installs item: `path` first, then the rest per
    /// `installsKeyOrder`, then anything else alphabetically.
    public static func sortInstallsKeys(_ keys: [String]) -> [String] {
        sort(keys, byOrder: installsKeyOrder)
    }

    /// Sort pkginfo (and manifest, and generic dict) keys:
    ///   - `name`, `display_name`, `version` first, in that order;
    ///   - `_metadata` last;
    ///   - everything else alphabetically in between.
    ///
    /// The alphabetic sort is case-sensitive (`String.<`), matching
    /// yamlutils.swift's `Array.sort()` behaviour — so capitalised legacy keys
    /// like `RestartAction`, `OnDemand`, `PayloadIdentifier` group at the top
    /// of the alphabetic section instead of being collated with lowercase
    /// keys.
    public static func sortPkginfoKeys(_ keys: [String]) -> [String] {
        var firstKeys: [String] = []
        var middleKeys: [String] = []
        var endKeys: [String] = []

        for key in keys {
            if priorityKeys.contains(key) {
                firstKeys.append(key)
            } else if lastKeys.contains(key) {
                endKeys.append(key)
            } else {
                middleKeys.append(key)
            }
        }

        firstKeys.sort { priorityKeys.firstIndex(of: $0)! < priorityKeys.firstIndex(of: $1)! }
        middleKeys.sort()
        endKeys.sort()
        return firstKeys + middleKeys + endKeys
    }

    /// Sort keys for a dict using whatever rule matches its apparent shape.
    public static func sortKeysForDict(_ dict: [String: Any]) -> [String] {
        let keys = Array(dict.keys)
        if isReceiptDict(dict) {
            return sortReceiptKeys(keys)
        } else if isInstallsDict(dict) {
            return sortInstallsKeys(keys)
        } else if isConditionalItemDict(dict) {
            return sortConditionalItemKeys(keys)
        } else {
            return sortPkginfoKeys(keys)
        }
    }

    /// Generic helper: keys in `order` come first (in declared positions), the
    /// rest alphabetically.
    private static func sort(_ keys: [String], byOrder order: [String]) -> [String] {
        var orderedKeys: [String] = []
        var otherKeys: [String] = []
        for key in keys {
            if order.contains(key) {
                orderedKeys.append(key)
            } else {
                otherKeys.append(key)
            }
        }
        orderedKeys.sort {
            (order.firstIndex(of: $0) ?? Int.max) < (order.firstIndex(of: $1) ?? Int.max)
        }
        otherKeys.sort()
        return orderedKeys + otherKeys
    }
}
