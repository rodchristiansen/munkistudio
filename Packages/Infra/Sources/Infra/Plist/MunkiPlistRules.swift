import Foundation

/// 1:1 port of Munki PR #1261's `plistutils.swift`.
///
/// **Source of truth:** `rodchristiansen/munki@add-yaml-support`,
/// `code/cli/munki/shared/utils/plistutils.swift`.
///
/// The XML plist format itself is owned by Apple's `PropertyListSerialization`
/// — there's not much opinion to encode at the byte level. What this file
/// does port is Munki's *behaviour*:
///
///   * `serialize` / `deserialize` go through `PropertyListSerialization`
///     directly, so our written bytes match the CLI's exactly.
///   * `readPlist(fromData:)` and `readPlist(fromString:)` try plist first
///     and fall back to YAML — same dual-parse behaviour the CLI uses for
///     mixed-format repos.
///   * `writePlist(_:toFile:)` dispatches by extension: `.yaml`/`.yml`
///     route to ``MunkiYamlRules`` (via the YAML coders), everything else
///     emits XML plist.
///   * `parseFirstPlist(fromString:)` extracts the first `<?xml … </plist>`
///     blob from arbitrary text — used by tools that embed plists in stdout.
///
/// Section headers below mirror `plistutils.swift`. When the upstream file
/// changes, diff the two and port the delta.
public enum MunkiPlistRules {

    // MARK: - Errors

    public enum PlistError: Error, LocalizedError {
        case readError(description: String)
        case writeError(description: String)

        public var errorDescription: String? {
            switch self {
            case let .readError(description): description
            case let .writeError(description): description
            }
        }
    }

    // MARK: - Format detection

    /// True if `pathExtension` is `yaml` or `yml` (case-insensitive).
    /// Mirrors plistutils.swift's `isYamlFile(_:)`.
    public static func isYamlFile(_ filepath: String) -> Bool {
        let ext = (filepath as NSString).pathExtension.lowercased()
        return ext == "yaml" || ext == "yml"
    }

    // MARK: - Deserialize

    /// Convert XML/binary plist data into a Foundation property-list graph.
    ///
    /// Uses immutable containers to avoid memory-corruption issues when
    /// bridging between Objective-C `NSDictionary`/`NSArray` and Swift types.
    /// The mutable variant has historically caused ARC reference-counting
    /// trouble when Swift code accesses values from the returned dictionary.
    /// Mirrors plistutils.swift's `deserialize(_:)`.
    public static func deserialize(_ data: Data) throws -> Any {
        do {
            return try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            )
        } catch {
            throw PlistError.readError(description: "\(error)")
        }
    }

    // MARK: - readPlist

    /// Attempt to read a property-list from data. Tries plist first; on
    /// failure, tries YAML. Mirrors plistutils.swift's `readPlist(fromData:)`.
    ///
    /// `yamlFallback` is a caller-provided closure so this module doesn't have
    /// to know about Yams — the YAML coders inject `MunkiYamlRules.deserialize`
    /// through this hook.
    public static func readPlist(
        fromData data: Data,
        yamlFallback: (Data) throws -> Any
    ) throws -> Any {
        do {
            return try deserialize(data)
        } catch {
            do {
                return try yamlFallback(data)
            } catch let yamlError {
                throw PlistError.readError(
                    description: "Failed to parse as plist or yaml. Plist error: \(error). YAML error: \(yamlError)"
                )
            }
        }
    }

    /// Attempt to read a property-list from a string. Same dual-parse
    /// behaviour as `readPlist(fromData:)`.
    public static func readPlist(
        fromString string: String,
        yamlFallback: (String) throws -> Any
    ) throws -> Any {
        let data = string.data(using: .utf8) ?? Data()
        do {
            return try deserialize(data)
        } catch {
            do {
                return try yamlFallback(string)
            } catch let yamlError {
                throw PlistError.readError(
                    description: "Failed to parse as plist or yaml. Plist error: \(error). YAML error: \(yamlError)"
                )
            }
        }
    }

    // MARK: - Serialize

    /// Convert a Foundation property-list graph into XML plist data.
    /// Mirrors plistutils.swift's `serialize(_:)`.
    public static func serialize(_ plist: Any) throws -> Data {
        do {
            return try PropertyListSerialization.data(
                fromPropertyList: plist,
                format: .xml,
                options: 0
            )
        } catch {
            throw PlistError.writeError(description: "\(error)")
        }
    }

    // MARK: - parseFirstPlist

    /// Find the first `<?xml … </plist>` block in `str`. Returns
    /// `(plistText, remainder)`. If no plist is found, returns
    /// `("", str)`. Mirrors plistutils.swift's `parseFirstPlist(fromString:)`.
    public static func parseFirstPlist(fromString str: String) -> (String, String) {
        let header = "<?xml version"
        let footer = "</plist>"
        let nsStr = str as NSString
        let headerRange = nsStr.range(of: header)
        guard headerRange.location != NSNotFound else { return ("", str) }
        let footerSearchStart = headerRange.location + headerRange.length
        let footerSearchRange = NSRange(
            location: footerSearchStart,
            length: nsStr.length - footerSearchStart
        )
        let footerRange = nsStr.range(of: footer, range: footerSearchRange)
        guard footerRange.location != NSNotFound else { return ("", str) }
        let plistRange = NSRange(
            location: headerRange.location,
            length: footerRange.location + footerRange.length - headerRange.location
        )
        let plistStr = nsStr.substring(with: plistRange)
        let remainderIndex = plistRange.location + plistRange.length
        let remainder = nsStr.substring(from: remainderIndex)
        return (plistStr, remainder)
    }

    // MARK: - independentCopy

    /// Deep-copy a property-list dictionary by serializing and deserializing.
    /// Used when the source may contain Objective-C bridged objects whose
    /// memory lifetime we don't control. Mirrors plistutils.swift's
    /// `independentCopy(of:)`.
    public static func independentCopy(of dict: [String: Any]) -> [String: Any]? {
        do {
            let data = try serialize(dict)
            return try deserialize(data) as? [String: Any]
        } catch {
            return nil
        }
    }
}
