import SwiftUI
import Core

/// Upcoming promotions card — every pkginfo currently sitting in some
/// rule's source-catalog set, with per-row actions.
struct PromoterUpcomingSection: View {
    let candidates: [PromotionCandidate]
    let busyURL: URL?
    let hiddenCatalogs: Set<String>
    let pkginfoCount: Int
    /// Set of catalog names found in any rule's `promote_from`, surfaced
    /// in the diagnostic so the user can compare against pkginfo catalogs.
    let knownPromoteFromSets: [[String]]
    /// First few pkginfo catalog signatures (deduped), shown when count
    /// > 0 so the user can see why no rule matches.
    let pkginfoCatalogSamples: [[String]]
    let repositoryPath: String?
    let onPromote: (PromotionCandidate) -> Void
    let onDefer: (PromotionCandidate) -> Void
    /// Wired to double-click on a candidate row → open in Packages tab.
    var onOpenPackage: ((String) -> Void)? = nil

    @State private var selectedRowID: URL?
    @State private var lastTapID: URL?
    @State private var lastTapAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader
            VStack(spacing: 0) {
                if candidates.isEmpty {
                    emptyState
                } else {
                    ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                        PromoterCandidateRow(
                            candidate: candidate,
                            busy: busyURL == candidate.pkginfoURL,
                            hiddenCatalogs: hiddenCatalogs,
                            isSelected: selectedRowID == candidate.id,
                            onTap: { handleTap(candidate: candidate) },
                            onPromote: { onPromote(candidate) },
                            onDefer: { onDefer(candidate) }
                        )
                        .transition(.asymmetric(
                            insertion: .opacity,
                            removal: .opacity.combined(with: .move(edge: .trailing))
                        ))
                        if index < candidates.count - 1 { Divider() }
                    }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
            )
        }
    }

    private var sectionHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar.badge.clock")
                .foregroundStyle(.tint)
            Text("Upcoming Promotions").font(.headline)
            Text("\(candidates.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var emptyState: some View {
        diagnosticPanel
    }

    /// Pinpoint why the list is empty so the user doesn't have to guess.
    /// Three reasons are common: the repo's pkginfo set is empty (open
    /// the wrong folder, or still loading), `promoter.yml` has no rules,
    /// or rules exist but no pkginfo's catalog set matches a rule's
    /// `promote_from`.
    private var diagnosticPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No pkginfos match any current promoter rule.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if pkginfoCount == 0 {
                Label("0 pkginfos loaded from the open repository.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .labelStyle(.titleAndIcon)
                if let repositoryPath {
                    Text("Open repo path: \(repositoryPath)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
                Text("Expected pkginfo files at <repo>/pkgsinfo/ — open the folder containing pkgsinfo/.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Label("\(pkginfoCount) pkginfo\(pkginfoCount == 1 ? "" : "s") loaded but none match any rule's `promote_from` set.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .labelStyle(.titleAndIcon)
                if !knownPromoteFromSets.isEmpty {
                    Text("Rules expect:").font(.caption2).foregroundStyle(.tertiary)
                    ForEach(Array(knownPromoteFromSets.enumerated()), id: \.offset) { _, set in
                        Text("  • [\(set.joined(separator: ", "))]")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                }
                if !pkginfoCatalogSamples.isEmpty {
                    Text("Sample pkginfo catalogs:").font(.caption2).foregroundStyle(.tertiary)
                    ForEach(Array(pkginfoCatalogSamples.enumerated()), id: \.offset) { _, set in
                        Text("  • [\(set.joined(separator: ", "))]")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    /// Timing-based double-click resolution — see the corresponding
    /// notes in PromoterImportsSection.
    private func handleTap(candidate: PromotionCandidate) {
        let now = Date()
        if lastTapID == candidate.id, let last = lastTapAt, now.timeIntervalSince(last) < 0.4 {
            onOpenPackage?(candidate.pkgName)
            lastTapID = nil
            lastTapAt = nil
        } else {
            selectedRowID = candidate.id
            lastTapID = candidate.id
            lastTapAt = now
        }
    }
}

private struct PromoterCandidateRow: View {
    let candidate: PromotionCandidate
    let busy: Bool
    let hiddenCatalogs: Set<String>
    let isSelected: Bool
    let onTap: () -> Void
    let onPromote: () -> Void
    let onDefer: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            statusBadge
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(candidate.pkgName)
                        .font(.callout.weight(.medium))
                    if let version = candidate.version {
                        Text(version)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 6) {
                    Text(candidate.ruleName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.tertiary)
                    Text(catalogTransition)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            timingLabel
            actionMenu
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .contentShape(.rect)
        .onTapGesture(perform: onTap)
    }

    private var statusBadge: some View {
        ZStack {
            Circle()
                .fill(candidate.isEligible() ? Color.green.opacity(0.18) : Color.orange.opacity(0.18))
                .frame(width: 28, height: 28)
            Image(systemName: candidate.isEligible() ? "checkmark" : "clock")
                .font(.caption.weight(.semibold))
                .foregroundStyle(candidate.isEligible() ? Color.green : Color.orange)
        }
    }

    private var catalogTransition: String {
        let current = filteringHidden(candidate.currentCatalogs, hidden: hiddenCatalogs)
        let target = filteringHidden(candidate.targetCatalogs, hidden: hiddenCatalogs)
        let left = current.isEmpty ? "—" : current.joined(separator: ",")
        let right = target.isEmpty ? "—" : target.joined(separator: ",")
        return left + " → " + right
    }

    @ViewBuilder
    private var timingLabel: some View {
        if candidate.isEligible() {
            Text("Eligible")
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
        } else {
            let days = candidate.daysRemaining()
            Text("\(days)d remaining")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actionMenu: some View {
        if busy {
            ProgressView().controlSize(.small).frame(width: 110, alignment: .trailing)
        } else {
            HStack(spacing: 6) {
                // `.bordered` instead of `.borderedProminent` so the
                // button keeps its colored chrome when the window
                // loses key — `.borderedProminent` collapses to a
                // flat label in that state and the action becomes
                // invisible.
                Button(candidate.isEligible() ? "Approve" : "Promote Early", action: onPromote)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(candidate.isEligible() ? .green : .orange)
                Menu {
                    Button("Defer (restart timer)", action: onDefer)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("More actions")
            }
        }
    }
}
