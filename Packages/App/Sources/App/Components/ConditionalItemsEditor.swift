import SwiftUI
import Core

/// Editor for a manifest's `conditional_items[]` array.
///
/// Each entry has one NSPredicate string plus up to four package lists.
/// The condition itself is presented as a read-only chip row with Edit /
/// trash buttons; clicking Edit opens a ``ConditionSheet`` modal that
/// mirrors CimianAdmin's predicate dialog.
struct ConditionalItemsEditor: View {
    @Binding var items: [ConditionalItem]
    @State private var editing: EditingRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, _ in
                ConditionalItemRow(
                    item: $items[index],
                    onEditCondition: { editing = EditingRequest(index: index) },
                    onRemove: { items.remove(at: index) }
                )
            }
            Button {
                let new = ConditionalItem(condition: "")
                items.append(new)
                editing = EditingRequest(index: items.count - 1)
            } label: {
                Label("Add condition…", systemImage: "plus")
            }
        }
        .sheet(item: $editing) { request in
            ConditionSheet(source: bindingForCondition(at: request.index))
        }
    }

    private func bindingForCondition(at index: Int) -> Binding<String> {
        Binding(
            get: { items.indices.contains(index) ? items[index].condition : "" },
            set: { newValue in
                guard items.indices.contains(index) else { return }
                items[index].condition = newValue
            }
        )
    }

    private struct EditingRequest: Identifiable {
        let index: Int
        var id: Int { index }
    }
}

private struct ConditionalItemRow: View {
    @Binding var item: ConditionalItem
    let onEditCondition: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("condition")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.18), in: .capsule)
            Text(item.condition.isEmpty ? "(empty)" : item.condition)
                .font(.system(.body, design: .monospaced))
                .lineLimit(2)
                .foregroundStyle(item.condition.isEmpty ? .tertiary : .primary)
            Spacer()
            Button("Edit", action: onEditCondition)
                .controlSize(.small)
            Button(role: .destructive, action: onRemove) {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove condition")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 8))
    }
}
