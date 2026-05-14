import SwiftUI
import Core

/// Modal "Condition" dialog — mirrors CimianAdmin's predicate editor.
///
/// Two tabs:
/// - **Predicate Editor**: structured rows of `key OP value` clauses joined
///   by All/Any (AND/OR), with - and + buttons to add/remove rows.
/// - **Custom**: raw NSPredicate string for the edge cases (NOT-wrapped,
///   nested groups, BETWEEN, etc.) the structured editor can't express.
///
/// The two views share the same `Binding<String>` source so flipping
/// between tabs always reflects the latest committed expression. Switching
/// to Custom always wins (raw text is the source of truth on save) — when
/// we re-enter Predicate Editor we re-parse and either populate or drop to
/// a blank canvas.
struct ConditionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var source: String

    @State private var draft: String
    @State private var clauses: [PredicateClause]
    @State private var joiner: PredicateModel.Compound.Kind
    @State private var mode: Mode

    enum Mode: String, CaseIterable, Identifiable {
        case structured = "Predicate Editor"
        case raw = "Custom"
        var id: String { rawValue }
    }

    init(source: Binding<String>) {
        self._source = source
        let initial = source.wrappedValue
        self._draft = State(initialValue: initial)
        let parsed = PredicateParser.parse(initial)
        let (initialClauses, initialJoiner) = ConditionSheet.unpack(parsed)
        self._clauses = State(initialValue: initialClauses)
        self._joiner = State(initialValue: initialJoiner)
        // If the expression couldn't be structured, start on the Custom
        // tab so the user sees their raw text instead of an empty form.
        let canStructure = !initialClauses.isEmpty || initial.isEmpty
        self._mode = State(initialValue: canStructure ? .structured : .raw)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            Group {
                switch mode {
                case .structured: structuredEditor
                case .raw: rawEditor
                }
            }
            .padding(16)
            Divider()
            footer
        }
        .frame(minWidth: 620, minHeight: 360)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Condition")
                .font(.title3.bold())
            Spacer()
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 280)
            .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var structuredEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Picker("", selection: $joiner) {
                    Text("All").tag(PredicateModel.Compound.Kind.and)
                    Text("Any").tag(PredicateModel.Compound.Kind.or)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 90)
                Text("of the following are true")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            VStack(spacing: 6) {
                ForEach(Array(clauses.enumerated()), id: \.offset) { index, _ in
                    ClauseRow(
                        clause: $clauses[index],
                        canRemove: clauses.count > 1,
                        onRemove: { removeClause(at: index) },
                        onAdd: { addClause(after: index) }
                    )
                }
            }
            if clauses.isEmpty {
                Button {
                    clauses.append(PredicateClause())
                } label: {
                    Label("Add clause", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }
            Spacer(minLength: 0)
        }
    }

    private var rawEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NSPredicate expression")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextEditor(text: $draft)
                .font(.system(.body, design: .monospaced))
                .padding(6)
                .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 6))
                .frame(minHeight: 140)
            Text("Examples: `arch == \"arm64\"`, `os_vers BEGINSWITH \"14.\"`, `\"Production\" IN catalogs`")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button("OK") {
                commit()
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func addClause(after index: Int) {
        clauses.insert(PredicateClause(), at: index + 1)
    }

    private func removeClause(at index: Int) {
        guard clauses.indices.contains(index), clauses.count > 1 else { return }
        clauses.remove(at: index)
    }

    /// Build the canonical predicate string from the active tab and write
    /// it back to the bound source.
    private func commit() {
        switch mode {
        case .raw:
            source = draft
        case .structured:
            source = ConditionSheet.serialize(clauses: clauses, joiner: joiner)
        }
    }

    // MARK: Parsing / serializing

    private static func unpack(_ model: PredicateModel) -> ([PredicateClause], PredicateModel.Compound.Kind) {
        switch model {
        case .comparison(let comparison):
            return ([PredicateClause(from: comparison)], .and)
        case .compound(let compound):
            let clauses = compound.children.compactMap { child -> PredicateClause? in
                if case .comparison(let comparison) = child {
                    return PredicateClause(from: comparison)
                }
                return nil
            }
            if clauses.count == compound.children.count {
                return (clauses, compound.kind)
            }
            return ([], .and)
        case .not, .raw:
            return ([], .and)
        }
    }

    static func serialize(clauses: [PredicateClause], joiner: PredicateModel.Compound.Kind) -> String {
        let comparisons = clauses.compactMap { $0.asComparison() }
        guard !comparisons.isEmpty else { return "" }
        if comparisons.count == 1 {
            return PredicateSerializer.serialize(.comparison(comparisons[0]))
        }
        let model = PredicateModel.compound(.init(
            kind: joiner,
            children: comparisons.map { PredicateModel.comparison($0) }
        ))
        return PredicateSerializer.serialize(model)
    }
}

/// A single editable clause used by both the modal and the inline summary.
struct PredicateClause: Hashable {
    var key: String = "machine_type"
    var op: PredicateModel.Operator = .equal
    var value: String = ""

    static let knownKeys: [String] = [
        "arch", "machine_type", "machine_model", "hostname",
        "os_vers", "os_vers_major", "os_vers_minor",
        "ipv4_address", "ipv6_address",
        "console_user", "date", "munki_version",
        "catalogs",
    ]

    init() {}

    init(from comparison: PredicateModel.Comparison) {
        self.key = comparison.leftKey
        self.op = comparison.op
        self.value = PredicateClause.unwrap(comparison.rightValue)
    }

    func asComparison() -> PredicateModel.Comparison? {
        guard !key.isEmpty else { return nil }
        return PredicateModel.Comparison(
            leftKey: key,
            op: op,
            rightValue: .string(value),
            modifiers: []
        )
    }

    static func unwrap(_ value: PredicateModel.Value) -> String {
        switch value {
        case .string(let s): s
        case .number(let n): String(n)
        case .bool(let b): b ? "TRUE" : "FALSE"
        case .identifier(let s): s
        case .list: ""
        }
    }
}

private struct ClauseRow: View {
    @Binding var clause: PredicateClause
    let canRemove: Bool
    let onRemove: () -> Void
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            keyControl
            Picker("", selection: $clause.op) {
                ForEach(PredicateModel.Operator.allCases, id: \.rawValue) { op in
                    Text(op.rawValue).tag(op)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 110)
            TextField("value", text: $clause.value)
                .textFieldStyle(.roundedBorder)
            Button(action: onRemove) {
                Image(systemName: "minus")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!canRemove)
            .help("Remove clause")
            Button(action: onAdd) {
                Image(systemName: "plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Add clause")
        }
    }

    private var keyControl: some View {
        HStack(spacing: 4) {
            Menu {
                ForEach(PredicateClause.knownKeys, id: \.self) { key in
                    Button(key) { clause.key = key }
                }
                Divider()
                Button("Custom…") { clause.key = "" }
            } label: {
                Image(systemName: "chevron.down.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            TextField("key", text: $clause.key)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 140)
        }
    }
}
