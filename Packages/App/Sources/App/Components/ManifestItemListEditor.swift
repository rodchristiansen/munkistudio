import SwiftUI
import Core
import UniformTypeIdentifiers

/// Row-based editor for a manifest's install lists (managed_installs,
/// managed_uninstalls, managed_updates, optional_installs, featured_items).
///
/// Replaces the chip-cloud pattern. Each entry is a row with:
/// - drag handle on the left (reorders within the list)
/// - package name in the middle
/// - conditional dropdown on the right (binds the item to a `conditional_items`
///   entry — when "Always" is selected the item lives at the top level;
///   otherwise it's moved into the chosen ConditionalItem's matching array.)
/// - delete button on the far right
///
/// Mirrors Cimian's `ContextualChipList` in shape, including the
/// "Conditionals" column header.
struct ManifestItemListEditor: View {
    let title: String
    let kind: Kind
    @Binding var manifest: Manifest

    @State private var newItemName: String = ""
    @FocusState private var addFocused: Bool

    enum Kind {
        case managedInstalls, managedUninstalls, managedUpdates
        case optionalInstalls, featuredItems
    }

    /// True when the manifest has at least one conditional_items entry.
    /// Drives whether each row shows its per-item Conditional dropdown
    /// — there's no choice to make if conditions don't exist yet.
    private var conditionsExist: Bool {
        !(manifest.conditionalItems?.isEmpty ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            ForEach(entries) { entry in
                ManifestItemRow(
                    entry: entry,
                    conditionOptions: conditionOptions,
                    showsConditionalPicker: conditionsExist,
                    onRemove: { remove(entry) },
                    onMoveTo: { newConditionPath in move(entry, to: newConditionPath) }
                )
                .onDrag {
                    NSItemProvider(object: entry.id as NSString)
                } preview: {
                    Text(entry.name).padding(6).background(.regularMaterial, in: .rect(cornerRadius: 6))
                }
                .onDrop(
                    of: [.plainText],
                    delegate: DropReorderDelegate(target: entry, all: entries, perform: reorder)
                )
            }
            addRow
        }
        .padding(8)
        .background(.regularMaterial.opacity(0.4), in: .rect(cornerRadius: 8))
    }

    // MARK: Layout

    private var header: some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            if conditionsExist {
                Text("Conditional")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 200, alignment: .leading)
            }
            // spacer column to align with delete button
            Color.clear.frame(width: 24)
        }
    }

    private var addRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus")
                .foregroundStyle(.tertiary)
            TextField("Add package", text: $newItemName)
                .textFieldStyle(.plain)
                .focused($addFocused)
                .onSubmit { addPending() }
            Button("Add") { addPending() }
                .disabled(newItemName.trimmingCharacters(in: .whitespaces).isEmpty)
                .controlSize(.small)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
    }

    // MARK: Data

    /// Flat view of items: top-level entries first, then one section per
    /// conditional item that has any matching entries.
    private var entries: [Entry] {
        var rows: [Entry] = []
        let topLevel = list(for: nil)
        for name in topLevel {
            rows.append(Entry(conditionPath: nil, name: name))
        }
        for (index, condition) in (manifest.conditionalItems ?? []).enumerated() {
            let cond = ConditionPath.condition(index: index, source: condition.condition)
            for name in list(for: cond) {
                rows.append(Entry(conditionPath: cond, name: name))
            }
        }
        return rows
    }

    private var conditionOptions: [ConditionOption] {
        var options: [ConditionOption] = [.top]
        for (index, condition) in (manifest.conditionalItems ?? []).enumerated() {
            options.append(.condition(index: index, source: condition.condition))
        }
        return options
    }

    private func list(for path: ConditionPath?) -> [String] {
        if let path {
            guard case .condition(let index, _) = path,
                  let conditionals = manifest.conditionalItems,
                  index < conditionals.count else { return [] }
            return arrayInConditional(at: index) ?? []
        }
        return manifestArray ?? []
    }

    // MARK: Mutation

    private func addPending() {
        let value = newItemName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        var current = manifestArray ?? []
        current.append(value)
        setManifestArray(current)
        newItemName = ""
        addFocused = true
    }

    private func remove(_ entry: Entry) {
        switch entry.conditionPath {
        case .none:
            var current = manifestArray ?? []
            current.removeAll { $0 == entry.name }
            setManifestArray(current.isEmpty ? nil : current)
        case .some(.condition(let index, _)):
            guard var conditionals = manifest.conditionalItems, index < conditionals.count else { return }
            var current = arrayInConditional(at: index) ?? []
            current.removeAll { $0 == entry.name }
            setArrayInConditional(at: index, to: current.isEmpty ? nil : current, conditionals: &conditionals)
            manifest.conditionalItems = conditionals.isEmpty ? nil : conditionals
        }
    }

    private func move(_ entry: Entry, to newPath: ConditionPath?) {
        guard entry.conditionPath != newPath else { return }
        remove(entry)
        switch newPath {
        case .none:
            var current = manifestArray ?? []
            current.append(entry.name)
            setManifestArray(current)
        case .some(.condition(let index, _)):
            guard var conditionals = manifest.conditionalItems, index < conditionals.count else { return }
            var current = arrayInConditional(at: index) ?? []
            current.append(entry.name)
            setArrayInConditional(at: index, to: current, conditionals: &conditionals)
            manifest.conditionalItems = conditionals
        }
    }

    private func reorder(_ source: Entry, before target: Entry) {
        guard source.conditionPath == target.conditionPath else { return }
        var current = list(for: source.conditionPath)
        guard let from = current.firstIndex(of: source.name),
              let to = current.firstIndex(of: target.name) else { return }
        current.remove(at: from)
        let insertion = to > from ? to - 1 : to
        current.insert(source.name, at: insertion)

        switch source.conditionPath {
        case .none: setManifestArray(current)
        case .some(.condition(let index, _)):
            guard var conditionals = manifest.conditionalItems, index < conditionals.count else { return }
            setArrayInConditional(at: index, to: current, conditionals: &conditionals)
            manifest.conditionalItems = conditionals
        }
    }

    // MARK: Manifest accessors

    private var manifestArray: [String]? {
        switch kind {
        case .managedInstalls: manifest.managedInstalls
        case .managedUninstalls: manifest.managedUninstalls
        case .managedUpdates: manifest.managedUpdates
        case .optionalInstalls: manifest.optionalInstalls
        case .featuredItems: manifest.featuredItems
        }
    }

    private func setManifestArray(_ value: [String]?) {
        let normalized = (value?.isEmpty == true) ? nil : value
        switch kind {
        case .managedInstalls: manifest.managedInstalls = normalized
        case .managedUninstalls: manifest.managedUninstalls = normalized
        case .managedUpdates: manifest.managedUpdates = normalized
        case .optionalInstalls: manifest.optionalInstalls = normalized
        case .featuredItems: manifest.featuredItems = normalized
        }
    }

    private func arrayInConditional(at index: Int) -> [String]? {
        guard let conditionals = manifest.conditionalItems, index < conditionals.count else { return nil }
        let item = conditionals[index]
        return switch kind {
        case .managedInstalls: item.managedInstalls
        case .managedUninstalls: item.managedUninstalls
        case .managedUpdates: item.managedUpdates
        case .optionalInstalls: item.optionalInstalls
        case .featuredItems: item.featuredItems
        }
    }

    private func setArrayInConditional(
        at index: Int,
        to value: [String]?,
        conditionals: inout [ConditionalItem]
    ) {
        var item = conditionals[index]
        let normalized = (value?.isEmpty == true) ? nil : value
        switch kind {
        case .managedInstalls: item.managedInstalls = normalized
        case .managedUninstalls: item.managedUninstalls = normalized
        case .managedUpdates: item.managedUpdates = normalized
        case .optionalInstalls: item.optionalInstalls = normalized
        case .featuredItems: item.featuredItems = normalized
        }
        conditionals[index] = item
    }
}

// MARK: Row

private struct ManifestItemRow: View {
    let entry: Entry
    let conditionOptions: [ConditionOption]
    let showsConditionalPicker: Bool
    let onRemove: () -> Void
    let onMoveTo: (ConditionPath?) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(entry.name)
                .lineLimit(1)
            Spacer()
            if showsConditionalPicker {
                Picker("Conditional", selection: pickerBinding) {
                    ForEach(conditionOptions, id: \.id) { option in
                        Text(option.label).tag(option.path)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 200)
            }
            Button(role: .destructive, action: onRemove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .frame(width: 24)
            .accessibilityLabel("Remove \(entry.name)")
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(.regularMaterial.opacity(0.6), in: .rect(cornerRadius: 6))
    }

    private var pickerBinding: Binding<ConditionPath?> {
        Binding(get: { entry.conditionPath }, set: { onMoveTo($0) })
    }
}

// MARK: Drop reordering

private struct DropReorderDelegate: DropDelegate {
    let target: Entry
    let all: [Entry]
    let perform: (Entry, Entry) -> Void

    func dropEntered(info: DropInfo) {
        guard let provider = info.itemProviders(for: [.plainText]).first else { return }
        _ = provider.loadObject(ofClass: NSString.self) { value, _ in
            guard let id = value as? String,
                  let source = all.first(where: { $0.id == id }),
                  source.id != target.id else { return }
            Task { @MainActor in perform(source, target) }
        }
    }

    func performDrop(info: DropInfo) -> Bool { true }
}

// MARK: Models

private struct Entry: Identifiable, Hashable {
    let conditionPath: ConditionPath?
    let name: String

    var id: String {
        switch conditionPath {
        case .none: "top|\(name)"
        case .some(let path): "\(path.id)|\(name)"
        }
    }
}

enum ConditionPath: Hashable {
    case condition(index: Int, source: String)

    var id: String {
        switch self {
        case .condition(let index, _): "cond:\(index)"
        }
    }
}

struct ConditionOption: Identifiable {
    let path: ConditionPath?
    let label: String

    var id: String {
        path?.id ?? "top"
    }

    static let top = ConditionOption(path: nil, label: "Always")

    static func condition(index: Int, source: String) -> ConditionOption {
        let trimmed = source.isEmpty ? "(empty)" : source
        return ConditionOption(
            path: .condition(index: index, source: source),
            label: "If: \(trimmed)"
        )
    }
}
