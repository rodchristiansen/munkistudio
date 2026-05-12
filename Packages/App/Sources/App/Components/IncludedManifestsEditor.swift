import SwiftUI
import UniformTypeIdentifiers

/// Row-based editor for `included_manifests`. Mirrors the
/// ``ManifestItemListEditor`` shape but without a conditional dropdown:
/// included-manifests inherit their parent's conditional gating, so a
/// per-row picker would be misleading.
struct IncludedManifestsEditor: View {
    @Binding var values: [String]
    @State private var pending: String = ""
    @FocusState private var addFocused: Bool

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
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                TextField("Add manifest path", text: $pending)
                    .textFieldStyle(.plain)
                    .focused($addFocused)
                    .onSubmit(commit)
                Button("Add", action: commit)
                    .disabled(pending.trimmingCharacters(in: .whitespaces).isEmpty)
                    .controlSize(.small)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
        }
    }

    private func commit() {
        let value = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !values.contains(value) else { return }
        values.append(value)
        pending = ""
        addFocused = true
    }
}

private struct IncludedManifestRow: View {
    let name: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .frame(width: 14)
                .accessibilityHidden(true)
            Image(systemName: "doc.text")
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
        .background(.regularMaterial.opacity(0.6), in: .rect(cornerRadius: 6))
    }
}

private struct ReorderDelegate: DropDelegate {
    let targetIndex: Int
    @Binding var values: [String]

    func dropEntered(info: DropInfo) {
        guard let provider = info.itemProviders(for: [.plainText]).first else { return }
        _ = provider.loadObject(ofClass: NSString.self) { value, _ in
            guard let name = value as? String,
                  let sourceIndex = values.firstIndex(of: name),
                  sourceIndex != targetIndex else { return }
            Task { @MainActor in
                values.remove(at: sourceIndex)
                let insertion = targetIndex > sourceIndex ? targetIndex - 1 : targetIndex
                values.insert(name, at: insertion)
            }
        }
    }

    func performDrop(info: DropInfo) -> Bool { true }
}
