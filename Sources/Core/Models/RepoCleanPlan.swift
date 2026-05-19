import Foundation

/// A structured view of what a `repoclean` run reported. Built from the
/// tool's stdout by ``RepoCleanOutputParser`` — pure data, no I/O.
public struct RepoCleanPlan: Sendable, Equatable {
    /// One software item (a `name`) and every version of it `repoclean`
    /// listed, with the versions it would remove flagged.
    public struct Item: Sendable, Equatable, Identifiable {
        public var name: String
        public var catalogs: [String]
        public var minimumOSVersion: String?
        public var receipts: String?
        public var versions: [Version]

        public var id: String { name }

        /// Versions this run would delete.
        public var doomedVersions: [Version] { versions.filter(\.willDelete) }

        public init(
            name: String,
            catalogs: [String] = [],
            minimumOSVersion: String? = nil,
            receipts: String? = nil,
            versions: [Version] = []
        ) {
            self.name = name
            self.catalogs = catalogs
            self.minimumOSVersion = minimumOSVersion
            self.receipts = receipts
            self.versions = versions
        }
    }

    /// One version row under an item: its version string, the pkginfo
    /// path, and whether `repoclean` marked it `[to be DELETED]`.
    public struct Version: Sendable, Equatable, Hashable {
        public var version: String
        public var path: String
        public var willDelete: Bool

        public init(version: String, path: String, willDelete: Bool) {
            self.version = version
            self.path = path
            self.willDelete = willDelete
        }
    }

    /// The closing tally `repoclean` prints. `nil` when the output didn't
    /// contain a recognisable summary (e.g. the run failed early).
    public struct Summary: Sendable, Equatable {
        public var totalPkginfoItems: Int
        public var itemVariants: Int
        public var pkginfoItemsToDelete: Int
        public var pkgsToDelete: Int
        /// Human-readable savings strings exactly as `repoclean` printed
        /// them (e.g. "2.4 KB", "76.5 MB").
        public var pkginfoSpaceSavings: String
        public var pkgSpaceSavings: String

        public init(
            totalPkginfoItems: Int = 0,
            itemVariants: Int = 0,
            pkginfoItemsToDelete: Int = 0,
            pkgsToDelete: Int = 0,
            pkginfoSpaceSavings: String = "",
            pkgSpaceSavings: String = ""
        ) {
            self.totalPkginfoItems = totalPkginfoItems
            self.itemVariants = itemVariants
            self.pkginfoItemsToDelete = pkginfoItemsToDelete
            self.pkgsToDelete = pkgsToDelete
            self.pkginfoSpaceSavings = pkginfoSpaceSavings
            self.pkgSpaceSavings = pkgSpaceSavings
        }
    }

    public var items: [Item]
    public var summary: Summary?

    public init(items: [Item] = [], summary: Summary? = nil) {
        self.items = items
        self.summary = summary
    }

    /// Items with at least one version slated for deletion.
    public var itemsWithDeletions: [Item] {
        items.filter { !$0.doomedVersions.isEmpty }
    }

    /// `true` when the run would remove something.
    public var hasDeletions: Bool {
        (summary?.pkginfoItemsToDelete ?? 0) > 0 || items.contains { !$0.doomedVersions.isEmpty }
    }
}

/// Parses `repoclean` stdout into a ``RepoCleanPlan``. The tool prints a
/// block per item — `name:` / `catalogs:` / `versions:` and an indented
/// version list — then a closing summary. See the inline format notes.
public enum RepoCleanOutputParser {
    public static func parse(_ output: String) -> RepoCleanPlan {
        parse(lines: output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
    }

    public static func parse(lines: [String]) -> RepoCleanPlan {
        var items: [RepoCleanPlan.Item] = []
        var current: RepoCleanPlan.Item?
        var inVersions = false
        var summary = RepoCleanPlan.Summary()
        var sawSummary = false

        func flush() {
            if let current { items.append(current) }
            current = nil
            inVersions = false
        }

        for raw in lines {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { inVersions = false; continue }

            if let value = field("name:", in: trimmed) {
                flush()
                current = RepoCleanPlan.Item(name: value)
                continue
            }
            if current != nil, let value = field("catalogs:", in: trimmed) {
                current?.catalogs = value
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                continue
            }
            if current != nil, let value = field("minimum_os_version:", in: trimmed) {
                current?.minimumOSVersion = value
                continue
            }
            if current != nil, let value = field("receipts:", in: trimmed) {
                current?.receipts = value
                continue
            }
            if current != nil, trimmed == "versions:" {
                inVersions = true
                continue
            }
            if inVersions, current != nil, let version = parseVersion(trimmed) {
                current?.versions.append(version)
                continue
            }

            if let value = field("Total pkginfo items:", in: trimmed) {
                summary.totalPkginfoItems = Int(value) ?? 0
                sawSummary = true
            } else if let value = field("Item variants:", in: trimmed) {
                summary.itemVariants = Int(value) ?? 0
                sawSummary = true
            } else if let value = field("pkginfo items to delete:", in: trimmed) {
                summary.pkginfoItemsToDelete = Int(value) ?? 0
                sawSummary = true
            } else if let value = field("pkgs to delete:", in: trimmed) {
                summary.pkgsToDelete = Int(value) ?? 0
                sawSummary = true
            } else if let value = field("pkginfo space savings:", in: trimmed) {
                summary.pkginfoSpaceSavings = value
                sawSummary = true
            } else if let value = field("pkg space savings:", in: trimmed) {
                summary.pkgSpaceSavings = value
                sawSummary = true
            }
        }
        flush()
        return RepoCleanPlan(items: items, summary: sawSummary ? summary : nil)
    }

    /// Returns the text after `prefix` (whitespace-trimmed) when `line`
    /// begins with it, otherwise `nil`.
    private static func field(_ prefix: String, in line: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    /// Parses a version row: `1.0 (pkgsinfo/foo-1.0.yaml) [to be DELETED]`.
    /// The trailing marker is optional; the path sits between parentheses.
    private static func parseVersion(_ line: String) -> RepoCleanPlan.Version? {
        let marker = "[to be DELETED]"
        var body = line
        let willDelete = body.hasSuffix(marker)
        if willDelete { body = String(body.dropLast(marker.count)).trimmingCharacters(in: .whitespaces) }

        guard let open = body.firstIndex(of: "("),
              let close = body.lastIndex(of: ")"),
              open < close else { return nil }

        let version = String(body[body.startIndex..<open]).trimmingCharacters(in: .whitespaces)
        let path = String(body[body.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
        guard !version.isEmpty, !path.isEmpty else { return nil }
        return RepoCleanPlan.Version(version: version, path: path, willDelete: willDelete)
    }
}
