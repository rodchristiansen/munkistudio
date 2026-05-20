import SwiftUI
import Core

/// Promotion history — git commits whose subject begins with "Promoter".
/// Each entry expands inline into one sub-row per touched pkginfo with
/// its `before → after` catalog transition, so users can scan exactly
/// what was promoted from where to where.
struct PromoterHistorySection: View {
    let entries: [PromotionHistoryEntry]
    let hiddenCatalogs: Set<String>
    /// Shared with the other Promoter columns — picking a delta
    /// here clears any selection in Imports or Upcoming.
    @Binding var selectedRowID: String?
    /// Wired to double-click on a per-pkginfo delta row → open in
    /// Packages tab. The commit-level row stays informational.
    var onOpenPackage: ((String) -> Void)? = nil

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
                            selectedRowID: $selectedRowID,
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
            selectedRowID = id
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
    @Binding var selectedRowID: String?
    /// `(deltaSelectionID, deltaPkgName) -> Void` — bubbled to the
    /// section so the timing-based double-click handler sees every
    /// click across all commits in one place.
    let onTap: (String, String) -> Void

    /// Globally unique selection ID for a delta — namespaced by
    /// section ("history::"), commit hash, and the delta's own id
    /// (its pkginfo URL) so the same package across two commits or
    /// across columns can never collide.
    private func selectionID(for delta: PromotionDelta) -> String {
        "history::" + commitHash + "::" + delta.id
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
                            isSelected: selectedRowID == id,
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

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Color.clear.frame(width: 26)
            Text(delta.pkgName)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
            if let version = delta.version {
                Text(version)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            // Catalog transitions used to render here. Dropped on
            // purpose — every promotion follows the same fixed
            // Development → Testing → Staging → Production flow,
            // so spelling the source / target sets out per row was
            // noise that also wrapped badly in narrow columns.
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
}
