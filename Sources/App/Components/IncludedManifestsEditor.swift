import SwiftUI

/// Row-based editor for `included_manifests`. Mirrors the
/// ``ManifestItemListEditor`` shape but without a conditional dropdown:
/// included-manifests inherit their parent's conditional gating, so a
/// per-row picker would be misleading.
struct IncludedManifestsEditor: View {
    @Binding var values: [String]
    /// Valid manifest paths in the repo. The add menu only lists these
    /// — typed entry is intentionally not supported.
    let availableNames: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(values.enumerated()), id: \.element) { index, name in
                IncludedManifestRow(
                    name: name,
                    onRemove: { values.remove(at: index) }
                )
                .draggable(name)
                .dropDestination(for: String.self) { dropped, _ in
                    reorder(dropped: dropped, targetIndex: index)
                }
            }
            addRow
        }
    }

    private var addRow: some View {
        SearchableAddPicker(
            placeholder: "Add manifest",
            availableNames: addableNames,
            onAdd: { add($0) }
        )
    }

    private var addableNames: [String] {
        let existing = Set(values)
        return availableNames.filter { !existing.contains($0) }
    }

    private func add(_ name: String) {
        guard !values.contains(name) else { return }
        values.append(name)
    }

    /// Drop the dragged name(s) at `targetIndex`. Plain reorder when
    /// the dragged value is already in the list; ignored when it isn't
    /// — typed entry happens through the add-row picker, not drops.
    @discardableResult
    private func reorder(dropped: [String], targetIndex: Int) -> Bool {
        guard let name = dropped.first,
              let sourceIndex = values.firstIndex(of: name),
              sourceIndex != targetIndex else { return false }
        values.remove(at: sourceIndex)
        let insertion = targetIndex > sourceIndex ? targetIndex - 1 : targetIndex
        values.insert(name, at: min(insertion, values.count))
        return true
    }
}

private struct IncludedManifestRow: View {
    let name: String
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .frame(width: 14)
                .accessibilityHidden(true)
            Image(systemName: "list.bullet.rectangle")
                .foregroundStyle(.secondary)
                .imageScale(.small)
                .accessibilityHidden(true)
            Text(name).lineLimit(1)
            Spacer()
            Button(role: .destructive, action: onRemove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .frame(width: 24)
            .accessibilityLabel("Remove included manifest \(name)")
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 6))
    }
}

