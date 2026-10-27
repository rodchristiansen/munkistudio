import SwiftUI
import Core

/// Read-only advisory context within Promoter; approvals still use its normal rules.
struct PromoterCVESection: View {
    let report: PromoterCVEReport
    let productionVersions: [String: String]
    let candidates: [PromotionCandidate]
    let config: PromoterConfig
    let onOpenPackage: (String) -> Void
    @State private var expanded = true
    @State private var query = ""

    private var rows: [PromoterCVEReport.Finding] {
        report.findings.filter {
            productionVersions[$0.name.lowercased()] != nil &&
            (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) ||
             $0.cve.id.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("Find app or CVE", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                    Spacer()
                }
                Text("\(report.scannedPackages) apps scanned · \(report.incompleteApplications) with incomplete or unmatched lookups · \(report.failedRequests) request failures. Missing advisories do not establish that an app is patched.")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if rows.isEmpty {
                            Text("No matching High/Critical advisories for the open repository in this report.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(rows) { finding in
                            advisoryRow(finding)
                            Divider()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 210)
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Label("CVE Reporting", systemImage: "shield.lefthalf.filled")
                    .font(.headline)
                Text("\(rows.count) assessments").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let date = report.scanDate {
                    Text("Scanned \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Scan date unavailable").font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func advisoryRow(_ finding: PromoterCVEReport.Finding) -> some View {
        let production = productionVersions[finding.name.lowercased()]
        let current = report.matchesProduction(for: finding.name, currentVersion: production)
        let next = candidates.filter { $0.pkgName.caseInsensitiveCompare(finding.name) == .orderedSame }
        let pending = next.filter { candidate in
            guard let version = candidate.version, let production else { return false }
            return version.compare(production, options: .numeric) == .orderedDescending
        }.max { ($0.version ?? "").compare($1.version ?? "", options: .numeric) == .orderedAscending }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Button(finding.name) { onOpenPackage(finding.name) }
                    .buttonStyle(.link)
                Text(finding.cve.severity + " " + String(format: "%.1f", finding.cve.score))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(finding.cve.score >= 9 ? Color.red : Color.orange)
                if let url = finding.cve.sourceURL {
                    Link(finding.cve.id, destination: url)
                        .help("Open the source CVE record")
                } else {
                    Text(finding.cve.id)
                }
                if let url = finding.cve.nvdURL { Link("NVD ↗", destination: url) }
                Spacer()
                HStack(spacing: 6) {
                    Text(current ? statusLabel(finding.patchStatus) : "Needs rescan")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(current && finding.patchStatus == "fixed" ? Color.green : Color.secondary)
                    Text("· Production \(production ?? "—")")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    productionBadge(for: pending)
                }
            }
            Text(finding.cve.description).font(.callout).textSelection(.enabled)
            Text("Production: \(production ?? "—") · Assessed version: \(finding.version)" +
                 (finding.fixedVersion.map { " · Advisory fix: \($0)" } ?? ""))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            if !current {
                Text("Production differs from the scan baseline. This saved assessment does not establish its patch status.")
                    .font(.caption).foregroundStyle(.orange)
            } else if let reason = finding.patchReason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(next) { candidate in
                Text("Incoming \(candidate.version ?? "—") · \(candidate.currentCatalogs.joined(separator: ", ")) → \(candidate.targetCatalogs.joined(separator: ", ")) · " +
                     candidate.readinessLabel())
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func productionBadge(for candidate: PromotionCandidate?) -> some View {
        if let candidate {
            if let outlook = candidate.productionEligibility(using: config) {
                Text(outlook.badgeLabel())
                    .font(.caption.weight(.medium).monospacedDigit())
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.blue.opacity(0.12), in: .capsule)
                    .help("\(candidate.pkgName) \(candidate.version ?? "") · Earliest rule-based Production eligibility: \(outlook.date.formatted(date: .abbreviated, time: .shortened)). Future stages assume immediate promotion when eligible. Approval, pipeline runs and publication can delay delivery. This does not confirm that the update fixes this CVE.")
            } else {
                Text("No automatic Production path")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Text("No newer update queued")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func statusLabel(_ status: String?) -> String {
        switch status {
        case "outstanding": "Outstanding"
        case "fixed": "Fixed in Production"
        default: "Unknown"
        }
    }
}

struct PromoterCVELinks: View {
    let findings: [PromoterCVEReport.Finding]

    var body: some View {
        if !findings.isEmpty {
            Menu {
                ForEach(findings) { finding in
                    if let url = finding.cve.sourceURL {
                        Link("\(finding.cve.id) · \(finding.cve.severity)", destination: url)
                    }
                }
            } label: {
                Label("CVE", systemImage: "shield.lefthalf.filled")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Related advisories; open a source record")
        }
    }
}
