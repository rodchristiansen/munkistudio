import Foundation

/// Catalogs in Munki are *derived* artifacts: `makecatalogs` walks
/// `pkgsinfo/` and emits one array-of-dicts file per catalog name under
/// `catalogs/`, plus an `all` catalog containing every pkginfo. We never
/// edit catalogs directly in the UI — to add or remove a package from a
/// catalog you edit the pkginfo's `catalogs[]`.
///
/// This type holds the *projection* the UI displays: a name and the set of
/// pkginfo records it currently contains.
public struct Catalog: Sendable, Hashable, Identifiable {
    public var name: String
    public var pkginfoNames: [String]

    public var id: String { name }

    public init(name: String, pkginfoNames: [String] = []) {
        self.name = name
        self.pkginfoNames = pkginfoNames
    }
}
