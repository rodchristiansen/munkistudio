import SwiftUI
import Core

/// Predicate builder for manifests.
///
/// Header row picks the `All | Any` quantifier; each subsequent row is
/// `[Attribute] [Operator] [Value]` with an `x` to remove and a `+` on
/// the last row to add. The component is purely an editor — running
/// the predicate against the record list is the caller's job, which
/// keeps this view reusable for both the inline filter and a future
/// "Smart Groups" sidebar destination.
struct ManifestCriteriaEditor: View {
    @Binding var group: ManifestCriteriaGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Picker("", selection: $group.quantifier) {
                    ForEach(ManifestCriteriaGroup.Quantifier.allCases, id: \.self) { q in
                        Text(q.label).tag(q)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                Text("of the following are true")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    addCriterion()
                } label: {
                    Label("Add rule", systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                if !group.criteria.isEmpty {
                    Button {
                        group.criteria.removeAll()
                    } label: {
                        Label("Clear", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
            if group.criteria.isEmpty {
                Text("No rules yet — add one to filter the manifest list.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ForEach($group.criteria) { $criterion in
                    CriterionRow(criterion: $criterion) {
                        if let index = group.criteria.firstIndex(where: { $0.id == criterion.id }) {
                            group.criteria.remove(at: index)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(.regularMaterial, in: .rect(cornerRadius: 8))
    }

    private func addCriterion() {
        let attribute: ManifestAttribute = .name
        let op = attribute.allowedOperators.first ?? .contains
        group.criteria.append(ManifestCriterion(attribute: attribute, op: op, value: ""))
    }
}

private struct CriterionRow: View {
    @Binding var criterion: ManifestCriterion
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            // Attribute picker — text-search-style menu so the long
            // list stays usable. SwiftUI's plain `Picker` menu handles
            // the 25-item attribute list well enough without a search
            // field; the labels are unique so users scan visually.
            Picker("", selection: $criterion.attribute) {
                ForEach(ManifestAttribute.allCases) { attr in
                    Text(attr.label).tag(attr)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(minWidth: 220, alignment: .leading)
            .fixedSize()
            .onChange(of: criterion.attribute) { _, newAttr in
                // Operators differ per attribute kind. When the user
                // switches from a string attribute to a count one,
                // `contains` is no longer valid — snap to the first
                // allowed op for the new kind.
                if !newAttr.allowedOperators.contains(criterion.op) {
                    criterion.op = newAttr.allowedOperators.first ?? .contains
                }
            }

            Picker("", selection: $criterion.op) {
                ForEach(criterion.attribute.allowedOperators) { op in
                    Text(op.label).tag(op)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()

            TextField(valuePlaceholder, text: $criterion.value)
                .textFieldStyle(.roundedBorder)

            Button {
                onRemove()
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove this rule")
        }
    }

    private var valuePlaceholder: String {
        switch criterion.attribute.kind {
        case .string: "value"
        case .count: "number"
        case .arrayMembership: "item name"
        }
    }
}
