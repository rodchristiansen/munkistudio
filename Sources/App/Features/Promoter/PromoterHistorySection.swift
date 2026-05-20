import SwiftUI
import Core

/// Promotion history — git commits whose subject begins with "Promoter".
/// One row per commit; the affected-file count is the headline number.
struct PromoterHistorySection: View {
    let entries: [PromotionHistoryEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader
            VStack(spacing: 0) {
                if entries.isEmpty {
                    emptyState
                } else {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        HistoryRow(entry: entry)
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

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "arrow.up.forward")
                .foregroundStyle(.green)
                .imageScale(.small)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.subject)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text("\(entry.affected.count) file\(entry.affected.count == 1 ? "" : "s") changed")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Self.dateFormatter.string(from: entry.date))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(String(entry.commitHash.prefix(7)))
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
