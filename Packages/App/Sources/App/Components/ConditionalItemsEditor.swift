import SwiftUI
import Core

/// Editor for a manifest's `conditional_items[]` array. Each entry is one
/// NSPredicate string plus four package lists. The PredicateBuilder
/// component handles structured editing for the common comparison shapes;
/// the editor here just composes that with the install-list ChipFields.
struct ConditionalItemsEditor: View {
    @Binding var items: [ConditionalItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, _ in
                ConditionalItemRow(item: $items[index]) {
                    items.remove(at: index)
                }
            }
            Button {
                items.append(ConditionalItem(condition: ""))
            } label: {
                Label("Add condition", systemImage: "plus")
            }
        }
    }
}

private struct ConditionalItemRow: View {
    @Binding var item: ConditionalItem
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                PredicateBuilder(source: $item.condition)
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
            }
            ChipField(values: bindArray(\.managedInstalls), placeholder: "Managed installs")
            ChipField(values: bindArray(\.managedUninstalls), placeholder: "Managed uninstalls")
            ChipField(values: bindArray(\.optionalInstalls), placeholder: "Optional installs")
        }
        .padding(12)
        .background(.regularMaterial, in: .rect(cornerRadius: 8))
    }

    private func bindArray(_ keyPath: WritableKeyPath<ConditionalItem, [String]?>) -> Binding<[String]> {
        Binding(
            get: { item[keyPath: keyPath] ?? [] },
            set: { item[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }
}
