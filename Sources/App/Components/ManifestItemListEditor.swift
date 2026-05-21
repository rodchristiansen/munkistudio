import SwiftUI
import Core

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
    let kind: Kind
    @Binding var manifest: Manifest
    /// Valid package names available in the repo. The add menu only
    /// lists these — free-text entry is intentionally not supported so
    /// users can't introduce typos that resolve to nothing at runtime.
    let availableNames: [String]
    @ScaledMetric(relativeTo: .caption) private var conditionalColumnWidth: CGFloat = 200

    enum Kind {
        case managedInstalls, managedUninstalls, managedUpdates
        case optionalInstalls, featuredItems
        /// `default_installs` only lives at the manifest top level
        /// (Munki doesn't recognise it inside conditional_items), so
        /// the per-row conditional picker stays hidden for this kind.
        case defaultInstalls
    }

    /// True when the manifest has at least one conditional_items entry
    /// AND this kind can be conditional. `default_installs` is only
    /// valid at the manifest top level, so the picker stays hidden
    /// even when the manifest has conditions defined.
    private var conditionsExist: Bool {
        if case .defaultInstalls = kind { return false }
        return !(manifest.conditionalItems?.isEmpty ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if conditionsExist { header }
            ForEach(entries) { entry in
                ManifestItemRow(
                    entry: entry,
                    conditionOptions: conditionOptions,
                    showsConditionalPicker: conditionsExist,
                    onRemove: { remove(entry) },
                    onMoveTo: { newConditionPath in move(entry, to: newConditionPath) }
                )
                .draggable(entry.id) {
                    Text(entry.name)
                        .padding(6)
                        .background(.regularMaterial, in: .rect(cornerRadius: 6))
                }
                .dropDestination(for: String.self) { dropped, _ in
                    guard let id = dropped.first,
                          let source = entries.first(where: { $0.id == id }),
                          source.id != entry.id else { return false }
                    reorder(source, before: entry)
                    return true
                }
            }
            addRow
        }
    }

    // MARK: Layout

    /// Column header — only shown when a conditional picker column is
    /// present. The list's title is supplied by the enclosing card.
    private var header: some View {
        HStack {
            Spacer()
            Text("Conditional")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: conditionalColumnWidth, alignment: .leading)
            // spacer column to align with delete button
            Color.clear.frame(width: 24)
        }
    }

    private var addRow: some View {
        // Search-first add: a Menu over a thousand packages is
        // unusable. The popover lets the user type to filter and hit
        // Return to pick the first match.
        SearchableAddPicker(
            placeholder: "Add package",
            availableNames: addableNames,
            onAdd: { add($0) }
        )
    }

    /// Names not already present anywhere in this list (top-level or
    /// inside a conditional). Prevents duplicate-add UI noise.
    private var addableNames: [String] {
        let existing = Set(entries.map(\.name))
        return availableNames.filter { !existing.contains($0) }
    }

    private func add(_ name: String) {
        var current = manifestArray ?? []
        guard !current.contains(name) else { return }
        current.append(name)
        setManifestArray(current)
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
        case .defaultInstalls: manifest.defaultInstalls
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
        case .defaultInstalls: manifest.defaultInstalls = normalized
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
        // default_installs can't be nested inside conditional_items
        // in Munki — return nil so the editor never tries to read it.
        case .defaultInstalls: nil
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
        case .defaultInstalls: return // no-op: default_installs is top-level only
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
        // `.top` alignment + lineLimit(2) on the menu label lets the row
        // grow taller when the selected condition is too long for one
        // line; the picker is capped to ~50% of the row width so it can't
        // shove the package name off-screen.
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(entry.name)
                .lineLimit(1)
            Spacer(minLength: 8)
            if showsConditionalPicker {
                conditionalMenu
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
        .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 6))
    }

    private var conditionalMenu: some View {
        Menu {
            ForEach(conditionOptions, id: \.id) { option in
                Button(option.menuLabel) { onMoveTo(option.path) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selectedLabel)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .truncationMode(.tail)
                    .foregroundStyle(selectedLabel.isEmpty ? .tertiary : .primary)
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 360, alignment: .trailing)
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel("Conditional")
    }

    /// Empty string when no condition is selected — the dropdown stays
    /// clickable but doesn't display a placeholder word like "Always".
    private var selectedLabel: String {
        guard let path = entry.conditionPath else { return "" }
        return conditionOptions.first { $0.path == path }?.label ?? ""
    }
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

    /// What to show inside the dropdown menu. The "no condition" option
    /// needs a visible placeholder there so the user can pick it; the
    /// `label` stays empty so the picker's resting state shows nothing.
    var menuLabel: String {
        label.isEmpty ? "—" : label
    }

    /// "No conditional" — rendered as an empty menu label so the
    /// dropdown shows nothing when an item lives at the top level.
    static let top = ConditionOption(path: nil, label: "")

    static func condition(index: Int, source: String) -> ConditionOption {
        let trimmed = source.isEmpty ? "(empty)" : source
        return ConditionOption(
            path: .condition(index: index, source: source),
            label: "If: \(trimmed)"
        )
    }
}
