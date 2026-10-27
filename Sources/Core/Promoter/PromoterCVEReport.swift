import Foundation

/// Advisory evidence exported by the CVE scanner. Catalog and promotion state
/// continue to come from the open repository, not from this saved report.
public struct PromoterCVEReport: Decodable, Sendable {
    public let generatedAt: String
    public let scannedPackages: Int
    public let failedRequests: Int
    public let applications: [Application]
    public let patchFindings: [Finding]?
    public let relatedFindings: [Finding]?

    public struct Application: Decodable, Sendable {
        public let name: String
        public let productionVersion: String?
        public let latestVersion: String?
        public let lookupStatus: String
    }

    public struct Finding: Decodable, Sendable, Identifiable {
        public let name: String
        public let version: String
        public let cve: Advisory
        public let patchStatus: String?
        public let fixedVersion: String?
        public let patchReason: String?

        public var id: String { name + "::" + cve.id + "::" + (patchStatus ?? "unknown") }
    }

    public struct Advisory: Decodable, Sendable {
        public let id: String
        public let score: Double
        public let severity: String
        public let description: String

        /// Build links only for a valid CVE identifier. Report content cannot
        /// substitute an executable, file, or arbitrary URL for a source link.
        public var sourceURL: URL? {
            guard id.range(of: #"^CVE-[0-9]{4}-[0-9]{4,}$"#, options: .regularExpression) != nil else { return nil }
            return URL(string: "https://www.cve.org/CVERecord?id=" + id)
        }

        public var nvdURL: URL? {
            guard sourceURL != nil else { return nil }
            return URL(string: "https://nvd.nist.gov/vuln/detail/" + id)
        }
    }

    public var scanDate: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: generatedAt) ?? ISO8601DateFormatter().date(from: generatedAt)
    }

    public var findings: [Finding] {
        var seen: Set<String> = []
        return (patchFindings ?? relatedFindings ?? [])
            .filter { $0.cve.score >= 7 && seen.insert($0.id).inserted }
            .sorted {
                if $0.cve.score != $1.cve.score { return $0.cve.score > $1.cve.score }
                return $0.id < $1.id
            }
    }

    public var incompleteApplications: Int {
        applications.filter { $0.lookupStatus != "queried" }.count
    }

    public func findings(for name: String) -> [Finding] {
        findings.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// An old assessment must not label a newly promoted version as fixed or
    /// affected. A report with no Production baseline is also inconclusive.
    public func matchesProduction(for name: String, currentVersion: String?) -> Bool {
        guard let currentVersion,
              let baseline = applications.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })?.productionVersion
        else { return false }
        return baseline == currentVersion
    }
}
