import SwiftUI
import Core

/// Recent AutoPkg imports — read from git commits whose subject begins
/// with "AutoPkg import". One row per touched pkginfo file.
struct PromoterImportsSection: View {
    let imports: [AutoPkgImport]
    let hiddenCatalogs: Set<String>
    /// Optional row-tap handler. Wired to "double-click → jump to
    /// Packages detail" when set; nil leaves the rows display-only.
    var onOpenPackage: ((String) -> Void)? = nil

    @State private var selectedRowID: String?
    /// Tracks the most recent click for double-tap detection — single
    /// vs. double click is resolved by time delta rather than two
    /// chained `.onTapGesture` modifiers, which compose unreliably
    /// and were dropping double-clicks in practice.
    @State private var lastTapID: String?
    @State private var lastTapAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader
            VStack(spacing: 0) {
                if imports.isEmpty {
                    emptyState
                } else {
                    ForEach(Array(imports.enumerated()), id: \.element.id) { index, entry in
                        ImportRow(
                            entry: entry,
                            hiddenCatalogs: hiddenCatalogs,
                            isSelected: selectedRowID == entry.id,
                            onTap: { handleTap(entry: entry) }
                        )
                        if index < imports.count - 1 { Divider() }
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
            Image(systemName: "square.and.arrow.down")
                .foregroundStyle(.tint)
            Text("Recent AutoPkg Imports").font(.headline)
            Text("\(imports.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.bottom, 8)
    }

    private var emptyState: some View {
        HStack {
            Text("No \"AutoPkg import\" commits in this repository's git history.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(14)
    }

    /// Single tap handler that resolves to either select or open
    /// based on whether the previous click was on the same row
    /// within macOS's standard double-click interval (0.4s).
    private func handleTap(entry: AutoPkgImport) {
        let now = Date()
        if lastTapID == entry.id, let last = lastTapAt, now.timeIntervalSince(last) < 0.4 {
            onOpenPackage?(entry.pkgName)
            lastTapID = nil
            lastTapAt = nil
        } else {
            selectedRowID = entry.id
            lastTapID = entry.id
            lastTapAt = now
        }
    }
}

private struct ImportRow: View {
    let entry: AutoPkgImport
    let hiddenCatalogs: Set<String>
    let isSelected: Bool
    let onTap: () -> Void

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private var visibleCatalogs: [String] {
        filteringHidden(entry.catalogs, hidden: hiddenCatalogs)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "shippingbox.fill")
                .foregroundStyle(.indigo)
                .imageScale(.small)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.pkgName).font(.callout.weight(.medium))
                    if let version = entry.version {
                        Text(version).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                if !visibleCatalogs.isEmpty {
                    Text(visibleCatalogs.joined(separator: ", "))
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Self.dateFormatter.string(from: entry.date))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                // .textSelection intentionally omitted — it captures
                // double-clicks for word selection and would prevent
                // the row-level onTapGesture from firing.
                Text(String(entry.commitHash.prefix(7)))
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .contentShape(.rect)
        .onTapGesture(perform: onTap)
    }
}
