import SwiftUI
import Core

/// Structured editor for an NSPredicate condition string.
///
/// Each conditional_items entry has a single condition expression — the
/// shape we model here is a flat list of `key OP value` clauses joined
/// by a single logical operator (AND or OR). That matches what Munki
/// admins actually write in pkginfo files in practice; nested groups
/// fall back to the raw escape hatch.
///
/// Mirrors Cimian's PredicateEditor in the screenshots:
/// - row per clause: key picker, operator picker, value field
/// - top-of-list AND/OR joiner
/// - "+" to add another clause, trash to remove
/// - "Edit raw" toggle to switch to a plain TextField that parses
///   back into the structured view on close.
struct PredicateBuilder: View {
    @Binding var source: String

    @State private var clauses: [Clause] = []
    @State private var joiner: PredicateModel.Compound.Kind = .and
    @State private var rawMode: Bool = false
    @State private var rawDraft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if rawMode {
                rawEditor
            } else {
                structured
            }
        }
        .padding(8)
        .background(.regularMaterial.opacity(0.5), in: .rect(cornerRadius: 6))
        .onAppear { ingest(source) }
        .onChange(of: source) { _, new in
            // Re-ingest if the underlying source changed externally
            // (e.g. switching between conditional items).
            ingest(new)
        }
    }

    // MARK: Layout

    private var header: some View {
        HStack {
            statusIndicator
            if !rawMode {
                Picker("", selection: $joiner) {
                    Text("All of (AND)").tag(PredicateModel.Compound.Kind.and)
                    Text("Any of (OR)").tag(PredicateModel.Compound.Kind.or)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .disabled(clauses.count < 2)
            }
            Spacer()
            Button(rawMode ? "Structured" : "Edit raw") {
                if rawMode {
                    source = rawDraft
                    ingest(rawDraft)
                    rawMode = false
                } else {
                    rawDraft = source
                    rawMode = true
                }
            }
            .controlSize(.small)
        }
    }

    private var statusIndicator: some View {
        Group {
            switch PredicateParser.parse(source) {
            case .raw:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Couldn't parse this expression; it'll be saved verbatim.")
            default:
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .help("Valid NSPredicate expression.")
            }
        }
    }

    private var structured: some View {
        VStack(spacing: 6) {
            ForEach(Array(clauses.enumerated()), id: \.offset) { index, _ in
                ClauseRow(
                    clause: $clauses[index],
                    onRemove: { remove(at: index) }
                ) { commit() }
            }
            HStack {
                Button {
                    clauses.append(Clause())
                    commit()
                } label: {
                    Label("Add clause", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
            }
        }
        .onChange(of: joiner) { _, _ in commit() }
    }

    private var rawEditor: some View {
        TextField("NSPredicate expression", text: $rawDraft, axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .lineLimit(3...10)
    }

    // MARK: Conversion

    /// Pull the source string into structured clauses if possible.
    private func ingest(_ string: String) {
        let model = PredicateParser.parse(string)
        switch model {
        case .raw, .not:
            // Unparseable or NOT-wrapped — keep the source intact but
            // present an empty structured view. The user can still
            // switch to raw to edit.
            clauses = []
        case .comparison(let comparison):
            clauses = [Clause(from: comparison)]
            joiner = .and
        case .compound(let compound):
            joiner = compound.kind
            clauses = compound.children.compactMap { child in
                if case .comparison(let comparison) = child {
                    return Clause(from: comparison)
                }
                return nil
            }
            if clauses.count < compound.children.count {
                // Some children weren't simple comparisons — drop into
                // raw mode so we don't lose data on save.
                clauses = []
            }
        }
    }

    private func remove(at index: Int) {
        clauses.remove(at: index)
        commit()
    }

    /// Serialize current clauses back to the source binding.
    private func commit() {
        let comparisons = clauses.compactMap { $0.asComparison() }
        guard !comparisons.isEmpty else {
            source = ""
            return
        }
        if comparisons.count == 1 {
            source = PredicateSerializer.serialize(.comparison(comparisons[0]))
            return
        }
        let model = PredicateModel.compound(.init(
            kind: joiner,
            children: comparisons.map { PredicateModel.comparison($0) }
        ))
        source = PredicateSerializer.serialize(model)
    }
}

/// A single editable clause: key, operator, value.
struct Clause {
    var key: String = "machine_type"
    var op: PredicateModel.Operator = .equal
    var value: String = ""

    /// Common Munki facts surfaced in the key picker. Custom keys go
    /// through the "Custom…" option which exposes a free-text field.
    static let knownKeys: [String] = [
        "arch", "machine_type", "machine_model", "hostname",
        "os_vers", "os_vers_major", "os_vers_minor",
        "ipv4_address", "ipv6_address",
        "console_user", "date", "munki_version",
    ]

    init() {}

    init(from comparison: PredicateModel.Comparison) {
        self.key = comparison.leftKey
        self.op = comparison.op
        self.value = Clause.unwrap(comparison.rightValue)
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
    @Binding var clause: Clause
    let onRemove: () -> Void
    let onCommit: () -> Void

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
            .frame(width: 100)
            TextField("value", text: $clause.value)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 120)
            Button(role: .destructive, action: onRemove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove clause")
        }
        .onChange(of: clause.key) { _, _ in onCommit() }
        .onChange(of: clause.op) { _, _ in onCommit() }
        .onChange(of: clause.value) { _, _ in onCommit() }
    }

    /// Combo picker — a menu of known keys plus a "Custom…" item that
    /// gives the user a plain text field for free-form keypaths.
    private var keyControl: some View {
        HStack(spacing: 4) {
            Menu {
                ForEach(Clause.knownKeys, id: \.self) { key in
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
