import Foundation

/// Strip `NSNull` values from a YAML-loaded property-list graph.
///
/// Munki YAML files commonly leave list keys empty (`optional_installs:`
/// with no value, `managed_uninstalls:` with no value), which Yams parses
/// as `NSNull`. `PropertyListSerialization` rejects `NSNull`, so without
/// this pass any manifest or pkginfo with an empty list key would refuse
/// to load — that's why ~20 root manifests went missing.
///
/// We treat `NSNull` as "key is absent": drop the entry from a dictionary,
/// drop the element from an array. The model uses optionals throughout, so
/// dropping is preferable to substituting a default (which would round-trip
/// as `[]` and silently change the file on save).
enum YamlSanitizer {
    static func sanitize(_ value: Any) -> Any? {
        if value is NSNull { return nil }
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            out.reserveCapacity(dict.count)
            for (key, raw) in dict {
                if let cleaned = sanitize(raw) {
                    out[key] = cleaned
                }
            }
            return out
        }
        if let array = value as? [Any] {
            return array.compactMap { sanitize($0) }
        }
        return value
    }
}
