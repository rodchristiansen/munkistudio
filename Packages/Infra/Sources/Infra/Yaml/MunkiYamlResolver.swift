import Foundation
import Yams

/// Custom Yams resolver mirroring the one Munki's PR #1261 uses
/// (`yamlutils.swift`). The float rule is removed so version-like scalars
/// — `"10.13"`, `"2.3"`, `"1.0"` — survive a read/write cycle as strings
/// instead of being silently coerced into `Double` and losing trailing
/// zeros. Munki itself uses the same resolver, so we stay byte-for-byte
/// compatible with the CLI.
public enum MunkiYamlResolver {
    /// Custom resolver mirroring Munki PR #1261's `yamlutils.swift`.
    ///
    /// - `.float` is removed so version-like scalars (`10.13`, `2.3`,
    ///   `1.0`) survive a read/write cycle as strings instead of being
    ///   coerced to `Double` and losing trailing zeros.
    /// - `.timestamp` is removed so ISO-8601 strings authored as YAML
    ///   strings stay strings. Previously Yams resolved them to
    ///   `Date`, our emitter wrote them back with the `!!timestamp`
    ///   tag, and round-tripping replaced `'2015-11-23T23:54:30Z'`
    ///   with the unquoted form — a noisy, semantically-equivalent
    ///   diff. Munki's CLI doesn't care either way; preserving the
    ///   original spelling keeps git diffs clean.
    public static let strict: Resolver = Resolver.default
        .removing(.float)
        .removing(.timestamp)
}
