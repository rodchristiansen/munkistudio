import SwiftUI
import Core

/// Outline view of pkginfo records grouped by category. Folder rows show
/// a chevron, a category icon, and a count; leaf rows show package name
/// and version (no format badge — Rod's feedback was that per-row format
/// labels are visual noise).
struct PackageTreeList: View {
    @Environment(RepositoryStore.self) private var store
    let records: [PkginfoRecord]

    var body: some View {
        @Bindable var bindableStore = store
        List(selection: $bindableStore.selectedItemID) {
            ForEach(nodes, id: \.id) { node in
                DisclosureGroup(isExpanded: expansionBinding(for: node)) {
                    ForEach(node.records, id: \.id) { record in
                        PackageRow(record: record).tag(AnyHashable(record.id))
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        Text(node.category).bold()
                        Text("\(node.records.count)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
            }
        }
    }

    private var nodes: [CategoryNode] {
        let grouped = Dictionary(grouping: records) { record in
            (record.pkginfo.category?.trimmingCharacters(in: .whitespaces).nilIfEmpty) ?? "Uncategorized"
        }
        return grouped
            .map { CategoryNode(category: $0.key, records: $0.value.sorted { $0.pkginfo.name < $1.pkginfo.name }) }
            .sorted { $0.category.localizedCaseInsensitiveCompare($1.category) == .orderedAscending }
    }

    private func expansionBinding(for node: CategoryNode) -> Binding<Bool> {
        Binding(
            get: { store.expandedCategories.contains(node.category) },
            set: { isExpanded in
                if isExpanded {
                    store.expandedCategories.insert(node.category)
                } else {
                    store.expandedCategories.remove(node.category)
                }
            }
        )
    }
}

struct PackageRow: View {
    let record: PkginfoRecord

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "shippingbox")
                .foregroundStyle(.secondary)
                .imageScale(.small)
            Text(record.pkginfo.name)
            if let version = record.pkginfo.version {
                Text(version)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
    }
}

struct CategoryNode: Identifiable {
    var category: String
    var records: [PkginfoRecord]
    var id: String { category }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
