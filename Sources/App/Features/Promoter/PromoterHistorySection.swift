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
    @State private var lastTapID: String?
    @State private var lastTapAt: Date?

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
                            commitHash: entry.commitHash,
                            selectedDeltaID: $selectedDeltaID,
                            onTap: { id, pkgName in handleTap(id: id, pkgName: pkgName) }
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

    /// Timing-based double-click resolution. The history section
    /// owns this rather than each row because deltas can repeat
    /// across commits and the selection ID is composite — easier
    /// to keep all the state in one place.
    private func handleTap(id: String, pkgName: String) {
        let now = Date()
        if lastTapID == id, let last = lastTapAt, now.timeIntervalSince(last) < 0.4 {
            onOpenPackage?(pkgName)
            lastTapID = nil
            lastTapAt = nil
        } else {
            selectedDeltaID = id
            lastTapID = id
            lastTapAt = now
        }
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
    /// Used to namespace delta selection IDs per commit — the same
    /// pkginfo can appear in multiple commits and would otherwise
    /// share a selection ID, lighting up both at once.
    let commitHash: String
    @Binding var selectedDeltaID: String?
    /// `(deltaSelectionID, deltaPkgName) -> Void` — bubbled to the
    /// section so the timing-based double-click handler sees every
    /// click across all commits in one place.
    let onTap: (String, String) -> Void

    /// Per-commit unique ID for a delta — combines commit hash with
    /// the delta's pkginfo path so the same package across two
    /// commits gets distinct selection IDs.
    private func selectionID(for delta: PromotionDelta) -> String {
        commitHash + "::" + delta.id
    }

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
                        let id = selectionID(for: delta)
                        DeltaRow(
                            delta: delta,
                            hiddenCatalogs: hiddenCatalogs,
                            isSelected: selectedDeltaID == id,
                            onTap: { onTap(id, delta.pkgName) }
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
    let onTap: () -> Void

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
        // Rounded, inset selection — sits cleanly inside the
        // commit's padding without bleeding to the edges.
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.35) : Color.clear, lineWidth: 1)
        )
        .padding(.horizontal, 4)
        .contentShape(.rect)
        .onTapGesture(perform: onTap)
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
