/// Public umbrella for the Core domain layer.
///
/// Core holds pure-Swift, Sendable value types describing a Munki repository
/// (`Pkginfo`, `Manifest`, `Catalog`, …), the protocols that abstract
/// repository I/O, and the predicate model that powers `installable_condition`
/// and `conditional_items`. It depends on nothing outside the standard library
/// and Foundation.
public enum Core {
    public static let schemaVersion = "1.0"
}
