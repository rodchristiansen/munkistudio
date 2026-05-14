import Foundation

/// Key-ordering policy for emitting pkginfo / manifest YAML, matching the
/// rules in Munki PR #1261's `yamlutils.swift` `sortPkginfoKeys`.
///
/// Order is: declared *priority* keys first (in declaration order); the
/// remaining keys alphabetically (case-insensitive); declared *trailing*
/// keys last. Special structures (`installs`, `receipts`, `conditional_items`)
/// have their own per-item priority key.
public enum CanonicalKeyOrder {
    public static let pkginfoPriority: [String] = ["name", "display_name", "version"]
    public static let pkginfoTrailing: [String] = ["_metadata"]

    public static let manifestPriority: [String] = ["display_name"]
    public static let manifestTrailing: [String] = ["_metadata"]

    /// `installs[]` items begin with their identity (`path`) and the
    /// `type` discriminator (`application` / `file` / etc.) so a
    /// reader can immediately classify the entry before scanning the
    /// rest of the metadata. Matches the Munki PR's `installs` sort
    /// policy.
    public static let installsItemPriority: [String] = ["path", "type"]
    public static let receiptPriority: [String] = ["packageid"]
    public static let conditionalItemPriority: [String] = ["condition"]
    /// `items_to_copy[]` leads with `destination_path` — the Munki
    /// repository convention (and what real repos in the wild already
    /// emit). Round-tripping was previously starting with `source_item`,
    /// causing a meaningless reorder on every save.
    public static let itemsToCopyPriority: [String] = ["destination_path"]

    /// Keys whose value is multi-line shell text. When emitting YAML we
    /// always force the literal (`|`) block scalar style on these so the
    /// content is readable and diffs cleanly.
    public static let scriptKeys: Set<String> = [
        "preinstall_script",
        "postinstall_script",
        "preuninstall_script",
        "postuninstall_script",
        "uninstall_script",
        "installcheck_script",
        "uninstallcheck_script",
    ]

    /// Apply the priority / alpha / trailing ordering to `keys`.
    public static func order(
        _ keys: some Sequence<String>,
        priority: [String],
        trailing: [String]
    ) -> [String] {
        let allKeys = Array(keys)
        let prioritySet = Set(priority)
        let trailingSet = Set(trailing)
        let middle = allKeys
            .filter { !prioritySet.contains($0) && !trailingSet.contains($0) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let priorityPresent = priority.filter { allKeys.contains($0) }
        let trailingPresent = trailing.filter { allKeys.contains($0) }
        return priorityPresent + middle + trailingPresent
    }
}

/// Context tells the encoder which priority list to use for a given mapping
/// in the on-disk graph. Inferred at the call site based on the key path.
public enum KeyOrderingContext: Sendable {
    case pkginfoRoot
    case manifestRoot
    case installsItem
    case receipt
    case conditionalItem
    case itemToCopy
    case other
}
