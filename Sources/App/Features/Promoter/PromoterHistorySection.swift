import SwiftUI
import Core

/// Promotion history — git commits whose subject begins with "Promoter".
/// Each entry expands inline into one sub-row per touched pkginfo with
/// its `before → after` catalog transition, so users can scan exactly
/// what was promoted from where to where.
struct PromoterHistorySection: View {
    let entries: [PromotionHistoryEntry]
    let hiddenCatalogs: Set<String>
    /// Wired to double-click on a per-pkginfo delta row → open in
    /// Packages tab. The commit-level row stays informational.
    var onOpenPackage: ((String) -> Void)? = nil

    /// Selection lives at the section level — delta rows across all
    /// commits share one selection so single-click feedback feels
    /// natural ("pick a delta, double-click to open").
    @State private var selectedDeltaID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader
            VStack(spacing: 0) {
                if entries.isEmpty {
                    emptyState
                } else {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        HistoryRow(
                            entry: entry,
                            hiddenCatalogs: hiddenCatalogs,
                            selectedDeltaID: $selectedDeltaID,
                            onOpenPackage: onOpenPackage
                        )
                        if index < entries.count - 1 { Divider() }
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
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.tint)
            Text("Promotion History").font(.headline)
            Text("\(entries.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.bottom, 8)
    }

    private var emptyState: some View {
        HStack {
            Text("No \"Promoter:\" commits in this repository's git history.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(14)
    }
}

private struct HistoryRow: View {
    let entry: PromotionHistoryEntry
    let hiddenCatalogs: Set<String>
    @Binding var selectedDeltaID: String?
    var onOpenPackage: ((String) -> Void)? = nil

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "arrow.up.forward")
                    .foregroundStyle(.green)
                    .imageScale(.small)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.subject)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text("\(entry.deltas.count) file\(entry.deltas.count == 1 ? "" : "s") changed")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Self.dateFormatter.string(from: entry.date))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    // .textSelection intentionally omitted so the
                    // commit-hash text doesn't swallow double-clicks
                    // before the delta rows below get a chance.
                    Text(String(entry.commitHash.prefix(7)))
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
            if !entry.deltas.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(entry.deltas.prefix(8)) { delta in
                        DeltaRow(
                            delta: delta,
                            hiddenCatalogs: hiddenCatalogs,
                            isSelected: selectedDeltaID == delta.id,
                            onSelect: { selectedDeltaID = delta.id },
                            onOpenPackage: { onOpenPackage?(delta.pkgName) }
                        )
                    }
                    if entry.deltas.count > 8 {
                        Text("…and \(entry.deltas.count - 8) more")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 32)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct DeltaRow: View {
    let delta: PromotionDelta
    let hiddenCatalogs: Set<String>
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpenPackage: () -> Void

    private var before: [String] {
        filteringHidden(delta.before, hidden: hiddenCatalogs)
    }

    private var after: [String] {
        filteringHidden(delta.after, hidden: hiddenCatalogs)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Color.clear.frame(width: 26)
            HStack(spacing: 4) {
                Text(delta.pkgName)
                    .font(.caption.weight(.medium))
                if let version = delta.version {
                    Text(version)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Text(transitionText)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .contentShape(.rect)
        .onTapGesture(count: 2, perform: onOpenPackage)
        .onTapGesture(count: 1, perform: onSelect)
    }

    /// Render the transition. `[]` on either side is omitted gracefully —
    /// an added file shows as `→ Testing,Staging` and a deleted file
    /// shows as `Testing,Staging →` without misleading empty arrows.
    private var transitionText: String {
        let left = before.isEmpty ? "" : before.joined(separator: ",")
        let right = after.isEmpty ? "" : after.joined(separator: ",")
        if left.isEmpty && right.isEmpty {
            return ""
        }
        if left == right {
            return "(metadata only)"
        }
        return "(\(left) → \(right))"
    }
}
