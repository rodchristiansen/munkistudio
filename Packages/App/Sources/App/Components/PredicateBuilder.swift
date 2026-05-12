import SwiftUI
import Core

/// Inline editor for a single NSPredicate condition string. v1 ships as a
/// plain text field with a parse-status indicator; the structured tree
/// view (operator picker, left/right inputs) is a v2 expansion that the
/// existing ``PredicateModel`` can drive.
struct PredicateBuilder: View {
    @Binding var source: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Condition", text: $source)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                statusIndicator
            }
            if let preview = preview {
                Text(preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var parsed: PredicateModel { PredicateParser.parse(source) }

    private var statusIndicator: some View {
        Group {
            switch parsed {
            case .raw:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Couldn't parse this expression; it'll be saved verbatim.")
            default:
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .help("Parses as a valid NSPredicate expression.")
            }
        }
    }

    private var preview: String? {
        switch parsed {
        case .raw: return nil
        case .comparison(let comparison):
            return "\(comparison.leftKey) \(comparison.op.rawValue) …"
        case .compound(let compound):
            return "\(compound.kind.rawValue) of \(compound.children.count) parts"
        case .not:
            return "NOT (…)"
        }
    }
}
