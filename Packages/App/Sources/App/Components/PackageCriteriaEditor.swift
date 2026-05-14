import SwiftUI
import Core

/// Predicate builder for packages — mirrors ``ManifestCriteriaEditor`` so
/// both list panes feel identical from the user's side.
struct PackageCriteriaEditor: View {
    @Binding var group: PackageCriteriaGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Picker("", selection: $group.quantifier) {
                    ForEach(PackageCriteriaGroup.Quantifier.allCases, id: \.self) { q in
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
                Text("No rules yet — add one to filter the package list.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ForEach($group.criteria) { $criterion in
                    PackageCriterionRow(criterion: $criterion) {
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
        let attribute: PackageAttribute = .name
        let op = attribute.allowedOperators.first ?? .contains
        group.criteria.append(PackageCriterion(attribute: attribute, op: op, value: ""))
    }
}

private struct PackageCriterionRow: View {
    @Binding var criterion: PackageCriterion
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Picker("", selection: $criterion.attribute) {
                ForEach(PackageAttribute.allCases) { attr in
                    Text(attr.label).tag(attr)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(minWidth: 200, alignment: .leading)
            .fixedSize()
            .onChange(of: criterion.attribute) { _, newAttr in
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
