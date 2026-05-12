import Foundation
import Yams

/// Custom Yams resolver mirroring the one Munki's PR #1261 uses
/// (`yamlutils.swift`). The float rule is removed so version-like scalars
/// — `"10.13"`, `"2.3"`, `"1.0"` — survive a read/write cycle as strings
/// instead of being silently coerced into `Double` and losing trailing
/// zeros. Munki itself uses the same resolver, so we stay byte-for-byte
/// compatible with the CLI.
public enum MunkiYamlResolver {
    public static let strict: Resolver = Resolver.default.removing(.float)
}
