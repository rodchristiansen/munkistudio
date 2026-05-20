import SwiftUI
import Core

/// Upcoming promotions card — every pkginfo currently sitting in some
/// rule's source-catalog set, with per-row actions.
struct PromoterUpcomingSection: View {
    let candidates: [PromotionCandidate]
    let busyURL: URL?
    let onPromote: (PromotionCandidate) -> Void
    let onDefer: (PromotionCandidate) -> Void

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
                            onPromote: { onPromote(candidate) },
                            onDefer: { onDefer(candidate) }
                        )
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

    private var emptyState: some View {
        HStack {
            Text("No pkginfos match any current promoter rule.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(14)
    }
}

private struct PromoterCandidateRow: View {
    let candidate: PromotionCandidate
    let busy: Bool
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
        candidate.currentCatalogs.joined(separator: ",") + " → " + candidate.targetCatalogs.joined(separator: ",")
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
                Button(candidate.isEligible() ? "Approve" : "Promote Early", action: onPromote)
                    .buttonStyle(.borderedProminent)
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
