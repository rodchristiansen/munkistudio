import SwiftUI
import UniformTypeIdentifiers

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
                .onDrag {
                    NSItemProvider(object: name as NSString)
                }
                .onDrop(
                    of: [.plainText],
                    delegate: ReorderDelegate(targetIndex: index, values: $values)
                )
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

private struct ReorderDelegate: DropDelegate {
    let targetIndex: Int
    @Binding var values: [String]

    func dropEntered(info: DropInfo) {
        guard let provider = info.itemProviders(for: [.plainText]).first else { return }
        let target = targetIndex
        _ = provider.loadObject(ofClass: NSString.self) { [$values] value, _ in
            guard let name = value as? String else { return }
            Task { @MainActor in
                guard let sourceIndex = $values.wrappedValue.firstIndex(of: name),
                      sourceIndex != target else { return }
                $values.wrappedValue.remove(at: sourceIndex)
                let insertion = target > sourceIndex ? target - 1 : target
                $values.wrappedValue.insert(name, at: insertion)
            }
        }
    }

    func performDrop(info: DropInfo) -> Bool { true }
}
